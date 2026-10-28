#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "startup_trace.h"

namespace {

constexpr char kWindowChannelName[] = "wxbills/window";

bool ReadBool(const flutter::EncodableMap& map, const char* key, bool fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  const bool* value = std::get_if<bool>(&it->second);
  return value != nullptr ? *value : fallback;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             const wxb::WindowState& state)
    : project_(project), state_(state) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  AttachWindowChannel();

  dock_ = std::make_unique<EdgeDock>();
  dock_->Attach(GetHandle(), state_.prefs.edge_hide);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // 首帧已经画好了：这时候才让窗口出现。
    // 最大化是**创建时**就设好的（WS_MAXIMIZE），这里只要"显示"，不能用
    // SW_SHOWMAXIMIZED —— 那会再触发一次尺寸变化，白闪一下。
    if (start_maximized_) {
      ShowWindow(GetHandle(), SW_SHOW);
    } else {
      this->Show();
    }
    wxb::StartupTraceMark("native.first_frame_shown");
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::ApplyStartupState() {
  const HWND hwnd = GetHandle();
  if (hwnd == nullptr) return;

  // 与 main.cpp 用的是同一组判断（window_state.h 里的 inline helper），
  // 避免"建窗时按记忆、恢复时又按默认"这种两边对不上的情况。
  const bool use_saved = wxb::ShouldRestoreGeometry(state_);
  start_maximized_ = wxb::ShouldStartMaximized(state_);

  if (dock_) {
    RECT current{};
    GetWindowRect(hwnd, &current);
    dock_->RestoreFromState(use_saved ? state_.rect : current,
                            start_maximized_);
  }
  wxb::StartupTraceMark("native.placement_ready");
}

void FlutterWindow::OnDestroy() {
  if (dock_) {
    dock_->Detach();
    dock_.reset();
  }
  if (channel_) {
    // 必须先注销：MethodChannel 析构不会自动摘掉 messenger 里的 handler，
    // 而那个 lambda 捕获了 this。窗口没了之后再收到一次 Dart 调用就是悬垂指针。
    channel_->SetMethodCallHandler(nullptr);
    channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::AttachWindowChannel() {
  if (!flutter_controller_ || !flutter_controller_->engine()) return;
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), kWindowChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { OnWindowMethodCall(call, std::move(result)); });
}

void FlutterWindow::OnWindowMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "getPrefs") {
    flutter::EncodableMap map;
    map[flutter::EncodableValue("remember")] =
        flutter::EncodableValue(state_.prefs.remember);
    map[flutter::EncodableValue("edge")] =
        flutter::EncodableValue(state_.prefs.edge_hide);
    result->Success(flutter::EncodableValue(map));
    return;
  }

  if (method == "setPrefs") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("bad_args", "setPrefs expects a map");
      return;
    }
    const bool remember = ReadBool(*args, "remember", state_.prefs.remember);
    const bool edge = ReadBool(*args, "edge", state_.prefs.edge_hide);
    const bool edge_changed = edge != state_.prefs.edge_hide;
    state_.prefs.remember = remember;
    state_.prefs.edge_hide = edge;
    if (dock_ && edge_changed) {
      // 关掉时 EdgeDock 会先把窗口放回来，不会把窗口留在屏幕外
      dock_->SetEnabled(edge);
    }
    PersistWindowState();
    result->Success();
    return;
  }

  if (method == "snapToTop") {
    // 「贴到顶部」是唯一的贴边入口：Windows 的 Aero Snap 让"拖到顶边"这个
    // 手势不可用（会直接最大化），所以只能点一下
    if (dock_) dock_->SnapToTop();
    PersistWindowState();
    result->Success();
    return;
  }

  result->NotImplemented();
}

void FlutterWindow::PersistWindowState() {
  const HWND hwnd = GetHandle();
  if (hwnd == nullptr || !dock_) return;

  wxb::WindowState state;
  state.valid = true;
  state.rect = dock_->rest_rect();
  state.maximized = IsZoomed(hwnd) != FALSE;
  state.prefs = state_.prefs;
  wxb::SaveWindowState(state);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // 贴边隐藏的轮询/动画定时器（只有这几个 WM_TIMER 会被吞）
  if (dock_ && dock_->HandleMessage(message, wparam)) {
    return 0;
  }

  // 几何变化交给 Win32Window 处理之后再重新判定贴边：
  // WM_DPICHANGED 会由基类 SetWindowPos 到新的矩形，先同步会拿到旧值。
  bool sync_dock_after = false;

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
    case WM_ENTERSIZEMOVE:
      if (dock_) dock_->SetInSizeMove(true);
      break;
    case WM_EXITSIZEMOVE:
      if (dock_) {
        dock_->SetInSizeMove(false);
        dock_->SyncFromWindow();
      }
      // 拖完就存：下一次启动直接到位，也避免关机时来不及保存
      PersistWindowState();
      break;
    case WM_ACTIVATE:
      // Alt+Tab、点任务栏图标：隐藏中的窗口必须立刻放出来，
      // 否则会"点了图标什么都不发生"。
      if (dock_ && LOWORD(wparam) != WA_INACTIVE) {
        dock_->ShowNow();
      }
      break;
    case WM_CLOSE:
      PersistWindowState();
      break;
    case WM_ENDSESSION:
      // 注销 / 关机：能存就存一次，别等下一条消息（可能不会再来）
      if (wparam != 0) PersistWindowState();
      break;
    case WM_MOVE:
    case WM_SIZE:
    case WM_DPICHANGED:
    case WM_DISPLAYCHANGE:
    case WM_SETTINGCHANGE:
      sync_dock_after = true;
      break;
    default:
      break;
  }

  const LRESULT result =
      Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  if (sync_dock_after && dock_) {
    dock_->SyncFromWindow();
  }
  return result;
}
