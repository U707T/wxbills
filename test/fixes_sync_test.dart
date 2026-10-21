import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/app/app_controller.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/platform/photo_source.dart';
import 'package:wxbills/src/webdav/sync.dart';

import 'support/test_dav_server.dart';

/// 只实现同步真正用到的两件事：读原图（可挂起）与读原图大小。
class SyncSource implements PhotoSource {
  SyncSource({this.gate, this.onReadOriginal, this.originalSize = 16});

  Completer<void>? gate;
  void Function()? onReadOriginal;
  final int? originalSize;

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
  Future<int?> originalLength(String path) async => originalSize;

  @override
  Future<Uint8List?> readOriginal(String path) async {
    onReadOriginal?.call();
    final g = gate;
    if (g != null) await g.future;
    return Uint8List.fromList(List<int>.filled(16, 7));
  }
}

SyncConfig cfgFor(TestDavServer s) => SyncConfig(
      url: s.url,
      username: 'alice',
      password: 'secret',
      autoSync: false,
    );

Future<(AppDirs, BillStore)> newDevice(String label, TestDavServer s) async {
  final tmp = await Directory.systemTemp.createTemp('wxbills_fix_$label');
  final dirs = AppDirs(tmp);
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  store.setSync(cfgFor(s));
  return (dirs, store);
}

Bill makeBill({
  required String id,
  int? cents = 100,
  int updatedAt = 1000,
  bool deleted = false,
  String thumb = '',
  String photo = '',
  String name = 'a.png',
  String path = '',
}) =>
    Bill(
      id: id,
      name: name,
      path: path,
      amountCents: cents,
      confidence: deleted ? 0 : 1,
      manual: false,
      fileModified: 1,
      importedAt: 1,
      updatedAt: updatedAt,
      deleted: deleted,
      thumb: thumb,
      photo: photo,
    );

void main() {
  late TestDavServer server;

  setUp(() async {
    server = await TestDavServer.start();
  });

  tearDown(() async {
    await server.stop();
  });

  test('同步上传原图期间删掉的记录，不会被旧快照改写回「未删除」', () async {
    final (dirs, store) = await newDevice('a', server);
    store.put(makeBill(id: 'aaaa', path: '/album/a.png'));
    await store.save();

    final entered = Completer<void>();
    final source = SyncSource(
      gate: Completer<void>(),
      onReadOriginal: () {
        if (!entered.isCompleted) entered.complete();
      },
    );

    final running = SyncEngine(store, source: source).run();
    await entered.future.timeout(const Duration(seconds: 10));
    // 用户此刻删掉这条记录（写墓碑）
    store.remove('aaaa');
    await store.save();
    expect(store.byId('aaaa')!.deleted, isTrue);

    source.gate!.complete();
    await running;

    expect(store.byId('aaaa')!.deleted, isTrue,
        reason: '上传原图用的是同步开始时的旧快照，不能用它覆盖墓碑');

    await dirs.root.delete(recursive: true);
  });

  test('同步上传原图期间手改的金额，不会被旧快照覆盖', () async {
    final (dirs, store) = await newDevice('a2', server);
    store.put(makeBill(id: 'bbbb', path: '/album/b.png', cents: 100));
    await store.save();

    final entered = Completer<void>();
    final source = SyncSource(
      gate: Completer<void>(),
      onReadOriginal: () {
        if (!entered.isCompleted) entered.complete();
      },
    );

    final running = SyncEngine(store, source: source).run();
    await entered.future.timeout(const Duration(seconds: 10));
    store.setAmount('bbbb', 8888); // 用户手改
    await store.save();

    source.gate!.complete();
    await running;

    expect(store.byId('bbbb')!.amountCents, 8888);
    expect(store.byId('bbbb')!.manual, isTrue,
        reason: '同步只该补 photo 字段，不能把金额与 manual 标记一起写回旧值');

    await dirs.root.delete(recursive: true);
  });

  test('两端缩略图长度不同：以远端为准收敛，不会每轮互相覆盖', () async {
    final (dirsA, a) = await newDevice('ta', server);
    final (dirsB, b) = await newDevice('tb', server);

    await a.writeThumb('t1.jpg', List<int>.filled(100, 1));
    a.put(makeBill(id: 'th1', thumb: 't1.jpg'));
    await a.save();
    expect((await SyncEngine(a).run()).thumbsUp, 1);

    // 另一台设备自己生成过一份（长度不同），它不应该反过来覆盖远端
    await b.writeThumb('t1.jpg', List<int>.filled(200, 2));
    b.put(makeBill(id: 'th1', thumb: 't1.jpg'));
    await b.save();

    final rb = await SyncEngine(b).run();
    expect(rb.thumbsUp, 0, reason: '远端已有就该以远端为准，不要互相覆盖');
    expect((await b.readThumb('t1.jpg'))!.length, 100,
        reason: '下载远端版本，两边才会一轮收敛');

    final ra = await SyncEngine(a).run();
    expect(ra.thumbsUp, 0, reason: '收敛之后再同步不该产生任何上传');

    await dirsA.root.delete(recursive: true);
    await dirsB.root.delete(recursive: true);
  });

  test('过期墓碑随合并结果一起清掉，不会同步一次又回来', () async {
    final (dirs, store) = await newDevice('tomb', server);

    final old = DateTime.now().millisecondsSinceEpoch - 200 * 24 * 3600 * 1000;
    final tomb = makeBill(id: 'dead', deleted: true, updatedAt: old);
    server.putFile(
      '${server.root}/bills.json',
      utf8.encode(jsonEncode({
        'v': 2,
        'savedAt': old,
        'bills': [tomb.toJson()],
      })),
    );

    final r = await SyncEngine(store).run();
    expect(r.ok, isTrue, reason: r.message);
    expect(store.byId('dead'), isNull, reason: '过期墓碑不该被合并回本机');

    final raw = utf8.decode(server.getFile('${server.root}/bills.json')!);
    expect(raw, isNot(contains('"dead"')),
        reason: '远端快照也要一起变小，否则下次同步又会合并回来');

    await dirs.root.delete(recursive: true);
  });

  test('远端 bills.json 结构不对：中止同步，不覆盖它', () async {
    final (dirs, store) = await newDevice('shape', server);
    const raw = '{"foo": 1}';
    server.putFile('${server.root}/bills.json', utf8.encode(raw));

    final r = await SyncEngine(store).run();
    expect(r.ok, isFalse);
    expect(r.message, contains('格式'), reason: r.message);
    expect(utf8.decode(server.getFile('${server.root}/bills.json')!), raw,
        reason: '不认识的内容一律不覆盖');

    await dirs.root.delete(recursive: true);
  });

  test('没有导入文件夹时，启动仍会执行一次自动同步', () async {
    final (dirs, store) = await newDevice('boot', server);
    store.setSync(SyncConfig(
      url: server.url,
      username: 'alice',
      password: 'secret',
      autoSync: true,
    ));
    await store.save();

    final controller =
        AppController(dirs: dirs, store: store, source: SyncSource());
    await controller.init();

    expect(server.getFile('${server.root}/bills.json'), isNotNull,
        reason: '「没有相册目录」只该跳过扫描，不该连同步一起跳过');

    await dirs.root.delete(recursive: true);
  });
}
