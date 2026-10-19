import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/app/app_controller.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/platform/photo_source.dart';

/// 只数「列目录被调用了几次」的图片源。
class CountingSource implements PhotoSource {
  CountingSource(this.paths);

  final List<String> paths;
  int listCalls = 0;

  @override
  bool get supportsRefreshDate => false;
  @override
  bool get supportsCopyImage => false;
  @override
  Future<bool> copyImage(String path) async => false;
  @override
  String get loadError => '';
  @override
  Future<({String path, String name})?> pickFolder() async => null;
  @override
  Future<bool> folderExists(String folderPath) async => true;
  @override
  Future<List<PhotoRef>> listImages(String folderPath, {String folderId = ''}) async {
    listCalls++;
    return [
      for (final p in paths)
        PhotoRef(
          path: p,
          name: p.split('/').last,
          modified: 1700000000000,
          size: 1,
          folderId: folderId,
        ),
    ];
  }

  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async => null;
  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async => null;
  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async =>
      const RefreshOutcome(ok: false);
}

Future<(Directory, AppDirs, BillStore, CountingSource)> setup({
  bool autoScan = false,
}) async {
  final tmp = await Directory.systemTemp.createTemp('wxbills_boot');
  final dirs = AppDirs(Directory('${tmp.path}/data'));
  await dirs.ensure();
  final store = BillStore(dirs);
  await store.load();
  store.addFolder('/album', 'album');
  if (autoScan) {
    store.setPrefs(store.prefs.copyWith(autoScanOnBoot: true));
  }
  await store.save();
  final source = CountingSource(['/album/a.png', '/album/b.png']);
  return (tmp, dirs, store, source);
}

/// 落盘是异步的：等一小会儿再删，避免和后台 save 抢同一个目录。
Future<void> _cleanup(Directory tmp) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  try {
    await tmp.delete(recursive: true);
  } catch (_) {}
}

void main() {
  test('启动不再自动扫相册：只在点「扫描识别」时列目录', () async {
    final (tmp, dirs, store, source) = await setup();
    final c = AppController(dirs: dirs, store: store, source: source);

    await c.init();
    expect(source.listCalls, 0, reason: '打开应用不该去列相册目录（大相册会卡首屏）');
    expect(store.count, 0);

    await c.scan(force: false);
    expect(source.listCalls, 1, reason: '手动扫描才刷新');
    expect(store.count, 2);

    // 再点一次：增量扫描，仍然允许列目录（用户就是要刷新）
    await c.scan(force: false);
    expect(source.listCalls, 2);

    await _cleanup(tmp);
  });

  test('设置里打开「启动时自动扫描」后，启动仍会扫一遍', () async {
    final (tmp, dirs, store, source) = await setup(autoScan: true);
    final c = AppController(dirs: dirs, store: store, source: source);

    await c.init();
    expect(source.listCalls, 1);
    expect(store.count, 2);

    await _cleanup(tmp);
  });

  test('一次性说明：标记已看过后落盘，重开应用不再弹', () async {
    final (tmp, dirs, store, source) = await setup();
    final c = AppController(dirs: dirs, store: store, source: source);
    await c.init();

    expect(c.hasSeenTip(TipKeys.refreshDate), isFalse, reason: '第一次应该弹');
    await c.markTipSeen(TipKeys.refreshDate);
    expect(c.hasSeenTip(TipKeys.refreshDate), isTrue);

    // 重新读盘：已读状态必须持久化，否则每次冷启动又弹一遍
    final reloaded = BillStore(dirs);
    await reloaded.load();
    expect(reloaded.prefs.hasSeen(TipKeys.refreshDate), isTrue);

    // 设置页的「重新显示所有说明」
    await c.resetTips();
    final again = BillStore(dirs);
    await again.load();
    expect(again.prefs.hasSeen(TipKeys.refreshDate), isFalse);

    await _cleanup(tmp);
  });

  test('相同文案的提示 4 秒内只弹一次（连点不再排队弹一串）', () async {
    final (tmp, dirs, store, source) = await setup();
    final c = AppController(dirs: dirs, store: store, source: source);
    await c.init();

    c.showToast('已是最新，无需同步');
    final first = c.toastSeq;
    c.showToast('已是最新，无需同步');
    c.showToast('已是最新，无需同步');
    expect(c.toastSeq, first, reason: '同一句话连弹三次只该显示一次');

    c.showToast('另一句话');
    expect(c.toastSeq, first + 1, reason: '不同内容仍然要提示');

    await _cleanup(tmp);
  });

  test('列表缓存与数据版本同步：改一条金额后列表立刻更新', () async {
    final (tmp, dirs, store, source) = await setup();
    final c = AppController(dirs: dirs, store: store, source: source);
    await c.init();
    await c.scan(force: false);

    final before = c.visibleBills.length;
    expect(before, 2);
    expect(c.visibleSumCents, 0, reason: '两张都没认出来');

    final id = store.bills.first.id;
    c.setAmount(id, 2450);
    expect(c.visibleSumCents, 2450, reason: '缓存必须随 store.revision 失效');
    expect(c.visibleBills.firstWhere((b) => b.id == id).amountCents, 2450);

    await _cleanup(tmp);
  });
}
