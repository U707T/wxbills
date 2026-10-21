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
    this.loadFailed = 0,
    this.retried = 0,
    this.currentName = '',
    this.finished = false,
    this.message = '',
  });

  final int total;
  final int done;

  /// 本次新增或金额有更新的条数。
  final int updated;

  /// 识别跑完但没得出金额（可能图里没有金额，也可能版式不认识）。
  final int failed;

  /// 连图片都没读出来（HEIC 解不了 / 权限被撤 / 大图 OOM）。和 [failed] 分开算，
  /// 因为处理方式完全不同：前者要查来源和解码，后者才需要调识别。
  final int loadFailed;

  /// 本次重新走了一遍识别流程的已有记录数（含「重新识别全部」与未识别重试）。
  final int retried;

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
  /// [retryUnrecognized] 为 true 时，**没识别出金额的旧记录也会重试**——
  /// 文件没改过不代表当时识别成功（Android SAF 的 lastModified 还可能恒为 0，
  /// 只按时间判会永久跳过）。启动时的静默扫描传 false，避免每次开机全量重算。
  Future<ScanProgress> scanAll({
    void Function(ScanProgress)? onProgress,
    bool forceRecheck = false,
    bool retryUnrecognized = true,
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
    var listErrorHint = '';
    for (final f in folders) {
      if (_cancelled) break;
      try {
        final refs = await source.listImages(f.path, folderId: f.id);
        perFolder[f.id] = refs;
        // 平台层部分失败时不会抛异常（例如 SAF 里某个子目录读不到），
        // 只看返回值就会把「没列出来」误判成「文件没了」。这里必须认这个信号。
        if (source.listError.isNotEmpty) {
          failedFolders.add(f.id);
          listErrorHint = source.listError;
        }
      } catch (e) {
        failedFolders.add(f.id);
        if (listErrorHint.isEmpty) listErrorHint = '$e';
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
    var loadFailed = 0;
    var retried = 0;
    // 每 10 张全量重写快照在几百条记录时是明显浪费，改成「按时间节流」。
    var lastSaveAt = 0;

    for (final ref in all) {
      if (_cancelled) break;
      done++;
      final prev = byPath[ref.path];
      // 用户已经显式删除过这条记录：扫描不得推翻它。
      // 原文件还在磁盘上（删除只写墓碑），照旧重识别就会把它「复活」成正常记录。
      if (prev != null && prev.deleted) continue;
      // 上次没识别出金额（且不是手工填的）：必须再试一次。
      final retry = retryUnrecognized &&
          prev != null &&
          prev.amountCents == null &&
          !prev.manual;
      final unchanged = !forceRecheck &&
          !retry &&
          prev != null &&
          prev.fileModified == ref.modified;

      if (unchanged) {
        // 缩略图缺失必须补一次：上次生成失败（大图 OOM / 系统缩略图被限流）时
        // 文件没改过，只按修改时间判断会让这条记录永远没有图。
        if (prev.thumb.isEmpty) {
          final thumb = await _ensureThumb(ref, prev.id);
          if (thumb.isNotEmpty && _stillOwned(prev)) {
            store.put(prev.copyWith(
              thumb: thumb,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ));
            updated++;
          }
        }
        if (done % 20 == 0 || done == all.length) {
          onProgress?.call(ScanProgress(
            total: all.length,
            done: done,
            updated: updated,
            failed: failed,
            loadFailed: loadFailed,
            retried: retried,
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
        loadFailed: loadFailed,
        retried: retried,
        currentName: ref.name,
      ));

      final id = prev?.id ?? newId();
      if (prev != null) retried++;
      final outcome = await _recognize(ref, id);
      if (outcome.loadFailed) loadFailed++;
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
        if (!_stillOwned(prev)) continue;
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
        // 识别是异步的：这期间用户可能已经手改了金额或删了这条记录。
        // 那种情况下扫描必须让位，不能拿旧快照把它写回去。
        if (!_stillOwned(prev)) continue;
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

      // 落盘按时间节流：几百条记录时「每 10 张全量重写一次 JSON」是纯浪费
      // （1000 张就是 100 次序列化 + 写盘），改成最多 4 秒一次。
      final saveNow = DateTime.now().millisecondsSinceEpoch;
      if (saveNow - lastSaveAt > 4000) {
        lastSaveAt = saveNow;
        await store.save();
      }
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
    // 墓碑不能在这里单独清：只清本机的话，下一次同步会把远端的墓碑原样合并回来
    // （清理等于没做）。过期墓碑的清理放在 SyncEngine.run() 里，随合并结果一起
    // 写回远端，两端才会真正变小。
    await store.save();
    await store.pruneThumbs();
    // 同步下来的原图副本也跟着记录走：记录没了就删掉，别白占几百 MB
    await store.pruneMedia();

    final parts = <String>['共 ${all.length} 张，更新 $updated 张'];
    if (failed > 0) parts.add('$failed 张未识别');
    if (loadFailed > 0) parts.add('$loadFailed 张图片读取失败');
    if (failedFolders.isNotEmpty) {
      final hint = listErrorHint.length > 80
          ? '${listErrorHint.substring(0, 80)}…'
          : listErrorHint;
      parts.add('${failedFolders.length} 个目录读取失败，已跳过清理'
          '${hint.isEmpty ? '' : '（$hint）'}');
    }
    final msg = parts.join('，');
    final result = ScanProgress(
      total: all.length,
      done: done,
      updated: updated,
      failed: failed,
      loadFailed: loadFailed,
      retried: retried,
      finished: true,
      message: msg,
    );
    onProgress?.call(result);
    return result;
  }

  /// 这条记录还是不是扫描开始时看到的那一份。
  ///
  /// 扫描一条一条跑、每条都要 await 解码与识别；这期间用户完全可能在列表里
  /// 手改金额或删掉它。写回前用 `updatedAt` 比对一次：对不上就整条让位，
  /// 绝不拿旧快照覆盖用户的选择。
  bool _stillOwned(Bill prev) {
    final cur = store.byId(prev.id);
    if (cur == null) return false;
    if (cur.deleted) return false;
    if (cur.updatedAt != prev.updatedAt) return false;
    if (cur.manual && !prev.manual) return false;
    return true;
  }

  Future<_Outcome> _recognize(PhotoRef ref, String billId) async {
    int? cents;
    var confidence = 0.0;
    // 「图都读不出来」和「读出来了但认不出金额」要分开报：
    // 前者要查来源（HEIC 解不了 / 权限被撤 / 大图 OOM），后者才是识别算法的事。
    var loadFailed = false;
    try {
      final ocr = await source.loadForOcr(ref.path);
      if (ocr == null) {
        loadFailed = true;
      } else {
        final r = AmountReader.read(ocr.rgba, ocr.width, ocr.height);
        confidence = r.confidence;
        // 认出来就记下来：置信度不够的由界面标「待核对」，不丢数据
        cents = Bill.centsFromYuan(r.value);
      }
    } catch (_) {
      // 单张失败不影响整批
      loadFailed = true;
    }

    final thumb = await _ensureThumb(ref, billId);
    return _Outcome(cents, confidence, thumb, loadFailed);
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
  const _Outcome(this.cents, this.confidence, this.thumb, this.loadFailed);
  final int? cents;
  final double confidence;
  final String thumb;

  /// 图片根本没读出来（不是「读出来了但没认金额」）。
  final bool loadFailed;
}
