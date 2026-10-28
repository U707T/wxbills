#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "edge_dock.h"
#include "win32_window.h"
#include "window_state.h"

// A window that does nothing but host a Flutter view.
//
// 除了托管 Flutter 视图，它还负责两件**必须发生在原生层**的事：
//  1. 记住窗口大小/位置（Create 之前就要读到，否则窗口会先小后大地跳一下）；
//  2. 贴边隐藏（需要窗口失焦时也轮询全局鼠标，见 EdgeDock 的注释）。
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  FlutterWindow(const flutter::DartProject& project,
                const wxb::WindowState& state);
  ~FlutterWindow() override;

  /// `Create()` 之后调用：接上上次的停靠状态，并记下"启动时是否该最大化"。
  /// 最大化**不能**在这里 ShowWindow —— 那会在首帧之前把未绘制的窗口亮出来。
  void ApplyStartupState();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void AttachWindowChannel();
  void OnWindowMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  /// 落盘当前矩形 + 两个开关。隐藏状态下存的是"露出时"的矩形。
  void PersistWindowState();

  // The project to run.
  flutter::DartProject project_;

  // 启动时读到的状态；也是运行期的唯一真相（Dart 改开关就是改这里）
  wxb::WindowState state_;

  // 首帧之后要不要直接最大化
  bool start_maximized_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<EdgeDock> dock_;

  // MethodChannel('wxbills/window')：只承载"读/写两个开关"这一件事
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
