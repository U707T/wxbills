#ifndef RUNNER_EDGE_DOCK_H_
#define RUNNER_EDGE_DOCK_H_

#include <windows.h>

#include "dock_math.h"

/// QQ 式的「贴边隐藏」。
///
/// ## 为什么整段都在 C++，不放 Dart
///  * 判断"鼠标离开窗口"要在**窗口没有焦点**时也成立，Flutter 拿不到全局鼠标位置；
///  * 这一版 OCR 跑在主 isolate 上（见 `store.dart` 里那段注释），Dart 侧 60fps 的
///    滑动动画在扫描几百张图时必然抖 —— 用户会以为功能坏了；
///  * 隐藏状态下窗口有一大半在屏幕外，依赖 Flutter 帧的动画更没有保障。
///
/// ## 一条踩过的坑（决定了这里的实现方式）
/// **鼠标在客户区时，消息是发给 Flutter 子窗口的**，父窗口收不到
/// `WM_MOUSEMOVE` / `WM_MOUSELEAVE`（只有标题栏、边框这些非客户区才发给父窗口）。
/// 所以这里完全不用 `WM_MOUSELEAVE`，改成 60ms 轮询 `GetCursorPos` +
/// `WindowFromPoint`：既拿得到客户区里的鼠标，也不受 Flutter 吞消息的影响。
class EdgeDock {
 public:
  /// 前三个是**逻辑像素**，会按窗口所在显示器的 DPI 缩放：
  /// 4px 的条如果在 150% 缩放下还是 4 物理像素，实际只有 2.7 逻辑像素，
  /// 又细又难点，和 100% 缩放下的手感完全不是一回事。
  struct Params {
    int tolerance = 8;          // 离工作区顶边多少逻辑像素算贴上
    int peek = 4;               // 藏起来后露出的条高
    int strip_margin = 3;       // 露出条两侧的热区容差
    int leave_delay_ms = 180;   // 鼠标离开多久后开始收（防"路过"，但别拖沓）
    int animation_ms = 150;     // 滑动时长（收起用 ease-in、弹回用 ease-out）
    int idle_tick_ms = 80;      // 贴顶但没收起时的轮询间隔
    int hidden_tick_ms = 40;    // 藏起来时的轮询间隔：要"碰到就弹回来"，得密一点
    int undocked_tick_ms = 250; // 没贴边时的轮询间隔：只为不错过"挪到顶边"
    int anim_tick_ms = 16;      // 动画帧间隔（~60fps）
    int min_visible = 80;       // 夹回屏幕时至少留多少像素可见（逻辑像素）
  };

  EdgeDock() = default;
  ~EdgeDock();

  EdgeDock(const EdgeDock&) = delete;
  EdgeDock& operator=(const EdgeDock&) = delete;

  /// 绑定窗口并开始轮询。[enabled] 为 false 时只是不动作，定时器也不会起。
  void Attach(HWND hwnd, bool enabled);
  void Detach();

  /// 用户开关切换。关掉的一瞬间必须先把窗口放回来，否则窗口留在屏幕外找不到了。
  void SetEnabled(bool enabled);
  bool enabled() const { return enabled_; }

  /// 窗口几何变了（用户拖完、DPI 变化、从最大化还原）之后重新判定贴边。
  void SyncFromWindow();

  /// 启动时把上次保存的矩形灌进来（夹回工作区、按几何重新判定贴边）。
  void RestoreFromState(const RECT& rect, bool maximized);

  /// 用户点「贴到顶部」：把窗口的**可见顶边**移到工作区顶部并进入贴顶状态。
  ///
  /// 为什么必须有一个显式动作：Windows 的 Aero Snap 会在鼠标碰到屏幕顶端时
  /// 直接最大化窗口，用户根本没法用"拖到顶边"这个手势（左右边更糟——会被
  /// 变成半屏贴靠）。所以贴顶是**点一下**完成的，不依赖拖拽。
  void SnapToTop();

  /// 立刻复位到"露出"状态：Alt+Tab、点任务栏图标、关窗口之前都要调。
  void ShowNow();

  /// 用户开始/结束拖动：拖动过程中不自动收（这时候收起来等于打断用户）。
  void SetInSizeMove(bool in_size_move) { in_size_move_ = in_size_move; }

  /// 保存几何时用这个：隐藏状态下拿到的是"露出时"的矩形，不是屏幕外那个。
  RECT rest_rect() const { return rest_; }

  wxb::DockEdge dock() const { return dock_; }
  bool hidden() const { return phase_ == Phase::kHidden; }
  bool animating() const {
    return phase_ == Phase::kHiding || phase_ == Phase::kShowing;
  }

  /// 只吞自己那几个 WM_TIMER，其余消息返回 false 交给 Win32Window。
  bool HandleMessage(UINT message, WPARAM wparam);

 private:
  enum class Phase { kNormal, kLeaving, kHiding, kHidden, kShowing };

  static constexpr UINT_PTR kTimerIdle = 0x1001;
  static constexpr UINT_PTR kTimerLeave = 0x1002;
  static constexpr UINT_PTR kTimerAnim = 0x1003;

  void StartIdleTimer();
  void RestartIdleTimer();
  void StopTimer(UINT_PTR* id);
  void UpdateDpiScale();
  int Scaled(int logical) const;
  void OnIdleTick();
  void OnLeaveTimeout();
  void OnAnimTick();
  void BeginHide();
  void FinishHide();
  void BeginShow();
  void FinishShow();
  void StopAllTimers();

  void MoveTo(const RECT& rect);
  void UpdateWorkArea();
  /// |force| 为 false 时只在 DPI / 显示器变化后真的去问 DWM：边框宽度不会天天变，
  /// 每次 tick 都查一遍纯属白花。
  void UpdateFramePadding(bool force);
  /// kNormal 状态下把 rest_ / dock_ 对齐到"窗口现在的真实位置"。
  /// 不变量：kNormal 时 `rest_ == GetWindowRect()`。
  void RefreshNormalGeometry();
  /// 别人全屏时把藏起来的窗口彻底 SW_HIDE，别在人家屏幕上留一条 4px 的亮线。
  void SetSuppressed(bool suppressed);
  bool ForegroundCoversWorkArea() const;
  wxb::Rect VisibleRest() const;
  RECT HiddenRect() const;
  bool CanAutoHide();
  bool CursorOnWindow(POINT pt) const;
  bool CursorOnStrip(POINT pt) const;
  bool ForegroundIsOwnDialog() const;

  HWND hwnd_ = nullptr;
  Params params_;
  bool enabled_ = false;
  Phase phase_ = Phase::kNormal;
  wxb::DockEdge dock_ = wxb::DockEdge::kNone;
  RECT rest_{};   // 露出时的窗口矩形（隐藏期间的还原目标）
  wxb::Rect work_{};  // 当前显示器的工作区（不含任务栏）
  wxb::FramePadding pad_{0, 0, 0, 0};  // DWM 不可见边框（见 dock_math.h）
  double scale_ = 1.0;                 // 当前显示器的 DPI 缩放（96dpi = 1.0）
  double padding_scale_ = -1.0;        // 上次量边框时的 DPI 缩放
  bool suppressed_ = false;            // 别人全屏 → 彻底隐藏（连 4px 条都不露）
  bool in_size_move_ = false;
  bool topmost_ = false;  // 隐藏期间是否置顶（保证那 4px 条不被别的窗口盖住）

  UINT_PTR idle_timer_ = 0;
  UINT_PTR leave_timer_ = 0;
  UINT_PTR anim_timer_ = 0;

  RECT anim_from_{};
  RECT anim_to_{};
  /// 动画进度（0..1），按**帧**累积而不是按墙钟算：
  /// WM_TIMER 在消息队列忙（Flutter 正在出帧）时会晚到，用墙钟算就会
  /// "一帧跳好远"——那正是滑动看起来生硬的原因。按帧步进最坏只是动画
  /// 稍微拖长一点，但每一帧的位移是连续的。
  double anim_progress_ = 0.0;
  bool anim_hiding_ = false;
};

#endif  // RUNNER_EDGE_DOCK_H_
