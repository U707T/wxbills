import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/bill.dart';
import 'app_dirs.dart';
import 'json_io.dart';

/// 一个图片来源目录。
///
/// [path] 是本机定位：Android 是 SAF 树 URI（`content://…`），桌面是绝对路径。
class SourceFolder {
  const SourceFolder({
    required this.id,
    required this.path,
    required this.name,
    required this.addedAt,
    this.lastScanAt = 0,
  });

  final String id;
  final String path;
  final String name;
  final int addedAt;
  final int lastScanAt;

  bool get isSaf => path.startsWith('content://');
  bool get isDesktopPath => !isSaf;

  Map<String, Object?> toJson() => {
        'id': id,
        'p': path,
        'n': name,
        'a': addedAt,
        's': lastScanAt,
      };

  static SourceFolder fromJson(Map<String, Object?> j) => SourceFolder(
        id: '${j['id'] ?? ''}',
        path: '${j['p'] ?? ''}',
        name: '${j['n'] ?? ''}',
        addedAt: (j['a'] as num?)?.toInt() ?? 0,
        lastScanAt: (j['s'] as num?)?.toInt() ?? 0,
      );

  SourceFolder copyWith({String? name, int? lastScanAt}) => SourceFolder(
        id: id,
        path: path,
        name: name ?? this.name,
        addedAt: addedAt,
        lastScanAt: lastScanAt ?? this.lastScanAt,
      );
}

/// WebDAV 同步配置。
class SyncConfig {
  const SyncConfig({
    this.url = '',
    this.username = '',
    this.password = '',
    this.allowInsecureTls = false,
    this.autoSync = true,
    this.lastSyncAt = 0,
    this.lastSyncMessage = '',
  });

  final String url;
  final String username;
  final String password;
  final bool allowInsecureTls;

  /// 启动 / 修改数据后自动同步。
  final bool autoSync;
  final int lastSyncAt;
  final String lastSyncMessage;

  bool get configured => url.trim().isNotEmpty;

  SyncConfig copyWith({
    String? url,
    String? username,
    String? password,
    bool? allowInsecureTls,
    bool? autoSync,
    int? lastSyncAt,
    String? lastSyncMessage,
  }) =>
      SyncConfig(
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
        allowInsecureTls: allowInsecureTls ?? this.allowInsecureTls,
        autoSync: autoSync ?? this.autoSync,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        lastSyncMessage: lastSyncMessage ?? this.lastSyncMessage,
      );
}

/// 全部本地数据：收款单 + 目录 + 同步配置。
///
/// 所有方法都在内存里操作，调用 [save] 才落盘（原子写），
/// 上层负责放到后台 isolate / 事件循环里跑重活。
class BillStore {
  BillStore(this.dirs);

  final AppDirs dirs;

  final Map<String, Bill> _bills = {};
  final List<SourceFolder> _folders = [];
  SyncConfig _sync = const SyncConfig();

  bool _loaded = false;
  bool _dirty = false;

  bool get loaded => _loaded;
  bool get dirty => _dirty;

  SyncConfig get sync => _sync;

  /// 所有未删除的收款单，按导入时间倒序（稳定的默认顺序）。
  List<Bill> get bills {
    final list = _bills.values.where((b) => !b.deleted).toList();
    list.sort((a, b) {
      final t = b.fileModified.compareTo(a.fileModified);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
    return list;
  }

  /// 含墓碑的全部记录（同步用）。
  List<Bill> get allIncludingDeleted => _bills.values.toList();

  List<SourceFolder> get folders => List.unmodifiable(_folders);

  Bill? byId(String id) => _bills[id];

  int get count => _bills.values.where((b) => !b.deleted).length;

  int get sumCents => _bills.values
      .where((b) => !b.deleted)
      .fold(0, (s, b) => s + (b.amountCents ?? 0));

  /// 需要人工核对的条数。
  int get reviewCount => _bills.values.where((b) => !b.deleted && b.needsReview).length;

  // ---------------------------------------------------------------- 载入 / 保存

  Future<void> load() async {
    await dirs.ensure();
    final json = await readJsonFile(dirs.dataFile);
    if (json != null) {
      final bills = json['bills'];
      if (bills is List) {
        for (final item in bills) {
          if (item is Map) {
            final bill = Bill.fromJson(Map<String, Object?>.from(item));
            if (bill.id.isNotEmpty) _bills[bill.id] = bill;
          }
        }
      }
      final folders = json['folders'];
      if (folders is List) {
        for (final item in folders) {
          if (item is Map) {
            _folders.add(SourceFolder.fromJson(Map<String, Object?>.from(item)));
          }
        }
      }
      final sync = json['sync'];
      if (sync is Map) {
        _sync = SyncConfig(
          url: '${sync['url'] ?? ''}',
          username: '${sync['user'] ?? ''}',
          password: '${sync['pass'] ?? ''}',
          allowInsecureTls: sync['insecure'] == true,
          autoSync: sync['auto'] != false,
          lastSyncAt: (sync['at'] as num?)?.toInt() ?? 0,
          lastSyncMessage: '${sync['msg'] ?? ''}',
        );
      }
    }
    _loaded = true;
    _dirty = false;
  }

  Future<void> save() async {
    final payload = {
      'v': 2,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'bills': _bills.values.map((b) => b.toJson()).toList(),
      'folders': _folders.map((f) => f.toJson()).toList(),
      'sync': {
        'url': _sync.url,
        'user': _sync.username,
        'pass': _sync.password,
        'insecure': _sync.allowInsecureTls,
        'auto': _sync.autoSync,
        'at': _sync.lastSyncAt,
        'msg': _sync.lastSyncMessage,
      },
    };
    await writeJsonAtomic(dirs.dataFile, payload);
    _dirty = false;
  }

  void markDirty() => _dirty = true;

  // ---------------------------------------------------------------- 目录

  bool addFolder(String path, String name) {
    if (_folders.any((f) => f.path == path)) return false;
    _folders.add(SourceFolder(
      id: newId(),
      path: path,
      name: name,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    _dirty = true;
    return true;
  }

  void removeFolder(String id) {
    _folders.removeWhere((f) => f.id == id);
    _dirty = true;
  }

  void touchFolder(String id, int at) {
    final i = _folders.indexWhere((f) => f.id == id);
    if (i < 0) return;
    _folders[i] = _folders[i].copyWith(lastScanAt: at);
    _dirty = true;
  }

  /// 按本机路径找所属目录（用于「刷新日期」定位 SAF 树 / 判断文件是否真的消失）。
  ///
  /// **匹配不到必须返回 null，绝不能退回「第一个目录」**：
  /// 从别的设备同步过来的记录带着那台设备的路径，本机根本没有这个文件。
  /// 如果这里随便返回一个目录，扫描时的「清理已删除文件」会把这些记录
  /// 当成已被删除而打上墓碑 —— 等于一台设备的扫描抹掉另一台的数据。
  SourceFolder? folderOf(Bill bill) {
    if (bill.folder.isNotEmpty) {
      for (final f in _folders) {
        if (f.id == bill.folder) return f;
      }
    }
    for (final f in _folders) {
      if (bill.path.startsWith(f.path)) return f;
    }
    return null;
  }

  // ---------------------------------------------------------------- 收款单

  /// 插入或更新（同 id 覆盖）。
  void put(Bill bill) {
    _bills[bill.id] = bill;
    _dirty = true;
  }

  void putAll(Iterable<Bill> bills) {
    for (final b in bills) {
      _bills[b.id] = b;
    }
    _dirty = true;
  }

  /// 手工改金额（打上 manual，之后重新扫描不再覆盖）。
  void setAmount(String id, int? cents, {String? note}) {
    final b = _bills[id];
    if (b == null) return;
    _bills[id] = b.copyWith(
      amountCents: cents,
      confidence: 1,
      manual: true,
      note: note,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _dirty = true;
  }

  void setNote(String id, String note) {
    final b = _bills[id];
    if (b == null) return;
    _bills[id] = b.copyWith(
      note: note,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _dirty = true;
  }

  /// 软删除（写墓碑，让删除也能同步到别的设备）。
  void remove(String id) {
    final b = _bills[id];
    if (b == null) return;
    _bills[id] = b.copyWith(
      deleted: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _dirty = true;
  }

  /// 彻底清掉过期墓碑（默认 120 天），避免同步文件无限增长。
  int purgeTombstones({int olderThanMs = 120 * 24 * 3600 * 1000}) {
    final cutoff = DateTime.now().millisecondsSinceEpoch - olderThanMs;
    final gone = _bills.entries
        .where((e) => e.value.deleted && e.value.updatedAt < cutoff)
        .map((e) => e.key)
        .toList();
    for (final id in gone) {
      _bills.remove(id);
    }
    if (gone.isNotEmpty) _dirty = true;
    return gone.length;
  }

  // ---------------------------------------------------------------- 同步配置

  void setSync(SyncConfig config) {
    _sync = config;
    _dirty = true;
  }

  /// 把同步结果写回配置（不标记 dirty 之外的东西）。
  void recordSync(int at, String message) {
    _sync = _sync.copyWith(lastSyncAt: at, lastSyncMessage: message);
    _dirty = true;
  }

  // ---------------------------------------------------------------- 缩略图

  File thumbFile(String name) => dirs.thumbFile(name);

  /// 读取缩略图字节（用于同步上传）。不存在返回 null。
  Future<List<int>?> readThumb(String name) async {
    if (name.isEmpty) return null;
    final f = dirs.thumbFile(name);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  Future<void> writeThumb(String name, List<int> bytes) async {
    await dirs.thumbDir.create(recursive: true);
    final f = dirs.thumbFile(name);
    final tmp = File(p.join(dirs.thumbDir.path, '$name.tmp'));
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  /// 清掉没有对应记录（或记录已删）的缩略图。
  Future<int> pruneThumbs() async {
    if (!await dirs.thumbDir.exists()) return 0;
    var removed = 0;
    await for (final e in dirs.thumbDir.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      final dot = name.lastIndexOf('.');
      final id = dot > 0 ? name.substring(0, dot) : name;
      final bill = _bills[id];
      if (bill == null || bill.deleted) {
        try {
          await e.delete();
          removed++;
        } catch (_) {}
      }
    }
    return removed;
  }
}
