import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/app/app.dart';
import 'package:wxbills/src/app/app_controller.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/scanner.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/platform/photo_source.dart';


/// 可控的图片源：能列出固定条目、能让列目录失败、能控制目录是否可访问。
class FakeSource implements PhotoSource {
  FakeSource({this.paths = const [], this.throwOnList = false});

  List<String> paths;
  bool throwOnList;
  bool accessible = true;

  /// 桌面端能力：行内按钮会换成「复制图片」
  bool copyable = false;
  final List<String> copied = [];

  @override
  bool get supportsRefreshDate => false;

  @override
  bool get supportsCopyImage => copyable;

  @override
  Future<bool> copyImage(String path) async {
    copied.add(path);
    return copyable;
  }

  @override
  String get loadError => '';

  @override
  Future<({String path, String name})?> pickFolder() async => null;

  @override
  Future<bool> folderExists(String folderPath) async => accessible;

  @override
  Future<List<PhotoRef>> listImages(String folderPath, {String folderId = ''}) async {
    if (throwOnList) throw const FileSystemException('SAF 列表读取超时');
    return [
      for (final p in paths)
        PhotoRef(
          path: p,
          name: p.split('/').last,
          modified: 1700000000000,
          size: 1,
          folderId: folderId,
        ),
    ];
  }

  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async => null;

  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async => null;

  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async =>
      const RefreshOutcome(ok: false);
}

Future<(Directory, AppDirs, BillStore, Scanner)> setup(
  FakeSource source, {
  List<String> paths = const ['/album/a.png'],
}) async {
  final tmp = await Directory.systemTemp.createTemp('wxbills_reg');
  final dirs = AppDirs(Directory('${tmp.path}/data'));
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  store.addFolder('/album', 'album');
  source.paths = paths;
  final scanner = Scanner(store: store, source: source, dirs: dirs);
  return (tmp, dirs, store, scanner);
}

Bill makeBill(String id, String path, {String folder = '', bool deleted = false}) =>
    Bill(
      id: id,
      name: path.split('/').last,
      path: path,
      amountCents: 1000,
      confidence: 1,
      manual: true,
      fileModified: 1000,
      importedAt: 1000,
      updatedAt: 1000,
      folder: folder,
      deleted: deleted,
    );

void main() {
  group('扫描不会误删', () {
    test('列目录失败：整个目录的记录保持不变（不能打墓碑）', () async {
      final (tmp, _, store, scanner) = await setup(FakeSource());
      await scanner.scanAll();
      final before = store.byId(store.bills.first.id)!;
      expect(before.deleted, isFalse);

      // 目录仍然可访问，但这次列目录失败（超时 / 授权抖动）
      final src = FakeSource()..throwOnList = true;
      final scanner2 = Scanner(store: store, source: src, dirs: store.dirs);
      final r = await scanner2.scanAll();

      expect(store.count, 1, reason: '列目录失败时不能把记录判成已删除');
      expect(store.byId(before.id)!.deleted, isFalse);
      expect(r.message, contains('读取失败'), reason: '要告诉用户这次清理被跳过了');

      await tmp.delete(recursive: true);
    });

    test('用户删除的记录：再扫描也不会自己复活', () async {
      final (tmp, _, store, scanner) = await setup(FakeSource());
      await scanner.scanAll();
      final id = store.bills.first.id;

      store.remove(id); // 界面点「删除」
      await store.save();
      expect(store.count, 0);

      await scanner.scanAll(); // 下次启动 / 手动扫描
      expect(store.count, 0, reason: '删除是用户的显式决策，扫描不得推翻');
      expect(store.byId(id)!.deleted, isTrue);

      await tmp.delete(recursive: true);
    });
  });

  group('存储', () {
    test('并发 save 不会写坏 data.json', () async {
      final tmp = await Directory.systemTemp.createTemp('wxbills_save');
      final dirs = AppDirs(tmp);
      await dirs.ensure();
      final store = BillStore(dirs);
      await store.load();
      for (var i = 0; i < 200; i++) {
        store.put(makeBill('id$i', '/album/$i.png'));
      }
      // 全部不 await：模拟「扫描落盘 + 界面编辑落盘」同时发生
      final futures = [for (var i = 0; i < 20; i++) store.save()];
      await Future.wait(futures);

      final text = await dirs.dataFile.readAsString();
      expect(() => jsonDecode(text), returnsNormally, reason: '落盘结果必须是完整 JSON');
      expect(text.trim().endsWith('}'), isTrue);

      final reloaded = BillStore(dirs);
      await reloaded.load();
      expect(reloaded.allIncludingDeleted.length, 200);
      expect(reloaded.loadWarning, isEmpty);

      await tmp.delete(recursive: true);
    });

    test('金额解析挡住会让 round() 抛异常的输入', () async {
      expect(Bill.parseYuan('NaN'), isNull);
      expect(Bill.parseYuan('inf'), isNull);
      expect(Bill.parseYuan('1e3'), isNull);
      expect(Bill.parseYuan('24.567'), isNull);
      expect(Bill.parseYuan('24.5'), 2450);
    });
  });

  group('合并语义', () {
    test('一方删除一方修改：删除胜（不会复活）', () {
      final live = makeBill('x', '/a/x.png');
      final tomb = live.copyWith(deleted: true, updatedAt: 99999);
      expect(mergeBill(live, tomb).deleted, isTrue);
      // 即使删除的时间戳更早，删除也胜
      expect(mergeBill(live.copyWith(updatedAt: 99999), tomb.copyWith(updatedAt: 1)).deleted,
          isTrue);
    });
  });

  testWidgets('定位能滚到屏幕外的记录（不是滚回顶部）', (tester) async {
    late Directory tmp;
    late AppController controller;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('wxbills_locate');
      final dirs = AppDirs(tmp);
      await dirs.ensure();
      final store = BillStore(dirs);
      await store.load();
      for (var i = 1; i <= 80; i++) {
        store.put(makeBill('id$i', '/album/n$i.png')
            .copyWith(amountCents: i * 100, manual: false));
      }
      await store.save();
      controller = AppController(
        dirs: dirs,
        store: store,
        source: FakeSource(paths: [for (var i = 1; i <= 80; i++) '/album/n$i.png']),
      );
      await controller.init();
    });
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    // 输入一个「没有完全相同金额」的查询，列表不会被筛窄，目标仍在屏幕外
    await tester.enterText(find.byType(TextField).first, '80.5');
    await tester.pumpAndSettle();
    await tester.tap(find.text('定位'));
    await tester.pumpAndSettle();

    final finder = find.text('¥ 80');
    expect(finder, findsOneWidget, reason: '目标记录必须被滚动到可视区域并构建出来');
    final dy = tester.getCenter(finder).dy;
    expect(dy, greaterThan(0));
    expect(dy, lessThan(tester.view.physicalSize.height / tester.view.devicePixelRatio));

    await tester.pump(const Duration(seconds: 2)); // 让闪烁定时器结束
    await tester.runAsync(() => tmp.delete(recursive: true));
  });

  testWidgets('编辑框清空金额 = 回到「未识别」，不是格式错误', (tester) async {
    late Directory tmp;
    late AppController controller;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('wxbills_clear');
      final dirs = AppDirs(tmp);
      await dirs.ensure();
      final store = BillStore(dirs);
      await store.load();
      store.put(makeBill('a', '/album/a.png'));
      await store.save();
      controller = AppController(dirs: dirs, store: store, source: FakeSource());
      await controller.init();
    });
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('¥ 10'));
    await tester.pumpAndSettle();
    // 对话框第一个输入框是金额：清空它再保存
    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(controller.store.byId('a')!.amountCents, isNull,
        reason: '清空金额应回到「未识别」，允许撤回错误识别');
    expect(find.text('未识别'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => tmp.delete(recursive: true));
  });

  test('识别诊断能指出卡在哪一步（读图失败 / 识别成功）', () async {
    final tmp = await Directory.systemTemp.createTemp('wxbills_diag');
    final dirs = AppDirs(Directory('${tmp.path}/data'));
    await dirs.ensure();
    final store = BillStore(dirs);
    await store.load();
    store.addFolder('/album', 'album');
    store.put(makeBill('a', '/album/a.png'));

    // 读图失败：诊断里必须带上具体原因，而不是只说「未识别」
    final broken = _DiagnoseSource()..error = '原生解码失败：decode_failed OOM';
    final c1 = AppController(dirs: dirs, store: store, source: broken);
    final text1 = await c1.diagnoseRecognition();
    expect(text1, contains('读图失败'));
    expect(text1, contains('decode_failed OOM'), reason: '失败原因必须原样带出来');

    // 读图成功：应报告尺寸与识别结果
    final ok = _DiagnoseSource()..readable = true;
    final c2 = AppController(dirs: dirs, store: store, source: ok);
    final text2 = await c2.diagnoseRecognition();
    expect(text2, contains('读图成功：2x2'));
    expect(text2, contains('识别结果'));

    await tmp.delete(recursive: true);
  });
  testWidgets('桌面端行内按钮是「复制图片」，点击后真的走复制', (tester) async {
    late Directory tmp;
    late AppController controller;
    late FakeSource source;
    late String shot;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('wxbills_copy');
      final dirs = AppDirs(tmp);
      await dirs.ensure();
      final store = BillStore(dirs);
      await store.load();
      // 原图必须是**真实存在**的文件：控制器会先确认文件在不在，
      // 找不到原图才退到缩略图（见 copy_plan.dart）。
      shot = '${tmp.path}/a.png';
      await File(shot).writeAsBytes(List<int>.filled(64, 1));
      source = FakeSource(paths: [shot])..copyable = true;
      store.addFolder('/album', 'album');
      controller = AppController(dirs: dirs, store: store, source: source);
      await controller.init();
      // 启动不再自动扫相册：要手动扫一次才会有记录（这正是本次的改动）
      await controller.scan(force: false);
    });
    await tester.pumpWidget(WxBillsApp(controller: controller));
    await tester.pumpAndSettle();

    // 桌面端：没有「刷新日期」，取而代之是「复制图片」
    expect(find.byIcon(Icons.content_copy_rounded), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);

    await tester.tap(find.byIcon(Icons.content_copy_rounded));
    await tester.pumpAndSettle();

    expect(source.copied, [shot], reason: '原图在本机时，点按钮要把原图交给剪贴板');
    await tester.pump(const Duration(seconds: 4));
    await tester.runAsync(() => tmp.delete(recursive: true));
  });
}

/// 诊断测试用：可切换「读图失败 / 成功」并带错误原因。
class _DiagnoseSource implements PhotoSource {
  bool readable = false;
  String error = '';

  @override
  bool get supportsRefreshDate => false;

  @override
  bool get supportsCopyImage => false;

  @override
  Future<bool> copyImage(String path) async => false;

  @override
  String get loadError => error;

  @override
  Future<({String path, String name})?> pickFolder() async => null;

  @override
  Future<bool> folderExists(String folderPath) async => true;

  @override
  Future<List<PhotoRef>> listImages(String folderPath, {String folderId = ''}) async => const [];

  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async {
    if (!readable) return null;
    return OcrImage(Uint8List(2 * 2 * 4)..fillRange(0, 16, 255), 2, 2);
  }

  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async =>
      Uint8List.fromList([1, 2, 3]);

  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async =>
      const RefreshOutcome(ok: false);
}
