#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <windows.h>

#include <string>

namespace wxb {

/// 窗口相关的两个开关。跟账本无关，**不进 data.json**。
struct WindowPrefs {
  bool remember = true;   // 记住窗口大小与位置
  bool edge_hide = true;  // 贴边隐藏
};

/// 上一次退出时的窗口状态。
struct WindowState {
  bool valid = false;    // 文件里有一份可用的几何
  RECT rect{};           // "露出时"的窗口矩形（物理像素，含标题栏）
  bool maximized = false;
  WindowPrefs prefs;
};

/// 要不要用上次保存的几何？（`valid` 且有记忆，且用户没关掉「记住」）
inline bool ShouldRestoreGeometry(const WindowState& state) {
  return state.valid && state.prefs.remember;
}

/// 要不要"一启动就最大化"？注意「记住窗口大小」关掉时这条也必须一起失效，
/// 否则用户关掉记忆后，窗口仍然每次弹成全屏。
inline bool ShouldStartMaximized(const WindowState& state) {
  return ShouldRestoreGeometry(state) && state.maximized;
}

/// `%LOCALAPPDATA%\wxbills\window.ini`
///
/// 为什么不放进 `data.json`（AppDirs 那套目录）：
///  1. data.json 会被 WebDAV 同步到另一台设备，窗口尺寸是**这台机器**的事；
///  2. 这份状态要在 Dart 起来**之前**读到 —— 否则窗口先按 1280x720 出现，再被
///     挪到记忆的位置，"闪一下"比不记忆还难看；
///  3. 写坏了也只影响窗口位置，不该有机会碰账本。
std::wstring WindowStateFilePath();

/// 读不到 / 解析失败都返回 `valid == false` 的默认值，不抛异常、不提示。
WindowState LoadWindowState();

/// 原子写（tmp + MoveFileEx）：关机瞬间被杀也不会留下半截文件。
void SaveWindowState(const WindowState& state);

}  // namespace wxb

#endif  // RUNNER_WINDOW_STATE_H_
