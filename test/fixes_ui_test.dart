import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/app/app_controller.dart';
import 'package:wxbills/src/app/pages/settings_page.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/platform/photo_source.dart';

class UiSource implements PhotoSource {
  @override
  bool get supportsRefreshDate => false;
  @override
  bool get supportsCopyImage => false;
  @override
  Future<bool> copyImage(String path) async => false;
  @override
  String get listError => '';
  @override
  String get loadError => '';
  @override
  Future<({String path, String name})?> pickFolder() async => null;
  @override
  Future<bool> folderExists(String folderPath) async => true;
  @override
  Future<List<PhotoRef>> listImages(String folderPath,
          {String folderId = ''}) async =>
      const [];
  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async => null;
  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async =>
      null;
  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async =>
      const RefreshOutcome(ok: false);
  @override
  Future<int?> originalLength(String path) async => null;
  @override
  Future<Uint8List?> readOriginal(String path) async => null;
}

Future<(Directory, AppController)> build(WidgetTester tester) async {
  late Directory tmp;
  late AppController controller;
  await tester.runAsync(() async {
    tmp = await Directory.systemTemp.createTemp('wxbills_ui_fix');
    final dirs = AppDirs(tmp);
    await dirs.ensure();
    final store = BillStore(dirs);
    await store.load();
    controller = AppController(dirs: dirs, store: store, source: UiSource());
    await controller.init();
  });
  return (tmp, controller);
}

void main() {
  testWidgets('只打开设置页再返回：不会凭空写入默认 WebDAV 地址', (tester) async {
    final (tmp, controller) = await build(tester);
    expect(controller.store.sync.configured, isFalse, reason: '前提：没配过同步');

    await tester.pumpWidget(MaterialApp(home: SettingsPage(controller: controller)));
    await tester.pumpAndSettle();

    // 相当于用户按返回
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(controller.store.sync.configured, isFalse,
        reason: '什么都没改就退出，不该把默认地址保存成「已配置」并开始自动同步');
    expect(controller.store.sync.autoSync, isTrue);

    await tester.runAsync(() => tmp.delete(recursive: true));
  });

  testWidgets('改了地址再返回：照常保存（dirty 标记不能把正常保存也挡掉）',
      (tester) async {
    final (tmp, controller) = await build(tester);

    await tester.pumpWidget(MaterialApp(home: SettingsPage(controller: controller)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'https://dav.example.com/x');
    await tester.pumpAndSettle();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();

    expect(controller.store.sync.url, 'https://dav.example.com/x');
    expect(controller.store.sync.configured, isTrue);

    await tester.runAsync(() => tmp.delete(recursive: true));
  });
}
