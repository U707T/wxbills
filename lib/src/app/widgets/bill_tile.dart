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

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final thumb = controller.thumbFileOf(bill);
    final amountColor = bill.amountCents == null
        ? (dark ? Palette.darkTextDim : Palette.textDim)
        : (dark ? Palette.darkText : Palette.text);

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ThumbView(file: thumb, size: 58),
          const SizedBox(width: 12),
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
                            size: 20,
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
            IconButton(
              onPressed: enabled ? onRefresh : null,
              tooltip: '刷新这张图片的日期（让 QQ/相册当成新图）',
              icon: const Icon(Icons.refresh_rounded, size: 18),
              style: IconButton.styleFrom(
                backgroundColor: dark ? const Color(0xFF262A2C) : Palette.greenSoft,
                foregroundColor: Palette.green,
                minimumSize: const Size(34, 34),
                padding: EdgeInsets.zero,
              ),
            )
          else if (controller.source.supportsCopyImage)
            IconButton(
              onPressed: enabled ? onCopy : null,
              tooltip: '复制图片（可直接粘贴到聊天窗口；本机没有原图时复制缩略图）',
              icon: const Icon(Icons.content_copy_rounded, size: 17),
              style: IconButton.styleFrom(
                backgroundColor: dark ? const Color(0xFF262A2C) : Palette.greenSoft,
                foregroundColor: Palette.green,
                minimumSize: const Size(34, 34),
                padding: EdgeInsets.zero,
              ),
            ),
          IconButton(
            onPressed: enabled ? onDelete : null,
            tooltip: enabled ? '删除记录' : '正在扫描/同步，完成后再操作',
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            style: IconButton.styleFrom(
              foregroundColor: dark ? Palette.darkTextDim : Palette.textDim,
              minimumSize: const Size(34, 34),
              padding: EdgeInsets.zero,
            ),
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
