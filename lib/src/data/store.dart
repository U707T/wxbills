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

  SourceFolder copyWith({int? lastScanAt}) => SourceFolder(
        id: id,
        path: path,
        name: name,
        addedAt: addedAt,
        lastScanAt: lastScanAt ?? this.lastScanAt,
      );
}

/// 默认的 WebDAV 地址（坚果云）。
///
/// 选它当默认值是因为国内最省事：注册即用、支持「应用密码」、支持标准 WebDAV，
/// 不需要自建 NAS。地址末尾的 `wxbills` 是应用自己的目录，首次同步会自动创建。
const String kDefaultDavUrl = 'https://dav.jianguoyun.com/dav/wxbills';

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

/// 界面偏好：只跟「怎么显示」有关，不参与同步。
///
/// 目前只有两件事：
///  * [seenTips]：哪些「一次性的说明弹窗」已经看过了。这些说明第一次看有用，
///    第二次就是噪音（例如「刷新日期会把入库时间改成现在」那段长文）。
///  * [autoScanOnBoot]：冷启动是否自动扫一遍相册。默认 **false** —— 相册动辄
///    几百上千张，每次打开都比对一遍既费电又卡首屏，结果通常和上次一样；
///    需要刷新时点一下「扫描识别」就行。
class UiPrefs {
  const UiPrefs({
    this.seenTips = const <String>{},
    this.autoScanOnBoot = false,
  });

  final Set<String> seenTips;
  final bool autoScanOnBoot;

  bool hasSeen(String key) => key.isNotEmpty && seenTips.contains(key);

  UiPrefs markSeen(String key) {
    if (key.isEmpty || seenTips.contains(key)) return this;
    return UiPrefs(
      seenTips: {...seenTips, key},
      autoScanOnBoot: autoScanOnBoot,
    );
  }

  UiPrefs copyWith({bool? autoScanOnBoot}) => UiPrefs(
        seenTips: seenTips,
        autoScanOnBoot: autoScanOnBoot ?? this.autoScanOnBoot,
      );

  /// 清空「已看过」记录：设置页的「重新显示所有说明」用。
  UiPrefs clearTips() =>
      UiPrefs(seenTips: const <String>{}, autoScanOnBoot: autoScanOnBoot);

  Map<String, Object?> toJson() => {
        'tips': seenTips.toList(),
        'autoScan': autoScanOnBoot,
      };

  static UiPrefs fromJson(Map<String, Object?> j) {
    final raw = j['tips'];
    final tips = <String>{
      if (raw is List)
        for (final t in raw)
          if (t is String && t.isNotEmpty) t,
    };
    return UiPrefs(seenTips: tips, autoScanOnBoot: j['autoScan'] == true);
  }
}

/// 全部本地数据：收款单 + 目录 + 同步配置 + 界面偏好。
///
/// 所有方法都在内存里操作，调用 [save] 才落盘（原子写；并发调用会排队串行执行）。
/// 注意：解码与模板匹配目前**仍在主 isolate 上跑**（扫几百张会明显掉帧），
/// 后续应把「解码 → OCR」整段搬进 `Isolate.run`；这里不再是"上层已负责"的状态。
class BillStore {
  BillStore(this.dirs);

  final AppDirs dirs;

  final Map<String, Bill> _bills = {};
  final List<SourceFolder> _folders = [];
  SyncConfig _sync = const SyncConfig();
  UiPrefs _prefs = const UiPrefs();

  bool _loaded = false;

  /// 数据文件损坏时的说明（启动后由界面提示用户「现场已备份到 …」）。
  String _loadWarning = '';

  bool get loaded => _loaded;
  String get loadWarning => _loadWarning;

  /// 数据版本号：任何会改变「列表应该显示什么」的操作都会 +1。
  /// 界面用它判断缓存是否还有效，省掉「每个改动点手动清缓存」这种必漏的写法。
  int _revision = 0;
  int get revision => _revision;

  SyncConfig get sync => _sync;

  /// 界面偏好（一次性提示的已读记录、启动是否自动扫描）。
  UiPrefs get prefs => _prefs;

  void setPrefs(UiPrefs prefs) {
    _prefs = prefs;
  }

  /// 所有未删除的收款单，按导入时间倒序（稳定的默认顺序）。
  List<Bill> get bills {
    final list = liveBills;
    list.sort((a, b) {
      final t = b.fileModified.compareTo(a.fileModified);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
    return list;
  }

  /// 未删除的记录，**不排序**：上层要自己排时用它，避免同一份数据排两遍。
  List<Bill> get liveBills => _bills.values.where((b) => !b.deleted).toList();

  /// 含墓碑的全部记录（同步用）。
  List<Bill> get allIncludingDeleted => _bills.values.toList();

  List<SourceFolder> get folders => List.unmodifiable(_folders);

  Bill? byId(String id) => _bills[id];

  int get count => _bills.values.where((b) => !b.deleted).length;

  int get sumCents => _bills.values
      .where((b) => !b.deleted)
      .fold(0, (s, b) => s + (b.amountCents ?? 0));

  /// 还没识别出金额的条数（界面用来提示「要不要重新识别」）。
  int get unrecognizedCount =>
      _bills.values.where((b) => !b.deleted && b.amountCents == null).length;

  /// 需要人工核对的条数。
  int get reviewCount => _bills.values.where((b) => !b.deleted && b.needsReview).length;

  // ---------------------------------------------------------------- 载入 / 保存

  Future<void> load() async {
    await dirs.ensure();
    // 先清空再读：load() 可能被调用多次（init 里总会读一次，测试里还会预读一次）。
    // 以前只是往 _folders 里 add，重复读盘会让同一个目录出现两次 ——
    // 表现是每次扫描把同一个相册列两遍（时间翻倍），而且「移除文件夹」删不干净。
    _bills.clear();
    _folders.clear();
    _sync = const SyncConfig();
    _prefs = const UiPrefs();
    _loadWarning = '';
    final json = await readJsonFile(
      dirs.dataFile,
      onCorrupt: (path) => _loadWarning = '数据文件损坏，已备份到 $path（本次以空账本启动）',
    );
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
      final prefs = json['prefs'];
      if (prefs is Map) {
        _prefs = UiPrefs.fromJson(Map<String, Object?>.from(prefs));
      }
    }
    _loaded = true;
    _revision++;
  }

  /// 落盘串行化：并发调用会排队，绝不出现两个写手同时动 `data.json.tmp`。
  ///
  /// 扫描（每 10 张一次）、同步、界面编辑都会调 `save()`，其中界面那几处是
  /// 不 await 就发出去的；两个 `writeAsString` 打同一个临时文件 = 写出半截 JSON，
  /// rename 之后就是账本损坏。这里用一个链把它们串起来。
  Future<void>? _saving;

  Future<void> save() {
    final next = (_saving ?? Future<void>.value()).then((_) => _writeSnapshot());
    // 链本身吞掉错误：一次失败不能让后续所有 save 都变成 rejected
    _saving = next.catchError((Object _) {});
    return next;
  }

  Future<void> _writeSnapshot() async {
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
      'prefs': _prefs.toJson(),
    };
    await writeJsonAtomic(dirs.dataFile, payload);
  }

  // ---------------------------------------------------------------- 目录

  bool addFolder(String path, String name) {
    if (_folders.any((f) => f.path == path)) return false;
    _folders.add(SourceFolder(
      id: newId(),
      path: path,
      name: name,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    _revision++;
    return true;
  }

  void removeFolder(String id) {
    _folders.removeWhere((f) => f.id == id);
    _revision++;
  }

  void touchFolder(String id, int at) {
    final i = _folders.indexWhere((f) => f.id == id);
    if (i < 0) return;
    _folders[i] = _folders[i].copyWith(lastScanAt: at);
    _revision++;
  }

  /// 按本机路径找所属目录（用于「刷新日期」定位 SAF 树 / 判断文件是否真的消失）。
  ///
  /// **匹配不到必须返回 null，绝不能退回「第一个目录」**：
  /// 从别的设备同步过来的记录带着那台设备的路径，本机根本没有这个文件。
  /// 如果这里随便返回一个目录，扫描时的「清理已删除文件」会把这些记录
  /// 当成已被删除而打上墓碑 —— 等于一台设备的扫描抹掉另一台的数据。
  ///
  /// 路径匹配必须带**段边界**：`/Pictures/Bills` 不能吃掉 `/Pictures/Bills-old/a.png`
  /// （SAF 的 tree URI 同理，`…%2FCamera` 与 `…%2FCamera2` 是两个目录）。
  SourceFolder? folderOf(Bill bill) {
    if (bill.folder.isNotEmpty) {
      for (final f in _folders) {
        if (f.id == bill.folder) return f;
      }
    }
    for (final f in _folders) {
      if (_isInside(f.path, bill.path)) return f;
    }
    return null;
  }

  /// [path] 是否位于目录 [base] 之内（按路径段比较，不是字符串前缀）。
  static bool _isInside(String base, String path) {
    if (base.isEmpty || path.isEmpty) return false;
    final b = base.replaceAll('\\', '/');
    final p = path.replaceAll('\\', '/');
    final prefix = b.endsWith('/') ? b : '$b/';
    return p.startsWith(prefix);
  }

  // ---------------------------------------------------------------- 收款单

  /// 插入或更新（同 id 覆盖）。
  void put(Bill bill) {
    _bills[bill.id] = bill;
    _revision++;
  }

  void putAll(Iterable<Bill> bills) {
    for (final b in bills) {
      _bills[b.id] = b;
    }
    _revision++;
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
    _revision++;
  }

  void setNote(String id, String note) {
    final b = _bills[id];
    if (b == null) return;
    _bills[id] = b.copyWith(
      note: note,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _revision++;
  }

  /// 软删除（写墓碑，让删除也能同步到别的设备）。
  void remove(String id) {
    final b = _bills[id];
    if (b == null) return;
    _bills[id] = b.copyWith(
      deleted: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _revision++;
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
    if (gone.isNotEmpty) _revision++;
    return gone.length;
  }

  // ---------------------------------------------------------------- 同步配置

  void setSync(SyncConfig config) {
    _sync = config;
  }

  /// 把同步结果写回配置。
  void recordSync(int at, String message) {
    _sync = _sync.copyWith(lastSyncAt: at, lastSyncMessage: message);
  }

  // ---------------------------------------------------------------- 缩略图

  /// 读取缩略图字节（用于同步上传）。不存在返回 null。
  Future<List<int>?> readThumb(String name) async {
    if (name.isEmpty) return null;
    final f = dirs.thumbFile(name);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  /// 缩略图字节数；没有这个文件返回 null。
  ///
  /// 同步时先用它判断要不要读整份字节——否则每次同步都要把几百张缩略图读进内存，
  /// 只为了比较大小。
  Future<int?> thumbLength(String name) async {
    if (name.isEmpty) return null;
    try {
      return await dirs.thumbFile(name).length();
    } catch (_) {
      return null;
    }
  }

  Future<void> writeThumb(String name, List<int> bytes) async {
    await dirs.thumbDir.create(recursive: true);
    final f = dirs.thumbFile(name);
    final tmp = File(p.join(dirs.thumbDir.path, '$name.tmp'));
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
    // 同步下载回来的缩略图也要让「文件是否存在」的缓存失效，
    // 否则列表会一直显示占位图，直到下次数据变更才突然出现图片。
    _revision++;
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
    if (removed > 0) _revision++;
    return removed;
  }
}
