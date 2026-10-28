import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ocr/amount_reader.dart';

import '../data/app_dirs.dart';
import '../data/copy_plan.dart';
import '../data/scanner.dart';
import '../data/store.dart';
import '../model/bill.dart';
import '../platform/photo_source.dart';
import '../platform/window_shell.dart';
import '../webdav/sync.dart';

/// 「一次性说明」的键。看过一次就记在 [UiPrefs.seenTips] 里，之后不再打扰。
///
/// 只放**纯说明性**的提示：危险操作（删除）的确认永远每次都问。
class TipKeys {
  TipKeys._();

  /// 刷新日期那段长说明（会把入库时间改成现在、必要时重建文件）。
  static const String refreshDate = 'refresh_date';

  /// 识别诊断卡片的长说明。
  static const String diagnose = 'diagnose';

  /// 贴边隐藏：第一次打开时说明「拖到边缘才会收」。
  static const String edgeHide = 'edge_hide';
}

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
    // 把图片源交给同步引擎：上传原图要按平台读文件（Android 是 SAF，桌面是文件系统）
    sync = SyncEngine(store, source: source);
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

  /// 只表示「正在扫描相册」——底部按钮用它决定转圈还是显示「停止」。
  /// 不能复用 [busy]：同步时也在 busy，扫描按钮不该跟着变灰。
  bool get scanning => _scanning;

  /// 上一次扫描完成的时间（毫秒，取各目录 lastScanAt 的最大值；没扫过为 0）。
  int get lastScanAt =>
      store.folders.fold(0, (m, f) => f.lastScanAt > m ? f.lastScanAt : m);

  // ---------------------------------------------------------------- 缓存 / 节流

  /// [visibleBills] 的缓存：列表页每帧会取三次（列表、合计、底部计数），
  /// 500 条记录每次重排 + 重建列表是实打实的卡顿来源。
  ///
  /// 用 [BillStore.revision] 做失效判断，而不是在各个改动点手动清缓存——
  /// 后者漏一处就会显示旧数据（这是比卡顿更难查的 bug）。
  List<Bill>? _visibleCache;
  int _visibleCacheRevision = -1;
  String _visibleCacheQuery = '';
  SortMode? _visibleCacheSort;
  int _visibleSumCache = 0;

  /// 扫描进度通知节流：一张图一次 notifyListeners 会让整页重建几百次，
  /// 进度条根本看不出区别，却把主线程占满（列表滚动会明显卡）。
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// 相同文案的 toast 在 4 秒内只弹一次：扫描 / 自动同步连点几下时
  /// 否则会排队弹一串一模一样的「已是最新，无需同步」。
  String _lastToast = '';
  DateTime _lastToastAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// dispose 之后还有异步回调（扫描收尾、同步、闪烁定时器）会走到这里。
  /// 不对已销毁的 ChangeNotifier 调 notifyListeners，否则直接抛
  /// 「A AppController was used after being disposed」。
  bool _disposed = false;

  // ---------------------------------------------------------------- 初始化

  /// 启动：只加载本地数据 + 一次轻量的自动同步，**不扫描相册**。
  ///
  /// 之前每次打开都会自动增量扫一遍相册（几百上千张的目录列一次就要好几秒，
  /// 首屏一直转圈），而且结果通常和上次完全一样。现在改成：
  ///  * 用户点「扫描识别」才真正去读相册（见 [scan]）；
  ///  * 需要开机自动扫描的人，可以在设置里打开「启动时自动扫描」。
  /// 自动同步仍然保留（它只传一份几十 KB 的快照，比列相册目录便宜得多，
  /// 而且不拉取的话另一台设备的改动永远看不到）。
  Future<void> init() async {
    try {
      // 已经载入过就不再读一次：重复 load 会把内存里刚改的东西（例如刚导入的目录）
      // 用磁盘上的旧快照覆盖掉，而且白白多一次 IO。
      if (!store.loaded) await store.load();
    } catch (e) {
      // 读盘失败（目录不可写 / 权限被撤）不能把界面永远卡在转圈上：
      // 照常进主界面，让用户能看到「导入相册」并自己处理。
      showToast('读取本地数据失败：$e');
    }
    _ready = true;
    _notify();
    if (store.loadWarning.isNotEmpty) showToast(store.loadWarning);

    // 窗口开关只有两个布尔值，读它不该挡首屏；通道不通也只是回落到默认值
    unawaited(loadWindowPrefs());

    // 「有没有相册目录」只决定要不要扫描，不该连同步一起跳过：
    // 新设备先填同步地址、还没导入相册时，正是最需要拉一次远端数据的时候。
    if (store.folders.isNotEmpty && store.prefs.autoScanOnBoot) {
      await scan(force: false, silent: true);
    }
    if (store.sync.configured && store.sync.autoSync) {
      await runSync(silent: true);
    }
  }

  // ---------------------------------------------------------------- 列表

  List<Bill> get allBills => store.bills;

  /// 当前筛选 + 排序后的列表（带缓存，见 [_visibleCache]）。
  List<Bill> get visibleBills {
    _ensureVisible();
    return _visibleCache!;
  }

  void _ensureVisible() {
    final rev = store.revision;
    final cached = _visibleCache;
    if (cached != null &&
        rev == _visibleCacheRevision &&
        _query == _visibleCacheQuery &&
        _sort == _visibleCacheSort) {
      return;
    }

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

    _visibleCache = sorted;
    _visibleCacheRevision = rev;
    _visibleCacheQuery = _query;
    _visibleCacheSort = _sort;
    _visibleSumCache =
        sorted.fold(0, (s, b) => s + (b.amountCents ?? 0));
  }

  int get visibleSumCents {
    // 借 _ensureVisible 把合计一起算掉，避免每次构建都再遍历一遍列表
    _ensureVisible();
    return _visibleSumCache;
  }

  int get totalCount => store.count;
  int get totalSumCents => store.sumCents;

  void setSort(SortMode mode) {
    if (_sort == mode) return;
    _sort = mode;
    _notify();
  }

  void setQuery(String q) {
    if (_query == q) return;
    _query = q;
    _notify();
  }

  /// 跳到第一个匹配项：返回目标 id（界面负责滚动 + 闪烁）。
  String? locateByAmount(String text) {
    final raw = text.trim();
    if (raw.isEmpty) {
      showToast('先输入金额，例如 31.5');
      return null;
    }
    final target = Bill.parseYuan(raw);
    if (target == null) {
      showToast('金额格式不对（最多两位小数，例如 31.5）');
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
    _notify();
    Timer(const Duration(milliseconds: 1600), () {
      if (_flashId == id) {
        _flashId = null;
        _notify();
      }
    });
    return id;
  }

  // ---------------------------------------------------------------- 编辑

  void setAmount(String id, int? cents, {String? note}) {
    store.setAmount(id, cents, note: note);
    _notify();
    _persist();
    _scheduleAutoSync();
  }

  void setNote(String id, String note) {
    store.setNote(id, note);
    _notify();
    _persist();
    _scheduleAutoSync();
  }

  void removeBill(String id) {
    store.remove(id);
    _notify();
    _persist();
    _scheduleAutoSync();
    // 顺手把这条记录的缩略图/原图副本清掉（不等下一次扫描）
    unawaited(_pruneMediaLater());
  }

  Future<void> _pruneMediaLater() async {
    try {
      await store.pruneThumbs();
      await store.pruneMedia();
    } catch (_) {
      // 清理失败不影响删除本身
    }
  }

  Future<void> _persist() async {
    try {
      await store.save();
    } catch (e) {
      showToast('保存失败：$e');
    }
  }

  /// 复制这张图到系统剪贴板（桌面端顶替「刷新日期」）。
  ///
  /// 来源按「先原图、后缩略图」两级取（见 [resolveCopyPlan]）：
  /// 从另一台设备同步来的记录，[Bill.path] 是那台设备的定位，在这台电脑上
  /// 并不存在；但缩略图已经随同步下载好了，列表里也看得见。这时直接判失败
  /// 就是「同步成功了，复制却失败」——所以用缩略图兜底，至少粘得出去。
  Future<void> copyImage(Bill bill) async {
    if (!source.supportsCopyImage) {
      showToast('当前平台不支持复制图片');
      return;
    }
    final plan = resolveCopyPlan(bill, dirs);
    if (!plan.canCopy) {
      showToast(plan.reason);
      return;
    }
    var ok = false;
    try {
      ok = await source.copyImage(plan.path);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      // 走到这里说明文件确实在（上面刚查过），失败的只可能是剪贴板本身：
      // 常见是别的程序（剪贴板管理器 / 远程桌面）正占着它。
      showToast('复制失败：系统剪贴板暂时不可用（可能被其他程序占用），请稍后重试');
      return;
    }
    showToast(plan.isFullSize
        ? '已复制图片，可直接粘贴到聊天窗口'
        : '已复制缩略图（原图太大或还没同步下来，这张是 256px 的预览图）');
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
      _notify();
      await scan(force: false);
    } catch (e) {
      showToast('导入失败：$e');
    }
  }

  Future<void> removeFolder(String id) async {
    store.removeFolder(id);
    await store.save();
    _notify();
  }

  // ---------------------------------------------------------------- 扫描

  /// 扫描相册（用户点「扫描识别」/「重新识别全部」时调用）。
  ///
  /// [force] 忽略文件修改时间，全部重新识别；[silent] 表示非用户主动触发
  /// （目前只有设置里打开的「启动时自动扫描」会用），此时不弹结果提示。
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
        // 用户主动点「扫描识别」时才重试未识别记录
        retryUnrecognized: !silent,
        onProgress: (p) {
          if (p.total > 0) {
            _setBusyThrottled(
                '识别 ${p.done}/${p.total} · ${p.currentName}', p.fraction);
          } else {
            _setBusyThrottled(p.message.isEmpty ? '准备中…' : p.message, 0);
          }
        },
      );
      _lastScanMessage = result.message;
      _setBusy(false, '', 0);
      _notify();
      // 用户亲手点的「扫描识别」一定要有回音（哪怕结果是「没变化」），
      // 否则点了没反应会让人以为按钮坏了；非用户触发（启动自动扫描）
      // 只在真有更新时说话，避免开机就弹一条没用的提示。
      if (!silent || result.updated > 0) showToast(result.message);
      if (result.updated > 0) _scheduleAutoSync();
    } catch (e) {
      _setBusy(false, '', 0);
      showToast('扫描失败：$e');
    } finally {
      _scanning = false;
      _notify();
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
    var skipped = 0;
    final failures = <String>[];
    try {
      for (var i = 0; i < list.length; i++) {
        if (_cancelRequested) break;
        // 列表是点击那一刻的快照：这期间用户可能删了记录、也可能改了金额。
        // 一律按 id 重读当前值，绝不拿旧对象 copyWith 写回（那会把墓碑覆盖成未删除，
        // 而且 updatedAt 会被刷成现在，合并时连其他设备的墓碑都会输给它）。
        final cur = store.byId(list[i].id);
        if (cur == null || cur.deleted) {
          skipped++;
          continue;
        }
        if (cur.path.isEmpty) {
          fail++;
          continue;
        }
        // 目录可能已被移除（记录还留着）。此时 folder 为 null，但原生侧
        // 还有「所有文件访问权限」那条路线可以不靠 treeUri 生效，
        // 所以不能在这里直接跳过——只把拿得到的目录传下去。
        final folder = store.folderOf(cur);
        final r = await source.refreshDate(cur.path, folder?.path);
        if (r.ok) {
          ok++;
          // 走「重建新文件」路线时路径会变，必须回写，否则记录失效
          if (r.newPath.isNotEmpty && r.newPath != cur.path) {
            store.put(cur.copyWith(
              path: r.newPath,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ));
            // 原生侧是先删旧文件再返回新路径的：这里必须立刻落盘，
            // 否则中途被杀，记录就指向一个已不存在的文件（下次扫描会打墓碑）。
            await store.save();
          }
        } else {
          fail++;
          if (failures.length < 3) {
            final reason = r.message.isNotEmpty ? r.message : r.diagnosis;
            failures.add(reason.isEmpty ? cur.name : '${cur.name}：$reason');
          }
        }
        _setBusyThrottled('刷新 ${i + 1}/${list.length}', (i + 1) / list.length);
      }
    } catch (e) {
      showToast('刷新中断：$e');
    } finally {
      _refreshing = false;
      await store.save();
      _setBusy(false, '', 0);
      _notify();
      final stopped = _cancelRequested && ok + fail + skipped < list.length;
      final detail = failures.isEmpty ? '' : '（${failures.join('；')}）';
      showToast('已刷新 $ok 张${fail > 0 ? '，$fail 张失败' : ''}'
          '${skipped > 0 ? '，$skipped 张已删除已跳过' : ''}'
          '${stopped ? '，已停止' : ''}$detail');
      // 刷新期间被挡住的同步请求，这里补跑（同 scan 的处理）
      _flushQueuedSync();
    }
  }

  // ---------------------------------------------------------------- 同步

  void updateSync(SyncConfig config) {
    store.setSync(config);
    _notify();
    unawaited(_persist());
  }

  /// 静默保存同步配置（设置页退出时用）。
  ///
  /// 刻意不 notifyListeners：调用发生在 dispose 里，此时树正在卸载，
  /// 通知会让别的组件 setState，直接抛「setState() called after dispose」。
  void saveSyncSilently(SyncConfig config) {
    store.setSync(config);
    unawaited(_persist());
  }

  Future<String> testSync() async {
    // 地址清空 / 写错时 WebDavClient 会抛 ArgumentError，这里必须兜住：
    // 否则设置页的「测试连接」会一直转圈（_testing 永远不回落）。
    if (!store.sync.configured) return '先填写服务器地址';
    try {
      final engine = SyncEngine(store, source: source);
      return await engine.testConnection();
    } catch (e) {
      return '测试失败：$e';
    }
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
        _setBusyThrottled(label.trim(), p.fraction,
            interval: const Duration(milliseconds: 200));
      });
      _setBusy(false, '', 0);
      _notify();
      // 静默同步一句都不弹：成功时那句「已是最新」每天要弹好几次，
      // 失败时弹的又是一条用户当场没法处理的网络错误。
      // 结果都记在 store.sync.lastSyncMessage 里，界面上有入口能看到（见
      // [syncFailed]），不会「悄悄失败」。
      if (!silent) showToast(result.message);
    } catch (e) {
      _setBusy(false, '', 0);
      showToast('同步失败：$e');
    } finally {
      // 同步期间到达的请求（改数据后 8 秒触发的那次）必须补跑，
      // 否则它会被静默丢掉，用户的修改一直留在本机。
      _flushQueuedSync();
    }
  }

  /// 最近一次同步是否失败（启动时的静默同步失败不弹提示，靠这个标记告诉界面）。
  bool get syncFailed => store.sync.configured && !store.sync.lastSyncOk;

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

  /// 安全通知：dispose 之后（扫描收尾、定时器、同步回调）不再触碰已销毁的对象。
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 用户点「停止」：扫描会尽快收尾（已识别的会落盘），刷新日期在下一张前停。
  /// 同步不支持中断（一次 PUT 很快，打断反而可能留下半截状态）。
  void cancelBusy() {
    if (!_busy) return;
    _cancelRequested = true;
    scanner.cancel();
    showToast(_scanning ? '正在停止扫描…' : '正在停止…');
  }

  void showToast(String message) {
    if (message.isEmpty) return;
    final now = DateTime.now();
    // 同一句话 4 秒内只弹一次：连点、自动同步重试时会连着弹一串一样的提示
    if (message == _lastToast && now.difference(_lastToastAt).inSeconds < 4) {
      return;
    }
    _lastToast = message;
    _lastToastAt = now;
    _toast = message;
    _toastSeq++;
    _notify();
  }

  // ---------------------------------------------------------------- 一次性说明

  /// 这条说明是否已经看过（看过就不再弹）。
  bool hasSeenTip(String key) => store.prefs.hasSeen(key);

  /// 标记「看过了」并落盘。之后的启动不会再弹同一个说明。
  Future<void> markTipSeen(String key) async {
    if (store.prefs.hasSeen(key)) return;
    store.setPrefs(store.prefs.markSeen(key));
    _notify();
    await _persist();
  }

  /// 设置页的「重新显示所有说明」：把已读记录清掉，下次操作时会再弹一次。
  Future<void> resetTips() async {
    store.setPrefs(store.prefs.clearTips());
    _notify();
    await _persist();
  }

  /// 启动时是否自动扫描（默认关）。
  bool get autoScanOnBoot => store.prefs.autoScanOnBoot;

  Future<void> setAutoScanOnBoot(bool value) async {
    store.setPrefs(store.prefs.copyWith(autoScanOnBoot: value));
    _notify();
    await _persist();
  }

  // ---------------------------------------------------------------- 窗口（Windows）

  /// 窗口的两个开关。存在 `%LOCALAPPDATA%\wxbills\window.ini`（runner 那边写），
  /// 不进 data.json：那是会被 WebDAV 同步到别的设备的账本。
  WindowPrefs _windowPrefs = const WindowPrefs();
  WindowPrefs get windowPrefs => _windowPrefs;

  Future<void> loadWindowPrefs() async {
    if (!WindowShell.isSupported) return;
    _windowPrefs = await WindowShell.load();
    _notify();
    // 贴边隐藏默认就是开的：如果只在"用户手动打开开关"时提示，默认用户
    // 永远看不到说明，第一次撞见窗口自己收起来只会当成 bug。
    if (_windowPrefs.edgeHide && !hasSeenTip(TipKeys.edgeHide)) {
      showToast('贴边隐藏已开启：窗口拖到屏幕边缘会自动收起，鼠标碰到边上的细条弹回来');
      await markTipSeen(TipKeys.edgeHide);
    }
  }

  Future<void> setRememberWindow(bool value) async {
    final previous = _windowPrefs;
    _windowPrefs = _windowPrefs.copyWith(remember: value);
    _notify();
    // 失败就回滚：否则界面显示"已关闭"，实际上 runner 还是老样子，重启才发现
    if (!await WindowShell.save(_windowPrefs)) {
      _windowPrefs = previous;
      _notify();
      showToast('窗口设置没写进去，重启后会恢复默认');
    }
  }

  Future<void> setEdgeHide(bool value) async {
    final previous = _windowPrefs;
    _windowPrefs = _windowPrefs.copyWith(edgeHide: value);
    _notify();
    if (!await WindowShell.save(_windowPrefs)) {
      _windowPrefs = previous;
      _notify();
      showToast('贴边隐藏没生效：窗口通道不通');
      return;
    }
    if (!value || hasSeenTip(TipKeys.edgeHide)) return;
    // 开了却不知道要"拖到边缘"，会以为功能没生效 —— 只说一次
    showToast('把窗口拖到屏幕左/右/上边缘，鼠标离开就会收起来；碰到边上的细条弹回来');
    await markTipSeen(TipKeys.edgeHide);
  }

  void _setBusy(bool busy, String label, double fraction) {
    _busy = busy;
    _busyLabel = label;
    _busyFraction = fraction;
    _notify();
  }

  /// 扫描进度的节流版：至少间隔 [interval] 才推一次界面，最后一条不丢
  /// （调用方在扫描结束时还会再 _setBusy 一次，所以收尾状态一定准确）。
  void _setBusyThrottled(
    String label,
    double fraction, {
    Duration interval = const Duration(milliseconds: 120),
  }) {
    final now = DateTime.now();
    if (now.difference(_lastProgressNotify) < interval) return;
    _lastProgressNotify = now;
    _setBusy(true, label, fraction);
  }

  /// 缩略图文件（不存在返回 null）。
  ///
  /// 走一层缓存：列表每帧都会为每个可见行问一次，`existsSync()` 是同步文件 IO，
  /// 一帧问十几次会把滚动卡住。缓存以 [BillStore.revision] 为界失效
  /// （扫描 / 同步写缩略图都会让 revision 变化）。
  final Map<String, bool> _thumbExists = {};
  int _thumbCacheRevision = -1;

  File? thumbFileOf(Bill bill) {
    if (bill.thumb.isEmpty) return null;
    if (_thumbCacheRevision != store.revision) {
      _thumbExists.clear();
      _thumbCacheRevision = store.revision;
    }
    final f = dirs.thumbFile(bill.thumb);
    final cached = _thumbExists[bill.thumb];
    if (cached == true) return f;
    if (cached == false) return null;
    final exists = f.existsSync();
    _thumbExists[bill.thumb] = exists;
    return exists ? f : null;
  }

  @override
  void dispose() {
    _disposed = true;
    _autoSyncTimer?.cancel();
    scanner.cancel();
    super.dispose();
  }
}
