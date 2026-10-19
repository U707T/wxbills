import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用私有目录布局。
///
/// ```
/// <support>/data.json          收款单 + 目录 + 设置（单文件快照）
/// <support>/thumbs/<id>.jpg    缩略图（随 WebDAV 同步）
/// <support>/cache/             扫描时的临时文件
/// ```
class AppDirs {
  AppDirs(this.root);

  final Directory root;

  static Future<AppDirs> resolve() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'wxbills'));
    await dir.create(recursive: true);
    return AppDirs(dir);
  }

  File get dataFile => File(p.join(root.path, 'data.json'));

  Directory get thumbDir => Directory(p.join(root.path, 'thumbs'));

  Directory get cacheDir => Directory(p.join(root.path, 'cache'));

  Future<void> ensure() async {
    await root.create(recursive: true);
    await thumbDir.create(recursive: true);
    await cacheDir.create(recursive: true);
  }

  File thumbFile(String name) => File(p.join(thumbDir.path, name));
}
