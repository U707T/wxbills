import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/bill.dart';
import 'app_dirs.dart';

/// 「复制图片」实际能拿到的东西。
enum CopyKind {
  /// 本机原图（路径存在）。
  original,

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
}

/// 决定这次复制该把哪个文件放进剪贴板。
///
/// **为什么不能直接用 [Bill.path]**：这个字段是**设备私有**的。从另一台设备
/// 同步来的记录，`path` 是那台设备的定位（Android 是 `content://…`，
/// Windows 是另一台机器的绝对路径），在本机根本不存在。同步成功后列表里
/// 明明看得见缩略图，点「复制」却必然失败——这就是「同步成功后复制失败」。
///
/// 缩略图（`<id>.jpg`）会随记录一起同步下来，所以原图不在时用它兜底，
/// 并把它复制成**原图的名字**（`copy/微信图片_xxx.jpg`）——直接拿
/// `thumbs/<id>.jpg` 交给剪贴板，粘到聊天窗口里对方看到的就是一串十六进制。
///
/// 刻意做成同步的：缩略图只有几十 KB，读写都在 1ms 量级；而「点一下按钮」
/// 必须立刻有反应，异步化只会让按钮和结果之间多出几帧空窗。
CopyPlan resolveCopyPlan(Bill bill, AppDirs dirs) {
  if (_exists(bill.path)) {
    return CopyPlan(CopyKind.original, path: bill.path);
  }
  final thumb = _materializeThumb(bill, dirs);
  if (thumb != null) {
    return CopyPlan(CopyKind.thumbnail, path: thumb);
  }
  return CopyPlan(
    CopyKind.none,
    reason: bill.path.isEmpty
        ? '这条记录没有本机原图（是从其他设备同步来的），也没有缩略图可复制'
        : '复制失败：原图不在这台电脑上（可能已被移动或删除），也没有缩略图可复制',
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

/// 把缩略图复制成 `copy/<原图名>`。没有缩略图返回 null。
String? _materializeThumb(Bill bill, AppDirs dirs) {
  if (bill.thumb.isEmpty) return null;
  final src = dirs.thumbFile(p.basename(bill.thumb));
  try {
    if (!src.existsSync()) return null;
    final bytes = src.readAsBytesSync();
    if (bytes.isEmpty) return null;
    dirs.copyDir.createSync(recursive: true);

    final target = _pickTarget(dirs, copyFileName(bill), bytes);
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
