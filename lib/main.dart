import 'package:flutter/material.dart';

import 'src/app/app.dart';
import 'src/app/app_controller.dart';
import 'src/data/app_dirs.dart';
import 'src/data/store.dart';
import 'src/platform/photo_source.dart';
import 'src/platform/startup_trace.dart';

/// 启动顺序刻意是这样：
///  1. [StartupTrace] 认参数（只有带 `--startup-trace` 才写日志）；
///  2. 解析数据目录（Windows 上是纯 Dart 的 FFI 调用，几毫秒）；
///  3. **先 runApp 再读盘** —— 窗口是"首帧画好才显示"的，越早出帧越早看见窗口；
///  4. 读完数据只差一次 setState，列表就出来了。
///
/// 这里**不再**单独 `dirs.ensure()`：`store.load()` 里已经做了一次，
/// 以前 main 里那次纯属在首帧之前白花两次 mkdir。
Future<void> main(List<String> args) async {
  StartupTrace.start(args);
  WidgetsFlutterBinding.ensureInitialized();

  final dirs = await AppDirs.resolve();
  StartupTrace.instance.mark('dart.dirs');
  final store = BillStore(dirs);
  final source = createPhotoSource();

  final controller = AppController(dirs: dirs, store: store, source: source);
  runApp(WxBillsApp(controller: controller));
  StartupTrace.instance.mark('dart.run_app');

  // 先渲染再加载数据：冷启动更快，也让「正在加载」有反馈
  await controller.init();
  StartupTrace.instance.mark('dart.data_ready');
  // 数据就绪后的第一帧 = 用户真正「看到列表」的时刻（和原生侧 first_frame 对齐）
  WidgetsBinding.instance.addPostFrameCallback((_) {
    StartupTrace.instance.mark('dart.list_frame');
  });
}
