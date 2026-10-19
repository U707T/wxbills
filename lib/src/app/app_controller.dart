import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/app_dirs.dart';
import '../data/scanner.dart';
import '../data/store.dart';
import '../model/bill.dart';
import '../platform/photo_source.dart';
import '../webdav/sync.dart';

/// 排序方式。
enum SortMode {
  amountAsc('金额 ↑'),
  amountDesc('金额 ↓'),
  timeDesc('时间 ↓'),
  importedDesc('导入 ↓');

  const SortMode(this.label);
  final String label;
}

/// 应用状态：数据 + 扫描 + 同步 + 筛选排序。
///
/// 刻意只用一个 [ChangeNotifier]：界面规模不大，一个状态源比多层
/// Provider/Riverpod 更好读，也方便把「扫描中」「同步中」这类互斥状态集中管。
class AppController extends ChangeNotifier {
  AppController({
    required this.dirs,
    required this.store,
    required this.source,
  }) {
    scanner = Scanner(store: store, source: source, dirs: dirs);
    sync = SyncEngine(store);
  }

  final AppDirs dirs;
  final BillStore store;
  final PhotoSource source;
  late final Scanner scanner;
  late final SyncEngine sync;

  // ---- 筛选 / 排序
  SortMode _sort = SortMode.amountAsc;
  String _query = '';
  SortMode get sort => _sort;
  String get query => _query;

  // ---- 运行状态
  bool _busy = false;
  String _busyLabel = '';
  double _busyFraction = 0;
  bool _ready = false;

  bool get ready => _ready;
  bool get busy => _busy;
  String get busyLabel => _busyLabel;
  double get busyFraction => _busyFraction;

  String _toast = '';
  int _toastSeq = 0;
  String get toast => _toast;
  int get toastSeq => _toastSeq;

  /// 正在闪烁高亮的记录 id（「定位」跳转后闪一下）。
  String? _flashId;
  String? get flashId => _flashId;

  Timer? _autoSyncTimer;

  // ---------------------------------------------------------------- 初始化

  Future<void> init() async {
    await store.load();
    _ready = true;
    notifyListeners();

    // 首次进入：没有目录就提示导入；有目录就静默增量扫描
    if (store.folders.isEmpty) return;
    unawaited(scan(force: false, silent: true));
    if (store.sync.configured && store.sync.autoSync) {
      unawaited(runSync(silent: true));
    }
  }

  // ---------------------------------------------------------------- 列表

  List<Bill> get allBills => store.bills;

  /// 当前筛选 + 排序后的列表。
  List<Bill> get visibleBills {
    final q = _query.trim();
    var list = store.bills;

    if (q.isNotEmpty) {
      final cents = Bill.parseYuan(q);
      if (cents != null) {
        // 输入金额：包含该金额的排前面（按金额位置快速滑动）
        final digits = q.replaceAll('.', '').replaceAll(RegExp(r'^0+'), '');
        final key = digits.isEmpty ? '0' : digits;
        final hit = list
            .where((b) => b.amountCents != null && '${b.amountCents}'.contains(key))
            .toList();
        if (hit.isNotEmpty) list = hit;
      } else {
        final lower = q.toLowerCase();
        list = list.where((b) {
          return b.name.toLowerCase().contains(lower) ||
              b.note.toLowerCase().contains(lower) ||
              b.amountYuan.contains(q);
        }).toList();
      }
    }

    final sorted = [...list];
    switch (_sort) {
      case SortMode.amountAsc:
        sorted.sort((a, b) {
          final x = a.amountCents;
          final y = b.amountCents;
          if (x == null && y == null) return b.fileModified.compareTo(a.fileModified);
          if (x == null) return 1;
          if (y == null) return -1;
          final c = x.compareTo(y);
          return c != 0 ? c : b.fileModified.compareTo(a.fileModified);
        });
        break;
      case SortMode.amountDesc:
        sorted.sort((a, b) {
          final x = a.amountCents;
          final y = b.amountCents;
          if (x == null && y == null) return b.fileModified.compareTo(a.fileModified);
          if (x == null) return 1;
          if (y == null) return -1;
          final c = y.compareTo(x);
          return c != 0 ? c : b.fileModified.compareTo(a.fileModified);
        });
        break;
      case SortMode.timeDesc:
        sorted.sort((a, b) => b.fileModified.compareTo(a.fileModified));
        break;
      case SortMode.importedDesc:
        sorted.sort((a, b) => b.importedAt.compareTo(a.importedAt));
        break;
    }
    return sorted;
  }

  int get visibleSumCents =>
      visibleBills.fold(0, (s, b) => s + (b.amountCents ?? 0));

  int get totalCount => store.count;
  int get totalSumCents => store.sumCents;

  void setSort(SortMode mode) {
    if (_sort == mode) return;
    _sort = mode;
    notifyListeners();
  }

  void setQuery(String q) {
    if (_query == q) return;
    _query = q;
    notifyListeners();
  }

  /// 跳到第一个匹配项：返回目标 id（界面负责滚动 + 闪烁）。
  String? locateByAmount(String text) {
    final target = Bill.parseYuan(text);
    if (target == null) {
      showToast('金额格式不对');
      return null;
    }
    final list = visibleBills;
    if (list.isEmpty) {
      showToast('列表是空的');
      return null;
    }
    var hit = list.indexWhere((b) => b.amountCents == target);
    if (hit < 0) {
      var bestDiff = 1 << 62;
      var bestIdx = -1;
      for (var i = 0; i < list.length; i++) {
        final c = list[i].amountCents;
        if (c == null) continue;
        final d = (c - target).abs();
        if (d < bestDiff) {
          bestDiff = d;
          bestIdx = i;
        }
      }
      hit = bestIdx;
    }
    if (hit < 0) {
      showToast('没有找到金额');
      return null;
    }
    final id = list[hit].id;
    _flashId = id;
    notifyListeners();
    Timer(const Duration(milliseconds: 1600), () {
      if (_flashId == id) {
        _flashId = null;
        notifyListeners();
      }
    });
    return id;
  }

  // ---------------------------------------------------------------- 编辑

  void setAmount(String id, int? cents, {String? note}) {
    store.setAmount(id, cents, note: note);
    notifyListeners();
    _persist();
    _scheduleAutoSync();
  }

  void setNote(String id, String note) {
    store.setNote(id, note);
    notifyListeners();
    _persist();
    _scheduleAutoSync();
  }

  void removeBill(String id) {
    store.remove(id);
    notifyListeners();
    _persist();
    _scheduleAutoSync();
  }

  Future<void> _persist() async {
    try {
      await store.save();
    } catch (e) {
      showToast('保存失败：$e');
    }
  }

  // ---------------------------------------------------------------- 目录

  Future<void> addFolder() async {
    try {
      final picked = await source.pickFolder();
      if (picked == null) return;
      final added = store.addFolder(picked.path, picked.name);
      if (!added) {
        showToast('这个目录已经导入过了');
        return;
      }
      await store.save();
      notifyListeners();
      await scan(force: false);
    } catch (e) {
      showToast('导入失败：$e');
    }
  }

  Future<void> removeFolder(String id) async {
    store.removeFolder(id);
    await store.save();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 扫描

  Future<void> scan({bool force = false, bool silent = false}) async {
    if (_busy) return;
    if (store.folders.isEmpty) {
      if (!silent) showToast('先导入一个相册文件夹');
      return;
    }
    _setBusy(true, force ? '重新识别全部…' : '正在识别金额…', 0);
    try {
      final result = await scanner.scanAll(
        forceRecheck: force,
        onProgress: (p) {
          if (p.total > 0) {
            _setBusy(true, '识别 ${p.done}/${p.total} · ${p.currentName}',
                p.fraction);
          } else {
            _setBusy(true, p.message.isEmpty ? '准备中…' : p.message, 0);
          }
        },
      );
      _setBusy(false, '', 0);
      notifyListeners();
      if (!silent || result.updated > 0) showToast(result.message);
      if (result.updated > 0) _scheduleAutoSync();
    } catch (e) {
      _setBusy(false, '', 0);
      showToast('扫描失败：$e');
    }
  }

  Future<void> recheckOne(String id) async {
    final bill = store.byId(id);
    if (bill == null || bill.path.isEmpty) return;
    _setBusy(true, '重新识别…', 0);
    try {
      final r = await scanner.readOne(bill.path);
      _setBusy(false, '', 0);
      if (r.text == null) {
        showToast('这张没认出来，请手动填写金额');
        return;
      }
      final cents = r.value == null ? null : (r.value! * 100).round();
      store.setAmount(id, cents);
      notifyListeners();
      await _persist();
      showToast('识别到 ¥${Bill.formatCents(cents ?? 0)}'
          '（置信度 ${(r.confidence * 100).toStringAsFixed(0)}%）');
      _scheduleAutoSync();
    } catch (e) {
      _setBusy(false, '', 0);
      showToast('识别失败：$e');
    }
  }

  // ---------------------------------------------------------------- 刷新日期

  Future<void> refreshDates(List<Bill> list) async {
    if (!source.supportsRefreshDate) {
      showToast('当前平台不支持刷新图片日期（该功能仅 Android 有效）');
      return;
    }
    if (list.isEmpty) return;
    _setBusy(true, '正在刷新日期…', 0);
    var ok = 0;
    var fail = 0;
    String? firstError;
    for (var i = 0; i < list.length; i++) {
      final b = list[i];
      if (b.path.isEmpty) {
        fail++;
        continue;
      }
      final folder = store.folderOf(b);
      final r = await source.refreshDate(b.path, folder?.path);
      if (r.ok) {
        ok++;
        // 走「重建新文件」路线时路径会变，必须回写，否则记录失效
        if (r.newPath.isNotEmpty && r.newPath != b.path) {
          store.put(b.copyWith(
            path: r.newPath,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ));
        }
      } else {
        fail++;
        if (r.message.isNotEmpty) firstError ??= r.message;
        if (r.diagnosis.isNotEmpty) firstError ??= r.diagnosis;
      }
      _setBusy(true, '刷新 ${i + 1}/${list.length}', (i + 1) / list.length);
    }
    await store.save();
    _setBusy(false, '', 0);
    notifyListeners();
    final err = fail > 0 && firstError != null ? '（$firstError）' : '';
    showToast('已刷新 $ok 张${fail > 0 ? '，$fail 张失败' : ''}$err');
  }

  // ---------------------------------------------------------------- 同步

  void updateSync(SyncConfig config) {
    store.setSync(config);
    notifyListeners();
    unawaited(_persist());
  }

  Future<String> testSync() async {
    final engine = SyncEngine(store);
    return engine.testConnection();
  }

  Future<void> runSync({bool silent = false}) async {
    if (_busy) return;
    if (!store.sync.configured) {
      if (!silent) showToast('先在设置里填写 WebDAV 地址');
      return;
    }
    _setBusy(true, '同步中…', 0);
    try {
      final result = await sync.run(onProgress: (p) {
        final label = p.message.isEmpty ? p.step : '${p.step} ${p.message}';
        _setBusy(true, label.trim(), p.fraction);
      });
      _setBusy(false, '', 0);
      notifyListeners();
      if (!silent || !result.ok) showToast(result.message);
    } catch (e) {
      _setBusy(false, '', 0);
      showToast('同步失败：$e');
    }
  }

  void _scheduleAutoSync() {
    if (!store.sync.configured || !store.sync.autoSync) return;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(const Duration(seconds: 8), () {
      unawaited(runSync(silent: true));
    });
  }

  // ---------------------------------------------------------------- 小工具

  void showToast(String message) {
    _toast = message;
    _toastSeq++;
    notifyListeners();
  }

  void _setBusy(bool busy, String label, double fraction) {
    _busy = busy;
    _busyLabel = label;
    _busyFraction = fraction;
    notifyListeners();
  }

  /// 缩略图文件（不存在返回 null）。
  File? thumbFileOf(Bill bill) {
    if (bill.thumb.isEmpty) return null;
    final f = dirs.thumbFile(bill.thumb);
    return f.existsSync() ? f : null;
  }

  @override
  void dispose() {
    _autoSyncTimer?.cancel();
    scanner.cancel();
    super.dispose();
  }
}
