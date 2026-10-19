import 'package:flutter/material.dart';

import 'src/app/app.dart';
import 'src/app/app_controller.dart';
import 'src/data/app_dirs.dart';
import 'src/data/store.dart';
import 'src/platform/photo_source.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dirs = await AppDirs.resolve();
  await dirs.ensure();
  final store = BillStore(dirs);
  final source = createPhotoSource();

  final controller = AppController(dirs: dirs, store: store, source: source);
  runApp(WxBillsApp(controller: controller));
  // 先渲染再加载数据：冷启动更快，也让「正在加载」有反馈
  await controller.init();
}
