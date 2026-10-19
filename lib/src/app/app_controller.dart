import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ocr/amount_reader.dart';

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

  /// 扫描 / 同步互斥：有任务在跑时，后到的请求排队而不是被静默丢弃。
  bool _syncQueued = false;

  /// 用户点了「停止」。扫描在识别循环里检查，刷新日期在批处理里检查。
  bool _cancelRequested = false;

  /// 最近一次扫描的结果文案（不落盘，只给界面和诊断用）。
  String _lastScanMessage = '';
  String get lastScanMessage => _lastScanMessage;

  /// 当前正在跑的是扫描 / 刷新日期（决定界面上要不要显示「停止」）。
  bool _scanning = false;
  bool _refreshing = false;
  bool get cancellable => _scanning || _refreshing;

  // ---------------------------------------------------------------- 初始化

  Future<void> init() async {
    await store.load();
    _ready = true;
    notifyListeners();
    if (store.loadWarning.isNotEmpty) showToast(store.loadWarning);

    // 首次进入：没有目录就提示导入；有目录就静默增量扫描
    if (store.folders.isEmpty) return;
    // 先扫描、再同步：scan / runSync 共用一个 _busy 守卫，同时发起会让后一个
    // 静默返回（这正是「启动自动同步从来没执行过」的原因）。
    await scan(force: false, silent: true);
    if (store.sync.configured && store.sync.autoSync) {
      await runSync(silent: true);
    }
  }

  // ---------------------------------------------------------------- 列表

  List<Bill> get allBills => store.bills;

  /// 当前筛选 + 排序后的列表。
  List<Bill> get visibleBills {
    final q = _query.trim();
    var list = store.liveBills;

    if (q.isNotEmpty) {
      final cents = Bill.parseYuan(q);
      if (cents != null) {
        // 输入的是金额：只保留完全相同的记录；一个都没有时保留全部，
        // 让「定位」按「最接近」跳过去——两处语义必须一致，别一个筛选一个取近。
        final exact = list.where((b) => b.amountCents == cents).toList();
        if (exact.isNotEmpty) list = exact;
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

  /// 复制这张图的原始文件到系统剪贴板（桌面端顶替「刷新日期」）。
  Future<void> copyImage(Bill bill) async {
    if (!source.supportsCopyImage) {
      showToast('当前平台不支持复制图片');
      return;
    }
    if (bill.path.isEmpty) {
      showToast('这条记录没有本机原图（可能是从其他设备同步来的）');
      return;
    }
    final ok = await source.copyImage(bill.path);
    showToast(ok ? '已复制图片，可直接粘贴到聊天窗口' : '复制失败：原图可能已被移动或删除');
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
    if (_busy) {
      if (!silent) showToast('正在忙，稍后再试');
      return;
    }
    if (store.folders.isEmpty) {
      if (!silent) showToast('先导入一个相册文件夹');
      return;
    }
    _cancelRequested = false;
    _scanning = true;
    _setBusy(true, force ? '重新识别全部…' : '正在识别金额…', 0);
    try {
      final result = await scanner.scanAll(
        forceRecheck: force,
        // 启动时的静默扫描只做增量；用户主动点「扫描识别」时才重试未识别记录
        retryUnrecognized: !silent,
        onProgress: (p) {
          if (p.total > 0) {
            _setBusy(true, '识别 ${p.done}/${p.total} · ${p.currentName}',
                p.fraction);
          } else {
            _setBusy(true, p.message.isEmpty ? '准备中…' : p.message, 0);
          }
        },
      );
      _lastScanMessage = result.message;
      _setBusy(false, '', 0);
      notifyListeners();
      if (!silent || result.updated > 0) showToast(result.message);
      if (result.updated > 0) _scheduleAutoSync();
    } catch (e) {
      _setBusy(false, '', 0);
      showToast('扫描失败：$e');
    } finally {
      _scanning = false;
      _flushQueuedSync();
    }
  }

  /// 扫描期间被拒绝的同步请求，在这里补跑（不能直接丢，否则「启动 / 修改后自动同步」失效）。
  void _flushQueuedSync() {
    if (!_syncQueued) return;
    _syncQueued = false;
    if (!store.sync.configured) return;
    unawaited(runSync(silent: true));
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
      final cents = Bill.centsFromYuan(r.value);
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
    if (_busy) {
      showToast('正在忙，稍后再试');
      return;
    }
    _cancelRequested = false;
    _refreshing = true;
    _setBusy(true, '正在刷新日期…', 0);
    // 整段包在 try/finally 里：中间任何一步抛异常都不能把 _busy 留在 true
    // （那会让「扫描识别」按钮永久变灰、点了没反应）。
    var ok = 0;
    var fail = 0;
    final failures = <String>[];
    try {
    for (var i = 0; i < list.length; i++) {
      if (_cancelRequested) break;
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
        if (failures.length < 3) {
          final reason = r.message.isNotEmpty ? r.message : r.diagnosis;
          failures.add(reason.isEmpty ? b.name : '${b.name}：$reason');
        }
      }
      // 每 10 张落一次盤：中途被杀时已回写的 path 不能丢，否则下次扫描会把
      // 这些记录当成「文件已消失」而打墓碑。
      if (i % 10 == 9) await store.save();
      _setBusy(true, '刷新 ${i + 1}/${list.length}', (i + 1) / list.length);
    }
    } catch (e) {
      showToast('刷新中断：$e');
    } finally {
      _refreshing = false;
      await store.save();
      _setBusy(false, '', 0);
      notifyListeners();
      final stopped = _cancelRequested && ok + fail < list.length;
      final detail = failures.isEmpty ? '' : '（${failures.join('；')}）';
      showToast('已刷新 $ok 张${fail > 0 ? '，$fail 张失败' : ''}'
          '${stopped ? '，已停止' : ''}$detail');
    }
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
    if (_busy) {
      // 扫描/刷新在跑：记下来，等它结束补跑，别把「自动同步」悄悄丢掉
      _syncQueued = true;
      if (!silent) showToast('正在忙，稍后自动同步');
      return;
    }
    if (!store.sync.configured) {
      if (!silent) showToast('先在设置里填写 WebDAV 地址');
      return;
    }
    _syncQueued = false;
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

  // ---------------------------------------------------------------- 诊断

  /// 识别诊断：把「读图 → 解码 → 识别」的中间结果摊开。
  ///
  /// 扫描只会在任一步失败时把记录留成「未识别」，界面上看不出卡在哪；
  /// 这里用第一条记录跑一遍并逐段报告，结果可以直接复制贴出来。
  Future<String> diagnoseRecognition() async {
    final buf = StringBuffer();
    buf.writeln('平台：${Platform.operatingSystem}');
    buf.writeln('目录：${store.folders.isEmpty ? '（未导入）' : store.folders.map((f) => f.isSaf ? 'SAF' : f.path).join(' / ')}');
    buf.writeln('最近扫描：${_lastScanMessage.isEmpty ? '（还没扫过）' : _lastScanMessage}');
    final bill = store.bills.isEmpty ? null : store.bills.first;
    if (bill == null) {
      buf.writeln('没有记录可诊断：先导入文件夹并扫描一次');
      return buf.toString();
    }
    buf.writeln('样本：${bill.name}');
    buf.writeln('路径：${bill.path}');
    try {
      final ocr = await source.loadForOcr(bill.path);
      if (ocr == null) {
        final err = source.loadError;
        buf.writeln('读图失败：${err.isEmpty ? '未知原因（没读到像素）' : err}');
      } else {
        buf.writeln('读图成功：${ocr.width}x${ocr.height}');
        final r = AmountReader.read(ocr.rgba, ocr.width, ocr.height);
        buf.writeln('识别结果：${r.text ?? '（空）'}　置信度 ${(r.confidence * 100).toStringAsFixed(1)}%');
      }
      final thumb = await source.makeThumbBytes(bill.path);
      buf.writeln('缩略图：${thumb == null ? '失败' : '${thumb.length} 字节'}');
    } catch (e) {
      buf.writeln('异常：$e');
    }
    return buf.toString();
  }

  // ---------------------------------------------------------------- 小工具

  /// 用户点「停止」：扫描会尽快收尾（已识别的会落盘），刷新日期在下一张前停。
  /// 同步不支持中断（一次 PUT 很快，打断反而可能留下半截状态）。
  void cancelBusy() {
    if (!_busy) return;
    _cancelRequested = true;
    scanner.cancel();
    showToast(_scanning ? '正在停止扫描…' : '正在停止…');
  }

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
