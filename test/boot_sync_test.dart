import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/app/app_controller.dart';
import 'package:wxbills/src/data/app_dirs.dart';
import 'package:wxbills/src/data/store.dart';
import 'package:wxbills/src/platform/photo_source.dart';

import 'support/test_dav_server.dart';

/// 不碰 widget 的图片源（本文件不能有 testWidgets：TestWidgetsFlutterBinding
/// 会把 HttpClient 打成 400，同步测试就必须能真发请求）。
class FakeSource implements PhotoSource {
  FakeSource(this.paths);
  final List<String> paths;
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
  Future<List<PhotoRef>> listImages(String folderPath, {String folderId = ''}) async => [
        for (final p in paths)
          PhotoRef(path: p, name: p.split('/').last, modified: 1, size: 1, folderId: folderId),
      ];
  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async => null;
  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async => null;
  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async =>
      const RefreshOutcome(ok: false);
}

void main() {
  test('启动时会真的执行一次自动同步', () async {
    final server = await TestDavServer.start();
    final tmp = await Directory.systemTemp.createTemp('wxbills_boot');
    final dirs = AppDirs(Directory('${tmp.path}/data'));
    await dirs.ensure();
    final store = BillStore(dirs);
    await store.load();
    final source = FakeSource(['/album/a.png']);
    store.addFolder('/album', 'album');
    store.setSync(SyncConfig(
      url: server.url,
      username: 'alice',
      password: 'secret',
      autoSync: true,
    ));
    await store.save();

    final controller = AppController(dirs: dirs, store: store, source: source);
    await controller.init();

    expect(server.getFile('${server.root}/bills.json'), isNotNull,
        reason: '启动时 scan 与 sync 不能互相抢 _busy，导致同步一次都不跑');
    expect(store.sync.lastSyncAt, greaterThan(0));

    await server.stop();
    await tmp.delete(recursive: true);
  });

}
