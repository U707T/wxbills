import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/store.dart';
import '../model/bill.dart';
import 'webdav_client.dart';

/// 同步进度（用于界面上的进度条与文案）。
class SyncProgress {
  const SyncProgress(this.step, this.done, this.total, {this.message = ''});

  final String step;
  final int done;
  final int total;
  final String message;

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);
}

/// 同步结果。
class SyncResult {
  const SyncResult({
    required this.ok,
    this.message = '',
    this.pushed = 0,
    this.pulled = 0,
    this.thumbsUp = 0,
    this.thumbsDown = 0,
    this.conflicts = 0,
  });

  final bool ok;
  final String message;
  final int pushed;
  final int pulled;
  final int thumbsUp;
  final int thumbsDown;

  /// 两台设备都改过、需要按时间裁决的条数。
  final int conflicts;

  static SyncResult failure(String message) =>
      SyncResult(ok: false, message: message);

  @override
  String toString() => message;
}

/// WebDAV 同步引擎。
///
/// ## 远端布局
/// ```
/// <配置的地址>/
///   bills.json          全部记录（含墓碑）的完整快照
///   thumbs/<id>.jpg     缩略图（随记录一起同步）
/// ```
///
/// ## 为什么是「整份快照 + 条件写」而不是「按文件增量」
/// 收款单条数在几百量级，整份 JSON 只有几十 KB，一次 PUT 就完成；
/// 用 ETag 做条件写（`If-Match`）保证并发安全：别人先写了就拿到 412，
/// 重新下载 → 重新合并 → 再写，不会互相覆盖。这比自造增量日志简单可靠得多。
///
/// ## 合并规则
/// 同一 id 先看删除：任一端删除即删除胜（见 [mergeBill]），避免「删了又回来」；
/// 都没删时取 `updatedAt` 更新的那条。删除是墓碑（`deleted=1`），所以
/// 「A 删、B 改」一定收敛到已删除，不会复活。
class SyncEngine {
  SyncEngine(this.store, {this.deviceName = ''});

  final BillStore store;
  final String deviceName;

  static const String snapshotName = 'bills.json';
  static const String thumbsDirName = 'thumbs';
  static const int _maxAttempts = 3;

  WebDavClient _client() {
    final cfg = store.sync;
    return WebDavClient(
      cfg.url,
      username: cfg.username,
      password: cfg.password,
      allowInsecureTls: cfg.allowInsecureTls,
    );
  }

  /// 执行一次双向同步。
  ///
  /// [onProgress] 在同步线程里被调用，界面自行切回主线程。
  Future<SyncResult> run({void Function(SyncProgress)? onProgress}) async {
    final cfg = store.sync;
    if (!cfg.configured) return SyncResult.failure('还没有配置 WebDAV 服务器');

    final client = _client();
    try {
      onProgress?.call(const SyncProgress('连接服务器…', 0, 1));
      final snapshotUrl = '${client.root}/$snapshotName';
      final dirUrl = '${client.root}/';
      await client.ensureDir(dirUrl);

      // ---------------------------------------------------------- 1. 下载 + 合并
      onProgress?.call(const SyncProgress('下载远端数据…', 0, 1));
      var attempt = 0;
      while (true) {
        attempt++;
        final remote = await client.get(snapshotUrl);
        final remoteBills = _parseSnapshot(remote.bytes);

        final localBefore = <String, Bill>{
          for (final b in store.allIncludingDeleted) b.id: b,
        };
        final merged = <String, Bill>{};

        final ids = <String>{...localBefore.keys, ...remoteBills.keys};
        for (final id in ids) {
          final l = localBefore[id];
          final r = remoteBills[id];
          if (l == null) {
            merged[id] = r!;
            continue;
          }
          if (r == null) {
            merged[id] = l;
            continue;
          }
          final winner = mergeBill(l, r);
          // path / folder 是本机定位，属于「设备私有」字段：
          // 远端记录里的路径在这台设备上没有意义，一律保留本机值。
          merged[id] = winner.copyWith(path: l.path, folder: l.folder);
        }

        // 本机被远端改动的条数（界面上的「拉取」）
        final pulled = merged.values.where((b) {
          final before = localBefore[b.id];
          return before == null || !_sameContent(before, b);
        }).length;

        // 远端需要被本机改写的条数（界面上的「上传」）
        final toPush = merged.values.where((b) {
          final r = remoteBills[b.id];
          return r == null || !_sameContent(b, r);
        }).length;

        // 双方都改过、靠 updatedAt 裁决的条数（诊断用）
        final conflicts = merged.values.where((b) {
          final l = localBefore[b.id];
          final r = remoteBills[b.id];
          return l != null &&
              r != null &&
              l.updatedAt != r.updatedAt &&
              !_sameContent(l, r) &&
              _sameContent(b, l);
        }).length;

        final changedLocal = merged.values.where((b) {
          final before = localBefore[b.id];
          return before == null || !_sameContent(before, b);
        }).toList();

        store.putAll(changedLocal);
        await store.save();

        // ---------------------------------------------------------- 2. 上传合并结果
        onProgress?.call(SyncProgress('上传合并结果…', 0, 1));
        final payload = _encodeSnapshot(merged.values.toList());
        // 只在「合并结果和远端内容不一致」时才写回：
        //  * 不能用「字节是否相同」判断 —— 快照里带 savedAt 时间戳，字节永远不同；
        //  * 也不能只看「本机是否变化」—— 本机已是最终版本时（例如刚被远端合并过）
        //    同样需要把结果推上去，否则这台设备的修改永远传不出去。
        final needWrite = remote.bytes == null || toPush > 0;

        var pushed = 0;
        if (needWrite) {
          try {
            await client.put(
              snapshotUrl,
              payload,
              ifMatch: remote.etag,
              createOnly: remote.bytes == null,
            );
            pushed = toPush;
          } on PreconditionFailedException {
            // 别人刚写过：重新下载 → 重新合并（最多 3 轮）
            if (attempt >= _maxAttempts) {
              return SyncResult.failure(
                  '同步冲突：其他设备一直在修改，请稍后重试');
            }
            continue;
          }
        }

        // ---------------------------------------------------------- 3. 缩略图
        final thumbStats = await _syncThumbs(
          client,
          merged.values.where((b) => !b.deleted).toList(),
          onProgress,
        );

        final now = DateTime.now().millisecondsSinceEpoch;
        final summary = _summary(pushed, pulled, thumbStats.$1, thumbStats.$2);
        store.recordSync(now, summary);
        await store.save();
        onProgress?.call(SyncProgress('完成', 1, 1, message: summary));
        return SyncResult(
          ok: true,
          message: summary,
          pushed: pushed,
          pulled: pulled,
          thumbsUp: thumbStats.$1,
          thumbsDown: thumbStats.$2,
          conflicts: conflicts,
        );
      }
    } on WebDavException catch (e) {
      store.recordSync(DateTime.now().millisecondsSinceEpoch, '同步失败：${e.message}');
      await store.save();
      return SyncResult.failure(e.message);
    } catch (e) {
      final msg = '同步失败：$e';
      store.recordSync(DateTime.now().millisecondsSinceEpoch, msg);
      await store.save();
      return SyncResult.failure(msg);
    } finally {
      client.close();
    }
  }

  /// 只测试连接：列一次目录并读一次快照头，不修改任何数据。
  Future<String> testConnection() async {
    final client = _client();
    try {
      final entries = await client.list('${client.root}/');
      final hasSnapshot =
          entries.any((e) => !e.isDirectory && e.name == snapshotName);
      final count = entries.where((e) => !e.isDirectory).length;
      return hasSnapshot
          ? '连接成功：已找到远端快照，共 $count 个文件'
          : '连接成功：远端目录为空，首次同步会上传本机数据';
    } on WebDavException catch (e) {
      return '连接失败：${e.message}';
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------- 缩略图

  /// 返回（上传数, 下载数）。
  Future<(int, int)> _syncThumbs(
    WebDavClient client,
    List<Bill> bills,
    void Function(SyncProgress)? onProgress,
  ) async {
    final withThumb = bills.where((b) => b.thumb.isNotEmpty).toList();
    if (withThumb.isEmpty) return (0, 0);

    final base = '${client.root}/$thumbsDirName';
    await client.ensureDir(base);
    final remote = <String, DavEntry>{};
    try {
      for (final e in await client.list('$base/')) {
        if (!e.isDirectory) remote[e.name] = e;
      }
    } on WebDavException {
      // 列目录失败就当远端全空，逐个补传即可
    }

    var up = 0;
    var down = 0;
    for (var i = 0; i < withThumb.length; i++) {
      final b = withThumb[i];
      onProgress?.call(SyncProgress('同步缩略图…', i + 1, withThumb.length));
      final local = await store.readThumb(b.thumb);
      final remoteEntry = remote[b.thumb];
      if (local == null) {
        if (remoteEntry == null) continue;
        // 本机没有（例如刚从另一台设备同步来的记录）：下载下来才能显示
        try {
          final got = await client.get(remoteEntry.url);
          final bytes = got.bytes;
          if (bytes != null && bytes.isNotEmpty) {
            await store.writeThumb(b.thumb, bytes);
            down++;
          }
        } on WebDavException {
          // 单张失败不影响整体
        }
      } else {
        // 远端没有 → 补传；远端有但字节数不同 → 覆盖（缩略图文件名固定是
        // `<id>.jpg`，「重新识别全部」换了内容后只有靠长度才能发现不一致）。
        // 服务端没给 content-length（size < 0）时无法判断，宁可不动，避免每轮都写。
        final missing = remoteEntry == null;
        final changed =
            remoteEntry != null && remoteEntry.size >= 0 && remoteEntry.size != local.length;
        if (!missing && !changed) continue;
        try {
          await client.put(
            '$base/${WebDavClient.encodeSegment(b.thumb)}',
            local,
            contentType: 'image/jpeg',
          );
          up++;
        } on WebDavException {
          // 忽略单张失败
        }
      }
    }
    return (up, down);
  }

  // ---------------------------------------------------------------- 快照编解码

  List<int> _encodeSnapshot(List<Bill> bills) {
    // 只保留「记录本身」需要的字段：path 是本机定位，跨设备无意义，
    // 但保留可以让另一台设备在相同路径下（例如 Windows 同步盘）直接复用。
    final json = {
      'v': 2,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'device': deviceName,
      'bills': bills.map((b) => b.toJson()).toList(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  Map<String, Bill> _parseSnapshot(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return {};
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return {};
      final list = decoded['bills'];
      if (list is! List) return {};
      final out = <String, Bill>{};
      for (final item in list) {
        if (item is! Map) continue;
        final bill = Bill.fromJson(Map<String, Object?>.from(item));
        if (bill.id.isNotEmpty) out[bill.id] = bill;
      }
      return out;
    } catch (_) {
      // 远端文件损坏：不覆盖它，本次按「远端为空」合并会把它写坏，
      // 所以这里抛出去让上层中止更安全。
      throw WebDavException('远端 bills.json 解析失败（文件可能已损坏）');
    }
  }

  /// 记录内容是否一致（忽略本机 path/folder 这类设备专属字段）。
  static bool _sameContent(Bill a, Bill b) =>
      a.name == b.name &&
      a.amountCents == b.amountCents &&
      a.confidence == b.confidence &&
      a.manual == b.manual &&
      a.note == b.note &&
      a.deleted == b.deleted &&
      a.thumb == b.thumb &&
      a.updatedAt == b.updatedAt;

  static String _summary(int pushed, int pulled, int up, int down) {
    final parts = <String>[];
    if (pushed > 0) parts.add('上传 $pushed 条');
    if (pulled > 0) parts.add('拉取 $pulled 条');
    if (up > 0) parts.add('上传缩略图 $up 张');
    if (down > 0) parts.add('下载缩略图 $down 张');
    return parts.isEmpty ? '已是最新，无需同步' : '同步完成：${parts.join('，')}';
  }
}

/// 给同步用的设备名（仅用于诊断，不影响合并逻辑）。
Future<String> detectDeviceName() async {
  if (Platform.isAndroid) return 'Android';
  if (Platform.isWindows) return 'Windows';
  return Platform.operatingSystem;
}
