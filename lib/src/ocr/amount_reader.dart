import 'dart:typed_data';

import 'digit_templates.dart';

/// 微信收款单金额识别器（专用，不是通用 OCR）。
///
/// 版式固定：顶部绿色 + 白色卡片，卡片上部是「¥ XX.XX」，下面一行是备注，再下面是二维码。
/// 所以只需要：
///   1. 在固定比例带里找「墨迹行」（三通道都很暗的像素）；
///   2. 按列投影切成字符块，丢掉最左边的 ¥；
///   3. 每个块按真实宽高比缩到 25px 高，与 0-9 的 25xW 模板逐像素比对。
///
/// 本文件是原 Android 版 `AmountReader.kt` 的逐行移植（纯 Dart，无平台依赖）：
/// 输入从 ARGB int 数组改成 RGBA 字节流，算法与阈值完全一致，
/// 因此两端识别结果相同（见 test/amount_reader_test.dart 的 18 张真实样图回归）。
class AmountReader {
  AmountReader._();

  /// 低于这个置信度就标「待核对」。
  static const double confidenceThreshold = 0.80;

  /// 识别 [rgba]（每像素 4 字节，R/G/B/A）尺寸为 [width] x [height] 的图。
  static AmountResult read(Uint8List rgba, int width, int height) {
    if (width < 60 || height < 80) return AmountResult.empty;
    final direct = _readBody(rgba, width, height);
    if (direct.text != null) return direct;

    // 低分辨率兜底：字形太小时先放大再认（与原 Kotlin 版同样的倍数规则）
    final factor = width < 500
        ? 4
        : width < 900
            ? 3
            : width < 1600
                ? 2
                : 1;
    if (factor == 1) return direct;
    final big = _scaleUp(rgba, width, height, factor);
    return _readBody(big.pixels, big.width, big.height);
  }

  // ---------------------------------------------------------------- 主流程

  static AmountResult _readBody(Uint8List px, int w, int h) {
    final y0 = (h * 0.15).toInt();
    final y1 = (h * 0.30).toInt();
    final x0 = (w * 0.08).toInt();
    final x1 = (w * 0.92).toInt();
    final rw = x1 - x0;
    if (rw <= 8 || y1 <= y0) return AmountResult.empty;

    // 1) 逐行统计暗像素
    final rowInk = Int32List(h);
    for (var y = y0; y < y1; y++) {
      var c = 0;
      var idx = (y * w + x0) * 4;
      for (var x = 0; x < rw; x++) {
        if (_isInk(px, idx)) c++;
        idx += 4;
      }
      rowInk[y] = c;
    }

    // 2) 行连通带里取最高的一条
    var bestTop = -1;
    var bestBot = -1;
    var start = -1;
    var prev = -1;
    for (var y = y0; y < y1; y++) {
      if (rowInk[y] > 0) {
        if (start < 0) start = y;
        prev = y;
      } else if (start >= 0) {
        if (prev - start > bestBot - bestTop) {
          bestTop = start;
          bestBot = prev;
        }
        start = -1;
      }
    }
    if (start >= 0 && prev - start > bestBot - bestTop) {
      bestTop = start;
      bestBot = prev;
    }
    if (bestTop < 0) return AmountResult.empty;

    final gh = bestBot - bestTop + 1;
    if (gh < h * 0.02) return AmountResult.empty;

    // 3) 列投影切块
    final colInk = Int32List(rw);
    for (var x = 0; x < rw; x++) {
      var c = 0;
      var idx = (bestTop * w + x0 + x) * 4;
      for (var y = bestTop; y <= bestBot; y++) {
        if (_isInk(px, idx)) c++;
        idx += w * 4;
      }
      colInk[x] = c;
    }

    final starts = <int>[];
    final ends = <int>[];
    var s = -1;
    var p = -1;
    final gap = _imax(3, (gh * 0.07).toInt());
    for (var x = 0; x < rw; x++) {
      if (colInk[x] > 0) {
        if (s < 0) {
          s = x;
        } else if (x - p > gap) {
          starts.add(s);
          ends.add(p);
          s = x;
        }
        p = x;
      }
    }
    if (s >= 0) {
      starts.add(s);
      ends.add(p);
    }
    if (starts.length < 2) return AmountResult.empty;

    // 4) 跳过开头的 ¥，逐块解码
    final digitW = gh * 0.72;
    final sb = StringBuffer();
    var minConf = 1.0;

    var i = 1;
    while (i < starts.length) {
      final cs = x0 + starts[i];
      final ce = x0 + ends[i];
      final bw = ce - cs + 1;
      // 小数点：墨迹高度远小于行高（实测 10/58）。不能只看宽度——「1」也很窄。
      final bh = _inkHeight(px, w, bestTop, bestBot, cs, ce);
      if (bh < gh * 0.40 && i + 1 < starts.length) {
        sb.write('.');
        i++;
        continue;
      }
      final n = _imax(1, (bw / digitW).round());
      if (n <= 1) {
        final r = _decodeDigit(px, w, bestTop, bestBot, cs, ce);
        if (r.char != null) sb.write(r.char);
        minConf = _dmin(minConf, r.confidence);
      } else {
        final step = bw / n;
        for (var k = 0; k < n; k++) {
          final a = cs + (k * step).round();
          final b = cs + ((k + 1) * step).round() - 1;
          if (b <= a) continue;
          final r = _decodeDigit(px, w, bestTop, bestBot, a, b);
          if (r.char != null) sb.write(r.char);
          minConf = _dmin(minConf, r.confidence);
        }
      }
      i++;
    }

    final text = sb.toString();
    if (text.isEmpty) return AmountResult.empty;
    final value = double.tryParse(
        text.endsWith('.') ? text.substring(0, text.length - 1) : text);
    return AmountResult(text: text, confidence: minConf, value: value);
  }

  // ---------------------------------------------------------------- 工具

  static bool _isInk(Uint8List px, int i) =>
      px[i] < 120 && px[i + 1] < 120 && px[i + 2] < 120;

  static int _inkHeight(Uint8List px, int w, int top, int bot, int cs, int ce) {
    var t = 1 << 30;
    var b = -1;
    for (var y = top; y <= bot; y++) {
      var idx = (y * w + cs) * 4;
      var hit = false;
      for (var x = cs; x <= ce; x++) {
        if (_isInk(px, idx)) {
          hit = true;
          break;
        }
        idx += 4;
      }
      if (hit) {
        if (y < t) t = y;
        b = y;
      }
    }
    return b < 0 ? 0 : b - t + 1;
  }

  /// 把一个字符块缩到 25px 高后与各数字模板比对，返回（字符, 置信度）
  static _DigitResult _decodeDigit(
      Uint8List px, int w, int top, int bot, int cs, int ce) {
    var t = 1 << 30;
    var b = -1;
    for (var y = top; y <= bot; y++) {
      var idx = (y * w + cs) * 4;
      var hit = false;
      for (var x = cs; x <= ce; x++) {
        if (_isInk(px, idx)) {
          hit = true;
          break;
        }
        idx += 4;
      }
      if (hit) {
        if (y < t) t = y;
        b = y;
      }
    }
    if (b < t) return const _DigitResult(null, 0);

    final sh = b - t + 1;
    final sw = ce - cs + 1;
    if (sh < 4 || sw < 2) return const _DigitResult(null, 0);

    final tw = _imax(4, (sw / sh * kTemplateHeight).round());
    if (tw > 90) return const _DigitResult(null, 0);

    final probe = Float32List(kTemplateHeight * tw);
    for (var ty = 0; ty < kTemplateHeight; ty++) {
      final sy0 = t + ty * sh ~/ kTemplateHeight;
      // 上界必须夹在字形里，否则会采到相邻字符的像素，影响判别
      final sy1 =
          _imin(b + 1, _imax(sy0 + 1, t + (ty + 1) * sh ~/ kTemplateHeight));
      for (var tx = 0; tx < tw; tx++) {
        final sx0 = cs + tx * sw ~/ tw;
        final sx1 = _imin(ce + 1, _imax(sx0 + 1, cs + (tx + 1) * sw ~/ tw));
        var sum = 0.0;
        var cnt = 0;
        for (var y = sy0; y < sy1; y++) {
          var idx = (y * w + sx0) * 4;
          for (var x = sx0; x < sx1; x++) {
            if (_isInk(px, idx)) sum += 1;
            cnt++;
            idx += 4;
          }
        }
        probe[ty * tw + tx] = cnt > 0 ? sum / cnt : 0;
      }
    }

    String? bestC;
    var bestV = -1.0;
    for (final entry in kGlyphs.entries) {
      // 只比对数字模板（¥ 与小数点已在切块阶段处理掉）
      if (entry.key == 'Y' || entry.key == '.') continue;
      final tpl = _template(entry.key, tw);
      var acc = 0.0;
      for (var k = 0; k < probe.length; k++) {
        final d = probe[k] - tpl[k];
        acc += 1 - (d < 0 ? -d : d);
      }
      final v = acc / probe.length;
      if (v > bestV) {
        bestV = v;
        bestC = entry.key;
      }
    }
    return _DigitResult(bestC, bestV);
  }

  /// 模板缓存：key = 字符 code * 100 + 目标宽度
  static final Map<int, Float32List> _templateCache = {};

  /// 把位掩码模板采样到指定宽度（0..1）
  static Float32List _template(String ch, int tw) {
    final key = ch.codeUnitAt(0) * 100 + tw;
    final cached = _templateCache[key];
    if (cached != null) return cached;

    final rows = kGlyphs[ch]!.rows;
    var maxCol = 0;
    for (final bits in rows) {
      var v = bits;
      var c = 0;
      while (v != 0) {
        c++;
        v >>= 1;
      }
      if (c > maxCol) maxCol = c;
    }
    final sw = _imax(1, maxCol);

    final out = Float32List(kTemplateHeight * tw);
    for (var ty = 0; ty < kTemplateHeight; ty++) {
      final bits = rows[ty];
      for (var tx = 0; tx < tw; tx++) {
        final sx0 = tx * sw ~/ tw;
        final sx1 = _imax(sx0 + 1, (tx + 1) * sw ~/ tw);
        var hit = 0;
        for (var sx = sx0; sx < _imin(sx1, sw); sx++) {
          if ((bits >> sx) & 1 == 1) hit++;
        }
        out[ty * tw + tx] = hit / (sx1 - sx0);
      }
    }
    _templateCache[key] = out;
    return out;
  }

  /// 双线性放大（对应 Kotlin 版 `Bitmap.createScaledBitmap(..., filter=true)`）。
  static _Raster _scaleUp(Uint8List px, int w, int h, int factor) {
    final nw = w * factor;
    final nh = h * factor;
    final out = Uint8List(nw * nh * 4);
    for (var y = 0; y < nh; y++) {
      final sy = (y + 0.5) / factor - 0.5;
      final y0 = sy.floor().clamp(0, h - 1);
      final y1 = (y0 + 1).clamp(0, h - 1);
      final fy = (sy - y0).clamp(0.0, 1.0);
      for (var x = 0; x < nw; x++) {
        final sx = (x + 0.5) / factor - 0.5;
        final x0 = sx.floor().clamp(0, w - 1);
        final x1 = (x0 + 1).clamp(0, w - 1);
        final fx = (sx - x0).clamp(0.0, 1.0);
        final i00 = (y0 * w + x0) * 4;
        final i10 = (y0 * w + x1) * 4;
        final i01 = (y1 * w + x0) * 4;
        final i11 = (y1 * w + x1) * 4;
        final o = (y * nw + x) * 4;
        for (var c = 0; c < 3; c++) {
          final top = px[i00 + c] * (1 - fx) + px[i10 + c] * fx;
          final bottom = px[i01 + c] * (1 - fx) + px[i11 + c] * fx;
          out[o + c] = (top * (1 - fy) + bottom * fy).round().clamp(0, 255);
        }
        out[o + 3] = 255;
      }
    }
    return _Raster(out, nw, nh);
  }

  static int _imax(int a, int b) => a > b ? a : b;
  static int _imin(int a, int b) => a < b ? a : b;
  static double _dmin(double a, double b) => a < b ? a : b;
}

/// 识别结果。
class AmountResult {
  const AmountResult({this.text, required this.confidence, this.value});

  /// 识别出的文本，如 `24.50`；null 表示没认出来。
  final String? text;
  final double confidence;

  /// 解析后的元值；无法解析时为 null。
  final double? value;

  /// 是否达到可用置信度。
  bool get ok => text != null && confidence >= AmountReader.confidenceThreshold;

  static const AmountResult empty =
      AmountResult(text: null, confidence: 0, value: null);

  @override
  String toString() => 'AmountResult($text, conf=$confidence)';
}

class _DigitResult {
  const _DigitResult(this.char, this.confidence);
  final String? char;
  final double confidence;
}

class _Raster {
  const _Raster(this.pixels, this.width, this.height);
  final Uint8List pixels;
  final int width;
  final int height;
}
