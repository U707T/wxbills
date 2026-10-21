import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/copy_plan.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/platform/photo_source.dart';
import 'package:wxbills/src/webdav/sync.dart';

import 'support/test_dav_server.dart';

/// 桌面替身：只实现「读原图」——原图同步真正需要的唯一平台能力。
class FilePhotoSource implements PhotoSource {
  @override
  bool get supportsRefreshDate => false;

  @override
  bool get supportsCopyImage => false;
  @override
  String get listError => '';

  @override
  Future<int?> originalLength(String path) async => null;

  @override
  Future<bool> copyImage(String path) async => false;

  @override
  String get loadError => '';

  @override
  Future<Uint8List?> readOriginal(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

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
}

SyncConfig cfg(TestDavServer s) => SyncConfig(
      url: s.url,
      username: 'alice',
      password: 'secret',
      autoSync: false,
    );

Future<(Directory, AppDirs, BillStore)> newDevice(String label) async {
  final tmp = await Directory.systemTemp.createTemp('wxbills_$label');
  final dirs = AppDirs(tmp);
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  return (tmp, dirs, store);
}

Bill localBill({
  String id = 'b1',
  String name = '微信图片_1.png',
  String path = '',
  String thumb = '',
}) =>
    Bill(
      id: id,
      name: name,
      path: path,
      amountCents: 2450,
      confidence: 0.95,
      manual: false,
      fileModified: 1000,
      importedAt: 1000,
      updatedAt: 1000,
      thumb: thumb,
    );

/// 第一台设备：一张真实存在的原图 + 缩略图，同步一次。
Future<({Directory tmp, AppDirs dirs, BillStore store, List<int> original})>
    uploadFromDeviceA(TestDavServer server) async {
  final (tmp, dirs, store) = await newDevice('photo-a');
  store.setSync(cfg(server));
  final shot = File('${tmp.path}/微信图片_1.png');
  final original = List<int>.generate(5000, (i) => i % 256);
  await shot.writeAsBytes(original);
  store.put(localBill(path: shot.path, thumb: 'b1.jpg'));
  await store.save();
  await dirs.thumbFile('b1.jpg').writeAsBytes(List<int>.filled(300, 7));

  final r = await SyncEngine(store, source: FilePhotoSource()).run();
  expect(r.ok, isTrue, reason: r.message);
  return (tmp: tmp, dirs: dirs, store: store, original: original);
}

void main() {
  test('首次同步：本机原图传到 photos/，快照里带上文件名', () async {
    final server = await TestDavServer.start();
    final a = await uploadFromDeviceA(server);

    expect(a.store.byId('b1')!.photo, 'b1.png', reason: '上传后要记下远端文件名');
    expect(server.getFile('${server.root}/photos/b1.png'), a.original,
        reason: '远端必须是**完整原图**，不能是缩略图');
    expect(server.getFile('${server.root}/thumbs/b1.jpg'), isNotNull,
        reason: '缩略图仍要传，列表显示靠它');

    final json = jsonDecode(
            utf8.decode(server.getFile('${server.root}/bills.json')!))
        as Map<String, dynamic>;
    expect((json['bills'] as List).first['ph'], 'b1.png',
        reason: '快照里要带原图文件名，另一台设备才知道去下哪个文件');

    await server.stop();
    await a.tmp.delete(recursive: true);
  });

  test('第二台设备：原图下载到 media/，复制拿到的就是原图', () async {
    final server = await TestDavServer.start();
    final a = await uploadFromDeviceA(server);

    final (tmpB, dirsB, b) = await newDevice('photo-b');
    b.setSync(cfg(server));
    final r = await SyncEngine(b, source: FilePhotoSource()).run();
    expect(r.ok, isTrue, reason: r.message);
    expect(r.photosDown, 1);

    final got = b.byId('b1')!;
    expect(got.photo, 'b1.png');
    expect(await dirsB.mediaFile('b1.png').readAsBytes(), a.original,
        reason: '下载回来的必须是原图的字节');

    // 复制：走同步下来的原图，而不是 256px 缩略图。
    // 注意 path 仍是**那台设备**的定位；测试里两台"设备"共用同一个文件系统，
    // 所以把它改成一个不存在的路径，才等价于真实的另一台电脑。
    final onPc = got.copyWith(path: '/another-pc/照片/微信图片_1.png');
    final plan = resolveCopyPlan(onPc, dirsB);
    expect(plan.kind, CopyKind.syncedOriginal);
    expect(p.basename(plan.path), '微信图片_1.png',
        reason: '粘贴出去的文件名要是原图的名字');
    expect(await File(plan.path).readAsBytes(), a.original);

    await server.stop();
    await a.tmp.delete(recursive: true);
    await tmpB.delete(recursive: true);
  });

  test('重复同步：原图不重复上传，也不重复下载', () async {
    final server = await TestDavServer.start();
    final a = await uploadFromDeviceA(server);
    final photoUrl = '${server.root}/photos/b1.png';
    expect(server.putCount(photoUrl), 1);

    final again = await SyncEngine(a.store, source: FilePhotoSource()).run();
    expect(again.ok, isTrue, reason: again.message);
    expect(again.photosUp, 0, reason: '已经传过的原图不该再传一遍');
    expect(server.putCount(photoUrl), 1);

    final (tmpB, _, b) = await newDevice('photo-b2');
    b.setSync(cfg(server));
    final r1 = await SyncEngine(b, source: FilePhotoSource()).run();
    expect(r1.photosDown, 1);
    final gets = server.getCount(photoUrl);
    final r2 = await SyncEngine(b, source: FilePhotoSource()).run();
    expect(r2.photosDown, 0, reason: '本机已有副本就不再下载');
    expect(server.getCount(photoUrl), gets);

    await server.stop();
    await a.tmp.delete(recursive: true);
    await tmpB.delete(recursive: true);
  });

  test('网盘拒绝建目录：原图退化到根目录 photo_ 前缀，仍能相互同步', () async {
    final server = await TestDavServer.start()..refuseMkcol = true;
    final a = await uploadFromDeviceA(server);

    expect(server.getFile('${server.root}/photo_b1.png'), a.original,
        reason: '建不出 photos/ 目录时要退化成 photo_ 前缀，而不是丢掉原图');
    expect(server.getFile('${server.root}/photos/b1.png'), isNull);

    final (tmpB, dirsB, b) = await newDevice('photo-flat');
    b.setSync(cfg(server));
    final r = await SyncEngine(b, source: FilePhotoSource()).run();
    expect(r.ok, isTrue, reason: r.message);
    expect(await dirsB.mediaFile('b1.png').readAsBytes(), a.original,
        reason: '退化布局下另一台设备也要能下到原图');
    expect(r.message, contains('原图与记录同目录'));

    await server.stop();
    await a.tmp.delete(recursive: true);
    await tmpB.delete(recursive: true);
  });

  test('记录被另一台设备改过：原图文件名不能丢', () async {
    final server = await TestDavServer.start();
    final (tmpA, _, a) = await newDevice('photo-merge-a');
    final shot = File('${tmpA.path}/微信图片_1.png');
    final original = List<int>.generate(2048, (i) => i % 251);
    await shot.writeAsBytes(original);
    a.setSync(cfg(server));
    a.put(localBill(path: shot.path));
    await a.save();

    // 1) A 先只同步记录（没有图片源 = 不传原图）
    expect((await SyncEngine(a).run()).ok, isTrue);

    // 2) B 拉到记录，然后改金额（B 的 updatedAt 更新，但它没有原图名字）
    final (tmpB, dirsB, b) = await newDevice('photo-merge-b');
    b.setSync(cfg(server));
    expect((await SyncEngine(b).run()).ok, isTrue);
    expect(b.byId('b1')!.photo, isEmpty);
    b.setAmount('b1', 200);
    await b.save();
    // B 先把改动推上去（否则 A 第二轮拉到的还是旧快照，测不到合并）
    expect((await SyncEngine(b).run()).ok, isTrue);

    // 3) A 再同步：远端内容更新，但 photo 是本机先传的，必须留
    final ra = await SyncEngine(a, source: FilePhotoSource()).run();
    expect(ra.ok, isTrue, reason: ra.message);
    expect(a.byId('b1')!.amountCents, 200);
    expect(a.byId('b1')!.photo, 'b1.png',
        reason: '不能因为远端记录更新就把原图名字丢掉');

    // 4) B 再同步：拿到 photo，并把原图下载下来
    final rb = await SyncEngine(b, source: FilePhotoSource()).run();
    expect(rb.ok, isTrue, reason: rb.message);
    expect(b.byId('b1')!.photo, 'b1.png');
    expect(await dirsB.mediaFile('b1.png').readAsBytes(), original);

    await server.stop();
    await tmpA.delete(recursive: true);
    await tmpB.delete(recursive: true);
  });
}
