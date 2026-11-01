#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <utility>
#include <vector>

#include "dock_math.h"
#include "flutter_window.h"
#include "startup_trace.h"
#include "utils.h"
#include "window_state.h"

namespace {

bool HasFlag(const std::vector<std::string>& arguments, const char* flag) {
  for (const std::string& argument : arguments) {
    if (argument == flag) return true;
  }
  return false;
}

// 建窗之前先按目标显示器的工作区夹一次。
//
// 这一步不能省：Create 用的是 ini 里的**物理像素**原样尺寸，从 4K 外接屏换到
// 1080p 笔记本时，窗口第一帧就会是 3840x2160 —— 右下角的拉伸手柄正好在屏幕
// 外，用户自己都拉不回来。EdgeDock::RestoreFromState 里还会再夹一次（兜住
// "用户手改了 ini" 的情况），但那时候窗口已经画出来了。
RECT ClampSavedRect(const RECT& rect) {
  POINT center{rect.left + (rect.right - rect.left) / 2,
               rect.top + (rect.bottom - rect.top) / 2};
  const HMONITOR monitor = MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (monitor == nullptr || !GetMonitorInfoW(monitor, &info)) return rect;
  const wxb::Rect clamped = wxb::ClampToWork(
      wxb::Rect{rect.left, rect.top, rect.right, rect.bottom},
      wxb::Rect{info.rcWork.left, info.rcWork.top, info.rcWork.right,
                info.rcWork.bottom},
      wxb::kMinVisible);
  return RECT{clamped.left, clamped.top, clamped.right, clamped.bottom};
}

// 没有记忆时的默认窗口：1280x720（逻辑像素）放在左上角
constexpr int kDefaultX = 10;
constexpr int kDefaultY = 10;
constexpr unsigned int kDefaultWidth = 1280;
constexpr unsigned int kDefaultHeight = 720;

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // 冷启动埋点：只有带 --startup-trace 才写日志，平时零开销
  wxb::StartupTraceInit(HasFlag(command_line_arguments, "--startup-trace"));
  wxb::StartupTraceMark("native.entry");

  // 贴边隐藏的行为日志：只有带 --edge-trace 才写。
  // 这个功能出问题时（"它自己弹了一下"）全看当时的窗口/鼠标状态，
  // 从界面上什么都看不出来，日志是唯一能复盘的线索。
  EdgeDock::SetTraceEnabled(HasFlag(command_line_arguments, "--edge-trace"));

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // 单实例：两个进程会互相覆盖 window.ini（表现为"窗口位置随机"），
  // 还会各自轮询鼠标。已有的实例就把它叫到前台，然后安静退出。
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, L"Local\\wxbills-single-instance");
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    const HWND existing = ::FindWindowW(Win32Window::kRunnerWindowClassName,
                                        L"wxbills");
    if (existing != nullptr) {
      ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);  // 触发 WM_ACTIVATE，贴边隐藏的窗口会自己回来
    }
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // 几何必须在 Create 之前读到：窗口先按默认尺寸出现再被挪过去，会闪一下
  const wxb::WindowState state = wxb::LoadWindowState();
  const bool use_saved_rect = wxb::ShouldRestoreGeometry(state);
  const bool start_maximized = wxb::ShouldStartMaximized(state);

  FlutterWindow window(project, state);
  // 默认尺寸是逻辑像素（physical=false 时 Create 会乘 DPI）；
  // 记忆几何是物理像素，必须先夹回目标显示器的工作区。
  const RECT startup =
      use_saved_rect ? ClampSavedRect(state.rect)
                     : RECT{kDefaultX, kDefaultY,
                            kDefaultX + static_cast<LONG>(kDefaultWidth),
                            kDefaultY + static_cast<LONG>(kDefaultHeight)};
  Win32Window::Point origin(startup.left, startup.top);
  Win32Window::Size size(
      static_cast<unsigned int>(startup.right - startup.left),
      static_cast<unsigned int>(startup.bottom - startup.top));

  wxb::StartupTraceMark("native.before_create");
  // physical=true：保存下来的矩形已经是物理像素，不能再乘一次 DPI
  // maximized=true：直接用 WS_MAXIMIZE 创建，首帧之后不用再"跳到最大化"
  if (!window.Create(L"wxbills", origin, size, use_saved_rect,
                     start_maximized)) {
    return EXIT_FAILURE;
  }
  wxb::StartupTraceMark("native.window_created");

  window.ApplyStartupState();
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (single_instance != nullptr) {
    ::ReleaseMutex(single_instance);
    ::CloseHandle(single_instance);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
