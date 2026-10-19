import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一个本地文件原子写入器：先写 `.tmp` 再 rename。
///
/// 收款单数据是用户唯一的一份账，写到一半掉电/被杀不能变成半截 JSON。
Future<void> writeJsonAtomic(File target, Object? value) async {
  await target.parent.create(recursive: true);
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsString(jsonEncode(value), flush: true);
  await tmp.rename(target.path);
}

Future<Map<String, dynamic>?> readJsonFile(
  File file, {
  void Function(String backupPath)? onCorrupt,
}) async {
  try {
    if (!await file.exists()) return null;
    final text = await file.readAsString();
    if (text.trim().isEmpty) return null;
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    // 坏文件不阻断启动：保留现场，并让上层把这件事告诉用户
    try {
      final backup = '${file.path}.broken-${DateTime.now().millisecondsSinceEpoch}';
      await file.copy(backup);
      onCorrupt?.call(backup);
    } catch (_) {
      onCorrupt?.call('${file.path}.broken-*');
    }
    return null;
  }
}
