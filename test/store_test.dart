import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';

Future<(Directory, AppDirs, BillStore)> newStore() async {
  final tmp = await Directory.systemTemp.createTemp('wxbills_store');
  final dirs = AppDirs(tmp);
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  return (tmp, dirs, store);
}

Bill bill({
  required String id,
  int? cents = 1000,
  bool manual = false,
  bool deleted = false,
  String note = '',
  String thumb = '',
  int updatedAt = 1000,
  int fileModified = 1000,
}) =>
    Bill(
      id: id,
      name: '$id.png',
      path: '/p/$id.png',
      amountCents: cents,
      confidence: manual ? 1 : 0.9,
      manual: manual,
      fileModified: fileModified,
      importedAt: updatedAt,
      updatedAt: updatedAt,
      note: note,
      deleted: deleted,
      thumb: thumb,
    );

void main() {
  group('金额格式化', () {
    test('分 → 元', () {
      expect(Bill.formatCents(0), '0');
      expect(Bill.formatCents(5), '0.05');
      expect(Bill.formatCents(50), '0.50');
      expect(Bill.formatCents(2450), '24.50');
      expect(Bill.formatCents(3100), '31');
      expect(Bill.formatCents(-1050), '-10.50');
    });

    test('元 → 分（容忍 ¥ / 逗号 / 空格）', () {
      expect(Bill.parseYuan('24.5'), 2450);
      expect(Bill.parseYuan(' ¥ 1,234.56 '), 123456);
      expect(Bill.parseYuan(''), isNull);
      expect(Bill.parseYuan('abc'), isNull);
      expect(Bill.parseYuan('-1'), isNull, reason: '负数金额没有意义');
      expect(Bill.parseYuan('99999999'), isNull, reason: '超出上限');
    });

    test('浮点误差不会丢分', () {
      // 0.1 + 0.2 类的经典问题：必须按分取整，不能留浮点尾巴
      for (final v in ['0.07', '24.50', '31.5', '8.29', '1234.56']) {
        final cents = Bill.parseYuan(v)!;
        expect(Bill.formatCents(cents),
            v.contains('.') && v.split('.')[1].length == 1 ? '${v}0' : v);
      }
    });
  });

  group('同步合并', () {
    test('后写者胜', () {
      final older = bill(id: 'a', cents: 100, updatedAt: 1000);
      final newer = bill(id: 'a', cents: 200, updatedAt: 2000);
      expect(mergeBill(older, newer).amountCents, 200);
      expect(mergeBill(newer, older).amountCents, 200);
    });

    test('时间相同：有金额 > 无金额，手动 > 自动', () {
      final none = bill(id: 'a', cents: null, updatedAt: 1000);
      final some = bill(id: 'a', cents: 100, updatedAt: 1000);
      expect(mergeBill(none, some).amountCents, 100);
      expect(mergeBill(some, none).amountCents, 100);

      final auto = bill(id: 'a', manual: false, updatedAt: 1000);
      final manual = bill(id: 'a', manual: true, updatedAt: 1000);
      expect(mergeBill(auto, manual).manual, isTrue);
      expect(mergeBill(manual, auto).manual, isTrue);
    });

    test('合并满足交换律（两台设备独立操作也能收敛）', () {
      final cases = [
        (bill(id: 'x', cents: 100, updatedAt: 5), bill(id: 'x', cents: 200, updatedAt: 9)),
        (bill(id: 'x', cents: null, updatedAt: 5), bill(id: 'x', cents: 300, updatedAt: 5)),
        (bill(id: 'x', deleted: true, updatedAt: 5), bill(id: 'x', updatedAt: 9)),
      ];
      for (final (l, r) in cases) {
        final a = mergeBill(l, r);
        final b = mergeBill(r, l);
        expect(a.toJson(), b.toJson(), reason: '合并结果必须与参数顺序无关');
      }
    });

    test('删除（墓碑）能压过更早的修改', () {
      final alive = bill(id: 'x', cents: 100, updatedAt: 1000);
      final tomb = bill(id: 'x', deleted: true, updatedAt: 2000);
      expect(mergeBill(alive, tomb).deleted, isTrue);
      expect(mergeBill(tomb, alive).deleted, isTrue);
    });
  });

  group('存储', () {
    test('保存后重新载入，数据完全一致（含同步配置）', () async {
      final (tmp, dirs, store) = await newStore();
      store.addFolder('content://tree/x', '相册');
      store.put(bill(id: 'a', cents: 2450, note: '备注', thumb: 'a.jpg'));
      store.setSync(const SyncConfig(
        url: 'https://dav.example.com/wxbills',
        username: 'u',
        password: 'p',
        allowInsecureTls: true,
      ));
      await store.save();

      final reopened = BillStore(dirs);
      await reopened.load();
      expect(reopened.count, 1);
      expect(reopened.byId('a')!.amountCents, 2450);
      expect(reopened.byId('a')!.note, '备注');
      expect(reopened.byId('a')!.thumb, 'a.jpg');
      expect(reopened.folders.length, 1);
      expect(reopened.folders.first.name, '相册');
      expect(reopened.sync.url, 'https://dav.example.com/wxbills');
      expect(reopened.sync.allowInsecureTls, isTrue);

      await tmp.delete(recursive: true);
    });

    test('数据文件损坏时不崩溃，并保留现场', () async {
      final (tmp, dirs, _) = await newStore();
      await dirs.dataFile.writeAsString('{ broken json');
      final store = BillStore(dirs);
      await store.load();
      expect(store.count, 0, reason: '坏文件应被忽略而不是抛异常');
      final backups = dirs.root
          .listSync()
          .where((e) => e.path.contains('.broken-'))
          .toList();
      expect(backups, isNotEmpty, reason: '坏文件要留一份现场供排查');

      await tmp.delete(recursive: true);
    });

    test('手工改金额后标记 manual，且不再被自动结果覆盖', () async {
      final (tmp, _, store) = await newStore();
      store.put(bill(id: 'a', cents: null));
      store.setAmount('a', 2450, note: '客户已确认');
      final b = store.byId('a')!;
      expect(b.amountCents, 2450);
      expect(b.manual, isTrue);
      expect(b.note, '客户已确认');
      expect(b.updatedAt, greaterThan(1000), reason: '改动必须刷新时间戳');

      await tmp.delete(recursive: true);
    });

    test('软删除写入墓碑，列表里消失但记录仍在', () async {
      final (tmp, _, store) = await newStore();
      store.put(bill(id: 'a'));
      store.remove('a');
      expect(store.bills, isEmpty);
      expect(store.byId('a')!.deleted, isTrue);
      expect(store.allIncludingDeleted.length, 1);

      await tmp.delete(recursive: true);
    });

    test('过期墓碑会被清理，避免同步文件无限膨胀', () async {
      final (tmp, _, store) = await newStore();
      final old = DateTime.now().millisecondsSinceEpoch - 200 * 24 * 3600 * 1000;
      store.put(bill(id: 'old', deleted: true, updatedAt: old));
      store.put(bill(id: 'new', deleted: true, updatedAt: DateTime.now().millisecondsSinceEpoch));
      final removed = store.purgeTombstones();
      expect(removed, 1);
      expect(store.byId('old'), isNull);
      expect(store.byId('new'), isNotNull);

      await tmp.delete(recursive: true);
    });

    test('缩略图写入/读取/清理', () async {
      final (tmp, dirs, store) = await newStore();
      await store.writeThumb('a.jpg', [1, 2, 3]);
      expect(await store.readThumb('a.jpg'), [1, 2, 3]);

      // 没有对应记录的缩略图应被清掉
      store.put(bill(id: 'a', thumb: 'a.jpg'));
      await store.writeThumb('orphan.jpg', [9]);
      final removed = await store.pruneThumbs();
      expect(removed, 1);
      expect(await store.readThumb('orphan.jpg'), isNull);
      expect(await store.readThumb('a.jpg'), [1, 2, 3]);

      await tmp.delete(recursive: true);
    });

    test('远端快照里的文件名不能带路径（会被拼成本机路径）', () {
      final ok = Bill.fromJson({'id': 'a', 't': 'a.jpg', 'ph': 'a.png'});
      expect(ok.thumb, 'a.jpg');
      expect(ok.photo, 'a.png');

      final bad = Bill.fromJson({'id': 'a', 't': '../../evil.jpg', 'ph': '../x.png'});
      expect(bad.thumb, isEmpty, reason: '带路径的名字一律丢掉，宁可不显示图');
      expect(bad.photo, isEmpty);
    });

    test('原子写：不会留下半截 JSON', () async {
      final (tmp, dirs, store) = await newStore();
      store.put(bill(id: 'a'));
      await store.save();
      final text = await dirs.dataFile.readAsString();
      expect(text.trim().startsWith('{'), isTrue);
      expect(text.trim().endsWith('}'), isTrue);
      expect(File('${dirs.dataFile.path}.tmp').existsSync(), isFalse,
          reason: '临时文件应已 rename 掉');

      await tmp.delete(recursive: true);
    });
  });
}
