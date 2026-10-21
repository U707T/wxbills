import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/scanner.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/platform/photo_source.dart';

/// 扫描用替身：可指定列目录结果、是否报告列目录失败、读图时干什么。
class ScanSource implements PhotoSource {
  ScanSource({
    this.path = '/album/a.png',
    this.modified = 1,
    this.listErrorText = '',
    this.thumbBytes,
    this.onLoad,
  });

  final String path;
  final int modified;
  final String listErrorText;
  final List<int>? thumbBytes;
  final void Function()? onLoad;

  @override
  bool get supportsRefreshDate => false;
  @override
  bool get supportsCopyImage => false;
  @override
  Future<bool> copyImage(String path) async => false;
  @override
  String get listError => listErrorText;
  @override
  String get loadError => '';
  @override
  Future<({String path, String name})?> pickFolder() async => null;
  @override
  Future<bool> folderExists(String folderPath) async => true;
  @override
  Future<List<PhotoRef>> listImages(String folderPath,
          {String folderId = ''}) async =>
      [
        PhotoRef(
          path: path,
          name: 'a.png',
          modified: modified,
          size: 1,
          folderId: folderId,
        ),
      ];
  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async {
    onLoad?.call();
    return null; // 不真跑 OCR：这组用例只关心「写回时会不会覆盖用户的选择」
  }

  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async =>
      thumbBytes == null ? null : Uint8List.fromList(thumbBytes!);

  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async =>
      const RefreshOutcome(ok: false);

  @override
  Future<int?> originalLength(String path) async => null;
  @override
  Future<Uint8List?> readOriginal(String path) async => null;
}

Future<(Directory, AppDirs, BillStore)> newStore() async {
  final tmp = await Directory.systemTemp.createTemp('wxbills_scan_fix');
  final dirs = AppDirs(tmp);
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  store.addFolder('/album', 'album');
  return (tmp, dirs, store);
}

Bill bill({
  String id = 'x',
  String path = '/album/a.png',
  int? cents = 100,
  bool manual = false,
  int fileModified = 1,
  String thumb = '',
  String folder = '',
}) =>
    Bill(
      id: id,
      name: 'a.png',
      path: path,
      amountCents: cents,
      confidence: 1,
      manual: manual,
      fileModified: fileModified,
      importedAt: 1,
      updatedAt: 1,
      thumb: thumb,
      folder: folder,
    );

void main() {
  test('扫描期间用户手改的金额与 manual 标记，不会被识别结果覆盖', () async {
    final (tmp, dirs, store) = await newStore();
    final fid = store.folders.first.id;
    store.put(bill(folder: fid));
    await store.save();

    final src = ScanSource(modified: 2, onLoad: () {
      // 扫描正在跑，用户此刻把金额改成 88.88
      store.setAmount('x', 8888);
    });
    final scanner = Scanner(store: store, source: src, dirs: dirs);
    await scanner.scanAll();

    expect(store.byId('x')!.amountCents, 8888, reason: '扫描必须让位给用户输入');
    expect(store.byId('x')!.manual, isTrue);

    await tmp.delete(recursive: true);
  });

  test('扫描期间用户删掉的记录，不会被识别结果复活', () async {
    final (tmp, dirs, store) = await newStore();
    final fid = store.folders.first.id;
    store.put(bill(folder: fid));
    await store.save();

    final src = ScanSource(modified: 2, onLoad: () {
      store.remove('x');
    });
    final scanner = Scanner(store: store, source: src, dirs: dirs);
    await scanner.scanAll();

    expect(store.byId('x')!.deleted, isTrue, reason: '墓碑不该被扫描写回成未删除');

    await tmp.delete(recursive: true);
  });

  test('缩略图上次生成失败的记录：文件没变也要补一次', () async {
    final (tmp, dirs, store) = await newStore();
    final fid = store.folders.first.id;
    store.put(bill(thumb: '', folder: fid));
    await store.save();

    final src = ScanSource(modified: 1, thumbBytes: [1, 2, 3]);
    final scanner = Scanner(store: store, source: src, dirs: dirs);
    await scanner.scanAll();

    expect(store.byId('x')!.thumb, 'x.jpg',
        reason: 'unchanged 分支也要补缩略图，否则这条记录永远没图');
    expect(await store.readThumb('x.jpg'), [1, 2, 3]);

    await tmp.delete(recursive: true);
  });

  test('列目录失败（平台层不抛异常，只报 listError）时，不清空记录', () async {
    final (tmp, dirs, store) = await newStore();
    final fid = store.folders.first.id;
    store.put(bill(folder: fid));
    await store.save();

    // 只返回空列表 + 报错，模拟「SAF 某个子目录读不到」
    final broken = _EmptySource();
    final r = await Scanner(store: store, source: broken, dirs: dirs).scanAll();

    expect(store.byId('x')!.deleted, isFalse,
        reason: '列目录失败过的目录必须跳过清理');
    expect(r.message, contains('读取失败'));

    await tmp.delete(recursive: true);
  });
}

/// 列目录返回空、但通过 listError 报告失败。
class _EmptySource implements PhotoSource {
  @override
  bool get supportsRefreshDate => false;
  @override
  bool get supportsCopyImage => false;
  @override
  Future<bool> copyImage(String path) async => false;
  @override
  String get listError => '列目录失败：provider 超时';
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
