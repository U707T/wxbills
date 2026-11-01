import 'package:flutter/material.dart';

import '../../model/bill.dart';
import '../app_controller.dart';
import '../theme.dart';
import 'ui_kit.dart';

/// 一条收款单。
///
/// 与旧版自绘 View 等价的信息层级：缩略图 → 金额（大字）→ 备注/文件名 → 时间，
/// 右侧是状态标签与「刷新日期」按钮（仅 Android 显示）。
class BillTile extends StatelessWidget {
  const BillTile({
    super.key,
    required this.bill,
    required this.flashing,
    required this.controller,
    required this.onEdit,
    required this.onRefresh,
    required this.onCopy,
    required this.onDelete,
    this.enabled = true,
    this.compact = false,
  });

  final Bill bill;
  final bool flashing;
  final AppController controller;
  final VoidCallback onEdit;
  final VoidCallback onRefresh;

  /// 复制这张图到剪贴板（桌面端用它顶替 Android 的「刷新日期」）。
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  /// 扫描 / 同步 / 刷新日期在跑时置 false：那时后台正在批量改写账本，
  /// 这一行上的编辑与删除会被批处理的旧快照覆盖，干脆先不让点。
  final bool enabled;

  /// 窄模式：缩略图、金额、内边距各收一档，360px 宽也能把「金额 + 备注 +
  /// 两个行内按钮」摆在一行里，不横向溢出。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final thumb = controller.thumbFileOf(bill);
    final amountColor = bill.amountCents == null
        ? (dark ? Palette.darkTextDim : Palette.textDim)
        : (dark ? Palette.darkText : Palette.text);

    final content = Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(10, 8, 6, 8)
          : const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ThumbView(file: thumb, size: compact ? 50 : 58),
          SizedBox(width: compact ? 10 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        bill.amountCents == null
                            ? '未识别'
                            : '¥ ${bill.amountYuan}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: amountStyle(context,
                            size: compact ? 18 : 20,
                            color: amountColor,
                            weight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (bill.manual)
                      const StatusChip(text: '手动', color: Palette.blue, dense: true)
                    else if (bill.needsReview)
                      const StatusChip(
                          text: '待核对', color: Palette.amber, dense: true),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  bill.note.isNotBlank ? bill.note : bill.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: dark ? Palette.darkTextDim : Palette.textDim,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _formatTime(bill.fileModified),
                  style: TextStyle(
                    fontSize: 11,
                    color: dark ? Palette.darkTextDim : Palette.textDim,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (controller.source.supportsRefreshDate)
            _roundIcon(
              icon: Icons.refresh_rounded,
              tooltip: '刷新这张图片的日期（让 QQ/相册当成新图）',
              onTap: enabled ? onRefresh : null,
              background: dark ? const Color(0xFF262A2C) : Palette.greenSoft,
              foreground: Palette.green,
            )
          else if (controller.source.supportsCopyImage)
            _roundIcon(
              icon: Icons.content_copy_rounded,
              tooltip: '复制图片（可直接粘贴到聊天窗口；本机没有原图时复制缩略图）',
              onTap: enabled ? onCopy : null,
              background: dark ? const Color(0xFF262A2C) : Palette.greenSoft,
              foreground: Palette.green,
            ),
          _roundIcon(
            icon: Icons.delete_outline_rounded,
            tooltip: enabled ? '删除记录' : '正在扫描/同步，完成后再操作',
            onTap: enabled ? onDelete : null,
            foreground: dark ? Palette.darkTextDim : Palette.textDim,
          ),
        ],
      ),
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      decoration: BoxDecoration(
        color: flashing
            ? (dark ? const Color(0xFF1C3A2A) : const Color(0xFFE8FBEF))
            : (dark ? Palette.darkCard : Palette.card),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: flashing
              ? Palette.green
              : (dark ? Palette.darkLine : Palette.line),
          width: flashing ? 1.2 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onEdit : null,
          child: content,
        ),
      ),
    );
  }

  /// 行内圆形小按钮。窄模式缩到 30×30：一列 360px 里，
  /// 缩略图 + 金额 + 两个按钮要挤在一行。
  Widget _roundIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    required Color foreground,
    Color? background,
  }) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: compact ? 17 : 18),
      style: IconButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        minimumSize: Size.square(compact ? 30 : 34),
        padding: EdgeInsets.zero,
      ),
    );
  }

  static String _formatTime(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }
}

extension on String {
  bool get isNotBlank => trim().isNotEmpty;
}
