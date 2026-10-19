import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wxbills/src/ocr/amount_reader.dart';
import 'package:wxbills/src/platform/photo_source.dart';

/// 样图格式：int32 width, int32 height, 然后 width*height 个 ARGB int（大端）。
class _Sample {
  _Sample(this.name, this.rgba, this.w, this.h);
  final String name;
  final Uint8List rgba;
  final int w;
  final int h;
}

List<_Sample> _loadAll() {
  final dir = Directory('test/fixtures/raw');
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
    final name = f.path.split(Platform.pathSeparator).last.replaceAll('.raw.gz', '');
    return _Sample(name, rgba, w, h);
  }).toList();
}

/// 在图片上方插入 [pad] 像素纯色带，模拟状态栏 / 长截图多出来的顶部内容。
Uint8List _padTop(_Sample s, int pad) {
  final out = Uint8List(s.w * (s.h + pad) * 4)..fillRange(0, s.w * pad * 4, 255);
  out.setRange(s.w * pad * 4, out.length, s.rgba);
  return out;
}

void main() {
  // 这条测试守的是「识别不依赖固定版式比例」：
  // 以前识别区被钉在图像高度的 15%~30%，截图一旦带状态栏 / 多出顶部内容，
  // 金额整片落在窗外，表现为「所有图都未识别」。
  test('金额不在图像 15%~30% 高度时也要认得出（状态栏 / 长截图）', () {
    final truth = (jsonDecode(File('test/fixtures/raw/truth.json').readAsStringSync()) as Map)
        .map((k, v) => MapEntry('$k'.replaceAll('.png', ''), '$v'));
    final samples = _loadAll();
    expect(samples, isNotEmpty);

    for (final pad in [0, 120, 200, 300, 400]) {
      final missed = <String>[];
      for (final s in samples) {
        final rgba = pad == 0 ? s.rgba : _padTop(s, pad);
        final r = AmountReader.read(rgba, s.w, s.h + pad);
        if (r.text != truth[s.name]) missed.add('${s.name}=${r.text}');
      }
      expect(missed, isEmpty,
          reason: '顶部多出 ${pad}px 后有 ${missed.length} 张识别失败：${missed.take(5).join(', ')}');
    }
  });

  test('纯色图（顶部留白过大）不会误报金额', () {
    final w = 400, h = 700;
    final blank = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
    final r = AmountReader.read(blank, w, h);
    expect(r.text, isNull);
  });

  // Android 的第二条读图路线（原生只回原始字节、Dart 自己解码）走的就是
  // decodeBytesForOcr。这条测试保证它和桌面路径给出相同的识别结果。
  test('PNG 字节 → decodeBytesForOcr → 识别 与直接识别一致', () {
    final samples = _loadAll();
    final truth = (jsonDecode(File('test/fixtures/raw/truth.json').readAsStringSync()) as Map)
        .map((k, v) => MapEntry('$k'.replaceAll('.png', ''), '$v'));
    final missed = <String>[];
    for (final s in samples) {
      final im = img.Image.fromBytes(
        width: s.w,
        height: s.h,
        bytes: s.rgba.buffer,
        order: img.ChannelOrder.rgba,
      );
      final png = Uint8List.fromList(img.encodePng(im));
      final ocr = decodeBytesForOcr(png, maxDim: 1600);
      if (ocr == null) {
        missed.add('${s.name}=解码失败');
        continue;
      }
      final r = AmountReader.read(ocr.rgba, ocr.width, ocr.height);
      if (r.text != truth[s.name]) missed.add('${s.name}=${r.text}');
    }
    expect(missed, isEmpty, reason: 'Dart 侧解码路线识别失败：${missed.take(5).join(', ')}');
  });
}
