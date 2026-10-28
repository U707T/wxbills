#include "edge_dock.h"

#include <dwmapi.h>
#include <flutter_windows.h>

namespace {

// 老 SDK 里没有这个枚举值（Windows 10 1607 起才有），自己补一个
#ifndef DWMWA_EXTENDED_FRAME_BOUNDS
#define DWMWA_EXTENDED_FRAME_BOUNDS 9
#endif

wxb::Rect ToWxb(const RECT& r) {
  return wxb::Rect{r.left, r.top, r.right, r.bottom};
}

RECT ToRect(const wxb::Rect& r) {
  RECT out{};
  out.left = r.left;
  out.top = r.top;
  out.right = r.right;
  out.bottom = r.bottom;
  return out;
}

int ClampPadding(int value) {
  if (value < 0) return 0;
  if (value > 64) return 64;  // 窗口动画期间 DWM 会给出离谱的中间值
  return value;
}

}  // namespace

EdgeDock::~EdgeDock() { Detach(); }

// ---------------------------------------------------------------- 生命周期

void EdgeDock::Attach(HWND hwnd, bool enabled) {
  hwnd_ = hwnd;
  enabled_ = enabled;
  phase_ = Phase::kNormal;
  topmost_ = false;
  SyncFromWindow();
  if (enabled_) StartIdleTimer();
}

void EdgeDock::Detach() {
  StopAllTimers();
  hwnd_ = nullptr;
  phase_ = Phase::kNormal;
  topmost_ = false;
  dock_ = wxb::DockEdge::kNone;
}

void EdgeDock::SetEnabled(bool enabled) {
  if (enabled_ == enabled) return;
  enabled_ = enabled;
  if (!enabled_) {
    // 关掉时先把窗口放回来：否则窗口停在屏幕外，用户只能从任务栏把它"还原"
    ShowNow();
    StopAllTimers();
    phase_ = Phase::kNormal;
  } else {
    SyncFromWindow();
    StartIdleTimer();
  }
}

void EdgeDock::RestoreFromState(const RECT& rect, bool maximized) {
  if (hwnd_ == nullptr) return;
  UpdateWorkArea();
  UpdateDpiScale();
  const wxb::Rect clamped = wxb::ClampToWork(ToWxb(rect), work_,
                                             Scaled(params_.min_visible));
  rest_ = ToRect(clamped);
  if (clamped.left != rect.left || clamped.top != rect.top) {
    MoveTo(rest_);
  }
  // 停靠方向不单独存：它完全由几何决定，存两份只会有对不上的时候。
  if (maximized) {
    dock_ = wxb::DockEdge::kNone;
  } else {
    RefreshNormalGeometry();
  }
  phase_ = Phase::kNormal;
}

bool EdgeDock::ForegroundCoversWorkArea() const {
  const HWND foreground = GetForegroundWindow();
  if (foreground == nullptr || foreground == hwnd_) return false;
  DWORD pid = 0;
  GetWindowThreadProcessId(foreground, &pid);
  if (pid == GetCurrentProcessId()) return false;  // 自己的窗口不算
  RECT rect{};
  if (!GetWindowRect(foreground, &rect)) return false;
  return wxb::CoversWorkArea(ToWxb(rect), work_);
}

void EdgeDock::SetSuppressed(bool suppressed) {
  if (suppressed_ == suppressed || hwnd_ == nullptr) return;
  suppressed_ = suppressed;
  if (suppressed) {
    // 别人全屏（游戏 / 视频 / 最大化）：连那 4px 也不该留在画面上
    ShowWindow(hwnd_, SW_HIDE);
    return;
  }
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  // 回来时仍然藏好，位置按当前工作区重算（期间可能换了分辨率）
  MoveTo(HiddenRect());
}

void EdgeDock::ShowNow() {
  if (hwnd_ == nullptr) return;
  if (phase_ == Phase::kNormal && !animating() && !suppressed_) return;
  StopAllTimers();
  if (suppressed_) {
    // 被全屏挤走的那次：先让窗口重新可见，否则 move 一个隐藏窗口什么也看不见
    suppressed_ = false;
    ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  }
  if (topmost_) {
    SetWindowPos(hwnd_, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    topmost_ = false;
  }
  phase_ = Phase::kNormal;
  MoveTo(rest_);
  if (enabled_) StartIdleTimer();
}

// ---------------------------------------------------------------- 几何

void EdgeDock::UpdateWorkArea() {
  if (hwnd_ == nullptr) return;
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  const HMONITOR monitor = MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
  if (monitor != nullptr && GetMonitorInfoW(monitor, &info)) {
    work_ = ToWxb(info.rcWork);  // rcWork 已经排除任务栏
    return;
  }
  work_ = wxb::Rect{0, 0, GetSystemMetrics(SM_CXSCREEN),
                    GetSystemMetrics(SM_CYSCREEN)};
}

void EdgeDock::UpdateFramePadding(bool force) {
  if (hwnd_ == nullptr) return;
  // 边框宽度只在 DPI / 显示器变化时才变；tick 里每次都问 DWM 是白花
  if (!force && padding_scale_ == scale_) return;
  padding_scale_ = scale_;

  RECT window{};
  RECT visible{};
  if (!GetWindowRect(hwnd_, &window)) return;
  const HRESULT hr = DwmGetWindowAttribute(hwnd_, DWMWA_EXTENDED_FRAME_BOUNDS,
                                           &visible, sizeof(visible));
  if (FAILED(hr)) {
    // 没有 DWM 合成时外框就是可见框
    pad_ = wxb::FramePadding{0, 0, 0, 0};
    return;
  }
  pad_.left = ClampPadding(visible.left - window.left);
  pad_.top = ClampPadding(visible.top - window.top);
  pad_.right = ClampPadding(window.right - visible.right);
  pad_.bottom = ClampPadding(window.bottom - visible.bottom);
}

void EdgeDock::UpdateDpiScale() {
  if (hwnd_ == nullptr) return;
  const UINT dpi = FlutterDesktopGetDpiForHWND(hwnd_);
  scale_ = dpi > 0 ? static_cast<double>(dpi) / 96.0 : 1.0;
}

int EdgeDock::Scaled(int logical) const {
  if (logical <= 0) return 0;
  return static_cast<int>(static_cast<double>(logical) * scale_ + 0.5);
}

wxb::Rect EdgeDock::VisibleRest() const {
  return wxb::VisibleRect(ToWxb(rest_), pad_);
}

RECT EdgeDock::HiddenRect() const {
  return ToRect(wxb::HiddenRect(ToWxb(rest_), work_, dock_,
                                Scaled(params_.peek), pad_));
}

void EdgeDock::MoveTo(const RECT& rect) {
  if (hwnd_ == nullptr) return;
  // 只挪位置、不改尺寸：尺寸一变 Flutter 就要重排整棵树，滑动必然掉帧。
  SetWindowPos(hwnd_, nullptr, rect.left, rect.top, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS);
}

void EdgeDock::RefreshNormalGeometry() {
  if (hwnd_ == nullptr) return;
  RECT rect{};
  if (!GetWindowRect(hwnd_, &rect)) return;
  if (IsIconic(hwnd_) || IsZoomed(hwnd_)) {
    dock_ = wxb::DockEdge::kNone;
    return;
  }
  UpdateFramePadding(false);
  UpdateDpiScale();
  // kNormal 下 rest_ 就是窗口现在的矩形；夹取只发生在"从 ini 恢复"那一次，
  // 否则每次 tick 都夹一遍会和用户"故意把窗口拖出一半"较劲。
  rest_ = rect;
  // 用"看得见"的矩形判定贴边：外框每边多出约 7px，按外框判会把
  // 离边缘 15px 的窗口也算成贴边。
  dock_ = wxb::ComputeDock(VisibleRest(), work_, Scaled(params_.tolerance));
  // 不贴边就不必轮询：贴边状态由 WM_EXITSIZEMOVE / WM_SIZE 事件驱动。
  // 一个浮在屏幕中间的窗口让进程每秒醒 10 次纯属浪费电。
  if (dock_ == wxb::DockEdge::kNone) {
    StopTimer(&idle_timer_);
  } else {
    StartIdleTimer();
  }
}

void EdgeDock::SyncFromWindow() {
  if (hwnd_ == nullptr) return;
  // 拖动/拉拽过程中不必跟着算：每次 WM_MOVE 都做一遍纯属浪费，松手时会算
  if (in_size_move_) return;
  UpdateWorkArea();
  if (animating()) return;  // 动画中改目标会跳帧

  if (IsIconic(hwnd_)) {
    // 最小化：必须退出隐藏状态。留在屏幕外的话，从任务栏还原出来的是
    // 一个"看不见的窗口"，用户只能再点一次任务栏。顺便停掉轮询省点电。
    if (phase_ != Phase::kNormal) ShowNow();
    StopTimer(&idle_timer_);
    dock_ = wxb::DockEdge::kNone;
    return;
  }

  if (hidden()) {
    // 隐藏期间换了分辨率/插拔显示器：按 rest_ 重算停靠位置，别露出半截
    UpdateDpiScale();
    rest_ = ToRect(wxb::ClampToWork(ToWxb(rest_), work_,
                                    Scaled(params_.min_visible)));
    MoveTo(HiddenRect());
    return;
  }

  RefreshNormalGeometry();
  // 从最小化还原时把轮询接回来（最小化时被 StopTimer 停掉了）
  StartIdleTimer();
}

// ---------------------------------------------------------------- 判定

bool EdgeDock::ForegroundIsOwnDialog() const {
  const HWND foreground = GetForegroundWindow();
  if (foreground == nullptr || foreground == hwnd_) return false;
  DWORD pid = 0;
  GetWindowThreadProcessId(foreground, &pid);
  // 前台窗口属于本进程但不是主窗口 = 文件选择框 / 弹出菜单 / 提示气泡
  return pid == GetCurrentProcessId();
}

bool EdgeDock::CanAutoHide() {
  if (!enabled_ || hwnd_ == nullptr) return false;
  if (dock_ == wxb::DockEdge::kNone) return false;
  if (in_size_move_) return false;
  if (IsIconic(hwnd_) || IsZoomed(hwnd_)) return false;
  if (!IsWindowVisible(hwnd_)) return false;
  if (ForegroundIsOwnDialog()) return false;
  // 半屏贴靠（Win+←）本来就是为了并排看，别收
  if (wxb::LooksSnapped(VisibleRest(), work_)) return false;
  return true;
}

bool EdgeDock::CursorOnWindow(POINT pt) const {
  if (hwnd_ == nullptr) return false;
  const HWND under = WindowFromPoint(pt);
  if (under == nullptr) return false;
  // 命中的是 Flutter 子窗口：往上找到顶层窗口再比
  return GetAncestor(under, GA_ROOT) == hwnd_;
}

bool EdgeDock::CursorOnStrip(POINT pt) const {
  if (!wxb::InPeekStrip(ToWxb(rest_), work_, dock_, Scaled(params_.peek),
                        Scaled(params_.strip_margin), pt.x, pt.y)) {
    return false;
  }
  // 条被别人盖住时不算（隐藏期间本窗口是置顶的，正常情况下这里都成立）
  return CursorOnWindow(pt);
}

// ---------------------------------------------------------------- 定时器

void EdgeDock::StopTimer(UINT_PTR* id) {
  if (*id == 0 || hwnd_ == nullptr) {
    *id = 0;
    return;
  }
  KillTimer(hwnd_, *id);
  *id = 0;
}

void EdgeDock::StopAllTimers() {
  StopTimer(&idle_timer_);
  StopTimer(&leave_timer_);
  StopTimer(&anim_timer_);
}

void EdgeDock::StartIdleTimer() {
  if (!enabled_ || hwnd_ == nullptr || idle_timer_ != 0) return;
  // 没贴边、也没藏着：没有任何需要轮询的理由
  if (dock_ == wxb::DockEdge::kNone && phase_ != Phase::kHidden) return;
  const int interval = phase_ == Phase::kHidden ? params_.hidden_tick_ms
                                                : params_.idle_tick_ms;
  idle_timer_ = SetTimer(hwnd_, kTimerIdle, static_cast<UINT>(interval),
                         nullptr);
}

void EdgeDock::RestartIdleTimer() {
  StopTimer(&idle_timer_);
  StartIdleTimer();
}

bool EdgeDock::HandleMessage(UINT message, WPARAM wparam) {
  if (message != WM_TIMER) return false;
  if (wparam == kTimerIdle) {
    OnIdleTick();
    return true;
  }
  if (wparam == kTimerLeave) {
    OnLeaveTimeout();
    return true;
  }
  if (wparam == kTimerAnim) {
    OnAnimTick();
    return true;
  }
  return false;
}

void EdgeDock::OnIdleTick() {
  if (!enabled_ || hwnd_ == nullptr) {
    StopTimer(&idle_timer_);
    return;
  }
  POINT pt{};
  if (!GetCursorPos(&pt)) return;
  // 每个 tick 刷一次工作区：显示器热插拔、任务栏自动隐藏都不一定发消息
  UpdateWorkArea();

  switch (phase_) {
    case Phase::kNormal:
      // 每个 tick 让 rest_/dock_ 跟着窗口真实位置走：程序改了窗口位置、
      // 任务栏自动隐藏、显示器热插拔都不一定发消息，靠事件同步会漏。
      RefreshNormalGeometry();
      if (CanAutoHide() && !CursorOnWindow(pt)) {
        phase_ = Phase::kLeaving;
        StopTimer(&idle_timer_);
        leave_timer_ = SetTimer(hwnd_, kTimerLeave,
                                static_cast<UINT>(params_.leave_delay_ms),
                                nullptr);
      }
      break;
    case Phase::kHidden:
      // 别人全屏时连那条边也躲起来；恢复后自动回来
      SetSuppressed(ForegroundCoversWorkArea());
      if (!suppressed_ && CursorOnStrip(pt)) BeginShow();
      break;
    case Phase::kLeaving:
    case Phase::kHiding:
    case Phase::kShowing:
    default:
      break;
  }
}

void EdgeDock::OnLeaveTimeout() {
  StopTimer(&leave_timer_);
  if (phase_ != Phase::kLeaving) return;

  POINT pt{};
  const bool still_out =
      GetCursorPos(&pt) != FALSE && !CursorOnWindow(pt) && CanAutoHide();
  if (!still_out) {
    // 这 350ms 里鼠标又回来了 / 用户开始拖窗口：取消，从头再等
    phase_ = Phase::kNormal;
    StartIdleTimer();
    return;
  }
  BeginHide();
}

void EdgeDock::BeginHide() {
  phase_ = Phase::kHiding;
  // 真正开始收的时候窗口一定可见，这时候量到的不可见边框才是准的
  UpdateFramePadding(true);
  anim_from_ = rest_;
  anim_to_ = HiddenRect();
  anim_start_ = GetTickCount64();
  anim_hiding_ = true;
  StopTimer(&idle_timer_);
  StopTimer(&leave_timer_);
  anim_timer_ = SetTimer(hwnd_, kTimerAnim,
                         static_cast<UINT>(params_.anim_tick_ms), nullptr);
}

void EdgeDock::FinishHide() {
  StopTimer(&anim_timer_);
  phase_ = Phase::kHidden;
  MoveTo(anim_to_);  // 消掉最后不足一像素的误差
  // 置顶：那 4px 的条必须能被点到，否则"唤出"只能靠任务栏图标
  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  topmost_ = true;
  // 藏起来之后要更密地看鼠标（碰到就要弹回来）
  RestartIdleTimer();
}

void EdgeDock::BeginShow() {
  if (hwnd_ == nullptr) return;
  phase_ = Phase::kShowing;
  RECT current{};
  anim_from_ = GetWindowRect(hwnd_, &current) ? current : anim_to_;
  anim_to_ = rest_;
  anim_start_ = GetTickCount64();
  anim_hiding_ = false;
  StopTimer(&idle_timer_);
  anim_timer_ = SetTimer(hwnd_, kTimerAnim,
                         static_cast<UINT>(params_.anim_tick_ms), nullptr);
}

void EdgeDock::FinishShow() {
  StopTimer(&anim_timer_);
  phase_ = Phase::kNormal;
  MoveTo(rest_);
  if (topmost_) {
    SetWindowPos(hwnd_, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    topmost_ = false;
  }
  RestartIdleTimer();  // 回到"贴边但可见"，轮询可以慢下来
}

void EdgeDock::OnAnimTick() {
  if (hwnd_ == nullptr) {
    StopTimer(&anim_timer_);
    return;
  }
  const ULONGLONG elapsed = GetTickCount64() - anim_start_;
  const double span = static_cast<double>(params_.animation_ms);
  const double progress = span > 0.0 ? static_cast<double>(elapsed) / span : 1.0;
  const double eased = wxb::EaseOutCubic(progress);

  const LONG dx = anim_to_.left - anim_from_.left;
  const LONG dy = anim_to_.top - anim_from_.top;
  RECT r = anim_from_;
  r.left = anim_from_.left + static_cast<LONG>(static_cast<double>(dx) * eased);
  r.top = anim_from_.top + static_cast<LONG>(static_cast<double>(dy) * eased);
  // 尺寸恒定，right/bottom 跟着左上角走
  r.right = r.left + (anim_from_.right - anim_from_.left);
  r.bottom = r.top + (anim_from_.bottom - anim_from_.top);
  MoveTo(r);

  if (progress >= 1.0) {
    if (anim_hiding_) {
      FinishHide();
    } else {
      FinishShow();
    }
  }
}
