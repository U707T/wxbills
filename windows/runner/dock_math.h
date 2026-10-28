#ifndef RUNNER_DOCK_MATH_H_
#define RUNNER_DOCK_MATH_H_

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
