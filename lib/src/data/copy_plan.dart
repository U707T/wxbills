import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/bill.dart';
import 'app_dirs.dart';

/// 「复制图片」实际能拿到的东西。
enum CopyKind {
  /// 本机原图（`path` 指向的文件还在）。
  original,

  /// 随同步下载回来的原图（完整尺寸，存在 `<support>/media/`）。
  syncedOriginal,

  /// 本机没有原图，用随同步下载的缩略图兜底。
  thumbnail,

  /// 本机既没有原图也没有缩略图，复制不了。
  none,
}

/// 一次「复制图片」的决策结果。
class CopyPlan {
  const CopyPlan(this.kind, {this.path = '', this.reason = ''});

  final CopyKind kind;

  /// 要交给剪贴板的**本机文件**。仅 [CopyKind.none] 时为空。
  final String path;

  /// 复制不了时给用户看的原因（要能指导下一步，而不是只说「失败了」）。
  final String reason;

  bool get canCopy => kind != CopyKind.none;

  /// 这次复制的是不是完整尺寸（而不是 256px 的缩略图）。
  bool get isFullSize =>
      kind == CopyKind.original || kind == CopyKind.syncedOriginal;
}

/// 决定这次复制该把哪个文件放进剪贴板。
///
/// 来源按三级取，越靠前越清楚：
///  1. **本机原图**（[Bill.path] 指向的文件还在）；
///  2. **随同步下载的原图**（[Bill.photo] → `<support>/media/<id>.<ext>`）；
///  3. **缩略图**（`thumbs/<id>.jpg`，256px，能看但不清）。
///
/// 为什么要这套顺序：[Bill.path] 是**设备私有**的，从另一台设备同步来的记录
/// 带着那台设备的定位（Android 是 `content://…`，Windows 是另一台机器的路径），
/// 在本机根本不存在。原图现在会随同步下载到本机，所以第二级几乎总能命中；
/// 缩略图只在原图还没下完 / 太大被跳过时兜底，避免「列表里看得见图，点复制却失败」。
///
/// 不管用哪一级，都复制成**原图的名字**（`copy/微信图片_xxx.jpg`）——
/// 直接拿 `media/<id>.jpg` 交给剪贴板，粘到聊天窗口里对方看到的是一串十六进制。
///
/// 刻意做成同步的：缩略图只有几十 KB，原图也只有几 MB，读写都在毫秒级；
/// 而「点一下按钮」必须立刻有反应，异步化只会让按钮和结果之间多出几帧空窗。
CopyPlan resolveCopyPlan(Bill bill, AppDirs dirs) {
  // 1) 本机原图
  if (_exists(bill.path)) {
    return CopyPlan(CopyKind.original, path: bill.path);
  }

  // 2) 同步下来的原图（完整尺寸）
  if (bill.photo.isNotEmpty) {
    final synced =
        _materialize(dirs, dirs.mediaFile(bill.photo), copyFileName(bill));
    if (synced != null) return CopyPlan(CopyKind.syncedOriginal, path: synced);
  }

  // 3) 缩略图兜底
  if (bill.thumb.isNotEmpty) {
    final thumb = _materialize(
        dirs, dirs.thumbFile(p.basename(bill.thumb)), copyFileName(bill));
    if (thumb != null) return CopyPlan(CopyKind.thumbnail, path: thumb);
  }

  return CopyPlan(
    CopyKind.none,
    reason: bill.path.isEmpty
        ? '这条记录还没有可复制的图（原图和缩略图都没同步下来），先同步一次再试'
        : '复制失败：原图不在这台电脑上（可能已被移动或删除），也没有可复制的缩略图',
  );
}

/// 剪贴板里那个文件叫什么名字。
///
/// 尽量保留原图的名字：粘贴到微信 / QQ 时对方看到的就是这个文件名。
/// 同时按 Windows 的规则做清洗（非法字符、结尾的点与空格、`CON` 这类保留名），
/// 否则写文件这一步就会失败，用户只会看到「复制失败」。
String copyFileName(Bill bill) {
  // 远端记录的 name 里可能带路径分隔符，只取最后一段
  var base = bill.name.trim().split(RegExp(r'[\\/]')).last;
  var ext = '';
  final dot = base.lastIndexOf('.');
  if (dot > 0 && base.length - dot <= 6) {
    ext = base.substring(dot).toLowerCase();
    base = base.substring(0, dot);
  }
  base = base.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  // Windows 不允许文件名以点或空格结尾
  base = base.replaceAll(RegExp(r'[. ]+$'), '');
  if (base.length > 60) base = base.substring(0, 60);
  if (base.isEmpty) base = '收款单';
  if (_reservedNames.contains(base.toLowerCase())) base = '_$base';
  if (!RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(ext)) ext = '.jpg';
  return '$base$ext';
}

/// Windows 保留设备名：`CON.jpg` 一样写不出来。
const Set<String> _reservedNames = {
  'con', 'prn', 'aux', 'nul', //
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

bool _exists(String path) {
  if (path.isEmpty) return false;
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

/// 把 [src] 复制成 `copy/<原图名>` 并返回路径；源文件不存在返回 null。
///
/// 统一走这一条路：缩略图和同步原图都先落成「原图的名字」再交给剪贴板。
String? _materialize(AppDirs dirs, File src, String name) {
  try {
    if (!src.existsSync()) return null;
    final bytes = src.readAsBytesSync();
    if (bytes.isEmpty) return null;
    dirs.copyDir.createSync(recursive: true);

    final target = _pickTarget(dirs, name, bytes);
    // 同一条记录重复复制：内容一样就不再写盘（避免把上一次复制的文件换掉）
    if (!target.existsSync() || !_sameBytes(target.readAsBytesSync(), bytes)) {
      final tmp = File('${target.path}.tmp');
      tmp.writeAsBytesSync(bytes, flush: true);
      tmp.renameSync(target.path);
    }
    _pruneOldCopies(dirs, keep: target.path);
    return target.path;
  } catch (_) {
    return null;
  }
}

/// 选一个不会覆盖「上一次复制、可能还没被粘贴」的文件名：
/// 同名同内容直接复用，同名不同图就加 ` (2)`、` (3)`…。
File _pickTarget(AppDirs dirs, String name, List<int> bytes) {
  var target = dirs.copyFile(name);
  if (!target.existsSync()) return target;
  if (_sameBytes(target.readAsBytesSync(), bytes)) return target;

  final stem = p.basenameWithoutExtension(name);
  final ext = p.extension(name);
  for (var i = 2; i <= 20; i++) {
    final alt = dirs.copyFile('$stem ($i)$ext');
    if (!alt.existsSync()) return alt;
    if (_sameBytes(alt.readAsBytesSync(), bytes)) return alt;
  }
  // 极端情况（同名 20 份）：覆盖最后那个，也不要让复制失败
  return dirs.copyFile('$stem (20)$ext');
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 清掉过期副本：剪贴板只在刚复制后需要这些文件，留着占地方。
///
/// 不删「刚刚写进去的那个」——它可能正在被别处的粘贴读。
void _pruneOldCopies(AppDirs dirs, {required String keep}) {
  final cutoff = DateTime.now().subtract(const Duration(days: 7));
  try {
    for (final e in dirs.copyDir.listSync()) {
      if (e is! File || e.path == keep) continue;
      try {
        if (e.statSync().modified.isBefore(cutoff)) e.deleteSync();
      } catch (_) {
        // 单个文件删不掉不影响复制
      }
    }
  } catch (_) {
    // 目录列不出来也不影响复制
  }
}
