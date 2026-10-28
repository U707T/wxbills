#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <utility>
#include <vector>

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
  Win32Window::Point origin(use_saved_rect ? state.rect.left : kDefaultX,
                            use_saved_rect ? state.rect.top : kDefaultY);
  Win32Window::Size size(
      use_saved_rect
          ? static_cast<unsigned int>(state.rect.right - state.rect.left)
          : kDefaultWidth,
      use_saved_rect
          ? static_cast<unsigned int>(state.rect.bottom - state.rect.top)
          : kDefaultHeight);

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
