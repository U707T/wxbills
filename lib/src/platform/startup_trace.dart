import 'dart:io';

/// 冷启动埋点（Dart 侧）。
///
/// 和 Windows runner 的 `--startup-trace` 写进**同一个文件**
/// （`%TEMP%\wxbills-startup.log`），对着同一份日志能直接看出时间花在哪一段：
/// 引擎加载、Dart 初始化、读盘、首屏构建。
///
/// 默认**完全不动作**：不带这个参数启动时一个文件都不碰，也不会多一次 IO。
/// 只有要量启动时间的时候才：
///
/// ```
/// wxbills.exe --startup-trace
/// ```
///
/// 然后看 `%TEMP%\wxbills-startup.log`。
class StartupTrace {
  StartupTrace._(this.enabled) : _watch = (Stopwatch()..start());

  final bool enabled;
  final Stopwatch _watch;

  static StartupTrace _instance = StartupTrace._(false);

  static StartupTrace get instance => _instance;

  /// 由 `main()` 调用：带了参数才真的开始记。
  static void start(List<String> args) {
    if (!args.contains('--startup-trace')) return;
    _instance = StartupTrace._(true);
    _instance.mark('dart.main');
  }

  /// 记一个时间点。**任何失败都吞掉**：埋点绝不该影响启动。
  void mark(String name) {
    if (!enabled) return;
    final ms = _watch.elapsedMicroseconds / 1000.0;
    final now = DateTime.now();
    final line =
        'dart   pid=$pid ${_stamp(now)} $name=${ms.toStringAsFixed(1)}ms';
    try {
      File('${Directory.systemTemp.path}${Platform.pathSeparator}'
              'wxbills-startup.log')
          .writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // 临时目录不可写 / 被占用：安静放弃
    }
  }

  /// 与原生侧一致的 `HH:mm:ss.SSS`，用于把两份日志按时间对齐。
  String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }
}
