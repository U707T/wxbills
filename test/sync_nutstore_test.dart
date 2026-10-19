import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/webdav/sync.dart';

import 'support/test_dav_server.dart';

/// 这一组测试模拟「坚果云」这类真实网盘的几个行为：
///  * 目录是用户的子目录，第一次用的时候并不存在（要在 /dav 下建）；
///  * PROPFIND 返回弱 ETag（`W/"..."`），If-Match 必须按强校验发；
///  * 密码错是 401（坚果云要用应用密码）；
/// 以及一条硬要求：**重复同步不能重复传输同一份文件**。

Future<(AppDirs, BillStore)> newDevice(String label) async {
  final tmp = await Directory.systemTemp.createTemp('wxbills_$label');
  final dirs = AppDirs(tmp);
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  return (dirs, store);
}

/// 指向「/dav/wxbills」子目录（坚果云上就是 https://dav.jianguoyun.com/dav/wxbills）。
SyncConfig cfgFor(TestDavServer server,
        {String sub = 'wxbills', String password = 'secret'}) =>
    SyncConfig(
      url: '${server.url}/$sub',
      username: 'alice',
      password: password,
      autoSync: false,
    );

Bill makeBill({
  required String id,
  int? cents = 1000,
  required int updatedAt,
  String thumb = '',
}) =>
    Bill(
      id: id,
      name: '$id.png',
      path: '/local/$id.png',
      amountCents: cents,
      confidence: 0.95,
      manual: false,
      fileModified: updatedAt,
      importedAt: updatedAt,
      updatedAt: updatedAt,
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

  test('首次同步：目标子目录不存在时自动创建（坚果云默认路径）', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    a.put(makeBill(id: 'x', updatedAt: 1000));
    await a.save();

    final r = await SyncEngine(a).run();
    expect(r.ok, isTrue, reason: r.message);
    expect(server.getFile('/dav/wxbills/bills.json'), isNotNull,
        reason: '子目录要先 MKCOL 出来再写快照');
    expect(server.callCount('MKCOL'), greaterThan(0));

    await dirsA.root.delete(recursive: true);
  });

  test('同一台设备重复同步：快照与缩略图都不会再传一遍', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    await a.writeThumb('t1.jpg', [1, 2, 3, 4, 5]);
    a.put(makeBill(id: 'x', updatedAt: 1000, thumb: 't1.jpg'));
    await a.save();

    expect((await SyncEngine(a).run()).ok, isTrue);
    final snapshotPuts = server.putCount('/dav/wxbills/bills.json');
    final thumbPuts = server.putCount('/dav/wxbills/thumbs/t1.jpg');
    final totalPuts = server.callCount('PUT');
    expect(snapshotPuts, 1);
    expect(thumbPuts, 1);
    expect(server.getCount('/dav/wxbills/thumbs/t1.jpg'), 0,
        reason: '本机已有这张缩略图，不该再去下载');

    final second = await SyncEngine(a).run();
    expect(second.ok, isTrue, reason: second.message);
    expect(second.message, contains('已是最新'));
    expect(server.putCount('/dav/wxbills/bills.json'), snapshotPuts,
        reason: '内容没变就不该重写快照');
    expect(server.putCount('/dav/wxbills/thumbs/t1.jpg'), thumbPuts,
        reason: '缩略图没变就不该重传');
    expect(server.callCount('PUT'), totalPuts, reason: '第二次同步不该产生任何 PUT');

    await dirsA.root.delete(recursive: true);
  });

  test('第二台设备：同一份缩略图只下载一次', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    await a.writeThumb('t1.jpg', [9, 9, 9]);
    a.put(makeBill(id: 'x', updatedAt: 1000, thumb: 't1.jpg'));
    await a.save();
    await SyncEngine(a).run();

    final (dirsB, b) = await newDevice('b');
    b.setSync(cfgFor(server));
    expect((await SyncEngine(b).run()).ok, isTrue);
    expect(await b.readThumb('t1.jpg'), [9, 9, 9], reason: '另一台设备要能拿到图');
    final thumbGets = server.getCount('/dav/wxbills/thumbs/t1.jpg');
    expect(thumbGets, 1);

    expect((await SyncEngine(b).run()).ok, isTrue);
    expect(server.getCount('/dav/wxbills/thumbs/t1.jpg'), thumbGets,
        reason: '本地已经有了，重复同步不该再下载');

    await dirsA.root.delete(recursive: true);
    await dirsB.root.delete(recursive: true);
  });

  test('服务端给弱 ETag（坚果云 / Nextcloud 常见）：改完还能正常写，不会 412 死循环', () async {
    server
      ..weakEtags = true
      ..strictIfMatch = true; // 严格实现：客户端必须自己把 W/ 去掉
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    a.put(makeBill(id: 'x', cents: 100, updatedAt: 1000));
    await a.save();
    final first = await SyncEngine(a).run();
    expect(first.ok, isTrue, reason: first.message);

    a.put(makeBill(id: 'x', cents: 200, updatedAt: 2000));
    await a.save();
    final second = await SyncEngine(a).run();
    expect(second.ok, isTrue,
        reason: '弱 ETag 直接当 If-Match 发会被规范实现一律 412：${second.message}');
    expect(server.putCount('/dav/wxbills/bills.json'), 2);

    // 第三轮没有改动：不该再写
    expect((await SyncEngine(a).run()).ok, isTrue);
    expect(server.putCount('/dav/wxbills/bills.json'), 2);

    await dirsA.root.delete(recursive: true);
  });

  test('测试连接：路径不存在也给出「可用」结论，并回显最终路径', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server, sub: 'brand-new'));

    final first = await SyncEngine(a).testConnection();
    expect(first, contains('连接成功'), reason: first);
    expect(first, contains('可读可写'), reason: first);
    expect(first, contains('/dav/brand-new/'), reason: '要把最终路径回显出来：$first');
    expect(first, contains('首次同步'), reason: first);

    // 建好之后再测一次：目录已存在，仍然报可用
    final second = await SyncEngine(a).testConnection();
    expect(second, contains('连接成功'), reason: second);

    await dirsA.root.delete(recursive: true);
  });

  test('测试连接：密码错时提示坚果云要用「应用密码」', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server, password: 'wrong'));
    final msg = await SyncEngine(a).testConnection();
    expect(msg, contains('401'), reason: msg);
    expect(msg, contains('应用密码'), reason: msg);
    await dirsA.root.delete(recursive: true);
  });

  test('快照确实写在测试的那条路径上，且记录数正确', () async {
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server));
    a.put(makeBill(id: 'x', updatedAt: 1000));
    await a.save();
    await SyncEngine(a).run();

    final raw = server.getFile('/dav/wxbills/bills.json')!;
    final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    expect((json['bills'] as List).length, 1);
    await dirsA.root.delete(recursive: true);
  });

  test('坚果云式只读根：地址填成 /dav 根时，报错要能照着改', () async {
    server.refusePutAtRoot = true;
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server, sub: '')); // → http://…/dav/（根）
    a.put(makeBill(id: 'x', updatedAt: 1000));
    await a.save();

    final r = await SyncEngine(a).run();
    expect(r.ok, isFalse);
    expect(r.message, contains('只能读'),
        reason: '要说明是根目录不可写，而不是甩一段服务端 XML：${r.message}');
    expect(r.message, contains('wxbills'), reason: '要给出可照做的子目录地址：${r.message}');

    await dirsA.root.delete(recursive: true);
  });

  test('同一个「只读根」服务器：地址带上子目录就能同步成功', () async {
    server.refusePutAtRoot = true;
    final (dirsA, a) = await newDevice('a');
    a.setSync(cfgFor(server)); // → /dav/wxbills
    a.put(makeBill(id: 'x', updatedAt: 1000));
    await a.save();

    final r = await SyncEngine(a).run();
    expect(r.ok, isTrue, reason: r.message);
    expect(server.getFile('/dav/wxbills/bills.json'), isNotNull);

    await dirsA.root.delete(recursive: true);
  });

  test('测试连接会真的验证「能不能写」，不只是能不能读', () async {
    server.refusePutAtRoot = true;
    final (dirsA, a) = await newDevice('a');

    a.setSync(cfgFor(server, sub: ''));
    final rootMsg = await SyncEngine(a).testConnection();
    expect(rootMsg, contains('只能读'),
        reason: '只读根必须在测试连接这一步就暴露，而不是等同步失败：$rootMsg');

    a.setSync(cfgFor(server));
    final okMsg = await SyncEngine(a).testConnection();
    expect(okMsg, contains('可读可写'), reason: okMsg);

    await dirsA.root.delete(recursive: true);
  });
}
