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
    int dwell_ms = 200;         // 鼠标在条上停多久才算「要唤出」（防路过）
    int leave_delay_ms = 180;   // 鼠标离开多久后开始收（防"路过"，但别拖沓）
    int animation_ms = 150;     // 滑动时长（收起用 ease-in、弹回用 ease-out）
    int idle_tick_ms = 80;      // 贴顶但没收起时的轮询间隔
    int hidden_tick_ms = 40;    // 藏起来时的轮询间隔：要"碰到就弹回来"，得密一点
    int undocked_tick_ms = 250; // 没贴边时的轮询间隔：只为不错过"挪到顶边"
    int anim_tick_ms = 16;      // 动画帧间隔（~60fps）
    /// 用户主动唤出之后这段时间内不自动收起（毫秒）。
    ///
    /// 从任务栏点回来时鼠标还压在任务栏上、根本不在窗口里，光按"鼠标离开就收"
    /// 会在 180ms 后立刻把刚露出来的窗口收回 —— 用户看到的是"闪一下就没了"。
    int reveal_grace_ms = 700;
    int min_visible = wxb::kMinVisible;  // 夹回屏幕时至少留多少像素可见（逻辑像素）
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
  ///
  /// 返回 false = 窗口比工作区还高，`ComputeDock` 判不出贴顶，收起来连标题栏
  /// 都找不回来，所以只挪位置、不会自动收起。界面要把这件事说出来，
  /// 不能像以前那样点了没反应。
  bool SnapToTop();

  /// 窗口被激活（点任务栏图标 / Alt+Tab / 点了面板本身）：完整露出来。
  ///
  /// 和 [ShowNow] 的唯一区别是**会滑出来**：从任务栏点回来时硬跳一下，
  /// 看起来就是"窗口闪了一下"，而且紧接着还会被当成"鼠标已离开"收回去。
  void Reveal();

  /// `WM_ACTIVATE(WA_ACTIVE)`：要不要露出来，由这里决定。
  ///
  /// 不能无脑 [Reveal]：别的窗口被关掉 / 最小化时，系统会把激活顺位交给
  /// 我们（面板是可见窗口里的下一个），那不是用户想用这个窗口 ——
  /// 表现出来就是"关别人的窗口，这个窗口莫名弹出来又收回去"。
  ///
  /// 返回值：这次激活是不是**用户主动**的。false 时调用方不该把焦点交给
  /// Flutter 视图 —— 顺位继承来的激活本来就要立刻还回去，再抢一次焦点等于
  /// 把键盘输入拐进一个藏在屏幕外的窗口。
  bool OnActivated();

  /// `WM_ACTIVATE(WA_INACTIVE)`：失活时把"被动接管的前台"这个标记清掉。
  ///
  /// 顺位继承来的激活会让窗口变成"藏着但仍是前台"。如果一直按"前台就不收"
  /// 处理，下次悬停弹出之后就再也收不回去了（鼠标离开也不收）。
  void NoteDeactivated();

  /// 用户在窗口上点了鼠标 / 滚了滚轮（`WM_PARENTNOTIFY`）。
  ///
  /// 这是"他在用这个窗口"最硬的证据：继承来的那次激活会让窗口一直是前台，
  /// 之后系统不会再发 `WM_ACTIVATE`，光靠激活消息永远清不掉
  /// [accidental_focus_] —— 表现为"有时候鼠标一离开就收，有时候不收"。
  void NoteUserInteraction();

  /// `WM_SYSCOMMAND(SC_MINIMIZE)` 的拦截：只有"收着"的时候才拦。
  ///
  /// 面板收成 4px 之后，**点任务栏按钮在 Windows 眼里是"最小化当前活动窗口"**
  /// （它不知道面板已经缩到屏幕上方去了，只按"这个窗口还是前台"处理），
  /// 于是那一下不是把面板叫出来，而是把它最小化 —— 用户看到的就是
  /// "在任务栏单击，收起的主页面消失了"。
  ///
  /// 收着的面板上"最小化"对用户没有任何意义（他连窗口都看不见），
  /// 所以这里直接把这次最小化换成"露出来"。
  ///
  /// 返回 true = 已吃掉这条消息，调用方不要再交给 `DefWindowProc`。
  bool InterceptMinimize();

  /// 立刻复位到"露出"状态：Alt+Tab、点任务栏图标、关窗口之前都要调。
  void ShowNow();

  /// 用户开始/结束拖动：拖动过程中不自动收（这时候收起来等于打断用户）。
  void SetInSizeMove(bool in_size_move) { in_size_move_ = in_size_move; }

  /// 真的在拖动 / 拉伸吗？
  ///
  /// 不能只看 `in_size_move_`：`WM_EXITSIZEMOVE` **不一定来**（拖到一半弹出
  /// 系统菜单、远程桌面断线、窗口被别的程序 `SetCapture`）。标志位一旦卡在
  /// true，自动收起、唤出、贴顶全都静默失效，用户看到的是"点任务栏没反应"。
  /// 所以额外核对"左键是否真的按着 / 本线程是否真的持有鼠标捕获"，两者都不
  /// 成立就当它过期，顺手复位。
  bool IsSizeMoving();

  /// 保存几何时用这个：隐藏状态下拿到的是"露出时"的矩形，不是屏幕外那个。
  RECT rest_rect() const { return rest_; }

  /// 打开行为日志（`--edge-trace` 启动参数）。默认关，关着的时候零开销。
  ///
  /// 这个功能的每一步都取决于"现在谁在前台 / 鼠标在哪"，出问题时从界面
  /// 完全看不出来。日志写到 `%TEMP%\wxbills-edge.log`，只记状态转换，
  /// 不记每个 tick。
  static void SetTraceEnabled(bool enabled);

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

  /// [last_foreground_] 这个样本的有效期：超过就当成"没见过"，即按用户主动
  /// 处理（原因见 `wxb::IsInheritedActivation`）。
  static constexpr DWORD kForegroundSampleTtlMs = 500;

  /// "刚从最小化还原"的有效期：这段时间里的激活一律按用户主动处理
  /// （顺位继承不会把窗口从最小化里拉出来）。
  static constexpr DWORD kRestoredWindowMs = 1500;

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
  /// 移动**并改尺寸**：只在启动恢复 / 贴顶这类"没有动画"的地方用。
  /// 动画里必须走 [MoveTo]，尺寸一变 Flutter 每帧都要重排，滑动必然掉帧。
  void PlaceTo(const RECT& rect);
  void UpdateWorkArea();
  /// |force| 为 false 时只在 DPI / 显示器变化后真的去问 DWM：边框宽度不会天天变，
  /// 每次 tick 都查一遍纯属白花。
  void UpdateFramePadding(bool force);
  /// kNormal 状态下把 rest_ / dock_ 对齐到"窗口现在的真实位置"。
  /// 不变量：kNormal 时 `rest_ == GetWindowRect()`。
  void RefreshNormalGeometry();
  /// kNormal 下发现窗口"屏幕上几乎看不见"（动画中断、还原到隐藏位置…）时
  /// 把它放回工作区顶边。见 `wxb::IsNearlyOffscreen`。
  void RepairNormalPlacement();
  /// 动画的时间预算（毫秒）：超过这个时长还没走完，就直接落到终点。
  /// 帧步进理论上不会超时，但 WM_TIMER 是低优先级消息，消息队列堵住时会被
  /// 饿死；没有这条兜底，phase_ 会永远停在 kShowing/kHiding，窗口卡在半路。
  DWORD AnimationBudget() const;
  /// 别人全屏时把藏起来的窗口彻底收走（不是 `SW_HIDE`，见实现）。
  void SetSuppressed(bool suppressed);
  /// 前台窗口是不是**真全屏**（整块显示器都被盖住，且盖的是我们这块）。
  bool ForegroundIsFullscreen() const;
  wxb::Rect VisibleRest() const;
  RECT HiddenRect() const;
  /// 被全屏内容挤走时窗口待的位置：整块推到工作区上方，一个像素都不留在屏幕上。
  ///
  /// 刻意不用 `SW_HIDE`：那会把任务栏按钮一起拿走，副屏全屏时用户就再也
  /// 叫不出面板了（只能重启程序靠单实例逻辑捞回来）。
  RECT SuppressedRect() const;
  bool CanAutoHide();
  bool CursorOnWindow(POINT pt) const;
  bool CursorOnStrip(POINT pt) const;
  bool ForegroundIsOwnDialog() const;
  /// 顺位继承来的激活一律把前台还回去（见 [OnActivated]）。
  void ReleaseForegroundToShell();
  /// 采样「现在谁在前台」，供 [IsInheritedActivation] 判断下次激活的来源。
  void TrackForeground();

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
  bool suppressed_ = false;  // 别人全屏 → 整块挪到屏幕外（不是 SW_HIDE，见实现）
  bool in_size_move_ = false;
  bool topmost_ = false;  // 隐藏期间是否置顶（保证那 4px 条不被别的窗口盖住）

  UINT_PTR idle_timer_ = 0;
  UINT_PTR leave_timer_ = 0;
  UINT_PTR anim_timer_ = 0;

  /// 鼠标开始停在「露出条」上的时刻（GetTickCount）。0 表示当前不在条上。
  /// 见 `Params::dwell_ms`：只在条上**停够时间**才算唤出，路过不算。
  DWORD strip_since_ = 0;

  /// 上一次轮询时看到的「别的窗口」的前台 HWND。
  ///
  /// 用来区分两种 `WM_ACTIVATE`：
  ///  * 用户主动（点任务栏图标 / Alt+Tab）→ 上一个前台还好好活着 → 露出来；
  ///  * 顺位继承（上一个前台被关掉 / 最小化）→ 那个 HWND 已经没了或已最小化
  ///    → 什么都不做（见 [OnActivated]）。
  HWND last_foreground_ = nullptr;

  /// 上面那个样本的采样时刻（GetTickCount）。0 = 还没采过。
  ///
  /// 轮询在"自己最小化"期间是停着的（`kLeaving` 的 180ms 也不采），样本可能
  /// 已经过期几十秒；过期的样本一概不可信（见 `wxb::IsInheritedActivation`）。
  DWORD last_foreground_tick_ = 0;

  /// 这次前台是系统「顺位」塞给我们的，不是用户想用这个窗口。
  ///
  /// 有它才能两头都对：顺位激活既不弹面板，也不让"前台"这条规则把窗口钉住
  /// （否则悬停弹出来之后就收不回去了）。
  bool accidental_focus_ = false;

  /// 上次**用户主动**唤出的时刻（GetTickCount，0 = 没有过）。
  /// 保护期见 `Params::reveal_grace_ms`。
  DWORD reveal_tick_ = 0;

  /// 我们自己是不是正处在"被最小化"的状态。
  ///
  /// 不直接用 `IsIconic()`：`WM_SIZE(SIZE_MINIMIZED)` 与随后的
  /// `WM_ACTIVATE` 谁先到不确定，还原那一刻 `IsIconic()` 可能已经是 false 了。
  bool was_iconic_ = false;

  /// 最近一次"从最小化还原"的时刻。还原动作**只可能是用户做的**
  /// （顺位继承不会把窗口从最小化里拉出来），所以这段时间内的激活一律按
  /// 用户主动处理，不再看 `last_foreground_` 那个可能过期的样本。
  DWORD restored_tick_ = 0;

  /// 动画开始时刻 + 预算（见 [AnimationBudget]）。
  DWORD anim_started_ = 0;
  DWORD anim_budget_ms_ = 0;

  /// [RepairNormalPlacement] 里的重入保护：`MoveTo` 会同步派发 `WM_MOVE`，
  /// 那条消息又会走回 `SyncFromWindow` → `RefreshNormalGeometry`。
  bool repairing_ = false;

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
