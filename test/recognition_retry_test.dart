import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/scanner.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/platform/photo_source.dart';

/// 可控的图片源：第一次「读不出来」，之后能读出来 / 或一直读不出来。
class FlakySource implements PhotoSource {
  FlakySource(this.paths);

  final List<String> paths;
  bool readable = false; // false = 解码失败（loadForOcr 返回 null）
  double value = 31.5;

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
  Future<List<PhotoRef>> listImages(String folderPath, {String folderId = ''}) async => [
        for (final p in paths)
          // modified 恒为 0：模拟 Android SAF 拿不到 lastModified 的情况
          PhotoRef(path: p, name: p.split('/').last, modified: 0, size: 1, folderId: folderId),
      ];

  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async {
    if (!readable) return null;
    // 一张能认出来的「图」：直接给识别器喂一张真实样图不现实，
    // 所以这里用宽度足够 + 纯白的图（识别结果为空），金额由下面覆盖。
    final w = 200, h = 200;
    return OcrImage(Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255), w, h);
  }

  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async =>
      Uint8List.fromList([1, 2, 3]);

  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async =>
      const RefreshOutcome(ok: false);
}

Future<(Directory, AppDirs, BillStore)> setup() async {
  final tmp = await Directory.systemTemp.createTemp('wxbills_retry');
  final dirs = AppDirs(Directory('${tmp.path}/data'));
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  store.addFolder('/album', 'album');
  return (tmp, dirs, store);
}

void main() {
  test('解码失败的记录：用户点「扫描识别」时会重新识别，不会永久停在未识别', () async {
    final (tmp, dirs, store) = await setup();
    final src = FlakySource(['/album/a.png']); // readable = false → 第一次全失败
    final scanner = Scanner(store: store, source: src, dirs: dirs);

    final first = await scanner.scanAll(retryUnrecognized: true);
    expect(store.count, 1);
    expect(store.bills.first.amountCents, isNull);
    expect(first.loadFailed, 1, reason: '「读不出来」要和「认不出金额」分开统计');

    // 用户修好了来源（或重新授权），再点一次「扫描识别」：
    // 文件修改时间没变（SAF 给的是 0），但未识别的记录必须重试。
    src.readable = true;
    final second = await scanner.scanAll(retryUnrecognized: true);
    expect(second.loadFailed, 0);
    expect(second.retried, 1, reason: '未识别的记录应该被重新走一遍识别流程');

    await tmp.delete(recursive: true);
  });

  test('静默启动扫描不重试未识别记录（避免每次开机都全量重算）', () async {
    final (tmp, dirs, store) = await setup();
    final src = FlakySource(['/album/a.png']);
    final scanner = Scanner(store: store, source: src, dirs: dirs);
    await scanner.scanAll(retryUnrecognized: true);

    final boot = await scanner.scanAll(retryUnrecognized: false);
    expect(boot.retried, 0, reason: '启动时的静默扫描应该只做增量');

    await tmp.delete(recursive: true);
  });

  test('手工填过金额的记录不会被「重新识别」动到', () async {
    final (tmp, dirs, store) = await setup();
    final src = FlakySource(['/album/a.png']);
    final scanner = Scanner(store: store, source: src, dirs: dirs);
    await scanner.scanAll(retryUnrecognized: true);

    final id = store.bills.first.id;
    store.setAmount(id, 2450, note: '客户确认');
    src.value = 99;

    await scanner.scanAll(retryUnrecognized: true, forceRecheck: true);
    expect(store.byId(id)!.amountCents, 2450, reason: '手工金额优先，重识别不能覆盖');

    await tmp.delete(recursive: true);
  });
}
