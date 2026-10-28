#ifndef RUNNER_STARTUP_TRACE_H_
#define RUNNER_STARTUP_TRACE_H_

// 冷启动埋点：**只有带 `--startup-trace` 启动时才动作**，平时零开销、零文件。
//
// 为什么要有它：Windows 上的"启动慢"有四五种完全不同的成因（引擎加载、首帧
// 布局、杀软扫描、数据读取），猜哪个都会白干。这里在原生侧打几个时间点，
// Dart 侧（`lib/src/platform/startup_trace.dart`）往同一个文件再补几个，
// 对着同一份日志能直接看出时间花在哪一段。
//
// 输出：`%TEMP%\wxbills-startup.log`，每次启动追加一组记录，同时写
// OutputDebugString（DebugView / VS 输出窗口也能看到）。
namespace wxb {

/// 由 main 根据命令行决定是否开启。
void StartupTraceInit(bool enabled);
bool StartupTraceEnabled();

/// 记一个时间点。[name] 是静态字符串，不做拷贝。
void StartupTraceMark(const char* name);

}  // namespace wxb

#endif  // RUNNER_STARTUP_TRACE_H_
