import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/app/app.dart';
import 'package:wxbills/src/app/app_controller.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/platform/photo_source.dart';

/// 无副作用、不碰平台通道的假图片源。
class StubPhotoSource implements PhotoSource {
  @override
  bool get supportsRefreshDate => true;

  @override
  bool get supportsCopyImage => false;

  @override
  Future<bool> copyImage(String path) async => false;

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
      const RefreshOutcome(ok: true);
}

/// 建一个带数据的控制器。
///
/// 注意：`testWidgets` 的函数体跑在 fake async 区域里，直接 await 真实文件 IO
/// 会永久挂起 —— 所有磁盘操作都必须包在 [WidgetTester.runAsync] 里。
Future<(Directory, AppController)> buildController(
  WidgetTester tester, {
  List<Bill> bills = const [],
}) async {
  late Directory tmp;
  late AppController controller;
  await tester.runAsync(() async {
    tmp = await Directory.systemTemp.createTemp('wxbills_ui');
    final dirs = AppDirs(tmp);
    await dirs.ensure();
    final store = BillStore(dirs);
    await store.load();
    for (final b in bills) {
      store.put(b);
    }
    await store.save();
    controller = AppController(
      dirs: dirs,
      store: store,
      source: StubPhotoSource(),
    );
    await controller.init();
  });
  return (tmp, controller);
}

Future<void> cleanup(WidgetTester tester, Directory tmp) async {
  await tester.runAsync(() => tmp.delete(recursive: true));
}

Bill sample(String id, int cents, {String note = '', bool manual = false}) => Bill(
      id: id,
      name: '$id.png',
      path: '/x/$id.png',
      amountCents: cents,
      confidence: manual ? 1 : 0.9,
      manual: manual,
      fileModified: 1700000000000,
      importedAt: 1700000000000,
      updatedAt: 1700000000000,
      note: note,
    );

void main() {
  testWidgets('空列表显示引导文案与导入按钮', (tester) async {
    final (tmp, controller) = await buildController(tester);
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('收款单管理'), findsOneWidget);
    expect(find.text('还没有导入相册'), findsOneWidget);
    expect(find.text('导入文件夹'), findsOneWidget);

    await cleanup(tester, tmp);
  });

  testWidgets('有数据时按金额升序展示，合计正确', (tester) async {
    final (tmp, controller) = await buildController(tester, bills: [
      sample('a', 3100),
      sample('b', 1050),
      sample('c', 2450, note: '客户A'),
    ]);
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('¥ 10.50'), findsOneWidget);
    expect(find.text('¥ 24.50'), findsOneWidget);
    expect(find.text('¥ 31'), findsOneWidget);
    expect(find.textContaining('共 3 张'), findsOneWidget);
    expect(find.textContaining('合计 ¥66'), findsOneWidget);
    expect(find.text('客户A'), findsOneWidget);

    // 升序：10.50 在 24.50 之前
    final y10 = tester.getTopLeft(find.text('¥ 10.50')).dy;
    final y24 = tester.getTopLeft(find.text('¥ 24.50')).dy;
    final y31 = tester.getTopLeft(find.text('¥ 31')).dy;
    expect(y10 < y24 && y24 < y31, isTrue, reason: '金额升序排列');
    await cleanup(tester, tmp);
  });

  testWidgets('切换排序为金额降序后顺序反转', (tester) async {
    final (tmp, controller) = await buildController(tester, bills: [
      sample('a', 3100),
      sample('b', 1050),
    ]);
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('金额 ↓'));
    await tester.pumpAndSettle();

    final y31 = tester.getTopLeft(find.text('¥ 31')).dy;
    final y10 = tester.getTopLeft(find.text('¥ 10.50')).dy;
    expect(y31 < y10, isTrue, reason: '降序后 31 应在最前');

    await cleanup(tester, tmp);
  });

  testWidgets('搜索金额能筛选出对应记录', (tester) async {
    final (tmp, controller) = await buildController(tester, bills: [
      sample('a', 3100),
      sample('b', 1050),
      sample('c', 2450),
    ]);
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '24.5');
    await tester.pumpAndSettle();

    expect(find.text('¥ 24.50'), findsOneWidget);
    expect(find.text('¥ 31'), findsNothing);
    expect(find.text('¥ 10.50'), findsNothing);

    await cleanup(tester, tmp);
  });

  testWidgets('点记录打开编辑框，保存后金额与「手动」标记更新', (tester) async {
    final (tmp, controller) = await buildController(tester, bills: [sample('a', 1050)]);
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('¥ 10.50'));
    await tester.pumpAndSettle();
    expect(find.text('确认金额'), findsOneWidget);

    // 对话框里第一个输入框是金额（第二个是备注）
    await tester.enterText(find.byType(TextField).at(1), '88.8');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(controller.store.byId('a')!.amountCents, 8880);
    expect(controller.store.byId('a')!.manual, isTrue);
    expect(find.text('¥ 88.80'), findsOneWidget);
    expect(find.text('手动'), findsOneWidget);

    await cleanup(tester, tmp);
  });

  testWidgets('设置页可以打开并显示同步表单', (tester) async {
    final (tmp, controller) = await buildController(tester);
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.text('WebDAV 同步'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('图片来源文件夹'), findsOneWidget);

    await cleanup(tester, tmp);
  });

  testWidgets('删除记录：确认后从列表移除（写入墓碑）', (tester) async {
    final (tmp, controller) = await buildController(tester, bills: [
      sample('a', 1050),
      sample('b', 2450),
    ]);
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('删除这条记录？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(controller.store.bills.length, 1);
    expect(controller.store.allIncludingDeleted.length, 2,
        reason: '删除应写墓碑而不是物理删除');

    await cleanup(tester, tmp);
  });

  testWidgets('提示条真的会显示（ScaffoldMessenger 挂对了地方）', (tester) async {
    final (tmp, controller) = await buildController(tester, bills: [sample('a', 1050)]);
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    controller.showToast('已复制图片');
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget,
        reason: '之前 context 取在 MaterialApp 之上，maybeOf 返回 null，所有提示都不显示');
    expect(find.text('已复制图片'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await cleanup(tester, tmp);
  });

  testWidgets('「刷新日期」的说明只弹第一次，之后直接开始', (tester) async {
    final (tmp, controller) = await buildController(tester, bills: [sample('a', 1050)]);
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    // 第一次：弹说明
    await tester.tap(find.byIcon(Icons.refresh_rounded).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('刷新 1 张图片的日期'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 点过「开始」才算看过：这里用控制器直接标记，模拟用户确认过一次
    await tester.runAsync(() => controller.markTipSeen(TipKeys.refreshDate));
    await tester.pumpAndSettle();

    // 第二次：不再弹说明
    await tester.tap(find.byIcon(Icons.refresh_rounded).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('刷新 1 张图片的日期'), findsNothing,
        reason: '同一段说明每次点都弹一遍是噪音');

    await cleanup(tester, tmp);
  });
}
