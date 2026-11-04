#ifndef RUNNER_DOCK_MATH_H_
#define RUNNER_DOCK_MATH_H_

#include <wchar.h>  // wcscmp：壳表面类名比较用（不引入 windows.h，测试文件在 Linux 上也编得过）

// 贴边隐藏的**纯几何**部分：只依赖整数运算，不 include windows.h、不碰窗口句柄。
//
// 为什么要单独拆出来：这段逻辑决定了「窗口算不算贴边」「藏到哪」「鼠标碰到哪一块
// 算唤出」，全是边界条件成堆的地方（任务栏、多显示器、DPI）。拆成纯函数之后可以
// 用 `dock_math_test.cpp` 直接跑，不必开 Flutter、不必有窗口。
//
// **只做顶部贴边**。左边/右边在 Windows 上没法用拖动触发：鼠标碰到屏幕边缘时
// Aero Snap 会把窗口变成半屏，而"半屏贴靠"恰恰是最不该自动收起的情况
// （用户就是为了并排对照才那么放的）。顶部同理——拖到顶边会直接最大化。
// 所以触发方式是显式的「贴到顶部」动作（见 EdgeDock::SnapToTop），而不是拖拽。
namespace wxb {

/// 与 RECT 同构，但刻意不用 RECT：这样测试文件能在任何平台编译。
struct Rect {
  int left;
  int top;
  int right;
  int bottom;
};

inline int Width(const Rect& r) { return r.right - r.left; }
inline int Height(const Rect& r) { return r.bottom - r.top; }

/// 注意是左闭右开：窗口右边界正好等于 cursor.x 时不算在里面（与 Win32 的
/// HitTest 语义一致，少一像素的"粘手"感）。
inline bool Contains(const Rect& r, int x, int y) {
  return x >= r.left && x < r.right && y >= r.top && y < r.bottom;
}

/// 只有"没贴"和"贴顶"两种。
enum class DockEdge { kNone, kTop };

/// DWM 的"看不见的边框"：`GetWindowRect` 比肉眼看到的窗口每边多出约 7px
/// （Win10/11 的可调整边框 + 阴影），且随 DPI 缩放。
///
/// 这个差值决定了「露出 4px」到底是露出真的 4px，还是露出 4px 的**透明边框**
/// —— 后者表现为"条看不见、也点不到"，看起来就像功能彻底坏了。
struct FramePadding {
  int left;
  int top;
  int right;
  int bottom;
};

/// 窗口"肉眼可见"的矩形 = 外框去掉不可见边框。
inline Rect VisibleRect(const Rect& window, const FramePadding& pad) {
  return Rect{window.left + pad.left, window.top + pad.top,
              window.right - pad.right, window.bottom - pad.bottom};
}

/// 窗口贴在工作区顶边吗？
///
/// [tolerance] 是"离顶边多近算贴上"，调用方会按 DPI 缩放后传进来。
/// 比工作区还高的窗口一律不贴：收起来之后连标题栏都找不回来。
inline DockEdge ComputeDock(const Rect& window, const Rect& work, int tolerance) {
  if (Height(window) >= Height(work) - tolerance) return DockEdge::kNone;
  if (window.top - work.top <= tolerance) return DockEdge::kTop;
  return DockEdge::kNone;
}

/// 藏起来之后的窗口矩形：整块往上推，只留 [peek] 像素露在工作区顶部。
///
/// **只改位置不改尺寸**——runner 里靠 `SetWindowPos(SWP_NOSIZE)` 落实；一旦连带
/// 改尺寸，Flutter 每帧都要重新布局，滑动动画必然掉帧。
///
/// 露出量按**可见矩形**算，所以要补偿 [pad]：藏起来时 `rect.bottom` 要比
/// `work.top + peek` 再往下多一个底内边距，否则露出来的是透明边框。
inline Rect HiddenRect(const Rect& rest, const Rect& work, DockEdge dock,
                       int peek,
                       const FramePadding& pad = FramePadding{0, 0, 0, 0}) {
  Rect r = rest;
  if (dock == DockEdge::kTop) {
    r.bottom = work.top + peek + pad.bottom;
    r.top = r.bottom - Height(rest);
  }
  return r;
}

/// 光标是否落在"露出条"上（唤醒热区）。
///
/// [margin] 是条两侧的容差：条只有 4px 高，要求像素级命中会让人以为功能坏了。
inline bool InPeekStrip(const Rect& rest, const Rect& work, DockEdge dock,
                        int peek, int margin, int x, int y) {
  if (dock != DockEdge::kTop) return false;
  return y >= work.top - margin && y <= work.top + peek + margin &&
         x >= rest.left - margin && x <= rest.right + margin;
}

/// 夹回工作区时至少留多少像素可见（逻辑像素）。
///
/// `EdgeDock::Params::min_visible` 用它当默认值，`main.cpp` 在建窗之前夹
/// 记忆几何时也用它 —— 同一个数字不要在三个地方各写一遍。
inline constexpr int kMinVisible = 80;

/// 把矩形夹回工作区：先缩到能放下的尺寸，再保证横向/纵向各有至少
/// [min_visible] 像素可见。
///
/// 用在两个地方：读取上次保存的几何（显示器被拔掉、分辨率变了），以及
/// 隐藏期间换了分辨率后重算停靠位置。
///
/// **尺寸也要缩**：从 4K 换到 1080p 笔记本时，只挪位置的话窗口有一大半在屏幕
/// 外，而右下角的拉伸手柄正好也在屏幕外——用户自己都拉不回来。
inline Rect ClampToWork(const Rect& rect, const Rect& work, int min_visible) {
  Rect r = rect;
  if (Width(r) > Width(work)) r.right = r.left + Width(work);
  if (Height(r) > Height(work)) r.bottom = r.top + Height(work);

  const int w = Width(r);
  const int h = Height(r);

  if (r.right < work.left + min_visible) {
    r.left = work.left + min_visible - w;
    r.right = r.left + w;
  }
  if (r.left > work.right - min_visible) {
    r.right = work.right - min_visible;
    r.left = r.right - w;
  }
  if (r.bottom < work.top + min_visible) {
    r.top = work.top + min_visible - h;
    r.bottom = r.top + h;
  }
  if (r.top > work.bottom - min_visible) {
    r.bottom = work.bottom - min_visible;
    r.top = r.bottom - h;
  }
  return r;
}

/// 前台窗口把整个工作区都盖住了吗（全屏游戏 / 视频 / 最大化）。
///
/// 用来决定"藏起来的那条边要不要彻底躲开"：别人全屏的时候，屏幕上不该
/// 常驻一条 4px 的亮线。
inline bool CoversWorkArea(const Rect& window, const Rect& work) {
  return window.left <= work.left && window.top <= work.top &&
         window.right >= work.right && window.bottom >= work.bottom;
}

/// 这个窗口类名属于「系统壳表面」吗（桌面 / 任务栏 / 托盘溢出 / 任务栏预览）？
///
/// 这些窗口的矩形经常**就是整块显示器**，但它们不是"用户的全屏内容"：
///  * 任务栏设成"自动隐藏"时，`Shell_TrayWnd` 必须覆盖整块屏幕才能接住
///    鼠标（否则贴着屏幕下沿的那一下永远悬停不到）；
///  * Win10 1803+ / Win11 的桌面被拆成 `Progman` + `WorkerW`：`GetShellWindow()`
///    返回的是 `Progman`，而激活真正落到的是 `WorkerW`（还带着
///    `SHELLDLL_DefView`）。只比对 `GetShellWindow()` 会漏掉后者。
///
/// 为什么要单独认类名而不是"矩形够大就算"：见 [ShouldSuppressStrip] —— 误判
/// 一次，藏起来的那条 4px 就被挪到屏幕外（`SetSuppressed`），用户看到的是
/// "别的程序一最小化，面板也跟着没了"，而且鼠标再也唤不出来。
///
/// 这里只做纯字符串比较，不 include windows.h，测试文件能直接跑。
inline bool IsShellSurfaceClass(const wchar_t* class_name) {
  if (class_name == nullptr) return false;
  static const wchar_t* const kNames[] = {
      L"Progman",                             // 桌面（Win10/11 的一部分）
      L"WorkerW",                             // 桌面（壁纸 / 图标层）
      L"SHELLDLL_DefView",                    // 桌面图标层
      L"Shell_TrayWnd",                       // 主任务栏
      L"Shell_SecondaryTrayWnd",              // 副屏任务栏
      L"NotifyIconOverflowWindow",            // 托盘溢出面板
      L"TopLevelWindowForOverflowXamlIsland",  // Win11 的托盘溢出（XAML）
      L"TaskListThumbnailWnd",                // 任务栏缩略图预览
  };
  for (const wchar_t* name : kNames) {
    if (wcscmp(name, class_name) == 0) return true;
  }
  return false;
}

/// 这次「被激活」是不是系统**顺位继承**来的？
///
/// 别的窗口被关掉 / 最小化之后，Windows 会把前台交给 Z 序里的下一个可见窗口。
/// 贴边隐藏的面板虽然露在屏幕外，但它是 `WS_VISIBLE` 的，所以经常就是那个
/// "下一个" —— 于是用户明明是在关别人的窗口，这个面板却冒出来，过一会儿
/// （点了别的窗口、鼠标又不在上面）再自己收回去。
///
/// 参数全是调用方从 Win32 现查的，这里只做判断，方便在 dock_math_test 里
/// 把各种组合都跑一遍。
///
/// [previous_sample_fresh] 是**整个判据的前提**：`last_foreground_` 是轮询
/// 采样来的，而轮询在"自己最小化""收起/弹回动画"期间是停着的。样本一过期，
/// `IsWindow()` 查到的就是十几秒前的旧窗口（很可能已经关掉了）—— 于是用户
/// 真的去点任务栏，也会被当成"继承"，面板一点反应都没有（changelog v2.3.6
/// 第 2 条就是这个，当时只补了"用完即清"，没解决样本过期）。
///
/// 过期时**一律当成用户主动**：最坏的后果是面板多弹一次（用户再点一下别的
/// 窗口它就收回去）；反过来判错就是"面板叫不出来"，用户只能重启程序。
inline bool IsInheritedActivation(bool has_previous, bool previous_alive,
                                  bool previous_minimized,
                                  bool previous_visible,
                                  bool previous_sample_fresh = true) {
  if (!has_previous) return false;  // 没记到上一个前台：按"用户主动"处理
  if (!previous_sample_fresh) return false;  // 样本过期：不可信，按用户主动
  return !previous_alive || previous_minimized || !previous_visible;
}

/// 藏起来的那条边要不要彻底躲开（连 4px 都不留）？
///
/// 只有**真全屏**才躲：整块显示器都被别的窗口盖住（游戏 / 全屏视频），
/// 那种场景下面板上多一条亮边确实很碍眼。
///
/// 否决条件全是踩出来的，每一条都对应一次"面板自己消失 / 自己冒出来"：
///
///  * `is_shell_surface`（桌面 / 任务栏 / 托盘 / 任务栏预览）：它们的矩形
///    经常等于整块显示器。**这是最常见的一次误判**：用户只是最小化了别的
///    程序，前台顺位落到桌面（`WorkerW`）或任务栏，条就被挪到屏幕外 ——
///    看起来正是"别的程序最小化，它也最小化了"。判据见
///    [IsShellSurfaceClass]。
///  * `is_maximized`：任务栏设成"自动隐藏"时，最大化窗口也会盖满整块屏幕，
///    但它是用户日常最常见的状态，不是"全屏内容"。
///  * `is_dormant`（最小化 / 被 DWM 隐身（cloaked，UWP 挂起、别的虚拟桌面）/
///    不可见）：这些窗口的 `GetWindowRect` 还停在"还原后"的矩形上，拿它判
///    "盖住整块屏"必然误判 —— 而且它们此刻根本没在屏幕上放着任何内容。
///
/// [covers_monitor] 必须是「盖住**我们这块**显示器」：副屏放全屏视频时，
/// 主屏的条不该跟着躲——条一躲，那块屏上的面板就没了唤出入口。
inline bool ShouldSuppressStrip(bool has_foreground, bool same_process,
                                bool is_shell_surface, bool is_dormant,
                                bool is_maximized, bool covers_monitor) {
  if (!has_foreground || same_process || is_shell_surface) return false;
  if (is_dormant || is_maximized) return false;
  return covers_monitor;
}

/// 现在能不能自动收起？
///
/// 全是调用方从 Win32 现查的布尔值：这里只做判断，`dock_math_test.cpp` 能把
/// 每一种否决理由（没开 / 没贴顶 / 在拖 / 最小化 / 最大化 / 不可见 / 自己开着
/// 对话框 / 自己是前台 / 刚被唤出）分别跑一遍。
///
/// [foreground_is_self] 与 [accidental_focus] 是一对：窗口自己是前台时默认
/// **不收**（用户正在用，收起来等于"点一下就没"）；但如果这次前台是顺位继承
/// 来的（[IsInheritedActivation]），就不算用户在用它。
///
/// [within_reveal_grace] 是"刚被用户主动唤出（点任务栏 / Alt+Tab）之后的
/// 保护期"：那一刻鼠标还在任务栏上、不在窗口里，光看"鼠标是否在窗口内"会
/// 立刻把它收回去 —— 用户看到的就是**窗口闪一下就没了**。这段时间内不收。
inline bool CanAutoHideWith(bool enabled, bool docked, bool in_size_move,
                            bool iconic, bool zoomed, bool visible,
                            bool own_dialog, bool foreground_is_self,
                            bool accidental_focus,
                            bool within_reveal_grace = false) {
  if (!enabled || !docked || in_size_move) return false;
  if (iconic || zoomed) return false;
  if (!visible) return false;
  if (own_dialog) return false;
  if (within_reveal_grace) return false;
  if (foreground_is_self && !accidental_focus) return false;
  return true;
}

/// 贴顶状态下窗口"贴上去了但没贴平"（可见顶边跑到工作区上方）？
///
/// 这是"卡一半在顶部"的几何特征：贴顶的窗口只有两种合法位置 —— 完整露出来
/// （可见顶边 == 工作区顶边）或整个藏起来（只留 peek）。夹在中间说明有一次
/// 动画/还原被打断了，用户自己没法把它弄回来（Aero Snap 在顶边会直接最大化，
/// 所以他也拖不出这种位置）。
inline bool IsHalfBuried(const Rect& visible, const Rect& work, DockEdge dock) {
  return dock == DockEdge::kTop && visible.top < work.top;
}

/// 窗口是不是"屏幕上几乎看不见"（露在工作区里的高度 < [min_visible]）？
///
/// 用户**不可能**自己把窗口拖成这样：横向再怎么拖，`DragMove` 也会留一条
/// 标题栏在屏幕上；能变成这样的只有三种情况：
///  * 收起的动画被打断，窗口停在半路（"卡一半在顶部"）；
///  * 从任务栏还原时目标位置还是"隐藏矩形"（只剩 4px）；
///  * 记忆几何来自另一台机器 / 另一块屏幕，夹取没落实到尺寸。
///
/// 这些状态用户自己救不回来（看不见窗口，也就没地方点、没地方拖），所以
/// 调用方一旦发现就把它放回工作区顶边。
inline bool IsNearlyOffscreen(const Rect& visible, const Rect& work,
                              int min_visible) {
  const int top = visible.top > work.top ? visible.top : work.top;
  const int bottom = visible.bottom < work.bottom ? visible.bottom : work.bottom;
  const int left = visible.left > work.left ? visible.left : work.left;
  const int right = visible.right < work.right ? visible.right : work.right;
  if (right <= left) return true;   // 水平方向完全出界
  if (bottom <= top) return true;   // 垂直方向完全出界
  return (bottom - top) < (min_visible > 0 ? min_visible : 1);
}

/// 缓动：二次曲线。**收起和弹回用的不是同一条**：
///  * 收起（accelerate）用 ease-in —— 先慢后快，像被吸走；
///  * 弹回（decelerate）用 ease-out —— 先快后慢，稳稳停住。
///
/// 早先两边都用 ease-out，收起的**第一帧**就走完了 27% 的距离（700px 的窗口
/// 一帧跳 190px），看起来就是"啪"地一下没了，也就是用户说的"生硬"。
///
/// p 会被夹到 [0,1]，避免帧步进的累积误差导致过冲。
inline double ClampProgress(double p) {
  if (p <= 0.0) return 0.0;
  if (p >= 1.0) return 1.0;
  return p;
}

inline double EaseInQuad(double p) {
  const double t = ClampProgress(p);
  return t * t;
}

inline double EaseOutQuad(double p) {
  const double t = ClampProgress(p);
  const double inv = 1.0 - t;
  return 1.0 - inv * inv;
}

}  // namespace wxb

#endif  // RUNNER_DOCK_MATH_H_
