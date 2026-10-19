import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/bill.dart';
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
  }

  @override
  void dispose() {
    c.removeListener(_onChanged);
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
  }

  // ---------------------------------------------------------------- 定位

  Future<void> _locate() async {
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
    if (result.kind == _EditKind.invalid) {
      c.showToast('金额格式不对');
      return;
    }
    // cleared = 撤回这次识别，回到「未识别」；value = 正常落盘
    c.setAmount(
      bill.id,
      result.kind == _EditKind.cleared ? null : result.cents,
      note: result.note,
    );
  }

  Future<void> _confirmRefresh(List<Bill> list) async {
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
            '这样必被当成新图；新建失败则旧文件原样保留。',
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
      await c.refreshDates(list);
    }
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final bills = c.visibleBills;
    // 用 Set 做差集，别在 removeWhere 里对每个 key 再遍历一遍列表（O(n²)）
    final visibleIds = {for (final b in bills) b.id};
    _itemKeys.removeWhere((id, _) => !visibleIds.contains(id));
    for (final b in bills) {
      _itemKeys.putIfAbsent(b.id, () => GlobalKey());
    }

    return Column(
      children: [
        GreenHeader(
          title: '收款单管理',
          subtitle: '共 ${c.totalCount} 张 · 合计 ¥${Bill.formatCents(c.totalSumCents)}'
              '${c.store.unrecognizedCount > 0 ? ' · ${c.store.unrecognizedCount} 张未识别' : ''}'
              '${c.store.reviewCount > 0 ? ' · ${c.store.reviewCount} 张待核对' : ''}',
          actions: [
            HeaderIconButton(
              icon: Icons.restart_alt,
              tooltip: '重新识别全部（含之前没识别出来的）',
              onPressed: () => c.scan(force: true),
            ),
            HeaderIconButton(
              icon: Icons.sync_rounded,
              tooltip: '立即同步（WebDAV）',
              onPressed: () => c.runSync(),
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
                      : '当前筛选条件下没有记录。',
                  action: c.store.folders.isEmpty
                      ? FilledButton.icon(
                          onPressed: c.addFolder,
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('导入文件夹'),
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
                        key: _itemKeys[b.id],
                        child: BillTile(
                          bill: b,
                          flashing: c.flashId == b.id,
                          controller: c,
                          onEdit: () => _editBill(b),
                          onRefresh: () => _confirmRefresh([b]),
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
                    onChanged: c.setQuery,
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
                                setState(() {});
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
                Text(
                  '当前 ${c.visibleBills.length} 张 · ¥${Bill.formatCents(c.visibleSumCents)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Palette.darkTextDim
                        : Palette.textDim,
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
                icon: Icons.document_scanner_outlined,
                label: '扫描识别',
                primary: true,
                busy: c.busy,
                onPressed: () => c.scan(force: false),
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

  /// 文本解析不出金额（提示格式错误，不落盘）。
  invalid,
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
    Navigator.pop(
      context,
      _EditResult(cents == null ? _EditKind.invalid : _EditKind.value, cents, note),
    );
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
              decoration: const InputDecoration(
                prefixText: '¥ ',
                hintText: '例如 24.50',
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
