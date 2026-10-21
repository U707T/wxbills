import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

import 'windows_clipboard.dart';

/// 一张图片的「本机定位信息」。
class PhotoRef {
  const PhotoRef({
    required this.path,
    required this.name,
    required this.modified,
    required this.size,
    required this.folderId,
    this.isSaf = true,
  });

  /// Android：`content://…` 文档 URI；桌面：绝对路径。
  final String path;
  final String name;
  final int modified;
  final int size;
  final String folderId;
  final bool isSaf;
}

/// 供 OCR 使用的像素图（RGBA8888）。
class OcrImage {
  const OcrImage(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width;
  final int height;
}

/// 平台相关能力：列目录、读图、缩略图、刷新图片日期。
///
/// 抽成接口是因为 Android 与 Windows 的取图方式完全不同：
///  * Android：只能走 SAF（`saf_util` 插件 + 平台通道），URI 不是文件路径，
///    而且大图必须在原生侧下采样，否则 Dart 解码 12MP 图片会又慢又费内存；
///  * Windows：普通文件系统，`dart:io` + `image` 包直接读。
///
/// 上层（Scanner / UI）只依赖这个接口，两个平台共享同一套业务逻辑。
abstract class PhotoSource {
  /// 是否支持「刷新图片入库时间」（让 QQ / 相册把旧图当新图）。
  bool get supportsRefreshDate;

  /// 是否支持把图片复制到剪贴板。
  ///
  /// 桌面端拿它顶替 Android 的「刷新日期」：PC 上没有「相册入库时间」这回事，
  /// 但「复制这张图，粘到聊天窗口里发出去」是每天都会用到的动作。
  bool get supportsCopyImage;

  /// 把图片放进系统剪贴板。失败返回 false。
  Future<bool> copyImage(String path);

  /// 最后一次读图失败的原因（成功时为空）。界面「识别诊断」会显示它，
  /// 不再把「图都读不出来」和「认不出金额」混成同一个「未识别」。
  String get loadError;

  /// 选一个目录，返回 (本机路径, 展示名)。用户取消返回 null。
  Future<({String path, String name})?> pickFolder();

  /// 递归列出目录下的图片（最深 2 层子目录，与原版一致）。
  Future<List<PhotoRef>> listImages(String folderPath, {String folderId = ''});

  /// 最近一次 [listImages] 是否遇到过读取失败（含子目录）。
  ///
  /// 这个信号决定扫描敢不敢「按磁盘现状清理记录」：只要列目录失败过，
  /// 拿到的列表就是残缺的，那时把「不在列表里」当成「文件已删除」等于删账。
  /// 默认空串（测试替身不必实现）。
  String get listError => '';

  /// 读出用于 OCR 的像素图（已按需下采样，最长边约 [maxDim]）。
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600});

  /// 生成缩略图（JPEG 字节），失败返回 null。
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256});

  /// 读取**原文件**的完整字节（同步上传原图用）。失败返回 null。
  ///
  /// 默认返回 null = 这个实现不参与原图同步；测试里的替身因此不必逐个实现。
  /// Android（SAF 的 `content://`）与桌面（普通文件）都覆盖了它。
  Future<Uint8List?> readOriginal(String path) async => null;

  /// 原文件字节数。未知返回 null。
  ///
  /// 同步上传前先用它判断 32MB 上限：先 `readOriginal` 再判断等于
  /// 「先把几十 MB 读进堆再决定不要」，超限的图正好会在最需要保护时 OOM。
  Future<int?> originalLength(String path) async => null;

  /// 把图片的「入库时间」刷新为现在（Android 专属能力）。
  Future<RefreshOutcome> refreshDate(String path, String? folderPath);

  /// 目录是否仍然可访问。
  Future<bool> folderExists(String folderPath);
}

/// 从图片字节解码出 OCR 用的 RGBA 像素图（纯 Dart）。
///
/// 两个平台共用：Windows 直接走它；Android 在「原生下采样解码」失败时
/// 作为第二路线（原生只负责把原文件字节取回来）。多一条兜底，就不至于
/// 因为一处解码失败让整本账显示成「未识别」。
img.Image? decodeImageScaled(Uint8List bytes, int maxDim) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final longest =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    if (longest <= maxDim) return decoded;
    return img.copyResize(
      decoded,
      width: (decoded.width * maxDim / longest).round(),
      height: (decoded.height * maxDim / longest).round(),
      interpolation: img.Interpolation.average,
    );
  } catch (_) {
    return null;
  }
}

OcrImage? decodeBytesForOcr(Uint8List bytes, {int maxDim = 1600}) {
  final scaled = decodeImageScaled(bytes, maxDim);
  if (scaled == null) return null;
  return OcrImage(
    scaled.getBytes(order: img.ChannelOrder.rgba),
    scaled.width,
    scaled.height,
  );
}

/// 刷新日期的结果。
class RefreshOutcome {
  const RefreshOutcome({
    required this.ok,
    this.newPath = '',
    this.message = '',
    this.diagnosis = '',
  });

  final bool ok;

  /// 刷新后新的本机路径（走「重建新文件」路线时会变，调用方必须回写）。
  final String newPath;
  final String message;
  final String diagnosis;

  static const RefreshOutcome unsupported =
      RefreshOutcome(ok: false, message: '当前平台不支持刷新图片日期');
}

const Set<String> kImageExtensions = {
  'jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'heic', 'heif', 'avif',
};

bool isImageName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return kImageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

// ====================================================================== Android

/// Android 实现：SAF 列目录 + 平台通道下采样解码 + 刷新日期。
class AndroidPhotoSource implements PhotoSource {
  AndroidPhotoSource() : _saf = SafUtil();

  final SafUtil _saf;
  static const MethodChannel _scan = MethodChannel('wxbills/scan');

  String _loadError = '';

  @override
  String get loadError => _loadError;

  @override
  bool get supportsRefreshDate => true;

  // Android 侧还没有做「复制图片」（需要 FileProvider + ClipData），
  // 行内按钮继续用「刷新日期」。
  @override
  bool get supportsCopyImage => false;

  @override
  Future<bool> copyImage(String path) async => false;

  @override
  Future<({String path, String name})?> pickFolder() async {
    final dir = await _saf.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    if (dir == null) return null;
    final name = dir.name.trim().isEmpty ? '相册' : dir.name.trim();
    return (path: dir.uri, name: name);
  }

  @override
  Future<bool> folderExists(String folderPath) async {
    try {
      return await _saf.exists(folderPath, true);
    } catch (_) {
      return false;
    }
  }

  String _listError = '';

  @override
  String get listError => _listError;

  @override
  Future<List<PhotoRef>> listImages(String folderPath,
      {String folderId = ''}) async {
    _listError = '';
    final out = <PhotoRef>[];
    await _walk(folderPath, out, 0, folderId);
    return out;
  }

  Future<void> _walk(
      String dirUri, List<PhotoRef> out, int depth, String folderId) async {
    if (depth > 2) return;
    List<SafDocumentFile> children;
    try {
      children = await _saf.list(dirUri);
    } catch (e) {
      // 不能静默返回空列表：上层会以为「这个目录里一张图都没有」，
      // 收尾清理时把整个相册的记录打成墓碑（见 Scanner.scanAll 的清理段）。
      _listError = '列目录失败：$e';
      return;
    }
    for (final c in children) {
      if (c.isDir) {
        await _walk(c.uri, out, depth + 1, folderId);
        continue;
      }
      if (!isImageName(c.name)) continue;
      out.add(PhotoRef(
        path: c.uri,
        name: c.name,
        modified: c.lastModified,
        size: c.length,
        folderId: folderId,
      ));
    }
  }

  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async {
    // 路线 A：原生侧按 inSampleSize 下采样解码（最快、最省内存）
    try {
      final raw = await _scan.invokeMethod<Map<Object?, Object?>>(
        'readImage',
        {'uri': path, 'maxDim': maxDim},
      );
      if (raw == null) {
        _loadError = '原生解码返回 null（BitmapFactory 解不了这个文件）';
      } else {
        final bytes = raw['bytes'];
        final w = (raw['width'] as num?)?.toInt() ?? 0;
        final h = (raw['height'] as num?)?.toInt() ?? 0;
        if (bytes is Uint8List && w > 0 && h > 0) {
          _loadError = '';
          return OcrImage(bytes, w, h);
        }
        _loadError = '原生解码返回的数据不完整（${bytes.runtimeType} ${w}x$h）';
      }
    } on PlatformException catch (e) {
      _loadError = '原生解码失败：${e.code}${e.message == null ? '' : ' ${e.message}'}';
    } on MissingPluginException {
      _loadError = '平台通道 wxbills/scan 未注册';
    } catch (e) {
      _loadError = '原生解码异常：$e';
    }

    // 路线 B：只让原生把原文件字节取回来，Dart 侧自己解码。
    // 这条路线不碰 BitmapFactory，也不依赖通道返回位图，是 A 失败时的兜底。
    try {
      final bytes = await _scan.invokeMethod<Uint8List>('readBytes', {'uri': path});
      if (bytes == null || bytes.isEmpty) {
        _loadError = '$_loadError；读取文件字节失败';
        return null;
      }
      final ocr = decodeBytesForOcr(bytes, maxDim: maxDim);
      if (ocr == null) {
        _loadError = '$_loadError；Dart 侧解码失败（${bytes.length} 字节）';
        return null;
      }
      // 路线 B 成功：把 A 的错误降级成提示，不当失败处理
      _loadError = '';
      return ocr;
    } on PlatformException catch (e) {
      _loadError = '$_loadError；读取文件字节失败：${e.message ?? e.code}';
      return null;
    } on MissingPluginException {
      _loadError = '$_loadError；读取文件字节失败：通道未注册';
      return null;
    } catch (e) {
      _loadError = '$_loadError；读取文件字节异常：$e';
      return null;
    }
  }

  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async {
    // 优先用系统缩略图（最快，且不需要把原图读进内存）
    try {
      final tmp = await Directory.systemTemp.createTemp('wxbills_thumb');
      try {
        final dest = '${tmp.path}/t.jpg';
        final ok = await _saf.saveThumbnailToFile(
          uri: path,
          width: maxDim,
          height: maxDim,
          destPath: dest,
          format: 'jpeg',
          quality: 82,
        );
        if (ok) {
          final f = File(dest);
          if (await f.exists()) {
            final bytes = await f.readAsBytes();
            if (bytes.isNotEmpty) return bytes;
          }
        }
      } finally {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {
      // 退回下面的解码路线
    }
    final ocr = await loadForOcr(path, maxDim: maxDim);
    if (ocr == null) return null;
    return _encodeJpeg(ocr, maxDim);
  }

  /// 原图大小：走 `stat` 通道（`OpenableColumns.SIZE`，拿不到再退回 fd 长度）。
  @override
  Future<int?> originalLength(String path) async {
    try {
      final size = await _scan.invokeMethod<int>('stat', {'uri': path});
      return size != null && size >= 0 ? size : null;
    } catch (_) {
      return null;
    }
  }

  /// 原图上传：走 `readBytes` 通道（只回原始字节，不做下采样）。
  @override
  Future<Uint8List?> readOriginal(String path) async {
    try {
      final bytes = await _scan.invokeMethod<Uint8List>('readBytes', {'uri': path});
      if (bytes == null || bytes.isEmpty) {
        _loadError = '读取原图失败：通道返回空';
        return null;
      }
      return bytes;
    } on PlatformException catch (e) {
      _loadError = '读取原图失败：${e.message ?? e.code}';
      return null;
    } on MissingPluginException {
      _loadError = '读取原图失败：平台通道未注册';
      return null;
    } catch (e) {
      _loadError = '读取原图失败：$e';
      return null;
    }
  }

  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async {
    try {
      final raw =
          await _scan.invokeMethod<Map<Object?, Object?>>('refreshDate', {
        'uri': path,
        'treeUri': folderPath ?? '',
      });
      if (raw == null) {
        return const RefreshOutcome(ok: false, message: '刷新失败（平台未返回结果）');
      }
      return RefreshOutcome(
        ok: raw['ok'] == true,
        newPath: '${raw['newUri'] ?? ''}',
        message: '${raw['message'] ?? ''}',
        diagnosis: '${raw['diagnosis'] ?? ''}',
      );
    } on PlatformException catch (e) {
      return RefreshOutcome(ok: false, message: '刷新失败：${e.message}');
    } on MissingPluginException {
      return const RefreshOutcome(ok: false, message: '刷新失败：平台通道未注册');
    }
  }
}

// ====================================================================== Desktop

/// Windows / 桌面实现：普通文件系统。
class DesktopPhotoSource implements PhotoSource {
  DesktopPhotoSource();

  @override
  bool get supportsRefreshDate => false;

  @override
  bool get supportsCopyImage => true;

  @override
  Future<bool> copyImage(String path) => WindowsClipboard.copyFile(path);

  @override
  Future<({String path, String name})?> pickFolder() async {
    // 用 file_picker 的原生目录对话框（Windows 上是 IFileDialog），
    // 比自己写 FFI 调 Win32 简单，也不会额外拉 win32 依赖。
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择存放收款单截图的文件夹',
    );
    if (path == null || path.isEmpty) return null;
    final parts = path.split(RegExp(r'[\\/]'));
    final name = parts.isEmpty ? path : parts.lastWhere((e) => e.isNotEmpty, orElse: () => path);
    return (path: path, name: name.isEmpty ? path : name);
  }

  @override
  Future<bool> folderExists(String folderPath) async =>
      Directory(folderPath).exists();

  String _listError = '';

  @override
  String get listError => _listError;

  @override
  Future<List<PhotoRef>> listImages(String folderPath,
      {String folderId = ''}) async {
    _listError = '';
    final out = <PhotoRef>[];
    await _walk(Directory(folderPath), out, 0, folderId);
    return out;
  }

  Future<void> _walk(
      Directory dir, List<PhotoRef> out, int depth, String folderId) async {
    if (depth > 2) return;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (e) {
      // 网络盘断连 / 移动硬盘拔掉 / 权限变化：同样不能当成「目录是空的」
      _listError = '列目录失败：$e';
      return;
    }
    for (final e in entries) {
      final name = e.path.split(Platform.pathSeparator).last;
      if (e is Directory) {
        if (name.startsWith('.')) continue;
        await _walk(e, out, depth + 1, folderId);
        continue;
      }
      if (e is! File || !isImageName(name)) continue;
      try {
        final st = await e.stat();
        out.add(PhotoRef(
          path: e.path,
          name: name,
          modified: st.modified.millisecondsSinceEpoch,
          size: st.size,
          folderId: folderId,
          isSaf: false,
        ));
      } catch (_) {
        // 单个文件读不到就跳过
      }
    }
  }

  String _loadError = '';

  @override
  String get loadError => _loadError;

  Future<Uint8List?> _readBytes(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (e) {
      _loadError = '读取文件失败：$e';
      return null;
    }
  }

  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async {
    final bytes = await _readBytes(path);
    if (bytes == null) return null;
    final ocr = decodeBytesForOcr(bytes, maxDim: maxDim);
    _loadError = ocr == null ? '图片解码失败（${bytes.length} 字节）' : '';
    return ocr;
  }

  @override
  Future<Uint8List?> readOriginal(String path) => _readBytes(path);

  @override
  Future<int?> originalLength(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async {
    final bytes = await _readBytes(path);
    if (bytes == null) return null;
    final decoded = decodeImageScaled(bytes, maxDim);
    if (decoded == null) return null;
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 82));
  }

  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async =>
      const RefreshOutcome(
        ok: false,
        message: '桌面端没有「相册入库时间」这个概念，无需刷新（Android 专属功能）',
      );
}

/// 把 RGBA 像素图编码成 JPEG（Android 侧兜底用）。
Uint8List? _encodeJpeg(OcrImage image, int maxDim) {
  try {
    final im = img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: image.rgba.buffer,
      order: img.ChannelOrder.rgba,
    );
    final longest = im.width > im.height ? im.width : im.height;
    final scaled = longest <= maxDim
        ? im
        : img.copyResize(im,
            width: (im.width * maxDim / longest).round(),
            height: (im.height * maxDim / longest).round(),
            interpolation: img.Interpolation.average);
    return Uint8List.fromList(img.encodeJpg(scaled, quality: 82));
  } catch (_) {
    return null;
  }
}

/// 按平台返回实现。
PhotoSource createPhotoSource() =>
    Platform.isAndroid ? AndroidPhotoSource() : DesktopPhotoSource();
