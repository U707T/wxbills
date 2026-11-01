import 'dart:io';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 内容最大宽度约束（桌面端避免一行拉太宽）。
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.max = Dimens.maxContentWidth});

  final Widget child;
  final double max;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: max),
        child: child,
      ),
    );
  }
}

/// 通用卡片容器。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
    this.radius = Dimens.cardRadius,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? Palette.darkCard : Palette.card;
    // 用 Material 承载背景而不是 DecoratedBox：卡片里会有 ListTile / InkWell，
    // 它们把涟漪画在最近的 Material 上，外面套 DecoratedBox 会把效果盖掉
    // （Flutter 会直接报 "ListTile background color or ink splashes may be invisible"）。
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: dark ? Palette.darkLine : Palette.line,
            width: 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 小圆角标签（「手动」「待核对」这类状态）。
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.text,
    required this.color,
    this.dense = false,
  });

  final String text;
  final Color color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 1.5 : 2.5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: dense ? 10.5 : 11.5,
          color: color,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
      ),
    );
  }
}

/// 顶部标题栏（绿色渐变，与原版一致）。
class GreenHeader extends StatelessWidget {
  const GreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.actions = const [],
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> actions;

  /// 窄模式：标题小一号、上下留白收窄，副标题强制一行（放不下就省略）。
  ///
  /// 副标题里是「共 N 张 · 合计 ¥X」，窄窗口下也必须有 —— 那是这屏最重要的
  /// 信息，宁可省略号也不能像之前那样整段换行把头部撑成三行。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      padding: compact
          ? EdgeInsets.fromLTRB(12, 8 + top, 6, 8)
          : EdgeInsets.fromLTRB(18, 14 + top, 12, 14),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Palette.green, Palette.greenDark],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 17 : 19,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                if (subtitle != null) ...[
                  SizedBox(height: compact ? 2 : 4),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: const Color(0xCCFFFFFF),
                      fontSize: compact ? 11.5 : 12.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
          ...actions,
        ],
      ),
    );
  }
}

/// 顶部图标按钮（绿色头部上用）。
class HeaderIconButton extends StatelessWidget {
  const HeaderIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.compact = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  /// 窄模式：34×34（默认 40×40），一行才排得下三个图标 + 标题。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final side = compact ? 34.0 : 40.0;
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, color: Colors.white, size: compact ? 19 : 21),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: side, height: side),
    );
  }
}

/// 「更多」菜单里的一项。
class HeaderMenuEntry {
  const HeaderMenuEntry({
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
}

/// 绿色头部右侧的「更多」菜单。
///
/// 窄模式下一行只有 360px：标题和副标题要占掉一半，剩下的位置放不下四个
/// 图标按钮。与其让按钮挤成一团，不如像 QQ 那样把低频入口（重新识别 /
/// 贴顶）收进菜单，头部只留「同步 + 设置 + 更多」。
class HeaderMenuButton extends StatelessWidget {
  const HeaderMenuButton({
    super.key,
    required this.entries,
    this.compact = false,
  });

  final List<HeaderMenuEntry> entries;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final side = compact ? 34.0 : 40.0;
    return PopupMenuButton<int>(
      tooltip: '更多',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      icon: Icon(Icons.more_vert, color: Colors.white),
      iconSize: compact ? 19 : 21,
      // 注意 `constraints` 是**菜单**的约束，不是按钮的：写在这里会把弹出来的
      // 菜单挤成 34px 宽（每一项都溢出）。按钮尺寸要走 style。
      style: IconButton.styleFrom(
        minimumSize: Size.square(side),
        maximumSize: Size.square(side),
        padding: EdgeInsets.zero,
      ),
      onSelected: (index) => entries[index].onSelected(),
      itemBuilder: (_) => [
        for (var i = 0; i < entries.length; i++)
          PopupMenuItem<int>(
            value: i,
            height: 42,
            child: Row(
              children: [
                Icon(entries[i].icon, size: 18, color: Palette.textDim),
                const SizedBox(width: 10),
                Text(entries[i].label, style: const TextStyle(fontSize: 13.5)),
              ],
            ),
          ),
      ],
    );
  }
}

/// 进度条 + 文案（扫描 / 同步时显示在列表上方）。
class BusyBar extends StatelessWidget {
  const BusyBar({
    super.key,
    required this.label,
    required this.fraction,
    this.onCancel,
  });

  final String label;
  final double fraction;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? Palette.darkCard : const Color(0xFFF0FFF6);
    final fg = dark ? Palette.green : Palette.greenDark;
    final track = dark ? Palette.darkLine : const Color(0xFFD7F2E3);
    return Container(
      color: bg,
      padding: const EdgeInsets.fromLTRB(16, 9, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onCancel != null)
                GestureDetector(
                  onTap: onCancel,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text('停止',
                        style: TextStyle(fontSize: 12, color: fg)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction <= 0 ? null : fraction,
              minHeight: 4,
              backgroundColor: track,
              valueColor: const AlwaysStoppedAnimation(Palette.green),
            ),
          ),
        ],
      ),
    );
  }
}

/// 空状态占位。
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: dark ? Palette.darkTextDim : Palette.textDim),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: dark ? Palette.darkText : Palette.text,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 6),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: dark ? Palette.darkTextDim : Palette.textDim,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 缩略图：本地文件优先，没有则占位图标。
class ThumbView extends StatelessWidget {
  const ThumbView({
    super.key,
    required this.file,
    this.size = 56,
    this.radius = 9,
  });

  final File? file;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF262A2C)
            : Palette.greenSoft,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.receipt_long_outlined,
          size: size * 0.42, color: Palette.green),
    );
    final f = file;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: f == null
            ? placeholder
            : Image.file(
                f,
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: (size * 3).round(),
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// 顶部/底部通用的「分段选择」（排序切换）。
class SegmentedBar<T> extends StatelessWidget {
  const SegmentedBar({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });

  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF262A2C) : const Color(0xFFEDEFF1),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(values[i]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: values[i] == selected
                        ? (dark ? const Color(0xFF3A3E40) : Colors.white)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    boxShadow: values[i] == selected
                        ? const [
                            BoxShadow(
                              color: Color(0x14000000),
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            )
                          ]
                        : null,
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: values[i] == selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: values[i] == selected
                          ? (dark ? Palette.darkText : Palette.text)
                          : (dark ? Palette.darkTextDim : Palette.textDim),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 底部/工具栏按钮。
class ActionButton extends StatelessWidget {
  const ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.busy = false,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool busy;

  /// 只变灰、不转圈：用于「别的任务在跑，这个按钮现在按了也没用」。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // 用 LayoutBuilder 而不是让调用方传「窄不窄」：同一行里的按钮宽度取决于
    // 有几个按钮、外层卡片留白多少，写死一个标志位总有一处对不上。
    return LayoutBuilder(builder: (context, constraints) {
      // 放不下「图标 + 中文标签」时只留图标，标签挂到 tooltip 上。
      // 窄模式设置页那一行三个按钮正好落在 96px 上下，硬撑只会挤成省略号。
      final iconOnly = constraints.maxWidth < 104;
      final style = FilledButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: EdgeInsets.symmetric(horizontal: iconOnly ? 0 : 10),
        backgroundColor: primary ? Palette.green : null,
        foregroundColor: primary ? Colors.white : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );
      // 自己拼 Row 而不是用 *.icon 构造：那些构造里的标签不可压缩，
      // 宽度差几个像素就直接 RenderFlex overflow（黄黑条）。
      final content = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, size: 17),
          if (!iconOnly) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ],
      );
      final onTap = (busy || !enabled) ? null : onPressed;
      final button = primary
          ? FilledButton(onPressed: onTap, style: style, child: content)
          : FilledButton.tonal(onPressed: onTap, style: style, child: content);
      return SizedBox(
        width: double.infinity,
        child: iconOnly ? Tooltip(message: label, child: button) : button,
      );
    });
  }
}
