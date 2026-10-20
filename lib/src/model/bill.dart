import 'dart:math';

/// 识别结果「够不够可信」的唯一阈值。
///
/// OCR 侧（[AmountResult.ok]）和界面侧（[Bill.needsReview] 的标黄）共用这一个数，
/// 不再各写一份——否则调阈值时必然只改一处，出现「标了待核对但 OCR 认为 OK」。
const double kConfidenceThreshold = 0.84;

/// 一张收款单。
///
/// 关键设计（相比原 Android 单机版）：
///  * [id] 是**跨设备稳定**的主键（随机生成，永不变），同步时用它配对；
///  * [path] 是**本机**定位（Android 是 `content://` 文档 URI，Windows 是绝对路径），
///    不同设备各不相同，所以只在本机有效、不参与合并判断；
///  * [updatedAt] 是最后修改时间（毫秒），同步时按它做「后写者胜」（LWW）合并；
///  * [deleted] 是墓碑：删除也要同步，否则另一台设备会把记录又推回来。
///  * [thumb] 是缩略图文件名（`<id>.jpg`），随记录一起同步，
///    这样另一台设备没有原图也能看到图。
class Bill {
  const Bill({
    required this.id,
    required this.name,
    required this.path,
    required this.amountCents,
    required this.confidence,
    required this.manual,
    required this.fileModified,
    required this.importedAt,
    required this.updatedAt,
    this.note = '',
    this.folder = '',
    this.deleted = false,
    this.thumb = '',
    this.photo = '',
  });

  final String id;
  final String name;

  /// 本机定位：Android 为 `content://…`，桌面为绝对路径。可为空（仅远端记录）。
  final String path;

  /// 金额，单位「分」。null 表示还没识别出来。
  final int? amountCents;
  final double confidence;

  /// 用户手工确认过金额/备注 —— 重新扫描时绝不能被自动结果覆盖。
  final bool manual;

  /// 原图修改时间（毫秒），用于「按时间排序」和增量扫描。
  final int fileModified;
  final int importedAt;

  /// 最后修改时间（毫秒），同步合并依据。
  final int updatedAt;

  final String note;

  /// 来源目录（本机配置里的文件夹 key），用于定位与「刷新日期」。
  final String folder;

  /// 墓碑标记：true 表示已删除，仅用于把删除同步出去。
  final bool deleted;

  /// 缩略图文件名（相对缩略图目录），空表示没有。
  final String thumb;

  /// **原图**在远端的文件名（`<id>.<ext>`，位于 `photos/` 目录），空表示还没传过。
  ///
  /// 与 [thumb] 一样随记录同步，但它是完整尺寸的原图：另一台设备下载后
  /// 才能「复制原图」「留着以后重识别」，而不是只能看一张 256px 的缩略图。
  /// 名字由 id + 原扩展名决定，两台设备算出来是同一个，所以不需要额外协调。
  final String photo;

  bool get hasAmount => amountCents != null;

  /// 金额的展示文本，如 `24.5` / `24.50`（保留两位小数但去掉多余的 0）。
  String get amountYuan => amountCents == null ? '' : formatCents(amountCents!);

  /// 金额数值（元）。
  double get amountValue => (amountCents ?? 0) / 100.0;

  /// 需要人工核对：识别成功但置信度不够。
  bool get needsReview =>
      !manual && amountCents != null && confidence < kConfidenceThreshold;

  Bill copyWith({
    String? name,
    String? path,
    Object? amountCents = _sentinel,
    double? confidence,
    bool? manual,
    int? fileModified,
    int? importedAt,
    int? updatedAt,
    String? note,
    String? folder,
    bool? deleted,
    String? thumb,
    String? photo,
  }) {
    return Bill(
      id: id,
      name: name ?? this.name,
      path: path ?? this.path,
      amountCents: amountCents == _sentinel ? this.amountCents : amountCents as int?,
      confidence: confidence ?? this.confidence,
      manual: manual ?? this.manual,
      fileModified: fileModified ?? this.fileModified,
      importedAt: importedAt ?? this.importedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      note: note ?? this.note,
      folder: folder ?? this.folder,
      deleted: deleted ?? this.deleted,
      thumb: thumb ?? this.thumb,
      photo: photo ?? this.photo,
    );
  }

  /// 序列化（键名刻意短：一次同步要传几百条记录）。
  Map<String, Object?> toJson() => {
        'id': id,
        'n': name,
        'p': path,
        'a': amountCents,
        'c': confidence,
        'm': manual ? 1 : 0,
        'fm': fileModified,
        'ia': importedAt,
        'u': updatedAt,
        'nt': note,
        'fd': folder,
        'd': deleted ? 1 : 0,
        't': thumb,
        'ph': photo,
      };

  /// 只接受 `<id>.<ext>` / `<id>.jpg` 这种纯文件名的形态。
  ///
  /// 记录是从网盘下载的 JSON，`t` / `ph` 会被直接拿去拼本机路径
  /// （`thumbs/…`、`media/…`）。放一个 `../../…` 进来就能写到应用目录之外，
  /// 所以在这里就把不像文件名的值丢掉，宁可显示占位图。
  static final RegExp _safeFileName = RegExp(r'^[A-Za-z0-9_-]{1,64}\.[A-Za-z0-9]{1,5}$');

  static String _fileNameOrEmpty(Object? raw) {
    final name = '${raw ?? ''}';
    return _safeFileName.hasMatch(name) ? name : '';
  }

  static Bill fromJson(Map<String, Object?> j) {
    final a = j['a'];
    return Bill(
      id: '${j['id'] ?? ''}',
      name: '${j['n'] ?? ''}',
      path: '${j['p'] ?? ''}',
      amountCents: a is num ? a.toInt() : null,
      confidence: (j['c'] as num?)?.toDouble() ?? 0,
      manual: (j['m'] as num?)?.toInt() == 1,
      fileModified: (j['fm'] as num?)?.toInt() ?? 0,
      importedAt: (j['ia'] as num?)?.toInt() ?? 0,
      updatedAt: (j['u'] as num?)?.toInt() ?? 0,
      note: '${j['nt'] ?? ''}',
      folder: '${j['fd'] ?? ''}',
      deleted: (j['d'] as num?)?.toInt() == 1,
      thumb: _fileNameOrEmpty(j['t']),
      photo: _fileNameOrEmpty(j['ph']),
    );
  }

  @override
  String toString() => 'Bill($id, $name, ¥$amountYuan)';

  // ---------------------------------------------------------------- 金额格式化

  /// 分 → 元文本。整数金额不带小数点，其余最多两位。
  static String formatCents(int cents) {
    final neg = cents < 0;
    final v = cents.abs();
    final yuan = v ~/ 100;
    final fen = v % 100;
    final body = fen == 0
        ? '$yuan'
        : '$yuan.${fen < 10 ? '0$fen' : '$fen'}';
    return neg ? '-$body' : body;
  }

  /// 元 → 分。非法 / 非有限数 / 超范围返回 null。
  ///
  /// 这是全项目唯一的「元转分」入口：扫描、手动编辑、OCR 都走它，
  /// 免得三处各写一遍 `.round()` 导致同一条记录在不同路径下差一分。
  static int? centsFromYuan(double? yuan) {
    if (yuan == null || !yuan.isFinite) return null;
    if (yuan < 0 || yuan > 9999999) return null;
    return (yuan * 100).round();
  }

  /// 只接受「1 / 1.5 / 12.34」这类金额文本，最多 7 位整数 + 2 位小数。
  /// 挡住 `1e3`、`NaN`（`double.tryParse('NaN')` 会成功并让 `.round()` 抛异常）。
  static final RegExp _yuanPattern = RegExp(r'^(?:\d{1,7}(?:\.\d{1,2})?|\.\d{1,2})$');

  /// 元文本 → 分。非法返回 null。
  static int? parseYuan(String text) {
    final t = text
        .trim()
        .replaceAll('¥', '')
        .replaceAll('￥', '')
        .replaceAll(',', '')
        .replaceAll(' ', '');
    if (t.isEmpty) return null;
    if (!_yuanPattern.hasMatch(t)) return null;
    return centsFromYuan(double.tryParse(t));
  }
}

const Object _sentinel = Object();

/// 同步合并：同一 id 的两条记录，谁说了算。
///
/// 两条规则，顺序固定：
///  1. **删除优先**：一方删除、一方修改时，删除胜。否则「手机删掉、电脑上顺手改个
///     备注」就会把记录复活，用户只会认为删除功能坏了。
///  2. 都没删（或都删了）时取 [updatedAt] 更新的那条；平手按「信息更多者优先」
///     兜底（有金额 > 无金额，手动 > 自动），保证两端独立操作后仍收敛到同一结果。
Bill mergeBill(Bill local, Bill remote) {
  if (local.deleted != remote.deleted) return local.deleted ? local : remote;
  if (remote.updatedAt != local.updatedAt) {
    return remote.updatedAt > local.updatedAt ? remote : local;
  }
  if ((local.amountCents == null) != (remote.amountCents == null)) {
    return local.amountCents == null ? remote : local;
  }
  if (local.manual != remote.manual) return local.manual ? local : remote;
  if (local.note.length != remote.note.length) {
    return remote.note.length > local.note.length ? remote : local;
  }
  // 完全平手：用 id 之外的稳定字段做最终裁决，保证两端一致
  return local.name.compareTo(remote.name) <= 0 ? local : remote;
}

/// 生成随机 id（16 字节 hex），不引入额外依赖。
String newId([Random? random]) {
  final r = random ?? Random.secure();
  final sb = StringBuffer();
  for (var i = 0; i < 16; i++) {
    sb.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
