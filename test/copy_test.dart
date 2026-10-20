import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wxbills/src/app/app_controller.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/copy_plan.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/platform/photo_source.dart';
import 'package:wxbills/src/webdav/sync.dart';

import 'support/test_dav_server.dart';

/// 桌面端剪贴板替身：只接受**真实存在**的文件，和 Windows 实现一致。
class ClipboardSpy implements PhotoSource {
  final List<String> copied = [];

  /// 模拟剪贴板被别的程序占着（OpenClipboard 一直失败）。
  bool busy = false;

  @override
  bool get supportsRefreshDate => false;

  @override
  bool get supportsCopyImage => true;

  @override
  Future<bool> copyImage(String path) async {
    if (busy) return false;
    if (!File(path).existsSync()) return false;
    copied.add(path);
    return true;
  }

  /// 同步上传原图用：测试替身不参与原图同步
  @override
  Future<Uint8List?> readOriginal(String path) async => null;

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
}

Bill makeBill({
  String id = 'b1',
  String name = '微信图片_1.jpg',
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

Future<(Directory, AppDirs, BillStore)> newDevice(String label) async {
  final tmp = await Directory.systemTemp.createTemp('wxbills_$label');
  final dirs = AppDirs(tmp);
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  return (tmp, dirs, store);
}

void main() {
  test('同步成功后复制：原图在另一台设备上，用随同步下来的缩略图兜底', () async {
    final server = await TestDavServer.start();

    // 手机：原图是 content://，缩略图已生成并随同步上传
    final (phoneTmp, phoneDirs, phone) = await newDevice('phone');
    phone.setSync(SyncConfig(
      url: server.url,
      username: 'alice',
      password: 'secret',
      autoSync: false,
    ));
    const phonePath = 'content://com.android.externalstorage.documents/tree/a.jpg';
    phone.put(makeBill(path: phonePath, thumb: 'b1.jpg'));
    await phone.save();
    final thumbBytes = Uint8List.fromList(
        List<int>.generate(4096, (i) => i % 251));
    await phoneDirs.thumbFile('b1.jpg').writeAsBytes(thumbBytes);
    expect((await SyncEngine(phone).run()).ok, isTrue);

    // PC：同步之后，列表里这条记录看得见缩略图
    final (pcTmp, pcDirs, pc) = await newDevice('pc');
    pc.setSync(SyncConfig(
      url: server.url,
      username: 'alice',
      password: 'secret',
      autoSync: false,
    ));
    final r = await SyncEngine(pc).run();
    expect(r.ok, isTrue, reason: r.message);

    final bill = pc.byId('b1')!;
    expect(bill.path, phonePath,
        reason: '同步来的 path 是那台设备的定位，PC 上并不存在');

    final spy = ClipboardSpy();
    final controller = AppController(dirs: pcDirs, store: pc, source: spy);
    await controller.copyImage(bill);

    expect(spy.copied, hasLength(1),
        reason: '同步来的记录也必须能复制（这正是「同步成功后复制失败」的场景）');
    final copied = File(spy.copied.single);
    expect(copied.existsSync(), isTrue);
    expect(p.basename(copied.path), '微信图片_1.jpg',
        reason: '粘到聊天窗口时应显示原图的名字，而不是缩略图的 id');
    expect(await copied.readAsBytes(), thumbBytes);
    expect(controller.toast, contains('缩略图'));
    expect(controller.toast, isNot(contains('失败')));

    await server.stop();
    await phoneTmp.delete(recursive: true);
    await pcTmp.delete(recursive: true);
  });

  test('原图就在本机：复制原图，不生成缩略图副本', () async {
    final (tmp, dirs, store) = await newDevice('original');
    final original = File('${tmp.path}/收款单.png');
    await original.writeAsBytes(List<int>.filled(128, 9));
    final bill = makeBill(path: original.path, thumb: 'b1.jpg');
    store.put(bill);
    await dirs.thumbFile('b1.jpg').writeAsBytes(List<int>.filled(16, 1));

    final spy = ClipboardSpy();
    final controller = AppController(dirs: dirs, store: store, source: spy);
    await controller.copyImage(bill);

    expect(spy.copied, [original.path], reason: '原图存在时不该退到缩略图');
    expect(dirs.copyDir.existsSync(), isFalse, reason: '用不上副本就别建目录');
    expect(controller.toast, contains('已复制图片'));

    await tmp.delete(recursive: true);
  });

  test('原图和缩略图都没有：给出准确原因，不再误报「原图被移动或删除」', () async {
    final (tmp, dirs, store) = await newDevice('none');
    final spy = ClipboardSpy();
    final controller = AppController(dirs: dirs, store: store, source: spy);

    // 同步来的记录：path 有值但本机没有这个文件，也没有缩略图
    await controller.copyImage(makeBill(path: '/another/pc/a.jpg'));
    expect(spy.copied, isEmpty);
    expect(controller.toast, contains('不在这台电脑上'));
    expect(controller.toast, contains('缩略图'),
        reason: '要告诉用户「本机也没有缩略图」，而不是只说失败');

    // 连 path 都没有（远端记录，原图和缩略图都还没下下来）
    await controller.copyImage(makeBill(path: ''));
    expect(controller.toast, contains('先同步一次'));

    await tmp.delete(recursive: true);
  });

  test('剪贴板被占用：说清是剪贴板的问题，不甩锅给原图', () async {
    final (tmp, dirs, store) = await newDevice('busy');
    final original = File('${tmp.path}/a.png');
    await original.writeAsBytes(List<int>.filled(32, 3));
    final spy = ClipboardSpy()..busy = true;
    final controller = AppController(dirs: dirs, store: store, source: spy);
    await controller.copyImage(makeBill(path: original.path));

    expect(controller.toast, contains('剪贴板'));
    expect(controller.toast, contains('重试'));
    expect(controller.toast, isNot(contains('被移动')));

    await tmp.delete(recursive: true);
  });

  test('同名不同图：不覆盖上一次复制的文件（可能还没粘贴）', () async {
    final (tmp, dirs, _) = await newDevice('same-name');
    await dirs.thumbFile('a.jpg').writeAsBytes(List<int>.filled(16, 1));
    await dirs.thumbFile('b.jpg').writeAsBytes(List<int>.filled(16, 2));

    final first = resolveCopyPlan(makeBill(thumb: 'a.jpg'), dirs);
    final second = resolveCopyPlan(makeBill(thumb: 'b.jpg'), dirs);
    expect(first.kind, CopyKind.thumbnail);
    expect(second.kind, CopyKind.thumbnail);
    expect(first.path, isNot(second.path));
    expect(p.basename(first.path), '微信图片_1.jpg');
    expect(p.basename(second.path), '微信图片_1 (2).jpg');
    expect(await File(first.path).readAsBytes(), everyElement(1));
    expect(await File(second.path).readAsBytes(), everyElement(2));

    // 同一张再复制一次：复用第一个文件，别一直加序号
    final again = resolveCopyPlan(makeBill(thumb: 'a.jpg'), dirs);
    expect(again.path, first.path);

    await tmp.delete(recursive: true);
  });

  test('剪贴板文件名按 Windows 规则清洗', () {
    expect(copyFileName(makeBill(name: '微信图片_1.jpg')), '微信图片_1.jpg');
    expect(copyFileName(makeBill(name: '屏幕截图.PNG')), '屏幕截图.png');
    expect(copyFileName(makeBill(name: 'a/b:c*?.jpg')), 'b_c__.jpg');
    expect(copyFileName(makeBill(name: 'CON')), '_CON.jpg');
    expect(copyFileName(makeBill(name: '')), '收款单.jpg');
    expect(copyFileName(makeBill(name: '名字超长' * 40)), hasLength(64));
  });
}
