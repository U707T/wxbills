import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用私有目录布局。
///
/// ```
/// <support>/data.json          收款单 + 目录 + 设置（单文件快照）
/// <support>/thumbs/<id>.jpg    缩略图（随 WebDAV 同步）
/// <support>/cache/             扫描时的临时文件
/// <support>/copy/<原名>.jpg    复制图片时交给剪贴板的文件（没有原图时用缩略图生成）
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

  /// 「复制图片」交给剪贴板的文件放在这里。
  ///
  /// 不用 cache：Windows 的存储感知 / 清理工具会删 cache 里的东西，
  /// 而剪贴板里的文件是**按路径延迟读取**的——用户复制完过一会儿再粘贴，
  /// 文件必须还在。这里自己按天数清理（见 `copy_plan.dart`）。
  Directory get copyDir => Directory(p.join(root.path, 'copy'));

  Future<void> ensure() async {
    await root.create(recursive: true);
    await thumbDir.create(recursive: true);
    await cacheDir.create(recursive: true);
  }

  File thumbFile(String name) => File(p.join(thumbDir.path, name));

  File copyFile(String name) => File(p.join(copyDir.path, name));
}
