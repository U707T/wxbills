import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/webdav/sync.dart';

import 'support/test_dav_server.dart';

/// 建一个独立的临时「设备」（自己的数据目录 + 存储）。
Future<(AppDirs, BillStore)> newDevice(String label) async {
  final tmp = await Directory.systemTemp.createTemp('wxbills_$label');
  final dirs = AppDirs(tmp);
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  return (dirs, store);
}

SyncConfig cfgFor(TestDavServer server) => SyncConfig(
      url: server.url,
      username: 'alice',
      password: 'secret',
      autoSync: false,
    );

Bill makeBill({
  required String id,
  String name = 'a.png',
  int? cents = 1000,
  bool manual = false,
  bool deleted = false,
  String note = '',
  required int updatedAt,
  String thumb = '',
}) =>
    Bill(
      id: id,
      name: name,
      path: '/local/$name',
      amountCents: cents,
      confidence: manual ? 1 : 0.9,
      manual: manual,
      fileModified: updatedAt,
      importedAt: updatedAt,
      updatedAt: updatedAt,
      note: note,
      deleted: deleted,
      thumb: thumb,
    );

void main() {
  late TestDavServer server;

  setUp(() async {
    server = await TestDavServer.start();
  });

  tearDown(() async {
    await server.stop();
  });

  test('首次同步：本机记录上传，远端出现 bills.json', () async {
    final (dirs, store) = await newDevice('a');
    store.setSync(cfgFor(server));
    store.put(makeBill(id: 'b1', cents: 2450, updatedAt: 1000));
    await store.save();

    final result = await SyncEngine(store).run();
    expect(result.ok, isTrue, reason: result.message);

    final raw = server.getFile('${server.root}/bills.json');
    expect(raw, isNotNull, reason: '远端应生成快照');
    final json = jsonDecode(utf8.decode(raw!)) as Map<String, dynamic>;
    final bills = json['bills'] as List;
    expect(bills.length, 1);
    expect((bills.first as Map)['a'], 2450);

    await dirs.root.delete(recursive: true);
  });

  test('第二台设备拉取：记录与金额一致，且保留本机 path', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    a.put(makeBill(id: 'b1', cents: 2450, updatedAt: 1000));
    await a.save();
    expect((await SyncEngine(a).run()).ok, isTrue);

    final (dirsB, b) = await newDevice('b');
    b.setSync(cfgFor(server));
    final r = await SyncEngine(b).run();
    expect(r.ok, isTrue, reason: r.message);

    final got = b.byId('b1');
    expect(got, isNotNull);
    expect(got!.amountCents, 2450);
    expect(got.path, '/local/a.png', reason: '远端 path 不应覆盖本机定位');

    await dirsA.root.delete(recursive: true);
    await dirsB.root.delete(recursive: true);
  });

  test('两边都改：后写者胜（updatedAt 大的赢）', () async {
    final (dirsA, a) = await newDevice('a');
    final (dirsB, b) = await newDevice('b');
    a.setSync(cfgFor(server));
    b.setSync(cfgFor(server));

    a.put(makeBill(id: 'x', cents: 100, updatedAt: 1000));
    await a.save();
    expect((await SyncEngine(a).run()).ok, isTrue);

    // B 拉到 100
    expect((await SyncEngine(b).run()).ok, isTrue);
    expect(b.byId('x')!.amountCents, 100);

    // A 后改（时间更晚）
    a.put(makeBill(id: 'x', cents: 200, updatedAt: 2000));
    await a.save();
    expect((await SyncEngine(a).run()).ok, isTrue);

    // B 再同步：应拿到 A 的新值
    final r = await SyncEngine(b).run();
    expect(r.ok, isTrue, reason: r.message);
    expect(b.byId('x')!.amountCents, 200);

    await dirsA.root.delete(recursive: true);
    await dirsB.root.delete(recursive: true);
  });

  test('删除同步：A 删除后 B 不会把记录复活', () async {
    final (dirsA, a) = await newDevice('a');
    final (dirsB, b) = await newDevice('b');
    a.setSync(cfgFor(server));
    b.setSync(cfgFor(server));

    a.put(makeBill(id: 'd1', cents: 500, updatedAt: 1000));
    await a.save();
    await SyncEngine(a).run();
    await SyncEngine(b).run();
    expect(b.byId('d1'), isNotNull);

    // A 删除（墓碑，时间更晚）
    a.remove('d1');
    await a.save();
    await SyncEngine(a).run();

    await SyncEngine(b).run();
    expect(b.byId('d1')!.deleted, isTrue, reason: '删除必须同步过去');
    expect(b.bills.any((x) => x.id == 'd1'), isFalse, reason: '列表里不应再出现');

    // B 再改一次也不该复活成正常记录
    await SyncEngine(b).run();
    expect(b.byId('d1')!.deleted, isTrue);

    await dirsA.root.delete(recursive: true);
    await dirsB.root.delete(recursive: true);
  });

  test('ETag 冲突：自动重新下载 → 重新合并 → 再写，不丢数据', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    a.put(makeBill(id: 'c1', cents: 100, updatedAt: 1000));
    await a.save();
    await SyncEngine(a).run();

    // 让下一次 PUT 被「别的设备」抢先
    server.forceConflictOnPut = 1;

    a.put(makeBill(id: 'c2', cents: 300, updatedAt: 3000));
    await a.save();
    final r = await SyncEngine(a).run();
    expect(r.ok, isTrue, reason: r.message);

    // 冲突后仍应把 c2 写上去
    final raw = server.getFile('${server.root}/bills.json')!;
    final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final ids = (json['bills'] as List)
        .map((e) => (e as Map)['id'])
        .toSet();
    expect(ids.contains('c1'), isTrue);
    expect(ids.contains('c2'), isTrue, reason: '冲突后必须重试成功');

    await dirsA.root.delete(recursive: true);
  });

  test('已是最新时不重复上传（避免无意义的写放大）', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    a.put(makeBill(id: 'n1', cents: 100, updatedAt: 1000));
    await a.save();
    await SyncEngine(a).run();

    final before = server.callCount('PUT');
    final r = await SyncEngine(a).run();
    expect(r.ok, isTrue);
    expect(r.message, contains('已是最新'));
    expect(server.callCount('PUT'), before, reason: '内容没变就不该再 PUT');

    await dirsA.root.delete(recursive: true);
  });

  test('缩略图双向同步', () async {
    final (dirsA, a) = await newDevice('a');
    final (dirsB, b) = await newDevice('b');
    a.setSync(cfgFor(server));
    b.setSync(cfgFor(server));

    await a.writeThumb('t1.jpg', [1, 2, 3, 4, 5]);
    a.put(makeBill(id: 'th1', cents: 100, updatedAt: 1000, thumb: 't1.jpg'));
    await a.save();
    expect((await SyncEngine(a).run()).ok, isTrue);
    expect(server.getFile('${server.root}/thumbs/t1.jpg'), isNotNull);

    await SyncEngine(b).run();
    expect(b.byId('th1')!.thumb, 't1.jpg');
    expect(await b.readThumb('t1.jpg'), [1, 2, 3, 4, 5],
        reason: '另一台设备必须能拿到缩略图');

    await dirsA.root.delete(recursive: true);
    await dirsB.root.delete(recursive: true);
  });

  test('密码错误：返回可读的错误，不破坏本地数据', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(SyncConfig(url: server.url, username: 'alice', password: 'wrong'));
    a.put(makeBill(id: 'e1', cents: 100, updatedAt: 1000));
    await a.save();

    final r = await SyncEngine(a).run();
    expect(r.ok, isFalse);
    expect(r.message, contains('401'));
    expect(a.byId('e1'), isNotNull, reason: '同步失败不能动本地数据');
    expect(a.count, 1);

    await dirsA.root.delete(recursive: true);
  });

  test('服务器 500：返回失败并记录原因', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    server.failEverything = true;
    final r = await SyncEngine(a).run();
    expect(r.ok, isFalse);
    expect(r.message, contains('500'));
    expect(a.sync.lastSyncMessage, contains('失败'));

    await dirsA.root.delete(recursive: true);
  });

  test('未配置地址：直接返回提示，不发请求', () async {
    final (dirsA, a) = await newDevice('a');
    final r = await SyncEngine(a).run();
    expect(r.ok, isFalse);
    expect(r.message, contains('还没有配置'));
    await dirsA.root.delete(recursive: true);
  });

  test('远端快照损坏：中止同步，不覆盖远端文件', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    server.putFile('${server.root}/bills.json', utf8.encode('{ this is not json'));
    final r = await SyncEngine(a).run();
    expect(r.ok, isFalse);
    expect(r.message, contains('解析失败'));
    final raw = server.getFile('${server.root}/bills.json')!;
    expect(utf8.decode(raw), contains('this is not json'),
        reason: '不能把坏文件直接覆盖掉');
    await dirsA.root.delete(recursive: true);
  });
}
