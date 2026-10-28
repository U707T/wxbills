#ifndef RUNNER_DOCK_MATH_H_
#define RUNNER_DOCK_MATH_H_

// 贴边隐藏的**纯几何**部分：只依赖整数运算，不 include windows.h、不碰窗口句柄。
//
// 为什么要单独拆出来：这段逻辑决定了「窗口算不算贴边」「隐藏后停在哪」「鼠标
// 碰到哪一块算唤出」，全都是边界条件成堆的地方（任务栏、负坐标副屏、窗口比
// 屏幕还宽、贴着角落）。拆成纯函数之后可以用 `dock_math_test.cpp` 直接跑，
// 不必开 Flutter、不必有窗口。
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

enum class DockEdge { kNone, kLeft, kRight, kTop };

/// 窗口贴在哪条边上。
///
/// [tolerance] 是"离边多近算贴上"。**同时**贴上两条边的情况必须显式排除：
///  * 整宽（最大化、或用户拉得跟屏幕一样宽）→ 不贴，否则一移动到边上就收起来，
///    再也拖不回来；
///  * 比工作区还宽（跨屏/横跨两台显示器）→ 不贴，任何一侧收起都会遮住另一屏。
inline DockEdge ComputeDock(const Rect& window, const Rect& work, int tolerance) {
  if (Width(window) >= Width(work) - tolerance) return DockEdge::kNone;
  if (Height(window) >= Height(work) - tolerance) return DockEdge::kNone;

  const bool left = window.left - work.left <= tolerance;
  const bool right = work.right - window.right <= tolerance;
  // 左右都贴（窗口比工作区窄但横跨？）——不处理，宁可不动
  if (left && right) return DockEdge::kNone;
  if (left) return DockEdge::kLeft;
  if (right) return DockEdge::kRight;
  if (window.top - work.top <= tolerance) return DockEdge::kTop;
  return DockEdge::kNone;
}

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

/// 隐藏后的窗口矩形：只沿贴边方向平移出去，露出 [peek] 像素。
///
/// **只改位置不改尺寸**——runner 里靠 `SetWindowPos(SWP_NOSIZE)` 落实；一旦连带
/// 改尺寸，Flutter 每帧都要重新布局，滑动动画必然掉帧。
///
/// 露出量按**可见矩形**算，所以要补偿 [pad]：右贴时 `rect.left` 要比
/// `work.right - peek` 再往左挪一个左内边距。
inline Rect HiddenRect(const Rect& rest, const Rect& work, DockEdge dock,
                       int peek, const FramePadding& pad = FramePadding{0, 0,
                                                                       0, 0}) {
  Rect r = rest;
  switch (dock) {
    case DockEdge::kLeft:
      r.right = work.left + peek + pad.right;
      r.left = r.right - Width(rest);
      break;
    case DockEdge::kRight:
      r.left = work.right - peek - pad.left;
      r.right = r.left + Width(rest);
      break;
    case DockEdge::kTop:
      r.bottom = work.top + peek + pad.bottom;
      r.top = r.bottom - Height(rest);
      break;
    case DockEdge::kNone:
      break;
  }
  return r;
}

/// 光标是否落在"露出条"上（唤醒热区）。
///
/// [margin] 是条两侧的容差：条只有 4px 宽，要求像素级命中会让人以为功能坏了。
inline bool InPeekStrip(const Rect& rest, const Rect& work, DockEdge dock,
                        int peek, int margin, int x, int y) {
  switch (dock) {
    case DockEdge::kLeft:
      return x >= work.left - margin && x <= work.left + peek + margin &&
             y >= rest.top - margin && y <= rest.bottom + margin;
    case DockEdge::kRight:
      return x >= work.right - peek - margin && x <= work.right + margin &&
             y >= rest.top - margin && y <= rest.bottom + margin;
    case DockEdge::kTop:
      return y >= work.top - margin && y <= work.top + peek + margin &&
             x >= rest.left - margin && x <= rest.right + margin;
    case DockEdge::kNone:
      return false;
  }
  return false;
}

/// 看起来是系统"Aero Snap 半屏 / 全屏贴靠"（Win+←/→/↑）吗？
///
/// 这种窗口本来就是为了并排对照才贴边的，鼠标一离开就收起来会让人抓狂。
/// 两条判据，都只认"系统贴靠的那种尺寸"，不按"窗口大不大"一刀切：
///  * 宽度**正好**是工作区一半（±2px）—— 这是 Win+← / Win+→ 的结果；
///  * 宽度 ≥ 工作区 95% —— 这是 Win+↑ 的"铺满"（它不走最大化状态，
///    `IsZoomed` 判断不到）。
///
/// 早先的版本用"超过 55% 就不收"，结果是 1080p 上 1280 宽的默认窗口
/// （正好 66%）永远不收——功能看起来完全没生效。宁可少收，也不能整片不生效。
inline bool LooksSnapped(const Rect& window, const Rect& work) {
  const int work_width = Width(work);
  if (work_width <= 0) return false;
  const long long w = Width(window);
  const long long twice_diff = w * 2 - static_cast<long long>(work_width);
  if (twice_diff <= 4 && twice_diff >= -4) return true;
  return w * 100 >= static_cast<long long>(work_width) * 95;
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

/// 缓动：ease-out cubic。滑动不能是匀速的——匀速看起来"卡"，而且末端硬停。
/// p 会被夹到 [0,1]，避免定时器抖动导致过冲。
inline double EaseOutCubic(double p) {
  if (p <= 0.0) return 0.0;
  if (p >= 1.0) return 1.0;
  const double inv = 1.0 - p;
  return 1.0 - inv * inv * inv;
}

}  // namespace wxb

#endif  // RUNNER_DOCK_MATH_H_
