// 贴边隐藏的几何单测。**不依赖 Flutter、不依赖 Windows**：
//
//   g++ -std=c++17 -Wall -Wextra -Werror windows/runner/dock_math_test.cpp -o t && ./t
//
// CI 的 test job 会跑这一条（见 .github/workflows/ci.yml）。这里覆盖的全是
// "在真机上要试半小时才能碰到一次" 的情况：任务栏、副屏在左边（负坐标）、
// 拔掉显示器、半屏贴靠、窗口比屏幕宽。
#include <cstdio>
#include <cstdlib>

#include "dock_math.h"

namespace {

int g_failed = 0;
int g_checks = 0;

void Check(bool ok, const char* expr, int line) {
  ++g_checks;
  if (!ok) {
    ++g_failed;
    std::printf("FAIL line %d: %s\n", line, expr);
  }
}

#define CHECK(expr) Check((expr), #expr, __LINE__)

using wxb::DockEdge;
using wxb::Rect;

bool Same(const Rect& a, const Rect& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right &&
         a.bottom == b.bottom;
}

void TestComputeDock() {
  const Rect work{0, 0, 1920, 1040};  // 底边任务栏占 40

  // 贴左边 / 贴右边 / 贴顶边
  CHECK(wxb::ComputeDock(Rect{0, 100, 900, 800}, work, 8) == DockEdge::kLeft);
  CHECK(wxb::ComputeDock(Rect{1020, 100, 1920, 800}, work, 8) ==
        DockEdge::kRight);
  CHECK(wxb::ComputeDock(Rect{300, 0, 1200, 700}, work, 8) == DockEdge::kTop);

  // 离边 8px 以内算贴上；9px 不算
  CHECK(wxb::ComputeDock(Rect{8, 100, 900, 800}, work, 8) == DockEdge::kLeft);
  CHECK(wxb::ComputeDock(Rect{9, 100, 900, 800}, work, 8) == DockEdge::kNone);

  // 正常浮在中间：不贴
  CHECK(wxb::ComputeDock(Rect{200, 100, 1100, 800}, work, 8) ==
        DockEdge::kNone);

  // 左上角同时贴两条边：优先左边（QQ 的直觉也是往侧面收）
  CHECK(wxb::ComputeDock(Rect{0, 0, 900, 700}, work, 8) == DockEdge::kLeft);

  // 整宽（最大化）绝不贴边，否则收起来就再也拖不回来
  CHECK(wxb::ComputeDock(Rect{0, 0, 1920, 1040}, work, 8) == DockEdge::kNone);

  // 比工作区还宽（横跨两台显示器）：也不动
  CHECK(wxb::ComputeDock(Rect{-200, 100, 2100, 800}, work, 8) ==
        DockEdge::kNone);

  // 副屏在主屏左边，坐标是负的，仍然要能贴它的左边
  const Rect left_monitor{-1920, 0, 0, 1080};
  CHECK(wxb::ComputeDock(Rect{-1920, 100, -1000, 800}, left_monitor, 8) ==
        DockEdge::kLeft);
  CHECK(wxb::ComputeDock(Rect{-920, 100, 0, 800}, left_monitor, 8) ==
        DockEdge::kRight);
}

void TestHiddenRect() {
  const Rect work{0, 0, 1920, 1040};
  const Rect rest{1020, 100, 1920, 800};  // 900x700，贴右

  // 右贴：只留 4px，宽度不变
  const Rect hidden = wxb::HiddenRect(rest, work, DockEdge::kRight, 4);
  CHECK(hidden.left == 1916);
  CHECK(hidden.right == 1916 + 900);
  CHECK(wxb::Width(hidden) == wxb::Width(rest));
  CHECK(hidden.top == rest.top);

  // 右贴 + DWM 的 7px 不可见边框：露出的必须是"看得见"的 4px
  const wxb::FramePadding pad{7, 7, 7, 7};
  const Rect hidden_pad = wxb::HiddenRect(rest, work, DockEdge::kRight, 4, pad);
  CHECK(hidden_pad.left == 1920 - 4 - 7);
  const wxb::Rect visible =
      wxb::VisibleRect(wxb::Rect{hidden_pad.left, hidden_pad.top,
                                 hidden_pad.right, hidden_pad.bottom},
                       pad);
  CHECK(visible.left == 1920 - 4);
  CHECK(wxb::Width(visible) == wxb::Width(rest) - 14);

  // 左贴：可见的右边沿停在 work.left + 4
  const Rect left_hidden =
      wxb::HiddenRect(Rect{0, 100, 900, 800}, work, DockEdge::kLeft, 4, pad);
  CHECK(left_hidden.right == 4 + 7);
  CHECK(wxb::VisibleRect(wxb::Rect{left_hidden.left, left_hidden.top,
                                   left_hidden.right, left_hidden.bottom},
                         pad)
            .right == 4);

  // 上贴：只留 4px，高度不变
  const Rect top_hidden =
      wxb::HiddenRect(Rect{300, 0, 1200, 700}, work, DockEdge::kTop, 4);
  CHECK(top_hidden.top == 4 - 700);
  CHECK(top_hidden.bottom == 4);
  CHECK(wxb::Height(top_hidden) == 700);

  // 不贴边：原地不动（别把窗口搬走）
  CHECK(Same(wxb::HiddenRect(rest, work, DockEdge::kNone, 4), rest));
}

void TestPeekStrip() {
  const Rect work{0, 0, 1920, 1040};
  const Rect rest{1020, 100, 1920, 800};

  // 右贴：条在 [1916,1920]，y 在窗口范围内
  CHECK(wxb::InPeekStrip(rest, work, DockEdge::kRight, 4, 3, 1918, 400));
  CHECK(wxb::InPeekStrip(rest, work, DockEdge::kRight, 4, 3, 1919, 400));
  // 条外 3px 容差以内仍然算（4px 的条要求像素级命中太苛刻）
  CHECK(wxb::InPeekStrip(rest, work, DockEdge::kRight, 4, 3, 1915, 400));
  CHECK(wxb::InPeekStrip(rest, work, DockEdge::kRight, 4, 3, 1921, 400));
  // 容差之外
  CHECK(!wxb::InPeekStrip(rest, work, DockEdge::kRight, 4, 3, 1900, 400));
  // 纵向超出窗口范围：不算（否则整条屏幕边都成了热区）
  CHECK(!wxb::InPeekStrip(rest, work, DockEdge::kRight, 4, 3, 1918, 900));

  // 左贴
  CHECK(wxb::InPeekStrip(Rect{0, 100, 900, 800}, work, DockEdge::kLeft, 4, 3,
                         1, 400));
  CHECK(!wxb::InPeekStrip(Rect{0, 100, 900, 800}, work, DockEdge::kLeft, 4, 3,
                          40, 400));

  // 不贴边时没有热区
  CHECK(!wxb::InPeekStrip(rest, work, DockEdge::kNone, 4, 3, 1918, 400));
}

void TestLooksSnapped() {
  const Rect work{0, 0, 1920, 1040};
  // 半屏贴靠：按 Win+← 的那种（正好 50%），不能自动收
  CHECK(wxb::LooksSnapped(Rect{0, 0, 960, 1040}, work));
  // Win+↑ 的铺满（100%，但不是最大化状态）
  CHECK(wxb::LooksSnapped(Rect{0, 0, 1920, 1040}, work));
  // 1080p 上的默认窗口（1280 = 66%）**必须**能自动收，否则功能等于没做
  CHECK(!wxb::LooksSnapped(Rect{0, 100, 1280, 820}, work));
  // 普通窗口
  CHECK(!wxb::LooksSnapped(Rect{1000, 100, 1900, 800}, work));
  // 工作区宽度为 0 的退化情况不能除零/乱判
  CHECK(!wxb::LooksSnapped(Rect{0, 0, 10, 10}, Rect{0, 0, 0, 0}));
}

void TestClampToWork() {
  const Rect work{0, 0, 1920, 1040};

  // 位置正常：原样返回
  const Rect normal{100, 100, 900, 800};
  CHECK(Same(wxb::ClampToWork(normal, work, 80), normal));

  // 上次在副屏（副屏拔了），坐标整个跑到右边外面：拉回来，保证 80px 可见
  const Rect offscreen{3000, 200, 3800, 900};
  const Rect clamped = wxb::ClampToWork(offscreen, work, 80);
  CHECK(wxb::Width(clamped) == 800);
  CHECK(clamped.right == 1840);
  CHECK(clamped.left == 1040);

  // 整个在左边外面：只保证右边 80px 露出来，尺寸不变
  const Rect offscreen_left{-2000, 200, -1200, 900};
  const Rect clamped_left = wxb::ClampToWork(offscreen_left, work, 80);
  CHECK(clamped_left.right == 80);
  CHECK(clamped_left.left == 80 - 800);
  CHECK(wxb::Width(clamped_left) == 800);

  // 整个在上边外面（比如窗口被拖到标题栏都在屏幕外的位置）
  const Rect offscreen_top{100, -900, 900, -100};
  const Rect clamped_top = wxb::ClampToWork(offscreen_top, work, 80);
  CHECK(clamped_top.bottom == 80);
  CHECK(clamped_top.top == 80 - 800);
  CHECK(wxb::Height(clamped_top) == 800);

  // 从 4K 换到 1080p：尺寸必须一起缩。只挪位置的话，右下角的拉伸手柄
  // 正好在屏幕外，用户自己都拉不回来。
  const Rect huge{0, 0, 3840, 2160};
  const Rect shrunk = wxb::ClampToWork(huge, work, 80);
  CHECK(wxb::Width(shrunk) == 1920);
  CHECK(wxb::Height(shrunk) == 1040);
  CHECK(shrunk.left == 0 && shrunk.top == 0);
}

void TestCoversWorkArea() {
  const Rect work{0, 0, 1920, 1040};
  // 最大化 / 全屏独占（外框比工作区还大一点）
  CHECK(wxb::CoversWorkArea(Rect{0, 0, 1920, 1040}, work));
  CHECK(wxb::CoversWorkArea(Rect{-8, -8, 1928, 1040}, work));
  // 半屏、差一点的全屏都不算：不能因为"差不多"就把条藏掉
  CHECK(!wxb::CoversWorkArea(Rect{0, 0, 960, 1040}, work));
  CHECK(!wxb::CoversWorkArea(Rect{0, 0, 1920, 1030}, work));
}

void TestEase() {
  CHECK(wxb::EaseOutCubic(0.0) == 0.0);
  CHECK(wxb::EaseOutCubic(1.0) == 1.0);
  CHECK(wxb::EaseOutCubic(-1.0) == 0.0);  // 定时器抖动导致的负数不能过冲
  CHECK(wxb::EaseOutCubic(2.0) == 1.0);
  // 单调递增
  double prev = -1.0;
  for (int i = 0; i <= 10; ++i) {
    const double v = wxb::EaseOutCubic(i / 10.0);
    CHECK(v >= prev);
    prev = v;
  }
}

}  // namespace

int main() {
  TestComputeDock();
  TestHiddenRect();
  TestPeekStrip();
  TestLooksSnapped();
  TestClampToWork();
  TestCoversWorkArea();
  TestEase();

  std::printf("%d checks, %d failed\n", g_checks, g_failed);
  return g_failed == 0 ? 0 : 1;
}
