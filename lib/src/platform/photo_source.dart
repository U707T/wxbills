import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

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

  /// 选一个目录，返回 (本机路径, 展示名)。用户取消返回 null。
  Future<({String path, String name})?> pickFolder();

  /// 递归列出目录下的图片（最多 2 层子目录，与原版一致）。
  Future<List<PhotoRef>> listImages(String folderPath, {String folderId = ''});

  /// 读出用于 OCR 的像素图（已按需下采样，最长边约 [maxDim]）。
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600});

  /// 生成缩略图（JPEG 字节），失败返回 null。
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256});

  /// 把图片的「入库时间」刷新为现在（Android 专属能力）。
  Future<RefreshOutcome> refreshDate(String path, String? folderPath);

  /// 目录是否仍然可访问。
  Future<bool> folderExists(String folderPath);
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

  @override
  bool get supportsRefreshDate => true;

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

  @override
  Future<List<PhotoRef>> listImages(String folderPath,
      {String folderId = ''}) async {
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
    } catch (_) {
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
    try {
      final raw = await _scan.invokeMethod<Map<Object?, Object?>>(
        'readImage',
        {'uri': path, 'maxDim': maxDim},
      );
      if (raw == null) return null;
      final bytes = raw['bytes'];
      final w = (raw['width'] as num?)?.toInt() ?? 0;
      final h = (raw['height'] as num?)?.toInt() ?? 0;
      if (bytes is! Uint8List || w <= 0 || h <= 0) return null;
      return OcrImage(bytes, w, h);
    } on PlatformException {
      return null;
    } on MissingPluginException {
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

  @override
  Future<List<PhotoRef>> listImages(String folderPath,
      {String folderId = ''}) async {
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
    } catch (_) {
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

  @override
  Future<OcrImage?> loadForOcr(String path, {int maxDim = 1600}) async {
    final decoded = await _decodeFile(path, maxDim);
    if (decoded == null) return null;
    return OcrImage(decoded.getBytes(order: img.ChannelOrder.rgba),
        decoded.width, decoded.height);
  }

  Future<img.Image?> _decodeFile(String path, int maxDim) async {
    try {
      final bytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final longest = decoded.width > decoded.height ? decoded.width : decoded.height;
      if (longest <= maxDim) return decoded;
      final scale = maxDim / longest;
      return img.copyResize(
        decoded,
        width: (decoded.width * scale).round(),
        height: (decoded.height * scale).round(),
        interpolation: img.Interpolation.average,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> makeThumbBytes(String path, {int maxDim = 256}) async {
    final decoded = await _decodeFile(path, maxDim);
    if (decoded == null) return null;
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 82));
  }

  @override
  Future<RefreshOutcome> refreshDate(String path, String? folderPath) async {
    try {
      final f = File(path);
      if (!await f.exists()) {
        return const RefreshOutcome(ok: false, message: '文件不存在');
      }
      await f.setLastModified(DateTime.now());
      return const RefreshOutcome(ok: true, message: '已更新文件修改时间');
    } catch (e) {
      return RefreshOutcome(ok: false, message: '刷新失败：$e');
    }
  }
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
