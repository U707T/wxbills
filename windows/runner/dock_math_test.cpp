// 贴边隐藏的几何单测。**不依赖 Flutter、不依赖 Windows**：
//
//   g++ -std=c++17 -Wall -Wextra -Werror windows/runner/dock_math_test.cpp -o t && ./t
//
// CI 的 test job 会跑这一条（见 .github/workflows/ci.yml）。这里覆盖的全是
// "在真机上要试半小时才能碰到一次"的情况：任务栏、负坐标副屏、拔掉显示器、
// 全屏程序、DWM 的不可见边框。
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

  // 顶边齐平 / 差 8px 以内都算贴；差 9px 不算
  CHECK(wxb::ComputeDock(Rect{100, 0, 1000, 700}, work, 8) == DockEdge::kTop);
  CHECK(wxb::ComputeDock(Rect{100, 8, 1000, 700}, work, 8) == DockEdge::kTop);
  CHECK(wxb::ComputeDock(Rect{100, 9, 1000, 700}, work, 8) == DockEdge::kNone);

  // 窗口顶边跑到屏幕上方（DWM 外框溢出，实际齐平）：仍然算贴
  CHECK(wxb::ComputeDock(Rect{100, -7, 1000, 700}, work, 8) == DockEdge::kTop);

  // 浮在中间：不贴
  CHECK(wxb::ComputeDock(Rect{200, 100, 1100, 800}, work, 8) == DockEdge::kNone);

  // 比工作区还高（最大化、或用户拉到满高）：绝不贴，收起来连标题栏都没了
  CHECK(wxb::ComputeDock(Rect{0, 0, 1920, 1040}, work, 8) == DockEdge::kNone);
  CHECK(wxb::ComputeDock(Rect{100, 0, 1000, 1035}, work, 8) == DockEdge::kNone);

  // 副屏在主屏上方（坐标是负的），贴它的顶边
  const Rect upper_monitor{0, -1080, 1920, 0};
  CHECK(wxb::ComputeDock(Rect{100, -1080, 1000, -400}, upper_monitor, 8) ==
        DockEdge::kTop);
}

void TestHiddenRect() {
  const Rect work{0, 0, 1920, 1040};
  const Rect rest{100, 0, 1000, 700};  // 900x700，贴顶

  // 只留 4px，宽度/高度不变
  const Rect hidden = wxb::HiddenRect(rest, work, DockEdge::kTop, 4);
  CHECK(hidden.bottom == 4);
  CHECK(hidden.top == 4 - 700);
  CHECK(wxb::Width(hidden) == wxb::Width(rest));
  CHECK(wxb::Height(hidden) == wxb::Height(rest));
  CHECK(hidden.left == rest.left);

  // 不贴边：原地不动（别把窗口搬走）
  CHECK(Same(wxb::HiddenRect(rest, work, DockEdge::kNone, 4), rest));

  // DWM 7px 不可见边框：露出的必须是"看得见"的 4px
  const wxb::FramePadding pad{7, 7, 7, 7};
  const Rect hidden_pad = wxb::HiddenRect(rest, work, DockEdge::kTop, 4, pad);
  CHECK(hidden_pad.bottom == 4 + 7);
  const Rect visible{hidden_pad.left, hidden_pad.top, hidden_pad.right,
                     hidden_pad.bottom};
  CHECK(wxb::VisibleRect(visible, pad).bottom == 4);
}

void TestPeekStrip() {
  const Rect work{0, 0, 1920, 1040};
  const Rect rest{100, 0, 1000, 700};

  // 贴顶：条在 y ∈ [0,4]，x 在窗口范围内
  CHECK(wxb::InPeekStrip(rest, work, DockEdge::kTop, 4, 3, 500, 2));
  CHECK(wxb::InPeekStrip(rest, work, DockEdge::kTop, 4, 3, 500, 0));
  // 条外 3px 容差以内仍然算（4px 的条要求像素级命中太苛刻）
  CHECK(wxb::InPeekStrip(rest, work, DockEdge::kTop, 4, 3, 500, 7));
  // 容差之外
  CHECK(!wxb::InPeekStrip(rest, work, DockEdge::kTop, 4, 3, 500, 20));
  // 横向超出窗口范围：不算（否则整条屏幕顶边都成了热区）
  CHECK(!wxb::InPeekStrip(rest, work, DockEdge::kTop, 4, 3, 1500, 2));
  // 不贴边时没有热区
  CHECK(!wxb::InPeekStrip(rest, work, DockEdge::kNone, 4, 3, 500, 2));
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

  // 整个在上边外面（比如窗口被拖到标题栏都在屏幕外的位置）
  const Rect offscreen_top{100, -900, 900, -100};
  const Rect clamped_top = wxb::ClampToWork(offscreen_top, work, 80);
  CHECK(clamped_top.bottom == 80);
  CHECK(clamped_top.top == 80 - 800);

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
  TestClampToWork();
  TestCoversWorkArea();
  TestEase();

  std::printf("%d checks, %d failed\n", g_checks, g_failed);
  return g_failed == 0 ? 0 : 1;
}
