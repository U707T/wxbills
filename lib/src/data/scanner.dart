import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/bill.dart';
import '../ocr/amount_reader.dart';
import '../platform/photo_source.dart';
import 'app_dirs.dart';
import 'store.dart';

/// 扫描进度。
class ScanProgress {
  const ScanProgress({
    this.total = 0,
    this.done = 0,
    this.updated = 0,
    this.failed = 0,
    this.currentName = '',
    this.finished = false,
    this.message = '',
  });

  final int total;
  final int done;

  /// 本次新增或金额有更新的条数。
  final int updated;
  final int failed;
  final String currentName;
  final bool finished;
  final String message;

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);
}

/// 扫描图片来源目录，识别新图片的金额并入库。
///
/// 增量策略（沿用原版）：用「文件修改时间」判断是否变化，
/// 已入库且没变就直接跳过，所以第二次扫描几百张图也是秒级。
///
/// 与旧版的三个重要差别：
///  1. 主键改成跨设备稳定的 [Bill.id]（按本机路径查已有记录，不再依赖 SQLite 唯一索引）；
///  2. 手工确认过的金额**永不**被自动识别覆盖（原版的静默数据丢失问题）；
///  3. 顺手生成缩略图并落盘，这样 WebDAV 同步到另一台设备也能看到图；
///  4. 用户删掉的记录（墓碑）不会被后续扫描「复活」，列目录失败的目录也不参与清理。
class Scanner {
  Scanner({
    required this.store,
    required this.source,
    required this.dirs,
  });

  final BillStore store;
  final PhotoSource source;
  final AppDirs dirs;

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  /// 扫描全部已授权目录。
  ///
  /// [forceRecheck] 为 true 时忽略修改时间，全部重新识别（「重新识别全部」）。
  Future<ScanProgress> scanAll({
    void Function(ScanProgress)? onProgress,
    bool forceRecheck = false,
  }) async {
    _cancelled = false;
    final folders = store.folders;
    if (folders.isEmpty) {
      return const ScanProgress(finished: true, message: '还没有导入相册文件夹');
    }

    // 1) 列目录
    //
    // 按目录记录成败：列失败的目录**既不做识别、也不参与收尾清理**。
    // 否则一次 SAF 超时 / 授权抖动，就会让这个目录下所有记录都不在「还活着」集合里，
    // 收尾时被打成墓碑并同步出去——等于一次超时删掉整本账。
    onProgress?.call(const ScanProgress(message: '正在列目录…'));
    final perFolder = <String, List<PhotoRef>>{};
    final failedFolders = <String>{};
    for (final f in folders) {
      if (_cancelled) break;
      try {
        perFolder[f.id] = await source.listImages(f.path, folderId: f.id);
      } catch (_) {
        failedFolders.add(f.id);
      }
    }
    // 去重（同一张图可能被多个目录包含）
    final unique = <String, PhotoRef>{};
    for (final refs in perFolder.values) {
      for (final r in refs) {
        unique.putIfAbsent(r.path, () => r);
      }
    }
    final all = unique.values.toList();

    // 2) 建索引：本机路径 → 已有记录
    final byPath = <String, Bill>{};
    for (final b in store.allIncludingDeleted) {
      if (b.path.isNotEmpty) byPath[b.path] = b;
    }

    var done = 0;
    var updated = 0;
    var failed = 0;

    for (final ref in all) {
      if (_cancelled) break;
      done++;
      final prev = byPath[ref.path];
      // 用户已经显式删除过这条记录：扫描不得推翻它。
      // 原文件还在磁盘上（删除只写墓碑），照旧重识别就会把它「复活」成正常记录。
      if (prev != null && prev.deleted) continue;
      final unchanged = !forceRecheck &&
          prev != null &&
          prev.fileModified == ref.modified;

      if (unchanged) {
        if (done % 20 == 0 || done == all.length) {
          onProgress?.call(ScanProgress(
            total: all.length,
            done: done,
            updated: updated,
            failed: failed,
            currentName: ref.name,
          ));
        }
        continue;
      }

      onProgress?.call(ScanProgress(
        total: all.length,
        done: done - 1,
        updated: updated,
        failed: failed,
        currentName: ref.name,
      ));

      final id = prev?.id ?? newId();
      final outcome = await _recognize(ref, id);
      final now = DateTime.now().millisecondsSinceEpoch;

      if (prev == null) {
        // 新图片
        final bill = Bill(
          id: id,
          name: ref.name,
          path: ref.path,
          amountCents: outcome.cents,
          confidence: outcome.confidence,
          manual: false,
          fileModified: ref.modified,
          importedAt: now,
          updatedAt: now,
          folder: ref.folderId,
          thumb: outcome.thumb,
        );
        store.put(bill);
        byPath[ref.path] = bill;
        updated++;
        if (outcome.cents == null) failed++;
      } else if (prev.manual) {
        // 手工确认过：只刷新文件元信息与缩略图，金额/备注绝不动
        final needsThumb = prev.thumb.isEmpty && outcome.thumb.isNotEmpty;
        final next = prev.copyWith(
          name: ref.name,
          fileModified: ref.modified,
          deleted: false,
          thumb: needsThumb ? outcome.thumb : prev.thumb,
          // 只有缩略图是新补的才算「改动」，否则不动 updatedAt，
          // 免得「只是重新扫描」就把记录标成刚改过、在同步里压过别的设备
          updatedAt: needsThumb ? now : prev.updatedAt,
        );
        store.put(next);
        if (needsThumb) updated++;
      } else {
        final next = prev.copyWith(
          name: ref.name,
          amountCents: outcome.cents,
          confidence: outcome.confidence,
          fileModified: ref.modified,
          deleted: false,
          thumb: outcome.thumb.isEmpty ? prev.thumb : outcome.thumb,
        );
        if (next.amountCents != prev.amountCents ||
            next.confidence != prev.confidence ||
            next.thumb != prev.thumb) {
          store.put(next.copyWith(updatedAt: now));
          updated++;
        } else {
          store.put(next);
        }
        if (outcome.cents == null) failed++;
      }

      // 每 10 张落一次盘，避免扫到一半被杀全丢
      if (done % 10 == 0) await store.save();
    }

    // 3) 清理已从磁盘消失的文件（软删除，让删除能同步出去）
    //
    // 三个前提全部满足才允许打墓碑：目录列成功、记录属于本机某个目录、目录当前可访问。
    // 中途被取消时整段跳过（列表可能是半截的）。
    if (!_cancelled) {
      final alive = all.map((r) => r.path).toSet();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final b in store.allIncludingDeleted.toList()) {
        if (b.deleted || b.path.isEmpty) continue;
        if (alive.contains(b.path)) continue;
        final folder = store.folderOf(b);
        if (folder == null) continue;
        if (failedFolders.contains(folder.id)) continue;
        if (!await source.folderExists(folder.path)) continue;
        store.put(b.copyWith(deleted: true, updatedAt: now));
      }
    }

    for (final f in folders) {
      store.touchFolder(f.id, DateTime.now().millisecondsSinceEpoch);
    }
    // 墓碑会随同步一直传下去，但不必永久保留：清掉过期的，快照才不会被历史撑大。
    store.purgeTombstones();
    await store.save();
    await store.pruneThumbs();

    final msg = '共 ${all.length} 张，更新 $updated 张'
        '${failed > 0 ? '，$failed 张未识别' : ''}'
        '${failedFolders.isEmpty ? '' : '（${failedFolders.length} 个目录读取失败，已跳过清理）'}';
    final result = ScanProgress(
      total: all.length,
      done: done,
      updated: updated,
      failed: failed,
      finished: true,
      message: msg,
    );
    onProgress?.call(result);
    return result;
  }

  /// 只识别一张（用于「重新识别这一张」）。
  Future<AmountResult> readOne(String path) async {
    final ocr = await source.loadForOcr(path);
    if (ocr == null) return AmountResult.empty;
    return AmountReader.read(ocr.rgba, ocr.width, ocr.height);
  }

  Future<_Outcome> _recognize(PhotoRef ref, String billId) async {
    int? cents;
    var confidence = 0.0;
    try {
      final ocr = await source.loadForOcr(ref.path);
      if (ocr != null) {
        final r = AmountReader.read(ocr.rgba, ocr.width, ocr.height);
        confidence = r.confidence;
        // 认出来就记下来：置信度不够的由界面标「待核对」，不丢数据
        cents = Bill.centsFromYuan(r.value);
      }
    } catch (_) {
      // 单张失败不影响整批
    }

    final thumb = await _ensureThumb(ref, billId);
    return _Outcome(cents, confidence, thumb);
  }

  /// 缩略图文件名固定为 `<记录 id>.jpg` —— 同步（远端 thumbs/）与
  /// 本地清理（[BillStore.pruneThumbs]）都依赖这个约定，不能随意改。
  Future<String> _ensureThumb(PhotoRef ref, String billId) async {
    try {
      final bytes = await source.makeThumbBytes(ref.path);
      if (bytes == null || bytes.isEmpty) return '';
      await dirs.thumbDir.create(recursive: true);
      final name = '$billId.jpg';
      final f = File(p.join(dirs.thumbDir.path, name));
      if (!await f.exists() || (await f.length()) != bytes.length) {
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(f.path);
      }
      return name;
    } catch (_) {
      return '';
    }
  }
}

class _Outcome {
  const _Outcome(this.cents, this.confidence, this.thumb);
  final int? cents;
  final double confidence;
  final String thumb;
}
