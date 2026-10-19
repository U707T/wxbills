import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/ocr/amount_reader.dart';

/// 用 18 张真实微信收款单回归测试识别器。
///
/// 样图来自原 Android 版 `src/test/resources/raw`，格式：
///   int32 width, int32 height, 然后 width*height 个 ARGB int（大端）。
/// 之所以不用 PNG：这份数据与 Kotlin 版逐字节相同，能证明移植没有偏差。
/// 这些文件只参与测试，不会打进 APK。
class _Sample {
  _Sample(this.name, this.rgba, this.w, this.h);
  final String name;
  final Uint8List rgba;
  final int w;
  final int h;
}

List<_Sample> _loadAll() {
  final dir = Directory('test/fixtures/raw');
  expect(dir.existsSync(), isTrue, reason: '样图目录不存在: ${dir.path}');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.raw.gz'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files.map((f) {
    final raw = Uint8List.fromList(gzip.decode(f.readAsBytesSync()));
    final data = ByteData.sublistView(raw);
    final w = data.getInt32(0);
    final h = data.getInt32(4);
    final rgba = Uint8List(w * h * 4);
    var o = 0;
    for (var i = 0; i < w * h; i++) {
      final argb = data.getInt32(8 + i * 4);
      rgba[o++] = (argb >> 16) & 0xFF;
      rgba[o++] = (argb >> 8) & 0xFF;
      rgba[o++] = argb & 0xFF;
      rgba[o++] = (argb >> 24) & 0xFF;
    }
    final name = f.path.split(Platform.pathSeparator).last
        .replaceAll('.raw.gz', '');
    return _Sample(name, rgba, w, h);
  }).toList();
}

Map<String, String> _truth() {
  final text = File('test/fixtures/raw/truth.json').readAsStringSync();
  final map = jsonDecode(text) as Map<String, dynamic>;
  return map.map((k, v) => MapEntry(k.replaceAll('.png', ''), '$v'));
}

bool _sameAmount(String? got, String exp) {
  if (got == null) return false;
  final g = double.tryParse(got.endsWith('.')
      ? got.substring(0, got.length - 1)
      : got);
  final e = double.tryParse(exp);
  if (g == null || e == null) return false;
  return (g - e).abs() < 1e-9;
}

void main() {
  test('18 张真实收款单全部识别正确', () {
    final samples = _loadAll();
    final expected = _truth();
    expect(samples.length, 18, reason: '样图数量不对');

    final failures = StringBuffer();
    var ok = 0;
    for (final s in samples) {
      final exp = expected[s.name];
      if (exp == null) {
        failures.writeln('  缺期望值: ${s.name}');
        continue;
      }
      final r = AmountReader.read(s.rgba, s.w, s.h);
      if (_sameAmount(r.text, exp)) {
        ok++;
        expect(r.confidence, greaterThanOrEqualTo(0.85),
            reason: '置信度过低 ${s.name}=${r.text}');
      } else {
        failures.writeln(
            '  ${s.name}: 期望 $exp 实际 ${r.text} conf=${r.confidence}');
      }
    }
    expect(ok, samples.length, reason: '识别失败:\n$failures');
  });

  test('缩到 50% 仍要认得出（相册里可能有压缩过的版本）', () {
    final samples = _loadAll();
    final expected = _truth();
    var ok = 0;
    var total = 0;
    final failures = StringBuffer();

    for (final s in samples) {
      final exp = expected[s.name];
      if (exp == null) continue;
      final w2 = s.w ~/ 2;
      final h2 = s.h ~/ 2;
      final small = Uint8List(w2 * h2 * 4);
      // 面积平均下采样
      for (var y = 0; y < h2; y++) {
        for (var x = 0; x < w2; x++) {
          var r = 0, g = 0, b = 0;
          for (var dy = 0; dy < 2; dy++) {
            for (var dx = 0; dx < 2; dx++) {
              final i = ((y * 2 + dy) * s.w + (x * 2 + dx)) * 4;
              r += s.rgba[i];
              g += s.rgba[i + 1];
              b += s.rgba[i + 2];
            }
          }
          final o = (y * w2 + x) * 4;
          small[o] = r ~/ 4;
          small[o + 1] = g ~/ 4;
          small[o + 2] = b ~/ 4;
          small[o + 3] = 255;
        }
      }
      final rr = AmountReader.read(small, w2, h2);
      total++;
      if (_sameAmount(rr.text, exp)) {
        ok++;
      } else {
        failures.writeln('  ${s.name}: 期望 $exp 实际 ${rr.text}');
      }
    }
    expect(ok, total, reason: '缩图后识别失败:\n$failures');
  });

  test('空白图不崩溃且返回空结果', () {
    final w = 400, h = 600;
    final blank = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
    final r = AmountReader.read(blank, w, h);
    expect(r.text, isNull);
    expect(r.ok, isFalse);
  });
}
