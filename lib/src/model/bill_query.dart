import 'bill.dart';

/// 搜索框的查询语义 —— **筛选和「定位」共用这一份**，别在两处各写一套判断。
///
/// 分两类：
///
///  * **金额查询**（只有数字和最多一个小数点，如 `66`、`66.`、`66.5`）：
///    把输入当成「十进制前缀」，换算成一个金额区间再比。
///    `66` → ¥66.00 ~ ¥66.99（¥66 / ¥66.5 / ¥66.05 都算），
///    `66.5` → ¥66.50 ~ ¥66.59，`66.55` → 只有 ¥66.55。输入越完整筛得越窄。
///  * **文字查询**：名称 / 备注包含，或金额文本包含（`¥66`、`66元` 这类）。
///
/// 为什么不用「金额文本前缀」或「字符串包含」：
///  * 字符串包含会把 ¥660 / ¥166 也算成 `66`（「输入 `1` 命中一大片」的老毛病）；
///  * 文本前缀在「记录里的 ¥1 显示成 `1`，用户却输入 `1.0` / `1.00`」时失效。
///    区间按十进制位对齐，两种写法都自然成立。
///
/// 金额查询一个都没命中时，调用方**不要**把列表筛空：「定位」还要靠全量列表
/// 跳到最接近的那张，界面用 [missHint] 说明"没有这个金额"。
class BillQuery {
  BillQuery(String raw) : text = raw.trim();

  /// 去掉首尾空格的输入原文。
  final String text;

  bool get isEmpty => text.isEmpty;

  /// 是不是「金额查询」。
  ///
  /// 不复用 [Bill.parseYuan]：`66.` / `.5` 解析不成完整金额，但用户正打到一半，
  /// 按金额筛是合理的（以前这类输入会掉进文字分支，用 `contains` 匹配金额）。
  bool get isAmount => _amountLike.hasMatch(text);

  static final RegExp _amountLike =
      RegExp(r'^(?:\d{1,7}(?:\.\d{0,2})?|\.\d{1,2})$');

  /// 输入代表的金额区间（分，左闭右开）；不是金额查询时为 null。
  ///
  /// `66` → `[6600, 6700)`；`66.5` → `[6650, 6660)`；`66.55` → `[6655, 6656)`。
  late final (int lo, int hi)? range = _parseRange();

  /// 区间下界：`66` → 6600 分。给「定位」当目标金额用。
  int? get cents => range?.$1;

  (int lo, int hi)? _parseRange() {
    if (!isAmount) return null;
    var t = text;
    if (t.startsWith('.')) t = '0$t'; // `.5` 就是 0.5x
    if (t.endsWith('.')) t = t.substring(0, t.length - 1); // `66.` 还没打完，等同 `66`
    final dot = t.indexOf('.');
    final intPart = dot < 0 ? t : t.substring(0, dot);
    final fracPart = dot < 0 ? '' : t.substring(dot + 1);
    final n = int.tryParse('$intPart$fracPart');
    if (n == null) return null;
    // 输入到第几位小数，就按 10^(2-位数) 分对齐：0 位 → 1 元一档，1 位 → 1 角一档
    final scale = switch (fracPart.length) {
      0 => 100,
      1 => 10,
      _ => 1,
    };
    final lo = n * scale;
    return (lo, lo + scale);
  }

  /// 给用户看的金额文本。
  ///
  /// 走 [Bill.formatCents]，和列表里显示的金额完全一致：`0000066` / `.5`
  /// 分别规整成 `66` / `0.50`，别把用户的原始输入直接塞进提示里。
  String get display => cents == null ? text : Bill.formatCents(cents!);

  /// 按查询类型分派：金额查询走区间，其余走文字匹配。
  ///
  /// 收成一个入口，省得调用方自己按 [isAmount] 分派、分派错了还没人发现。
  bool matches(Bill b) => isAmount ? matchesAmount(b) : matchesText(b);

  /// 金额查询：这条记录的金额是否落在输入代表的区间里。
  ///
  /// 未识别（金额为 null）的记录永远不命中 —— 它们没有金额可比。
  bool matchesAmount(Bill b) {
    final r = range;
    final c = b.amountCents;
    if (r == null || c == null) return false;
    return c >= r.$1 && c < r.$2;
  }

  /// 文字查询：名称 / 备注 / 金额文本包含。
  ///
  /// 小写只算一次：这条会被每个记录调一遍，500 条时每帧 toLowerCase 500 次
  /// 纯属白给。
  late final String _lower = text.toLowerCase();

  bool matchesText(Bill b) {
    return b.name.toLowerCase().contains(_lower) ||
        b.note.toLowerCase().contains(_lower) ||
        b.amountYuan.contains(text);
  }

  /// 金额查询一个都没命中时给界面的说明；其它情况为空串。
  String get missHint => '没有 ¥$display 的记录';
}
