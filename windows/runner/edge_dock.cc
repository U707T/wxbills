#include "edge_dock.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <cstdio>
#include <string>

namespace {

// 老 SDK 里没有这个枚举值（Windows 10 1607 起才有），自己补一个
#ifndef DWMWA_EXTENDED_FRAME_BOUNDS
#define DWMWA_EXTENDED_FRAME_BOUNDS 9
#endif
// 同理：Win8 起才有，SDK 8.0 之前的头文件里没有
#ifndef DWMWA_CLOAKED
#define DWMWA_CLOAKED 14
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

// ---------------------------------------------------------------- 行为日志
//
// `--edge-trace` 才写，平时一行都不执行。为什么要有：贴边隐藏的每次判断都
// 取决于"现在谁在前台、鼠标在哪"，用户描述"它自己弹了一下"时，代码里可能
// 有五条路径，没有日志只能猜。

bool g_trace_enabled = false;

constexpr wchar_t kTraceFileName[] = L"wxbills-edge.log";

void AppendTraceLine(const std::string& line) {
  OutputDebugStringA(line.c_str());
  OutputDebugStringA("\r\n");

  wchar_t buffer[MAX_PATH] = {0};
  const DWORD length = GetTempPathW(MAX_PATH, buffer);
  if (length == 0) return;
  std::wstring path(buffer, length);
  if (!path.empty() && path.back() != L'\\') path.push_back(L'\\');
  path += kTraceFileName;

  const HANDLE file =
      CreateFileW(path.c_str(), FILE_APPEND_DATA,
                  FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                  FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written,
            nullptr);
  WriteFile(file, "\r\n", 2, &written, nullptr);
  CloseHandle(file);
}

void Trace(const char* event, int a = 0, int b = 0) {
  if (!g_trace_enabled || event == nullptr) return;
  SYSTEMTIME now{};
  GetLocalTime(&now);
  char stamp[32] = {0};
  std::snprintf(stamp, sizeof(stamp), "%02u:%02u:%02u.%03u", now.wHour,
                now.wMinute, now.wSecond, now.wMilliseconds);
  std::string line = "edge ";
  line += stamp;
  line += " ";
  line += event;
  line += " a=";
  line += std::to_string(a);
  line += " b=";
  line += std::to_string(b);
  AppendTraceLine(line);
}

// 前台窗口的类名（用于认出桌面 / 任务栏这类"系统表面"）。
// 取不到就当空串：宁可当普通窗口，也不要凭猜测把条藏掉。
std::wstring WindowClassName(HWND hwnd) {
  wchar_t buffer[128] = {0};
  const int length = GetClassNameW(hwnd, buffer, 128);
  if (length <= 0) return std::wstring();
  return std::wstring(buffer, static_cast<size_t>(length));
}

// 被 DWM 隐身（cloaked）的窗口：UWP 挂起、别的虚拟桌面、锁屏之后的窗口。
// 它们的 `IsWindowVisible` 仍然是 TRUE、`GetWindowRect` 还是原来那套矩形，
// 唯独屏幕上根本没有它们 —— 拿这种窗口判"别人全屏"必然误判。
// `DWMWA_CLOAKED` 是 Win8 之后才有的，老 SDK 里没有枚举值，自己补一个。
bool IsWindowCloaked(HWND hwnd) {
  BOOL cloaked = FALSE;
  const HRESULT hr =
      DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
  return SUCCEEDED(hr) && cloaked != FALSE;
}

}  // namespace

EdgeDock::~EdgeDock() { Detach(); }

void EdgeDock::SetTraceEnabled(bool enabled) { g_trace_enabled = enabled; }

// ---------------------------------------------------------------- 生命周期

void EdgeDock::Attach(HWND hwnd, bool enabled) {
  hwnd_ = hwnd;
  enabled_ = enabled;
  phase_ = Phase::kNormal;
  topmost_ = false;
  strip_since_ = 0;
  last_foreground_ = nullptr;
  last_foreground_tick_ = 0;
  accidental_focus_ = false;
  reveal_tick_ = 0;
  was_iconic_ = false;
  restored_tick_ = 0;
  anim_started_ = 0;
  anim_budget_ms_ = 0;
  repairing_ = false;
  SyncFromWindow();
  if (enabled_) StartIdleTimer();
}

void EdgeDock::Detach() {
  StopAllTimers();
  hwnd_ = nullptr;
  phase_ = Phase::kNormal;
  topmost_ = false;
  strip_since_ = 0;
  last_foreground_ = nullptr;
  last_foreground_tick_ = 0;
  accidental_focus_ = false;
  reveal_tick_ = 0;
  was_iconic_ = false;
  restored_tick_ = 0;
  anim_started_ = 0;
  anim_budget_ms_ = 0;
  repairing_ = false;
  dock_ = wxb::DockEdge::kNone;
}

void EdgeDock::SetEnabled(bool enabled) {
  if (enabled_ == enabled) return;
  enabled_ = enabled;
  strip_since_ = 0;
  accidental_focus_ = false;
  Trace("enabled", enabled ? 1 : 0);
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
  // 位置**和尺寸**都要落实。以前这里只比 left/top，而且走的是 MoveTo
  // （带 SWP_NOSIZE），于是 ClampToWork 缩出来的宽高从来没被应用过：
  // 从 4K 屏换到 1080p 笔记本，窗口会一直是 3840x2160，右下角的拉伸手柄
  // 永远在屏幕外，用户自己都拉不回来。
  if (rest_.left != rect.left || rest_.top != rect.top ||
      rest_.right != rect.right || rest_.bottom != rect.bottom) {
    PlaceTo(rest_);
  }
  // 停靠方向不单独存：它完全由几何决定，存两份只会有对不上的时候。
  if (maximized) {
    dock_ = wxb::DockEdge::kNone;
  } else {
    RefreshNormalGeometry();
  }
  phase_ = Phase::kNormal;
}

bool EdgeDock::SnapToTop() {
  if (hwnd_ == nullptr) return false;
  // 正在收 / 正在弹：动画定时器还在推窗口。不停掉它，这里把窗口挪到 rest_
  // 之后 OnAnimTick 会继续把它推到隐藏位置 —— 点「贴到顶部」的结果反而是
  // 收起来。别的入口（Reveal / ShowNow）都有这条守卫，这里不能例外。
  if (phase_ != Phase::kNormal) ShowNow();
  // 最大化 / 最小化状态下没有"顶部"可言，先还原成普通窗口
  if (IsIconic(hwnd_) || IsZoomed(hwnd_)) {
    ShowWindow(hwnd_, SW_RESTORE);
  }
  UpdateWorkArea();
  UpdateDpiScale();
  UpdateFramePadding(true);

  RECT rect{};
  if (!GetWindowRect(hwnd_, &rect)) return false;
  // 位置可以夹（把跑到屏幕外的窗口拉回来），**尺寸不动**：MoveTo 不改尺寸，
  // 这里要是按 ClampToWork 缩过的宽高去记 rest_，就和真实窗口对不上
  // （kNormal 的不变量是 rest_ == GetWindowRect()）。
  const wxb::Rect clamped =
      wxb::ClampToWork(ToWxb(rect), work_, Scaled(params_.min_visible));
  const int width = wxb::Width(ToWxb(rect));
  const int height = wxb::Height(ToWxb(rect));
  wxb::Rect r = ToWxb(rect);
  r.left = clamped.left;
  r.right = r.left + width;
  // 只把"看得见"的顶边吸到工作区顶：宽高都不动，也就不会触发 Flutter 重排
  r.top = work_.top - pad_.top;
  r.bottom = r.top + height;
  rest_ = ToRect(r);
  phase_ = Phase::kNormal;
  strip_since_ = 0;

  MoveTo(rest_);
  // 用真实几何重新判一次停靠：比工作区还高的窗口这里会得到 kNone，
  // 说明"贴顶"只是把窗口挪上去、不会自动收起 —— 结论交给界面。
  dock_ = wxb::ComputeDock(VisibleRest(), work_, Scaled(params_.tolerance));
  RestartIdleTimer();  // 换成"贴顶"档频率
  return dock_ == wxb::DockEdge::kTop;
}

bool EdgeDock::ForegroundIsFullscreen() const {
  const HWND foreground = GetForegroundWindow();
  if (foreground == nullptr || foreground == hwnd_) {
    return wxb::ShouldSuppressStrip(false, false, false, false, false, false);
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(foreground, &pid);
  const bool same_process = pid == GetCurrentProcessId();
  // 桌面（Progman / WorkerW / SHELLDLL_DefView）、任务栏 / 托盘 / 任务栏预览
  // 的矩形经常**就是整块显示器**，但它们不是"内容"。
  //
  // 这里是"别的程序一最小化，面板也消失了"的根因：最小化会把前台顺位交给
  // 桌面或任务栏，而我们只比对 `GetShellWindow()`（= Progman），于是在
  // WorkerW 桌面上、任务栏自动隐藏时全部漏判 → 条被挪到 -32000 → 屏幕上
  // 连 4px 都没有，悬停唤出彻底失效。判据现在按**类名**认，见
  // wxb::IsShellSurfaceClass。
  const bool is_shell_surface =
      foreground == GetShellWindow() ||
      wxb::IsShellSurfaceClass(WindowClassName(foreground).c_str());
  // 最大化窗口：任务栏设成"自动隐藏"时它也会盖满整块屏幕，但它仍然是
  // 普通窗口，不是用户的"全屏内容"。
  const bool is_maximized = IsZoomed(foreground) != FALSE;

  // 先做便宜的否决（类名 / 最大化），再量矩形，最后才问 DWM。
  // 隐藏状态下这个函数每 40ms 跑一次，别在常见路径上做 DWM 往返。
  bool covers_monitor = false;
  if (!same_process && !is_shell_surface && !is_maximized) {
    RECT rect{};
    if (!GetWindowRect(foreground, &rect)) {
      return wxb::ShouldSuppressStrip(false, false, false, false, false, false);
    }
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    const HMONITOR monitor =
        MonitorFromWindow(foreground, MONITOR_DEFAULTTONEAREST);
    // 必须盖住**我们这块**显示器：副屏放全屏视频时，主屏的条不该跟着躲。
    // 条一躲就意味着那块屏上的面板没了唤出入口（只能重启程序靠单实例捞回来）。
    const HMONITOR our_monitor =
        MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
    if (monitor != nullptr && monitor == our_monitor &&
        GetMonitorInfoW(monitor, &info)) {
      covers_monitor = wxb::CoversWorkArea(ToWxb(rect), ToWxb(info.rcMonitor));
    }
  }

  // 最小化 / 被 DWM 隐身 / 不可见：只有矩形真的盖满屏时才值得追查。
  //
  // 这一步不能省，而且**必须放在最后**：一个「最大化 → 被最小化」的窗口，
  // 在最小化的那一瞬间 `IsZoomed()` 已经变 false，但 `GetWindowRect()` 还是
  // 那块整屏矩形 —— 旧判据（只挡最大化）正好把它当成"盖满屏幕的全屏窗口"，
  // 于是条被挪到屏幕外。它此刻屏幕上根本没放任何内容，判据得看"还活不活跃"。
  bool is_dormant = false;
  if (covers_monitor) {
    is_dormant = IsIconic(foreground) != FALSE ||
                 !IsWindowVisible(foreground) ||
                 IsWindowCloaked(foreground);
  }

  return wxb::ShouldSuppressStrip(true, same_process, is_shell_surface,
                                  is_dormant, is_maximized, covers_monitor);
}

void EdgeDock::SetSuppressed(bool suppressed) {
  if (suppressed_ == suppressed || hwnd_ == nullptr) return;
  suppressed_ = suppressed;
  strip_since_ = 0;
  Trace("suppress", suppressed ? 1 : 0, static_cast<int>(phase_));
  if (suppressed) {
    // 别人全屏（游戏 / 视频）：连那 4px 也不该留在画面上。
    //
    // 但**不用 SW_HIDE**：那会把任务栏按钮一起拿走，用户就只剩"重开一次
    // 程序"这一条路（早期版本正是这么坏过的）。整块挪到任何显示器之外，
    // 屏幕上一样什么都没有，窗口却还活着、任务栏按钮还在。
    MoveTo(SuppressedRect());
    return;
  }
  // 回来时仍然藏好，位置按当前工作区重算（期间可能换了分辨率）
  MoveTo(HiddenRect());
}

void EdgeDock::ShowNow() {
  if (hwnd_ == nullptr) return;
  if (phase_ == Phase::kNormal && !animating() && !suppressed_) return;
  StopAllTimers();
  anim_started_ = 0;
  strip_since_ = 0;
  // 被全屏挤走的那次：窗口只是被挪到了显示器外面，没有 SW_HIDE，
  // 所以不用再 ShowWindow 一次，取消抑制后直接摆回露出位置即可。
  suppressed_ = false;
  if (topmost_) {
    SetWindowPos(hwnd_, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    topmost_ = false;
  }
  phase_ = Phase::kNormal;
  MoveTo(rest_);
  if (enabled_) StartIdleTimer();
}

bool EdgeDock::IsSizeMoving() {
  if (!in_size_move_) return false;
  if (GetCapture() != nullptr ||
      (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0) {
    return true;
  }
  // 标志位过期：左键早就松了、本线程也没有捕获。复位，否则自动收起 / 唤出 /
  // 贴顶会一起静默失效（用户看到的是"点任务栏没反应"）。
  in_size_move_ = false;
  Trace("size_move.stale_reset");
  return false;
}

void EdgeDock::Reveal() {
  if (hwnd_ == nullptr) return;
  // 正在拖 / 拉伸窗口：位置是用户的手指说了算，这里一动就变成"拽回去"
  if (IsSizeMoving()) return;
  StopTimer(&leave_timer_);
  strip_since_ = 0;
  // 用户主动唤出：给一段保护期（`Params::reveal_grace_ms`）。
  // 这一刻鼠标通常还压在任务栏上，不在窗口里；没有保护期的话，下一次 idle
  // tick 就会判成"鼠标离开"→ 180ms 后收起，用户看到的是"闪一下就没了"。
  reveal_tick_ = GetTickCount();
  // 最小化状态下"滑出来"没有意义（窗口根本不在屏幕上，动画没人看得见）：
  // 直接把还原位置摆到 rest_，随后系统的"还原"会把窗口放出来。
  if (IsIconic(hwnd_) != FALSE) {
    ShowNow();
    return;
  }
  if (suppressed_) {
    // 被全屏应用挤走的那次：先按隐藏位置摆好，再滑出来
    // （窗口没有 SW_HIDE，不用先 ShowWindow）
    suppressed_ = false;
    MoveTo(HiddenRect());
  }
  // 藏着 / 正在收 / 正在弹：都走动画，别硬跳（硬跳就是"闪一下"）
  if (phase_ == Phase::kHidden || animating()) {
    BeginShow();
    return;
  }
  if (topmost_) {
    SetWindowPos(hwnd_, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    topmost_ = false;
  }
  phase_ = Phase::kNormal;
  MoveTo(rest_);
  RestartIdleTimer();
}

bool EdgeDock::OnActivated() {
  if (hwnd_ == nullptr) return false;

  // ---- 先判"从最小化还原"这条**最硬的证据** ----
  //
  // 顺位继承的激活不会把窗口从最小化里拉出来；能把窗口从任务栏还原的只有
  // 用户。以前这条没有，一次"样本过期"就够让这次激活被判成继承 → 面板
  // 什么都不做 → 用户看到的是"点任务栏，收起的窗口没了"。
  const DWORD now = GetTickCount();
  const bool restored =
      was_iconic_ || IsIconic(hwnd_) != FALSE ||
      (restored_tick_ != 0 &&
       static_cast<DWORD>(now - restored_tick_) <= kRestoredWindowMs);

  // 这次激活是系统「顺位」给的，不是用户想用这个窗口：
  // 别的窗口被关掉 / 最小化后，前台会交给 Z 序里的下一个可见窗口，
  // 而藏在屏幕外的面板正好是 `WS_VISIBLE` 的、还置顶 —— 于是"别的窗口一
  // 最小化，这个面板就跟着动了"。
  const HWND prev = last_foreground_;
  const bool has_previous = prev != nullptr && prev != hwnd_;
  bool alive = false;
  bool minimized = false;
  bool visible = false;
  if (has_previous) {
    alive = IsWindow(prev) != FALSE;
    if (alive) {
      minimized = IsIconic(prev) != FALSE;
      visible = IsWindowVisible(prev) != FALSE;
    }
  }
  // 样本必须新鲜：轮询在最小化 / 动画期间是停着的，`prev` 可能是十几秒前
  // 就已经关掉的窗口 —— 拿它判"继承"会把真正点任务栏的那次也判错。
  const bool fresh =
      last_foreground_tick_ != 0 &&
      static_cast<DWORD>(now - last_foreground_tick_) <= kForegroundSampleTtlMs;
  if (!restored &&
      wxb::IsInheritedActivation(has_previous, alive, minimized, visible,
                                 fresh)) {
    // 唯一例外：面板本来就露着，而且鼠标正压在它上面 —— 那是用户自己点进来的，
    // 不管上一个前台是什么状态（他可能刚最小化了 A，顺手回来点面板）。
    //
    // 只对 kNormal 放行：藏着的时候不能让"鼠标刚好压在条上"绕过 dwell
    // （路过顶边就弹出来，正是 2.3.4 修掉的那个"闪一下"）。
    POINT cursor{};
    const bool pointer_on_us =
        phase_ == Phase::kNormal && GetCursorPos(&cursor) != FALSE &&
        CursorOnWindow(cursor);

    if (!pointer_on_us) {
      // 顺位继承：**什么都不做**。不弹面板、不改 phase、不碰 dock_ —— 这条
      // 激活不是用户要的，就不该产生任何可见效果（2.3.5 只做到"不弹"，
      // 2.3.7 又补了"还焦点"，但两边都还留着"这次激活算不算在用"的歧义）。
      //
      // 为什么要清 last_foreground_：不清的话它会一直指着那个已经关掉的
      // 窗口，之后用户真的去点任务栏图标也会被当成"继承"，面板永远叫不出来。
      accidental_focus_ = true;
      last_foreground_ = nullptr;
      last_foreground_tick_ = 0;
      Trace("activate.inherited", alive ? 1 : 0, minimized ? 1 : 0);
      // 这次"白捡的前台"会把键盘焦点也一起带走：用户关掉一个窗口之后接着
      // 打字，字全进了一个看不见的窗口（要是之前点过搜索框，列表还会被悄悄
      // 过滤）。此刻我们就是前台，把前台还给桌面是允许的。
      ReleaseForegroundToShell();
      return false;  // 别把焦点再交给 Flutter 视图
    }
    Trace("activate.inherited.but_pointer_on_us",
          alive ? 1 : 0, minimized ? 1 : 0);
  } else if (restored) {
    Trace("activate.restored", hidden() ? 1 : 0, animating() ? 1 : 0);
  } else if (has_previous && !fresh) {
    // 只在日志里留一条：这次"按用户主动处理"是因为样本过期，不是因为
    // 上一个前台确实还活着。真机排查时这两者要能分开。
    Trace("activate.user.stale_sample", alive ? 1 : 0, minimized ? 1 : 0);
  }

  accidental_focus_ = false;
  Trace("activate.user");
  Reveal();
  return true;
}

/// 把前台还给桌面。
///
/// 顺位继承来的激活一律要还：不还的话键盘焦点留在我们这儿（隐藏时窗口在
/// 屏幕外，用户以为自己在跟别的程序说话），而且"前台是我们"会让
/// [CanAutoHide] 的判断跟着一起错。
///
/// `SetForegroundWindow` 在某些前台锁（用户刚点了别的程序、UAC、锁屏）下会
/// 静默失败，所以不拿它的返回值当结论，回头用 `GetForegroundWindow()` 复核。
void EdgeDock::ReleaseForegroundToShell() {
  const HWND shell = GetShellWindow();
  if (shell == nullptr || SetForegroundWindow(shell) == FALSE) {
    Trace("activate.inherited.release_focus", 0);
    return;
  }
  // 复核：前台真的离开了我们，才算"白捡的前台"到此为止；还停在原地就保留
  // accidental_focus_，让 CanAutoHide 继续按"这不是用户在用"处理。
  const bool moved = GetForegroundWindow() != hwnd_;
  Trace("activate.inherited.release_focus", 1, moved ? 1 : 0);
  if (moved) accidental_focus_ = false;
}


void EdgeDock::NoteDeactivated() {
  accidental_focus_ = false;
}

void EdgeDock::NoteUserInteraction() {
  // 点进来 / 滚轮：这次激活是不是继承来的已经不重要了，他在用这个窗口。
  //
  // 不清的话：继承激活之后窗口一直是前台，系统不会再发 WM_ACTIVATE，
  // accidental_focus_ 永远清不掉 —— 鼠标一离开就收起；而同样的操作在正常
  // 激活下不会收。用户只会觉得"有时收有时不收"。
  if (!accidental_focus_) return;
  accidental_focus_ = false;
  Trace("interaction.clear_accidental");
}

bool EdgeDock::InterceptMinimize() {
  if (hwnd_ == nullptr) return false;
  // 只拦"收着"的时候：露着的窗口点任务栏按钮本来就是最小化，那是用户的意图。
  if (phase_ != Phase::kHidden && !animating()) return false;
  if (dock_ == wxb::DockEdge::kNone && !suppressed_) return false;
  Trace("minimize.intercepted", static_cast<int>(phase_),
        suppressed_ ? 1 : 0);
  Reveal();
  return true;
}

// ---------------------------------------------------------------- 几何

void EdgeDock::UpdateWorkArea() {
  if (hwnd_ == nullptr) return;
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  // 隐藏 / 抑制期间窗口本体不在它"该在"的地方：隐藏时大部分在屏幕上方，
  // 抑制时干脆在 -32000。按窗口位置找显示器会找到别人家去，于是
  // HiddenRect()/SuppressedRect() 会按错屏的工作区算 —— 表现为面板跑到
  // 另一块屏幕上。这时候按"露出时的矩形"找。
  const HMONITOR monitor =
      (suppressed_ || hidden())
          ? MonitorFromRect(&rest_, MONITOR_DEFAULTTONEAREST)
          : MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
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
  UINT dpi = 0;
  if (suppressed_ || hidden()) {
    // 隐藏时窗口大半在屏幕上方，抑制时干脆在 -32000：按 HWND 查 DPI 会问到
    // "离窗口最近的那块屏"，多屏上下叠放时拿到的不是面板所在的那块。
    // 这时按露出时的矩形找显示器。
    dpi = FlutterDesktopGetDpiForMonitor(
        MonitorFromRect(&rest_, MONITOR_DEFAULTTONEAREST));
  } else {
    dpi = FlutterDesktopGetDpiForHWND(hwnd_);
  }
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

RECT EdgeDock::SuppressedRect() const {
  // 挪到任何显示器之外（-32000 是 Windows 上"丢到屏幕外"的惯用坐标）。
  // 不能只往上推：副屏在主屏上方时，"工作区上方"正好是另一块屏幕，
  // 那条 4px 就会亮在别人家的屏幕上。
  const LONG width = rest_.right - rest_.left;
  const LONG height = rest_.bottom - rest_.top;
  RECT r{};
  r.left = -32000;
  r.top = -32000;
  r.right = r.left + width;
  r.bottom = r.top + height;
  return r;
}

void EdgeDock::MoveTo(const RECT& rect) {
  if (hwnd_ == nullptr) return;
  // 只挪位置、不改尺寸：尺寸一变 Flutter 就要重排整棵树，滑动必然掉帧。
  SetWindowPos(hwnd_, nullptr, rect.left, rect.top, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS);
}

void EdgeDock::PlaceTo(const RECT& rect) {
  if (hwnd_ == nullptr) return;
  // 和 MoveTo 的唯一区别是**带尺寸**。只给启动恢复 / 贴顶这类一次性动作用：
  // 那里没有动画，重排一次不影响手感；反过来，动画里绝对不能走这条。
  SetWindowPos(hwnd_, nullptr, rect.left, rect.top, rect.right - rect.left,
               rect.bottom - rect.top,
               SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS);
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
  // 离顶边 15px 的窗口也算成贴边。
  const wxb::DockEdge next =
      wxb::ComputeDock(VisibleRest(), work_, Scaled(params_.tolerance));
  if (next != dock_) {
    dock_ = next;
    // 频率跟着"贴没贴顶"换档（40 / 100 / 250ms），不能等下次重启
    RestartIdleTimer();
  }
  // 兜底：kNormal 不等于"窗口一定在用户看得见的地方"（动画被打断、从任务栏
  // 还原到隐藏位置都会留下这种残局）。每 tick 花一次矩形比较就能自愈。
  RepairNormalPlacement();
}

/// 窗口"屏幕上几乎看不见"时把它放回工作区。
///
/// 为什么必须有这一步：贴边隐藏的**唯一真相是窗口坐标**，而坐标会被三种
/// 外力改掉 —— 被打断的动画、从最小化还原时被写成"隐藏矩形"的还原位置、
/// 从别的机器/显示器带过来的越界记忆几何。这些状态下用户看不见窗口，
/// 也就没有任何地方可以点、可以拖，只能重装或改 ini。
///
/// 保守到什么程度：只有"露在工作区里的高度 < min_visible（默认 80px）"或
/// "贴顶却钻到工作区上方去了"才动手，而且只在 kNormal 且不在拖动时。
/// 用户自己在拖窗口时（`in_size_move_`）一律不碰，拖到一半的合法位置不会被抢走。
void EdgeDock::RepairNormalPlacement() {
  if (hwnd_ == nullptr || repairing_ || IsSizeMoving()) return;
  if (phase_ != Phase::kNormal) return;
  if (IsIconic(hwnd_) || IsZoomed(hwnd_) || !IsWindowVisible(hwnd_)) return;

  RECT rect{};
  if (!GetWindowRect(hwnd_, &rect)) return;
  const wxb::Rect current = ToWxb(rect);
  const wxb::Rect visible = wxb::VisibleRect(current, pad_);
  const bool nearly_invisible =
      wxb::IsNearlyOffscreen(visible, work_, Scaled(params_.min_visible));
  const bool half_buried = wxb::IsHalfBuried(visible, work_, dock_);
  if (!nearly_invisible && !half_buried) return;

  // 只挪位置、不改尺寸（`MoveTo` 是 SWP_NOSIZE：尺寸一变 Flutter 就要重排）
  wxb::Rect fixed = current;
  const int width = wxb::Width(current);
  const int height = wxb::Height(current);

  // 1) 水平方向整块跑到工作区外侧（换了显示器 / 手改了 ini）：贴到最近的那条边
  if (fixed.right <= work_.left) {
    fixed.left = work_.left;
  } else if (fixed.left >= work_.right) {
    fixed.left = work_.right - width;
  }
  fixed.right = fixed.left + width;

  // 2) 垂直方向：窗口主要在工作区下半部（被拖到屏幕下方）就贴底，否则贴顶。
  //    贴的必须是**看得见的那条边**，否则按键计算出来的贴顶判定会越偏越远。
  const int visible_center_y = (visible.top + visible.bottom) / 2;
  const bool align_bottom = height <= wxb::Height(work_) &&
                            visible_center_y > (work_.top + work_.bottom) / 2;
  if (align_bottom) {
    fixed.bottom = work_.bottom + pad_.bottom;
    fixed.top = fixed.bottom - height;
  } else {
    fixed.top = work_.top - pad_.top;
    fixed.bottom = fixed.top + height;
  }

  repairing_ = true;
  rest_ = ToRect(fixed);
  MoveTo(rest_);  // 会同步派发 WM_MOVE → SyncFromWindow → 这里，repairing_ 挡住
  dock_ = wxb::ComputeDock(VisibleRest(), work_, Scaled(params_.tolerance));
  phase_ = Phase::kNormal;
  repairing_ = false;
  Trace("repair.placement", fixed.top, nearly_invisible ? 1 : 0);
  RestartIdleTimer();
}

DWORD EdgeDock::AnimationBudget() const {
  // 帧步进理论上 150ms 就走完了；WM_TIMER 是低优先级消息，消息队列被 Flutter
  // 的渲染消息塞满时会被饿死。给 3 倍时长 + 200ms 的预算，超了就硬跳到终点。
  DWORD ms = params_.animation_ms > 0
                 ? static_cast<DWORD>(params_.animation_ms)
                 : 150u;
  const DWORD budget = ms * 3 + 200;
  return budget < 600 ? 600 : budget;
}

void EdgeDock::SyncFromWindow() {
  if (hwnd_ == nullptr) return;
  // 拖动/拉拽过程中不必跟着算：每次 WM_MOVE 都做一遍纯属浪费，松手时会算。
  // （`IsSizeMoving()` 会顺带把卡住的标志位复位，见它的注释）
  if (IsSizeMoving()) return;
  UpdateWorkArea();

  // ---- 1. 最小化：必须排在 animating() 前面 ----
  //
  // 点任务栏按钮 / Win+D 把窗口最小化时，很可能正好落在 150ms 的滑动动画里。
  // 以前 `if (animating()) return;` 写在最前面，于是这次最小化被整个忽略，
  // 动画随后 `FinishHide()` 把**隐藏矩形**写成了最小化窗口的还原位置：
  // 用户再从任务栏点回来，窗口就还原到屏幕上方只剩 4px —— 也就是
  // "卡在顶部 / 看着像消失了"。
  if (IsIconic(hwnd_) != FALSE) {
    was_iconic_ = true;
    // 动画必须立刻停掉，否则它会把"还原位置"写成隐藏位置
    if (phase_ != Phase::kNormal || animating()) ShowNow();
    StopTimer(&idle_timer_);
    dock_ = wxb::DockEdge::kNone;
    // 最小化期间 idle 定时器是停着的，但**别的窗口照样会最小化**：不采样的话
    // 等用户从任务栏还原回来，last_foreground_ 还指着最小化之前那个窗口
    // （可能早就关了）→ 第一次真实激活被判成"继承"，面板叫不出来。这里顺手
    // 采一次，代价只有一次 GetForegroundWindow。
    TrackForeground();
    return;
  }

  const bool restored = was_iconic_;
  if (restored) {
    was_iconic_ = false;
    restored_tick_ = GetTickCount();
    Trace("restore.from_iconic", hidden() ? 1 : 0, animating() ? 1 : 0);
  }

  if (hidden()) {
    // 隐藏期间换了分辨率/插拔显示器：按 rest_ 重算停靠位置，别露出半截
    UpdateDpiScale();
    // 边框宽度跟着 DPI 变，而 HiddenRect() 是靠 pad_ 把"看得见的 4px"补偿
    // 出来的。不重量一次，缩放从 100% 换到 150% 之后可见高度会算成负数——
    // 条整根跑到屏幕外，hover 唤出彻底失效，只能从任务栏点回来。
    UpdateFramePadding(true);
    rest_ = ToRect(wxb::ClampToWork(ToWxb(rest_), work_,
                                    Scaled(params_.min_visible)));
    if (restored) {
      // 从任务栏还原出来的窗口**绝不能停在隐藏位置**：用户点那一下是要用它，
      // 不是想再看一次那 4px。以前这里直接 MoveTo(HiddenRect())，窗口还原成
      // 一条边，用户以为程序坏了。
      // 走 Reveal()（而不是直接 BeginShow）：它顺带处理"被全屏挤走"（窗口
      // 在 -32000）和"刚被唤出"的保护期，避免窗口从屏幕左上角斜着飞进来。
      Reveal();
      return;
    }
    // 被全屏挤走时保持在工作区外面，别拽回 4px 位置
    const RECT target = suppressed_ ? SuppressedRect() : HiddenRect();
    RECT current{};
    if (GetWindowRect(hwnd_, &current) && current.left == target.left &&
        current.top == target.top) {
      return;  // 已经在目标位置：别为了挪 0 像素再触发一次 WM_MOVE
    }
    MoveTo(target);
    return;
  }

  if (animating()) {
    // 动画中来了一次"最小化 → 还原"：把动画目标改成"露出来"，从当前矩形
    // 重新起步（BeginShow 会重新采样 anim_from_）。
    if (restored) Reveal();
    return;  // 动画中改目标会跳帧
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
  if (hwnd_ == nullptr) return false;
  // 窗口自己就是前台窗口：用户正在用它，这时候收起来等于"点一下就没"。
  // 但「顺位继承来的前台」不算：那不是用户想用这个窗口，只是系统把激活
  // 塞给了我们（见 OnActivated）—— 少了这条，一次"关别人的窗口"就能让
  // 面板卡在"永远不收"的状态。规则本身在 dock_math.h 里，有单测。
  //
  // 还有一条"刚被用户唤出"的保护期：从任务栏点回来的那一刻，鼠标还在任务栏
  // 上、不在窗口里，没有它就会立刻判成"鼠标离开"→ 180ms 后收起 →
  // 用户看到的是"窗口闪一下就没了"。
  const DWORD now = GetTickCount();
  const bool within_grace =
      reveal_tick_ != 0 &&
      static_cast<DWORD>(now - reveal_tick_) <
          static_cast<DWORD>(params_.reveal_grace_ms > 0
                                 ? params_.reveal_grace_ms
                                 : 1);
  return wxb::CanAutoHideWith(
      enabled_, dock_ != wxb::DockEdge::kNone, IsSizeMoving(),
      IsIconic(hwnd_) != FALSE, IsZoomed(hwnd_) != FALSE,
      IsWindowVisible(hwnd_) != FALSE, ForegroundIsOwnDialog(),
      GetForegroundWindow() == hwnd_, accidental_focus_, within_grace);
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
  // 三档频率，都是"够用就好"：
  //   藏着 40ms    —— 鼠标碰到就要弹回来，慢了像坏了
  //   贴顶 100ms   —— 只需要察觉"鼠标离开了"
  //   没贴边 250ms —— 只需要不错过"用户把窗口挪到顶边"
  // 早先的版本在"没贴边"时干脆不起定时器，靠 WM_MOVE/WM_EXITSIZEMOVE 兜底；
  // 结果只要有一条消息没按预期到达，功能就整体静默失效（用户看到的就是
  // "贴边完全没生效"）。宁可每秒醒 4 次，也不要靠事件必须准时。
  int interval = params_.undocked_tick_ms;
  if (animating()) {
    // 动画期间 idle 定时器不停：它兼职看门狗（见 OnIdleTick）。
    // WM_TIMER 被消息队列饿死、或者动画定时器干脆没建起来时，靠它把窗口
    // 落到终点，而不是卡在屏幕上方半路。
    interval = params_.hidden_tick_ms;
  } else if (phase_ == Phase::kHidden) {
    interval = params_.hidden_tick_ms;
  } else if (dock_ != wxb::DockEdge::kNone) {
    interval = params_.idle_tick_ms;
  }
  idle_timer_ = SetTimer(hwnd_, kTimerIdle, static_cast<UINT>(interval), nullptr);
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

  // ---- 动画期间：这个 tick 现在是**看门狗**，不是状态机 ----
  //
  // 以前动画一来就把 idle 定时器停掉，只留一个 16ms 的动画定时器。只要那个
  // 定时器丢了（WM_TIMER 是低优先级消息、SetTimer 也可能失败），phase_ 就会
  // 永远停在 kShowing/kHiding，而两个定时器全没了 —— 窗口卡在屏幕上方半路，
  // 除了重启没有任何东西能把它救回来，也就是用户说的"卡一半在顶部"。
  if (animating()) {
    TrackForeground();  // 动画期间也要保持"上一个前台"的样本新鲜
    const bool budget_over =
        anim_started_ != 0 &&
        static_cast<DWORD>(GetTickCount() - anim_started_) > anim_budget_ms_;
    if (anim_timer_ == 0 || budget_over) {
      Trace(anim_timer_ == 0 ? "anim.watchdog.lost" : "anim.watchdog.deadline",
            static_cast<int>(phase_), anim_hiding_ ? 1 : 0);
      if (anim_hiding_) {
        FinishHide();
      } else {
        FinishShow();
      }
    }
    return;
  }

  // 每个 tick 刷一次工作区：显示器热插拔、任务栏自动隐藏都不一定发消息
  // （动画期间不刷：窗口大半个在屏幕外，MonitorFromWindow 可能问到隔壁那块屏）
  UpdateWorkArea();
  TrackForeground();

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
      // 只有真全屏才把条藏起来（最大化窗口不算，见 ShouldSuppressStrip）
      SetSuppressed(ForegroundIsFullscreen());
      // 唤出要"停一下"才算数：鼠标只是路过屏幕顶边（去点别的窗口的标题栏、
      // 浏览器标签页）时不该把面板拽出来 —— 拽出来之后鼠标一离开又收起，
      // 在用户眼里就是"窗口莫名闪了一下"。
      if (!suppressed_ && CursorOnStrip(pt)) {
        const DWORD now = GetTickCount();
        if (strip_since_ == 0) {
          strip_since_ = now;
        } else if (now - strip_since_ >=
                   static_cast<DWORD>(params_.dwell_ms)) {
          strip_since_ = 0;
          BeginShow();
        }
      } else {
        strip_since_ = 0;
      }
      break;
    case Phase::kLeaving:
    case Phase::kHiding:
    case Phase::kShowing:
    default:
      break;
  }
}

void EdgeDock::TrackForeground() {
  if (hwnd_ == nullptr) return;
  // 记下"现在谁在前台"（只要不是我们自己）：下一次收到 WM_ACTIVATE 时，
  // 靠它判断这次激活是用户主动的、还是别人关窗口/最小化后顺位继承来的。
  // 我们被激活之后这里不会再覆盖（fg 就是我们自己），所以判据不会被冲掉。
  const HWND fg = GetForegroundWindow();
  if (fg == nullptr || fg == hwnd_) return;
  last_foreground_ = fg;
  last_foreground_tick_ = GetTickCount();  // 样本新鲜度，见 OnActivated
  // 前台已经不是我们了：上一轮"白捡的前台"到此为止
  accidental_focus_ = false;
}

void EdgeDock::OnLeaveTimeout() {
  StopTimer(&leave_timer_);
  if (phase_ != Phase::kLeaving) return;
  // 这 180ms 里前台可能已经换人了（用户去点了别的程序）：判据要跟着走。
  // 这段时间 idle 定时器是停着的（kLeaving），正好把"别人就在这时最小化了
  // 一个窗口"这段高发窗口漏掉 —— 样本一过期，下一次激活就会判错。
  TrackForeground();

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
  Trace("hide.begin");
  // 真正开始收的时候窗口一定可见，这时候量到的不可见边框才是准的
  UpdateFramePadding(true);
  anim_from_ = rest_;
  anim_to_ = HiddenRect();
  anim_progress_ = 0.0;
  anim_hiding_ = true;
  anim_started_ = GetTickCount();
  anim_budget_ms_ = AnimationBudget();
  StopTimer(&leave_timer_);
  // **不停 idle 定时器**：动画期间它兼看门狗（见 OnIdleTick），
  // 动画定时器一旦丢了/超时了，靠它把窗口落到终点。
  RestartIdleTimer();
  StopTimer(&anim_timer_);
  anim_timer_ = SetTimer(hwnd_, kTimerAnim,
                         static_cast<UINT>(params_.anim_tick_ms), nullptr);
}

void EdgeDock::FinishHide() {
  StopTimer(&anim_timer_);
  anim_started_ = 0;
  phase_ = Phase::kHidden;
  strip_since_ = 0;
  Trace("hide.done");
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
  strip_since_ = 0;
  StopTimer(&leave_timer_);  // 中途唤出：别再被之前那次"离开"收回去
  Trace("show.begin");
  RECT current{};
  if (GetWindowRect(hwnd_, &current)) {
    anim_from_ = current;
  } else {
    anim_from_ = rest_;  // 取不到就以露出位置为起点（别用上一次的目标）
  }
  anim_to_ = rest_;
  anim_progress_ = 0.0;
  anim_hiding_ = false;
  anim_started_ = GetTickCount();
  anim_budget_ms_ = AnimationBudget();
  // 同 BeginHide：idle 定时器留着当看门狗
  RestartIdleTimer();
  StopTimer(&anim_timer_);
  anim_timer_ = SetTimer(hwnd_, kTimerAnim,
                         static_cast<UINT>(params_.anim_tick_ms), nullptr);
}

void EdgeDock::FinishShow() {
  StopTimer(&anim_timer_);
  anim_started_ = 0;
  phase_ = Phase::kNormal;
  Trace("show.done");
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
  // idle 定时器在动画期间也是开着的，判据在这里再补采一次；否则"收起动画那
  // 150ms 里别人最小化了一个窗口"会被当成用户主动激活（详见 OnActivated）。
  TrackForeground();
  // 兜底：帧步进理论上不会超时，但 WM_TIMER 会被消息队列饿死 —— 超预算就地
  // 落到终点，宁可硬跳一下，也不要卡在屏幕上方半路。
  if (anim_started_ != 0 &&
      static_cast<DWORD>(GetTickCount() - anim_started_) > anim_budget_ms_) {
    Trace("anim.deadline", static_cast<int>(phase_), anim_hiding_ ? 1 : 0);
    if (anim_hiding_) {
      FinishHide();
    } else {
      FinishShow();
    }
    return;
  }
  // 按帧推进（不是按墙钟）：晚到的 tick 只会让动画慢一点，不会"跳一大格"
  const double step =
      params_.animation_ms > 0
          ? static_cast<double>(params_.anim_tick_ms) /
                static_cast<double>(params_.animation_ms)
          : 1.0;
  anim_progress_ += step;
  // 收起用 ease-in（先慢后快，像被吸走），弹回用 ease-out（先快后慢，稳稳停住）
  const double eased = anim_hiding_ ? wxb::EaseInQuad(anim_progress_)
                                    : wxb::EaseOutQuad(anim_progress_);

  const double dy = static_cast<double>(anim_to_.top - anim_from_.top);
  RECT r = anim_from_;
  r.top = anim_from_.top + static_cast<LONG>(dy * eased);
  // 尺寸恒定，底边跟着顶边走
  r.bottom = r.top + (anim_from_.bottom - anim_from_.top);
  MoveTo(r);

  if (anim_progress_ >= 1.0) {
    if (anim_hiding_) {
      FinishHide();
    } else {
      FinishShow();
    }
  }
}
