import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/webdav/sync.dart';

import 'support/temp_cleanup.dart';
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
}) => Bill(
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
    expect(
      (bills.first as Map).containsKey('p'),
      isFalse,
      reason: '设备私有路径不应同步或暴露到远端',
    );
    expect(
      (bills.first as Map).containsKey('fd'),
      isFalse,
      reason: '本机目录 ID 不应同步',
    );

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
    expect(got.path, isEmpty, reason: '另一台设备的路径不是本机定位，不能直接复用');

    await deleteTempDirectory(dirsA.root);
    await deleteTempDirectory(dirsB.root);
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

    await deleteTempDirectory(dirsA.root);
    await deleteTempDirectory(dirsB.root);
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

    await deleteTempDirectory(dirsA.root);
    await deleteTempDirectory(dirsB.root);
  });

  test('服务器拒绝条件创建时不得无条件覆盖并发创建的远端快照', () async {
    final (dirs, store) = await newDevice('conditional-create-race');
    store.setSync(cfgFor(server));
    store.put(makeBill(id: 'local', cents: 500, updatedAt: 1000));
    await store.save();
    server
      ..rejectConditionalCreate = true
      ..raceOnRejectedConditionalCreate = true;

    final result = await SyncEngine(store).run();
    expect(result.ok, isFalse, reason: '条件创建不受支持时应 fail closed');
    expect(result.message, contains('未进行无条件重试'));
    expect(
      server.getFile('${server.root}/bills.json'),
      utf8.encode('remote concurrent content'),
    );

    await dirs.root.delete(recursive: true);
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
    final ids = (json['bills'] as List).map((e) => (e as Map)['id']).toSet();
    expect(ids.contains('c1'), isTrue);
    expect(ids.contains('c2'), isTrue, reason: '冲突后必须重试成功');

    await deleteTempDirectory(dirsA.root);
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

    await deleteTempDirectory(dirsA.root);
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
    expect(await b.readThumb('t1.jpg'), [
      1,
      2,
      3,
      4,
      5,
    ], reason: '另一台设备必须能拿到缩略图');

    await deleteTempDirectory(dirsA.root);
    await deleteTempDirectory(dirsB.root);
  });

  test('远端 bills 数组含无效条目：中止同步且不覆盖远端内容', () async {
    final (dirs, store) = await newDevice('invalid-item');
    store.setSync(cfgFor(server));
    store.put(makeBill(id: 'local', cents: 500, updatedAt: 1000));
    await store.save();
    const raw = '{"v":2,"bills":[1]}';
    server.putFile('${server.root}/bills.json', utf8.encode(raw));

    final result = await SyncEngine(store).run();
    expect(result.ok, isFalse);
    expect(result.message, contains('账单条目'));
    expect(
      utf8.decode(server.getFile('${server.root}/bills.json')!),
      raw,
      reason: '无法理解的远端条目不能被静默丢弃后覆盖',
    );

    await dirs.root.delete(recursive: true);
  });

  test('同步时自动清理旧版远端快照中的设备路径', () async {
    final (dirs, store) = await newDevice('redact-old-paths');
    store.setSync(cfgFor(server));
    final bill = makeBill(id: 'legacy-path', updatedAt: 1000);
    store.put(bill);
    await store.save();
    server.putFile(
      '${server.root}/bills.json',
      utf8.encode(
        jsonEncode({
          'v': 2,
          'savedAt': 1000,
          'bills': [bill.toJson()],
        }),
      ),
    );

    final result = await SyncEngine(store).run();
    expect(result.ok, isTrue, reason: result.message);
    final remote = jsonDecode(
      utf8.decode(server.getFile('${server.root}/bills.json')!),
    ) as Map<String, dynamic>;
    final record = (remote['bills'] as List).single as Map;
    expect(record.containsKey('p'), isFalse);
    expect(record.containsKey('fd'), isFalse);

    await deleteTempDirectory(dirs.root);
  });

  test('相同更新时间但金额冲突仍可在两台设备间收敛', () async {
    final (dirsA, a) = await newDevice('same-timestamp-a');
    final (dirsB, b) = await newDevice('same-timestamp-b');
    a.setSync(cfgFor(server));
    b.setSync(cfgFor(server));

    a.put(makeBill(id: 'tie', cents: 100, updatedAt: 1000));
    await a.save();
    expect((await SyncEngine(a).run()).ok, isTrue);

    b.put(makeBill(id: 'tie', cents: 200, updatedAt: 1000));
    await b.save();
    final first = await SyncEngine(b).run();
    expect(first.ok, isTrue, reason: first.message);
    final second = await SyncEngine(a).run();
    expect(second.ok, isTrue, reason: second.message);

    expect(a.byId('tie')!.amountCents, 100);
    expect(b.byId('tie')!.amountCents, 100, reason: '相同时间戳时两端必须选择同一赢家');

    await deleteTempDirectory(dirsA.root);
    await deleteTempDirectory(dirsB.root);
  });

  test('密码错误：返回可读的错误，不破坏本地数据', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(
      SyncConfig(url: server.url, username: 'alice', password: 'wrong'),
    );
    a.put(makeBill(id: 'e1', cents: 100, updatedAt: 1000));
    await a.save();

    final r = await SyncEngine(a).run();
    expect(r.ok, isFalse);
    expect(r.message, contains('401'));
    expect(a.byId('e1'), isNotNull, reason: '同步失败不能动本地数据');
    expect(a.count, 1);

    await deleteTempDirectory(dirsA.root);
  });

  test('服务器 500：返回失败并记录原因', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    server.failEverything = true;
    final r = await SyncEngine(a).run();
    expect(r.ok, isFalse);
    expect(r.message, contains('500'));
    expect(a.sync.lastSyncMessage, contains('失败'));

    await deleteTempDirectory(dirsA.root);
  });

  test('未配置地址：直接返回提示，不发请求', () async {
    final (dirsA, a) = await newDevice('a');
    final r = await SyncEngine(a).run();
    expect(r.ok, isFalse);
    expect(r.message, contains('还没有配置'));
    await deleteTempDirectory(dirsA.root);
  });

  test('远端快照损坏：中止同步，不覆盖远端文件', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    server.putFile(
      '${server.root}/bills.json',
      utf8.encode('{ this is not json'),
    );
    final r = await SyncEngine(a).run();
    expect(r.ok, isFalse);
    expect(r.message, contains('解析失败'));
    final raw = server.getFile('${server.root}/bills.json')!;
    expect(
      utf8.decode(raw),
      contains('this is not json'),
      reason: '不能把坏文件直接覆盖掉',
    );
    await deleteTempDirectory(dirsA.root);
  });
}
