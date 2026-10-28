import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/bill.dart';
import '../../platform/window_shell.dart';
import '../app_controller.dart';
import '../theme.dart';
import '../widgets/bill_tile.dart';
import '../widgets/ui_kit.dart';

/// 主页面：收款单列表（搜索 + 排序 + 定位 + 扫描 + 同步）。
class BillsPage extends StatefulWidget {
  const BillsPage({
    super.key,
    required this.controller,
    required this.onOpenSettings,
  });

  final AppController controller;
  final VoidCallback onOpenSettings;

  @override
  State<BillsPage> createState() => _BillsPageState();
}

class _BillsPageState extends State<BillsPage> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _searchFocus = FocusNode();
  final _itemKeys = <String, GlobalKey>{};

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChanged);
    _searchCtrl.text = c.query;
    _searchHadText = _searchCtrl.text.isNotEmpty;
    // 输入框的清空按钮显隐取决于「当前是否为空」，所以要跟着输入变化重建；
    // 之前只在 setState 时才刷，输入后 ✕ 一直不出现。
    _searchCtrl.addListener(_onSearchChanged);
  }

  bool _searchHadText = false;

  /// 输入防抖：每敲一个字就全量过滤 + 排序 + 整页重建，几百条时会明显掉帧。
  Timer? _queryDebounce;

  void _onQueryChanged(String value) {
    _queryDebounce?.cancel();
    _queryDebounce = Timer(const Duration(milliseconds: 200), () {
      c.setQuery(value);
    });
  }

  void _onSearchChanged() {
    final has = _searchCtrl.text.isNotEmpty;
    if (has == _searchHadText) return;
    _searchHadText = has;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    _queryDebounce?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    // 顺手把已经不在筛选结果里的 key 清掉：数量自然收敛到"一屏多一点"。
    // （以前是在 build 里为**全部**记录 putIfAbsent 再全量做差集，见 _keyFor）
    final visible = {for (final b in c.visibleBills) b.id};
    _itemKeys.removeWhere((id, _) => !visible.contains(id));
    setState(() {});
  }

  /// 只为"真正构建出来的行"建 GlobalKey。
  ///
  /// GlobalKey 只有一个用途：`_locate()` 里做一次精确对齐（`ensureVisible`）。
  /// 屏外的行本来就没有 context，提前给 500 条记录各建一个 key 纯属首帧白花。
  GlobalKey _keyFor(String id) => _itemKeys.putIfAbsent(id, GlobalKey.new);

  // ---------------------------------------------------------------- 定位

  Future<void> _locate() async {
    // 防抖可能还没把最新输入交给 controller（例如输入后立刻按回车），
    // 定位前先同步一次，保证「看到的输入」和「筛选结果」是同一份。
    c.setQuery(_searchCtrl.text);
    final id = c.locateByAmount(_searchCtrl.text);
    if (id == null) return;
    FocusScope.of(context).unfocus();
    // 等一帧，让列表按新的筛选结果重建
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scrollCtrl.hasClients) return;

    final bills = c.visibleBills;
    final index = bills.indexWhere((b) => b.id == id);
    if (index < 0) return;

    // 第一段：按「下标 × 行高」直接跳过去。
    // 不能依赖 GlobalKey 的 context——ListView 是懒构建的，屏外 item 根本没有
    // context，旧实现的兜底是 animateTo(0)，于是「定位」变成了「跳回顶部」。
    final extent = _tileExtent();
    final target =
        (index * extent).clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    await _scrollCtrl.animateTo(target,
        duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    if (!mounted) return;

    // 第二段：目标已进入视口附近，它的 key 这时才构建出来，做一次精确对齐。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final ctx = _itemKeys[id]?.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 160),
        alignment: 0.25,
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 单条记录占的高度：卡片（缩略图 58 + 上下内边距 20）+ 间隔 8。
  /// 优先量已经渲染出来的卡片，量不到再退回常量。
  double _tileExtent() {
    for (final key in _itemKeys.values) {
      final box = key.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize && box.size.height > 0) {
        return box.size.height + 8;
      }
    }
    return 86;
  }

  // ---------------------------------------------------------------- 编辑

  Future<void> _editBill(Bill bill) async {
    final result = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _AmountDialog(bill: bill),
    );
    if (result == null) return;
    // cleared = 撤回这次识别，回到「未识别」；value = 正常落盘
    c.setAmount(
      bill.id,
      result.kind == _EditKind.cleared ? null : result.cents,
      note: result.note,
    );
  }

  /// 刷新图片日期。
  ///
  /// 那段「会把入库时间改成现在、必要时重建文件」的说明只在**第一次**弹，
  /// 之后直接执行（同一句话每次点都看一遍纯属噪音）。想再看一次：
  /// 设置 → 重新显示所有说明。
  Future<void> _confirmRefresh(List<Bill> list) async {
    if (list.isEmpty) return;
    if (c.hasSeenTip(TipKeys.refreshDate)) {
      await c.refreshDates(list);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('刷新 ${list.length} 张图片的日期'),
        content: const SizedBox(
          width: 360,
          child: Text(
            '会把图片的「入库时间」改成现在——QQ 和相册判定新增图片看的就是这个，'
            '只改文件修改时间是没用的。\n\n'
            '改不动媒体库时，会在同一目录重建一个新文件（内容不变）再删掉旧的，'
            '这样必被当成新图；新建失败则旧文件原样保留。\n\n'
            '这条说明只显示这一次，之后点「刷新日期」会直接开始。',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('开始')),
        ],
      ),
    );
    if (ok == true) {
      await c.markTipSeen(TipKeys.refreshDate);
      await c.refreshDates(list);
    }
  }

  /// 标题栏副标题：记录数 + 合计 + 异常项。
  String _subtitle() {
    final buf = StringBuffer(
        '共 ${c.totalCount} 张 · 合计 ¥${Bill.formatCents(c.totalSumCents)}');
    if (c.store.unrecognizedCount > 0) {
      buf.write(' · ${c.store.unrecognizedCount} 张未识别');
    }
    if (c.store.reviewCount > 0) {
      buf.write(' · ${c.store.reviewCount} 张待核对');
    }
    return buf.toString();
  }

  /// 工具条右侧那句：没筛选时显示「上次扫描」，有筛选时显示筛选结果。
  ///
  /// 以前这里永远是「当前 N 张 · ¥X」，没筛选时和标题栏的「共 N 张 · 合计 ¥X」
  /// 完全重复。现在把位置让给「上次扫描」——启动不再自动扫描之后，
  /// 数据是什么时候的必须一眼能看到。
  String _toolbarHint() {
    if (c.query.trim().isEmpty) {
      final at = c.lastScanAt;
      if (at == 0) return c.totalCount == 0 ? '还没扫描过' : '未记录扫描时间';
      return '上次扫描 ${_ago(at)}';
    }
    return '当前 ${c.visibleBills.length} 张 · ¥${Bill.formatCents(c.visibleSumCents)}';
  }

  static String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final bills = c.visibleBills;

    return Column(
      children: [
        GreenHeader(
          title: '收款单管理',
          subtitle: _subtitle(),
          actions: [
            HeaderIconButton(
              icon: Icons.restart_alt,
              tooltip: '重新识别全部（含之前没识别出来的）',
              onPressed: () => c.scan(force: true),
            ),
            HeaderIconButton(
              // 上次同步失败：图标直接换成「云断开」，不用等下次弹窗才知道
              icon: c.syncFailed ? Icons.cloud_off_rounded : Icons.sync_rounded,
              tooltip: c.syncFailed
                  ? '上次同步失败：${c.store.sync.lastSyncMessage}\n点一下重试'
                  : '立即同步（WebDAV）',
              onPressed: () => c.runSync(),
            ),
            // 贴边隐藏开着时才出现：Windows 的 Aero Snap 会把"拖到顶边"变成
            // 最大化，所以贴顶只能点一下，不给入口就等于没有这个功能。
            if (WindowShell.isSupported && c.windowPrefs.edgeHide)
              HeaderIconButton(
                icon: Icons.vertical_align_top,
                tooltip: '贴到屏幕顶部（鼠标离开自动收起）',
                onPressed: () => unawaited(c.snapWindowToTop()),
              ),
            HeaderIconButton(
              icon: Icons.settings_outlined,
              tooltip: '设置',
              onPressed: widget.onOpenSettings,
            ),
          ],
        ),
        _toolbar(),
        if (c.busy)
          BusyBar(
            label: c.busyLabel,
            fraction: c.busyFraction,
            onCancel: c.cancellable ? c.cancelBusy : null,
          ),
        Expanded(
          child: bills.isEmpty
              ? EmptyHint(
                  icon: Icons.receipt_long_outlined,
                  title: c.store.folders.isEmpty ? '还没有导入相册' : '没有收款单',
                  detail: c.store.folders.isEmpty
                      ? '授权一个存放收款单截图的文件夹，\n应用会自动识别每张图的金额并按金额排序。'
                      : c.query.trim().isNotEmpty
                          ? '当前筛选条件下没有记录。'
                          : c.totalCount == 0
                              // 启动不再自动扫描，所以「有目录但没记录」时
                              // 直接告诉用户下一步该点哪里，而不是让他以为相册是空的
                              ? '相册还没扫描过。\n点下面的「扫描识别」读取一次即可，之后只有你点它才会刷新。'
                              : '相册里没有新的图片。',
                  action: c.store.folders.isEmpty
                      ? FilledButton.icon(
                          onPressed: c.addFolder,
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('导入文件夹'),
                        )
                      : c.totalCount == 0 && c.query.trim().isEmpty
                          ? FilledButton.icon(
                              onPressed: () => c.scan(force: false),
                              icon: const Icon(Icons.document_scanner_outlined, size: 18),
                              label: const Text('扫描识别'),
                            )
                          : null,
                )
              : ContentWidth(
                  child: ListView.separated(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                    itemCount: bills.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final b = bills[i];
                      return KeyedSubtree(
                        key: _keyFor(b.id),
                        child: BillTile(
                          bill: b,
                          // 后台批量改写账本时不接受逐条编辑：
                          // 那会把用户刚改的金额/刚删的记录用旧快照覆盖回去。
                          enabled: !c.busy,
                          flashing: c.flashId == b.id,
                          controller: c,
                          onEdit: () => _editBill(b),
                          onRefresh: () => _confirmRefresh([b]),
                          onCopy: () => c.copyImage(b),
                          onDelete: () => _deleteBill(b),
                        ),
                      );
                    },
                  ),
                ),
        ),
        _bottomBar(bills),
      ],
    );
  }

  Future<void> _deleteBill(Bill bill) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条记录？'),
        content: Text(
          '只会从本应用删除（并同步到其他设备），不会删除相册里的图片。\n\n${bill.name}',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Palette.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) c.removeBill(bill.id);
  }

  Widget _toolbar() {
    return ContentWidth(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    onChanged: _onQueryChanged,
                    onSubmitted: (_) => _locate(),
                    style: const TextStyle(fontSize: 13.5),
                    decoration: InputDecoration(
                      hintText: '输入金额快速定位，如 31.5',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () {
                                _searchCtrl.clear();
                                c.setQuery('');
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 42,
                  child: FilledButton(
                    onPressed: _locate,
                    style: FilledButton.styleFrom(
                      backgroundColor: Palette.green,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('定位', style: TextStyle(fontSize: 13.5)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SegmentedBar<SortMode>(
                    values: SortMode.values,
                    labels: SortMode.values.map((e) => e.label).toList(),
                    selected: c.sort,
                    onChanged: c.setSort,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    _toolbarHint(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Palette.darkTextDim
                          : Palette.textDim,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(List<Bill> visible) {
    final canRefresh = c.source.supportsRefreshDate;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Palette.darkCard
            : Palette.card,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).brightness == Brightness.dark
                ? Palette.darkLine
                : Palette.line,
          ),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
          14, 10, 14, 10 + MediaQuery.of(context).padding.bottom),
      child: ContentWidth(
        child: Row(
          children: [
            Expanded(
              child: ActionButton(
                icon: Icons.folder_open,
                label: '导入相册',
                onPressed: c.addFolder,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ActionButton(
                icon: c.scanning
                    ? Icons.stop_circle_outlined
                    : Icons.document_scanner_outlined,
                label: c.scanning ? '停止扫描' : '扫描识别',
                primary: true,
                // 扫描中同一个按钮变成「停止」；同步 / 刷新日期在跑时只变灰，
                // 别让它跟着转圈（用户会以为是扫描在跑）。
                enabled: c.scanning || !c.busy,
                onPressed: c.scanning ? c.cancelBusy : () => c.scan(force: false),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ActionButton(
                icon: canRefresh
                    ? Icons.schedule_rounded
                    : Icons.cloud_sync_outlined,
                label: canRefresh ? '刷新日期' : '同步',
                onPressed: canRefresh
                    ? () => _confirmRefresh(visible.isEmpty ? c.allBills : visible)
                    : () => c.runSync(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑金额/备注的对话框结果。
enum _EditKind {
  /// 用户把金额清空了：回到「未识别」。
  cleared,

  /// 合法金额。
  value,
}

class _EditResult {
  const _EditResult(this.kind, this.cents, this.note);
  final _EditKind kind;
  final int? cents;
  final String note;
}

/// 确认金额对话框。
///
/// 做成独立的 StatefulWidget 而不是在页面里 `showDialog` + 外部 controller：
/// `showDialog` 返回时路由的退场动画还没播完，控件仍会读 controller，
/// 在外部 dispose 会直接抛 "A TextEditingController was used after being disposed"。
class _AmountDialog extends StatefulWidget {
  const _AmountDialog({required this.bill});

  final Bill bill;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.bill.amountCents == null
        ? ''
        : Bill.formatCents(widget.bill.amountCents!),
  );
  late final TextEditingController _note =
      TextEditingController(text: widget.bill.note);

  /// 非法输入的提示。以前是「关掉对话框再弹 toast」——用户刚敲的数字跟着一起没了。
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _amount.text.trim();
    final note = _note.text.trim();
    if (raw.isEmpty) {
      Navigator.pop(context, _EditResult(_EditKind.cleared, null, note));
      return;
    }
    final cents = Bill.parseYuan(raw);
    if (cents == null) {
      // 留在对话框里，把输入还给他改
      setState(() => _error = '金额格式不对：最多 7 位整数 + 2 位小数');
      return;
    }
    Navigator.pop(context, _EditResult(_EditKind.value, cents, note));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('确认金额', style: TextStyle(fontSize: 17)),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                prefixText: '¥ ',
                hintText: '例如 24.50',
                errorText: _error,
              ),
              style: amountStyle(context, size: 19),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(hintText: '备注（可选）'),
              style: const TextStyle(fontSize: 13.5),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 10),
            Text(
              widget.bill.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: Palette.textDim),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
