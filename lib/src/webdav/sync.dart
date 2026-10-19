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
      // 刻意不在这里 MKCOL：坚果云这类网盘上「允许写文件、但拒绝建目录」是真实存在的
      // 组合。直接写快照，只有父目录确实不存在（404/409）时才去建目录再重试。

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
            try {
              try {
                await client.put(
                  snapshotUrl,
                  payload,
                  ifMatch: remote.etag,
                  createOnly: remote.bytes == null,
                );
              } on PreconditionFailedException {
                rethrow;
              } on WebDavException catch (e) {
                if (e.status != 404 && e.status != 409) rethrow;
                // 父目录不存在：建一次再重试（建不出来就是下面的提示）
                await client.ensureDir(dirUrl);
                await client.put(
                  snapshotUrl,
                  payload,
                  ifMatch: remote.etag,
                  createOnly: remote.bytes == null,
                );
              }
            } on WebDavException catch (e) {
              if (e is PreconditionFailedException) rethrow;
              // 写不进去这类问题，把具体怎么改直接写进结果
              throw WebDavException(_uploadHint(e, client.root), e, e.status);
            }
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
        final summary = _summary(pushed, pulled, thumbStats.$1, thumbStats.$2,
            thumbsDirFlat: thumbsAreFlat);
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

  /// 测试连接 = **验证路径真的可用**：能读目录，不存在就建出来再读一次。
  ///
  /// 只做一次 PROPFIND 的话，坚果云上填了一个还没创建的目录会直接报 404，
  /// 用户会以为地址错了。这里把「不存在」当成待创建，创建后再确认可读，
  /// 并把最终绝对路径回显出来——路径到底通不通，一眼能看到。
  Future<String> testConnection() async {
    final client = _client();
    final dirUrl = '${client.root}/';
    try {
      List<DavEntry>? entries;
      try {
        entries = await client.list(dirUrl);
      } on WebDavException catch (e) {
        if (e.status != 404) rethrow;
        await client.ensureDir(dirUrl);
        entries = await client.list(dirUrl);
      }
      // 2) 写权限：写一个探针文件再删掉。
      //    坚果云的 WebDAV 根目录能读不能写；不测这一步的话，用户会先看到
      //    「路径可用」，然后同步时才炸在 404 上。
      final probeUrl = '${client.root}/.wxbills-write-test';
      try {
        await client.put(probeUrl, utf8.encode('ok'), contentType: 'text/plain');
      } on WebDavException catch (e) {
        return _friendlyError(e, client.root, writing: true);
      }
      try {
        await client.delete(probeUrl);
      } on WebDavException {
        // 探针删不掉不影响结论：下次同步会用同名文件覆盖它
      }

      final files = entries.where((e) => !e.isDirectory).toList();
      final hasSnapshot = files.any((e) => e.name == snapshotName);
      final where = '路径：${client.root}/';
      return hasSnapshot
          ? '连接成功，路径可读可写。$where（已有远端快照，共 ${files.length} 个文件）'
          : '连接成功，路径可读可写。$where（远端为空，首次同步会上传本机数据）';
    } on WebDavException catch (e) {
      return _friendlyError(e, client.root);
    } finally {
      client.close();
    }
  }

  /// 上传 404 时给出能照做的建议。
  ///
  /// 坚果云的 WebDAV 根目录（`https://dav.jianguoyun.com/dav/`）**只读**：
  /// PROPFIND 正常、PUT 却回 404 ObjectNotFound。文件必须写在子目录里。
  static String _uploadHint(WebDavException e, String root) {
    final base = root.replaceAll(RegExp(r'/+$'), '');
    if (e.status == 404 || e.status == 409) {
      return '上传失败：服务端说这个位置不存在（HTTP ${e.status} ObjectNotFound），'
          '而且自动建目录也没成功。这通常是网盘对 WebDAV 的**写入**有限制：\n'
          '① 先在坚果云 App / 网页里手动新建一个文件夹（例如 wxbills）；\n'
          '② 把服务器地址填成 $base/wxbills ；\n'
          '③ 再点「测试连接」——它会真的写一个探针文件来验证能不能写。';
    }
    if (e.status == 403) {
      return '上传失败：这个账号在 $base 上没有写入权限（HTTP 403）。'
          '坚果云请确认用的是「应用密码」，且没有开启只读限制。';
    }
    if (e.status == 507 || e.status == 429) {
      return '上传失败：网盘空间不足或触发了限流（HTTP ${e.status}）。';
    }
    return e.message;
  }

  /// 把状态码翻译成用户能照着做的提示（坚果云是最常见的配置场景）。
  static String _friendlyError(WebDavException e, String root,
      {bool writing = false}) {
    if (writing) return _uploadHint(e, root);
    switch (e.status) {
      case 401:
        return '连接失败：账号或密码不对。坚果云要在「账户信息 → 安全选项 → 添加应用密码」'
            '生成一个专用密码，填到「密码」里——直接用登录密码会一直 401。';
      case 403:
        return '连接失败：这个账号没有写入 $root 的权限（HTTP 403）。';
      case 404:
        return '连接失败：路径不存在且创建失败（HTTP 404）：$root';
      case 409:
        return '连接失败：上级目录不存在（HTTP 409）。检查地址里的层级，'
            '坚果云的 WebDAV 根是 https://dav.jianguoyun.com/dav/';
      case 507:
        return '连接失败：网盘空间不足（HTTP 507）。';
      default:
        return '连接失败：${e.message}';
    }
  }

  // ---------------------------------------------------------------- 缩略图

  /// 返回（上传数, 下载数）。
  /// 这个网盘不允许建子目录（坚果云就是这样）：缩略图退化到与快照同目录，
  /// 文件名加 `thumb_` 前缀。每轮同步重新判断一次，不落盘。
  bool thumbsAreFlat = false;

  /// 退化模式下的文件名前缀。
  static const String _flatPrefix = 'thumb_';

  Future<(int, int)> _syncThumbs(
    WebDavClient client,
    List<Bill> bills,
    void Function(SyncProgress)? onProgress,
  ) async {
    final withThumb = bills.where((b) => b.thumb.isNotEmpty).toList();
    if (withThumb.isEmpty) return (0, 0);

    final base = '${client.root}/$thumbsDirName';
    final remote = <String, DavEntry>{};
    var flat = false;
    try {
      for (final e in await client.list('$base/')) {
        if (!e.isDirectory) remote[e.name] = e;
      }
    } on WebDavException catch (e) {
      if (e.status == 404) {
        // 目录还不存在：建一次。建不出来就退化——有些网盘（坚果云）
        // 允许直接写文件，但 MKCOL 被拒；此时把缩略图放到快照同目录，
        // 文件名加 thumb_ 前缀，功能不受影响。
        var created = true;
        try {
          await client.ensureDir(base);
        } on WebDavException {
          created = false;
        }
        if (!created) {
          flat = true;
          thumbsAreFlat = true;
          try {
            for (final e in await client.list('${client.root}/')) {
              if (e.isDirectory) continue;
              if (e.name.startsWith(_flatPrefix)) {
                remote[e.name.substring(_flatPrefix.length)] = e;
              }
            }
          } on WebDavException {
            // 列不出根目录就当远端全空，逐张补传即可
          }
        }
      }
      // 其他错误：当远端全空，逐个补传
    }

    var up = 0;
    var down = 0;
    for (var i = 0; i < withThumb.length; i++) {
      final b = withThumb[i];
      onProgress?.call(SyncProgress('同步缩略图…', i + 1, withThumb.length));
      final remoteEntry = remote[b.thumb];
      // 先只取本地文件长度：内容没变时不必把几百张缩略图读进内存
      final localLength = await store.thumbLength(b.thumb);
      if (localLength == null) {
        if (remoteEntry == null) continue;
        // 本机没有（例如刚从另一台设备同步来的记录）：下载下来才能显示。
        // 本地已经有了就不会再下载——重复同步不该重复拉同一张图。
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
        final changed = remoteEntry != null &&
            remoteEntry.size >= 0 &&
            remoteEntry.size != localLength;
        if (!missing && !changed) continue;
        final local = await store.readThumb(b.thumb);
        if (local == null) continue;
        final target = flat
            ? '${client.root}/$_flatPrefix${WebDavClient.encodeSegment(b.thumb)}'
            : '$base/${WebDavClient.encodeSegment(b.thumb)}';
        try {
          await client.put(target, local, contentType: 'image/jpeg');
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

  static String _summary(int pushed, int pulled, int up, int down,
      {bool thumbsDirFlat = false}) {
    final parts = <String>[];
    if (pushed > 0) parts.add('上传 $pushed 条');
    if (pulled > 0) parts.add('拉取 $pulled 条');
    if (up > 0) parts.add('上传缩略图 $up 张');
    if (down > 0) parts.add('下载缩略图 $down 张');
    if (thumbsDirFlat) parts.add('缩略图与记录同目录（该网盘不能建子目录）');
    return parts.isEmpty ? '已是最新，无需同步' : '同步完成：${parts.join('，')}';
  }
}

/// 给同步用的设备名（仅用于诊断，不影响合并逻辑）。
Future<String> detectDeviceName() async {
  if (Platform.isAndroid) return 'Android';
  if (Platform.isWindows) return 'Windows';
  return Platform.operatingSystem;
}
