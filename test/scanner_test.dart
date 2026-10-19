import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/scanner.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/platform/photo_source.dart';

/// 假图片源：用真实文件系统模拟一个相册目录，但读图/缩略图走可注入的假实现，
/// 这样测试不依赖任何 Android 能力，也不会去解码真图片。
class FakePhotoSource implements PhotoSource {
  FakePhotoSource(this.root, {this.amounts = const {}});

  final Directory root;

  /// 文件名 → 假 OCR 结果的金额文本（null 表示认不出来）
  final Map<String, String?> amounts;

  bool refreshSupported = true;
  int refreshCalls = 0;
  bool folderAccessible = true;

  /// 刷新时是否模拟「重建文件 → 路径变化」
  bool changePathOnRefresh = false;

  @override
  bool get supportsRefreshDate => refreshSupported;

  @override
  Future<({String path, String name})?> pickFolder() async =>
      (path: root.path, name: root.path.split(Platform.pathSeparator).last);

  @override
  Future<bool> folderExists(String folderPath) async => folderAccessible;

  @override
  Future<List<PhotoRef>> listImages(String folderPath,
      {String folderId = ''}) async {
    final out = <PhotoRef>[];
    for (final e in root.listSync(recursive: true)) {
      if (e is! File) continue;
      final name = e.path.split(Platform.pathSeparator).last;
      if (!isImageName(name)) continue;
      final st = e.statSync();
      out.add(PhotoRef(
        path: e.path,
        name: name,
        modified: st.modified.millisecondsSinceEpoch,
        size: st.size,
        folderId: folderId,
        isSaf: false,
      ));
    }
    return out;
  }

  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async {
    // 用一个 60x80 的纯白图代替：识别器会直接返回空结果，
    // 具体的金额由 _FakeReader 逻辑覆盖（见 readOne / recognize 的注入）
    return OcrImage(Uint8List(60 * 80 * 4)..fillRange(0, 60 * 80 * 4, 255), 60, 80);
  }

  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async {
    // 内容里带上路径长度，模拟「每张图的缩略图不同」
    return Uint8List.fromList([1, 2, 3, path.length & 0xFF]);
  }

  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async {
    refreshCalls++;
    if (changePathOnRefresh) {
      return RefreshOutcome(
        ok: true,
        newPath: '${path}_r.png',
        message: '已重建为新图片',
      );
    }
    return const RefreshOutcome(ok: true, message: '已刷新');
  }
}

Future<(Directory, AppDirs, BillStore)> setup() async {
  final root = await Directory.systemTemp.createTemp('wxbills_scan');
  final dirs = AppDirs(Directory('${root.path}_data'));
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  return (root, dirs, store);
}

void writeImage(Directory dir, String name, {DateTime? modified}) {
  final f = File('${dir.path}/$name');
  final image = img.Image(width: 4, height: 4);
  f.writeAsBytesSync(img.encodePng(image));
  if (modified != null) f.setLastModifiedSync(modified);
}

void main() {
  test('首次扫描：每张图入库、生成缩略图、统计正确', () async {
    final (root, dirs, store) = await setup();
    final album = Directory('${root.path}/album')..createSync();
    writeImage(album, 'a.png');
    writeImage(album, 'b.png');
    File('${album.path}/note.txt').writeAsStringSync('不是图片');

    final source = FakePhotoSource(album);
    final scanner = Scanner(store: store, source: source, dirs: dirs);
    store.addFolder(album.path, 'album');

    final r = await scanner.scanAll();
    expect(r.total, 2);
    expect(store.count, 2);
    expect(store.bills.every((b) => b.thumb.isNotEmpty), isTrue,
        reason: '缩略图应生成，否则另一台设备看不到图');
    for (final b in store.bills) {
      expect(File('${dirs.thumbDir.path}/${b.thumb}').existsSync(), isTrue);
    }

    await root.delete(recursive: true);
    await dirs.root.delete(recursive: true);
  });

  test('增量扫描：没改动的图不会重复处理（第二次秒回）', () async {
    final (root, dirs, store) = await setup();
    final album = Directory('${root.path}/album')..createSync();
    writeImage(album, 'a.png');
    writeImage(album, 'b.png');

    final source = FakePhotoSource(album);
    final scanner = Scanner(store: store, source: source, dirs: dirs);
    store.addFolder(album.path, 'album');

    await scanner.scanAll();
    final before = store.bills.map((b) => '${b.id}:${b.updatedAt}').toList();

    final r2 = await scanner.scanAll();
    expect(r2.updated, 0, reason: '文件没变就不该有更新');
    expect(store.bills.map((b) => '${b.id}:${b.updatedAt}').toList(), before,
        reason: 'id 与 updatedAt 都不应变（否则会误触发同步）');

    await root.delete(recursive: true);
    await dirs.root.delete(recursive: true);
  });

  test('手工确认过的金额：重新扫描（含强制重识别）也不会被覆盖', () async {
    final (root, dirs, store) = await setup();
    final album = Directory('${root.path}/album')..createSync();
    writeImage(album, 'a.png');

    final source = FakePhotoSource(album);
    final scanner = Scanner(store: store, source: source, dirs: dirs);
    store.addFolder(album.path, 'album');
    await scanner.scanAll();

    final id = store.bills.first.id;
    store.setAmount(id, 2450, note: '客户确认');
    await store.save();

    // 强制重识别（相当于「重新识别全部」）
    await scanner.scanAll(forceRecheck: true);

    final after = store.byId(id)!;
    expect(after.amountCents, 2450, reason: '手工金额被自动结果冲掉了');
    expect(after.note, '客户确认', reason: '备注被冲掉了');
    expect(after.manual, isTrue);

    await root.delete(recursive: true);
    await dirs.root.delete(recursive: true);
  });

  test('文件被删除 → 记录软删除（墓碑），不是直接消失', () async {
    final (root, dirs, store) = await setup();
    final album = Directory('${root.path}/album')..createSync();
    writeImage(album, 'a.png');
    writeImage(album, 'b.png');

    final source = FakePhotoSource(album);
    final scanner = Scanner(store: store, source: source, dirs: dirs);
    store.addFolder(album.path, 'album');
    await scanner.scanAll();
    expect(store.count, 2);

    File('${album.path}/a.png').deleteSync();
    await scanner.scanAll();

    expect(store.count, 1);
    expect(store.allIncludingDeleted.where((b) => b.deleted).length, 1,
        reason: '删除要留墓碑才能同步给别的设备');

    await root.delete(recursive: true);
    await dirs.root.delete(recursive: true);
  });

  test('目录不可访问时不会误删记录（拔 U 盘 / 撤授权）', () async {
    final (root, dirs, store) = await setup();
    final album = Directory('${root.path}/album')..createSync();
    writeImage(album, 'a.png');

    final source = FakePhotoSource(album);
    final scanner = Scanner(store: store, source: source, dirs: dirs);
    store.addFolder(album.path, 'album');
    await scanner.scanAll();
    expect(store.count, 1);

    // 模拟授权被撤销：列不出图，且目录不可访问
    source.folderAccessible = false;
    album.deleteSync(recursive: true);
    await scanner.scanAll();

    expect(store.count, 1, reason: '目录不可访问时不能把记录删掉');

    await root.delete(recursive: true);
    await dirs.root.delete(recursive: true);
  });

  test('从别的设备同步来的记录（本机没有该文件）不会被扫描误删', () async {
    final (root, dirs, store) = await setup();
    final album = Directory('${root.path}/album')..createSync();
    writeImage(album, 'mine.png');

    final source = FakePhotoSource(album);
    final scanner = Scanner(store: store, source: source, dirs: dirs);
    store.addFolder(album.path, 'album');
    await scanner.scanAll();
    expect(store.count, 1);

    // 模拟从另一台设备同步过来的记录：路径属于那台设备，本机不存在这个文件
    store.put(const Bill(
      id: 'remote-1',
      name: 'phone.png',
      path: '/storage/emulated/0/DCIM/phone.png',
      amountCents: 999,
      confidence: 0.9,
      manual: false,
      fileModified: 1,
      importedAt: 1,
      updatedAt: 1,
      folder: 'other-device-folder-id',
    ));
    await store.save();

    await scanner.scanAll();

    expect(store.byId('remote-1')!.deleted, isFalse,
        reason: '本机没有这个文件 ≠ 它被删除了，不能打墓碑（否则会同步回去抹掉别的设备的数据）');
    expect(store.count, 2);

    await root.delete(recursive: true);
    await dirs.root.delete(recursive: true);
  });

  test('没有导入目录时给出可读提示，不抛异常', () async {
    final (root, dirs, store) = await setup();
    final source = FakePhotoSource(Directory(root.path));
    final scanner = Scanner(store: store, source: source, dirs: dirs);
    final r = await scanner.scanAll();
    expect(r.finished, isTrue);
    expect(r.message, contains('还没有导入'));
    await root.delete(recursive: true);
    await dirs.root.delete(recursive: true);
  });

  test('多目录里同一张图只入库一次', () async {
    final (root, dirs, store) = await setup();
    final a = Directory('${root.path}/a')..createSync();
    writeImage(a, 'same.png');

    final source = FakePhotoSource(a);
    final scanner = Scanner(store: store, source: source, dirs: dirs);
    store.addFolder(a.path, 'a');
    store.addFolder(a.path, 'a2');
    final r = await scanner.scanAll();
    expect(r.total, 1, reason: '同一路径应去重');
    expect(store.count, 1);

    await root.delete(recursive: true);
    await dirs.root.delete(recursive: true);
  });
}
