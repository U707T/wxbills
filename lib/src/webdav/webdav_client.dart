import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// WebDAV 操作失败（消息直接面向用户，带状态码等上下文）。
class WebDavException implements Exception {
  WebDavException(this.message, [this.cause, this.status]);

  final String message;
  final Object? cause;
  final int? status;

  @override
  String toString() => message;
}

/// 一个 WebDAV 条目。
class DavEntry {
  const DavEntry({
    required this.url,
    required this.name,
    required this.isDirectory,
    required this.size,
    this.etag = '',
  });

  final String url;
  final String name;
  final bool isDirectory;

  /// 字节数；未知为 -1。
  final int size;

  /// 服务器给出的 ETag（含引号原样保留），未知为空串。
  final String etag;

  @override
  String toString() => 'DavEntry($url, dir=$isDirectory, size=$size)';
}

/// 极简 WebDAV 客户端（纯 Dart + `HttpClient`，Android / Windows 通用）。
///
/// 只实现同步需要的部分：PROPFIND（Depth 0/1）、GET、PUT（支持条件请求）、
/// DELETE、MKCOL、HEAD。认证用 HTTP Basic。
///
/// 之所以不引第三方包：需要的功能很少，自己写可以精确控制
/// ETag 条件写（多设备并发时的正确性关键）与超时/重试语义。
class WebDavClient {
  WebDavClient(
    String baseUrl, {
    this.username = '',
    this.password = '',
    this.allowInsecureTls = false,
    this.connectTimeout = const Duration(seconds: 15),
    this.readTimeout = const Duration(seconds: 60),
  }) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) throw ArgumentError('服务器地址不能为空');
    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    root = sanitizeUrl(withScheme).replaceAll(RegExp(r'/+$'), '');
    _http = HttpClient()..connectionTimeout = connectTimeout;
    // 关闭透明解压：同步文件要按字节校验，不能拿到解压后的长度
    _http.autoUncompress = false;
    if (allowInsecureTls) {
      _http.badCertificateCallback = (cert, host, port) => true;
    }
  }

  final String username;
  final String password;
  final bool allowInsecureTls;
  final Duration connectTimeout;
  final Duration readTimeout;

  /// 规范化后的根地址（无尾部斜杠）。
  late final String root;

  late final HttpClient _http;

  void close() => _http.close(force: true);

  static const String _userAgent = 'WxBills-WebDAV/2.0 (Flutter)';

  static final Uint8List _propfindBody = Uint8List.fromList(utf8.encode(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<D:propfind xmlns:D="DAV:"><D:prop>'
    '<D:resourcetype/><D:getcontentlength/><D:getetag/>'
    '</D:prop></D:propfind>',
  ));

  // ---------------------------------------------------------------- 目录

  /// PROPFIND Depth:1，列出目录下的条目（含自身）。
  Future<List<DavEntry>> list(String dirUrl) async {
    final base = ensureTrailingSlash(dirUrl);
    final r = await _send('PROPFIND', base,
        headers: const {'Depth': '1'}, body: _propfindBody);
    final text = await _readText(r.response, limit: _xmlLimit);
    if (!_isSuccess(r.status) && r.status != 207) {
      throw WebDavException('列目录失败 HTTP ${r.status}${_suffix(text)}', null, r.status);
    }
    return _parseMultiStatus(text, base);
  }

  /// 目录不存在就创建（逐级 MKCOL，已存在返回 405 视为成功）。
  ///
  /// 只创建 [root] 之下的层级；根地址本身也试一次（多数的网盘根目录已存在，
  /// 返回 405 会被忽略）。
  Future<void> ensureDir(String dirUrl) async {
    final target = Uri.parse(ensureTrailingSlash(dirUrl));
    final base = Uri.parse(root);
    final targetSegs = target.pathSegments.where((s) => s.isNotEmpty).toList();
    var current = '${base.scheme}://${base.authority}';
    for (final seg in targetSegs) {
      current = '$current/${encodeSegment(seg)}';
      final r = await _send('MKCOL', '$current/');
      await _drain(r.response);
      if (!_isSuccess(r.status) && r.status != 405 && r.status != 301) {
        throw WebDavException('创建目录失败 HTTP ${r.status}（$current）', null, r.status);
      }
    }
  }

  // ---------------------------------------------------------------- 读

  /// 下载整个文件。返回（字节, ETag）。文件不存在时 bytes 为 null。
  ///
  /// [limit] 是硬上限：配置写错指到一个大文件、或服务端把请求重定向到视频时，
  /// 不能把内存吃满（Android 上就是 OOM 被杀）。快照正常只有几十 KB。
  Future<({Uint8List? bytes, String etag})> get(
    String url, {
    int limit = 32 << 20,
  }) async {
    final r = await _send('GET', url);
    if (r.status == 404) {
      await _drain(r.response);
      return (bytes: null, etag: '');
    }
    if (!_isSuccess(r.status)) {
      final text = await _readText(r.response, limit: 512);
      throw WebDavException('下载失败 HTTP ${r.status}${_suffix(text)}', null, r.status);
    }
    final bytes = await _readAll(r.response, limit: limit);
    final etag = r.headers.value(HttpHeaders.etagHeader) ?? '';
    return (bytes: bytes, etag: etag);
  }

  // ---------------------------------------------------------------- 写

  /// 上传（PUT）。[ifMatch] 非空时做条件写：服务端 ETag 不匹配返回 412；
  /// [createOnly] 为 true 时用 `If-None-Match: *`（文件已存在返回 412）。
  ///
  /// 返回服务端的新 ETag（拿不到为空串）。412 会抛 [PreconditionFailedException]。
  Future<String> put(
    String url,
    List<int> bytes, {
    String ifMatch = '',
    bool createOnly = false,
    String contentType = 'application/json; charset=utf-8',
  }) async {
    final headers = <String, String>{'Content-Type': contentType};
    final strong = strongEtag(ifMatch);
    if (strong.isNotEmpty) headers[HttpHeaders.ifMatchHeader] = strong;
    if (createOnly) headers[HttpHeaders.ifNoneMatchHeader] = '*';
    var r = await _send('PUT', url, headers: headers, body: bytes);
    // 少数服务端（例如坚果云）见到 `If-None-Match: *` 不是回 412，而是直接
    // 404 ObjectNotFound。这种情况下把它当「不支持条件创建」处理：去掉条件头再发一次。
    // 安全性没问题——调用方是「刚 GET 过、确认文件不存在」才用 createOnly 的。
    if (createOnly && (r.status == 404 || r.status == 400 || r.status == 501)) {
      await _drain(r.response);
      headers.remove(HttpHeaders.ifNoneMatchHeader);
      r = await _send('PUT', url, headers: headers, body: bytes);
    }
    if (r.status == 412) {
      await _drain(r.response);
      throw PreconditionFailedException();
    }
    final text = await _readText(r.response, limit: 512);
    if (!_isSuccess(r.status)) {
      throw WebDavException('上传失败 HTTP ${r.status}${_suffix(text)}', null, r.status);
    }
    return r.headers.value(HttpHeaders.etagHeader) ?? '';
  }

  Future<void> delete(String url) async {
    final r = await _send('DELETE', url);
    final text = await _readText(r.response, limit: 512);
    if (!_isSuccess(r.status) && r.status != 404) {
      throw WebDavException('删除失败 HTTP ${r.status}${_suffix(text)}', null, r.status);
    }
  }

  // ---------------------------------------------------------------- URL 工具

  String resolve(String hrefRaw, String against) {
    final href = hrefRaw.trim();
    if (href.isEmpty) return against;
    try {
      return Uri.parse(against).resolve(sanitizeUrl(href)).toString();
    } catch (e) {
      throw WebDavException('无法解析服务器返回的路径: $hrefRaw', e);
    }
  }

  String ensureTrailingSlash(String url) => url.endsWith('/') ? url : '$url/';

  /// 去掉弱校验前缀：RFC 7232 规定 `If-Match` 必须用强比较，直接把服务端返回的
  /// `W/"abc"` 当条件发出去，规范实现会一律回 412 —— 表现就是「同步永远冲突」。
  /// 坚果云 / 部分 Nextcloud 的 PROPFIND 就会给弱 ETag，这里统一按强校验使用。
  static String strongEtag(String etag) {
    var e = etag.trim();
    if (e.startsWith('W/')) e = e.substring(2).trim();
    return e;
  }

  String fileNameOf(String url) {
    final trimmed = url.replaceAll(RegExp(r'/+$'), '');
    final idx = trimmed.lastIndexOf('/');
    final seg = idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
    return percentDecode(seg);
  }

  // ---------------------------------------------------------------- 底层

  static const int _xmlLimit = 16 << 20;

  bool _isSuccess(int s) => s >= 200 && s <= 299;

  String _suffix(String body) {
    final t = body.trim();
    if (t.isEmpty) return '';
    return ': ${t.length > 200 ? t.substring(0, 200) : t}';
  }

  Future<void> _drain(HttpClientResponse response) async {
    try {
      await response.drain<void>().timeout(const Duration(seconds: 5));
    } catch (_) {
      // 忽略
    }
  }

  Future<Uint8List> _readAll(HttpClientResponse response, {required int limit}) async {
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.timeout(readTimeout)) {
        builder.add(chunk);
        if (builder.length > limit) {
          throw WebDavException('响应过大（已接收 ${builder.length} 字节，上限 $limit）');
        }
      }
    } on TimeoutException {
      throw WebDavException('读取响应超时（已接收 ${builder.length} 字节）');
    }
    return builder.takeBytes();
  }

  Future<String> _readText(HttpClientResponse response, {required int limit}) async {
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.timeout(readTimeout)) {
        builder.add(chunk);
        if (builder.length >= limit) break;
      }
    } on TimeoutException {
      // 只用于读错误信息的短文本，超时不算致命
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<_DavResponse> _send(
    String method,
    String url, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    var current = url;
    var redirects = 0;
    while (true) {
      final uri = Uri.tryParse(current);
      if (uri == null || !uri.hasScheme) {
        throw WebDavException('URL 无效: $current');
      }
      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') {
        throw WebDavException('不支持的协议: $scheme');
      }
      if (uri.host.isEmpty) throw WebDavException('URL 缺少主机名: $current');

      try {
        final request =
            await _http.openUrl(method, uri).timeout(connectTimeout);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        if (username.isNotEmpty || password.isNotEmpty) {
          final token = base64.encode(utf8.encode('$username:$password'));
          request.headers.set(HttpHeaders.authorizationHeader, 'Basic $token');
        }
        headers.forEach((k, v) => request.headers.set(k, v));

        if (body != null) {
          request.headers.contentLength = body.length;
          request.add(body);
        } else if (method == 'PUT' || method == 'POST') {
          request.headers.contentLength = 0;
        }

        final response = await request.close().timeout(connectTimeout);
        final status = response.statusCode;

        if (status >= 300 && status <= 399 && status != 304 && redirects < 4) {
          final location =
              response.headers.value(HttpHeaders.locationHeader)?.trim();
          if (location != null && location.isNotEmpty) {
            await _drain(response);
            redirects++;
            current = uri.resolve(sanitizeUrl(location)).toString();
            continue;
          }
        }
        return _DavResponse(status, response.headers, response);
      } on WebDavException {
        rethrow;
      } on TimeoutException {
        throw WebDavException('连接 ${uri.host}:${uri.port} 超时$_lanHint');
      } on SocketException catch (e) {
        throw WebDavException('连接 ${uri.host}:${uri.port} 失败$_lanHint：${e.message}', e);
      } on HandshakeException catch (e) {
        throw WebDavException(
            'TLS 握手失败：${e.message}（自签证书请在设置里打开「允许不受信任的证书」）', e);
      } catch (e) {
        throw WebDavException('网络请求失败（$method ${e.runtimeType}: $e）', e);
      }
    }
  }

  static const String _lanHint =
      '（服务器不可达，或被网络/系统策略拦截：Android 17 访问局域网需授予「本地网络」权限，'
      '也可能是防火墙或服务器未启动）';

  List<DavEntry> _parseMultiStatus(String xmlText, String requestUrl) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlText);
    } catch (e) {
      throw WebDavException('解析目录列表失败（返回的不是合法 XML）: $e', e);
    }
    final out = <DavEntry>[];
    for (final resp in doc.findAllElements('response', namespace: '*')) {
      final hrefEl = _firstOrNull(resp.findAllElements('href', namespace: '*'));
      final href = hrefEl?.innerText.trim();
      if (href == null || href.isEmpty) continue;
      final url = resolve(href, requestUrl);
      final isDir = resp.findAllElements('collection', namespace: '*').isNotEmpty;
      final sizeEl =
          _firstOrNull(resp.findAllElements('getcontentlength', namespace: '*'));
      final size = int.tryParse(sizeEl?.innerText.trim() ?? '') ?? -1;
      final etag =
          _firstOrNull(resp.findAllElements('getetag', namespace: '*'))?.innerText.trim() ?? '';
      final clean = url.replaceAll(RegExp(r'/+$'), '');
      out.add(DavEntry(
        url: isDir ? '$clean/' : clean,
        name: fileNameOf(clean),
        isDirectory: isDir,
        size: size,
        etag: etag,
      ));
    }
    return out;
  }

  static T? _firstOrNull<T>(Iterable<T> items) => items.isEmpty ? null : items.first;

  // ---------------------------------------------------------------- 编码

  static const String _hex = '0123456789ABCDEF';

  static bool _isHexChar(int b) =>
      (b >= 0x30 && b <= 0x39) ||
      (b >= 0x61 && b <= 0x66) ||
      (b >= 0x41 && b <= 0x46);

  /// 对 URL 做安全编码：保留已有 `%XX` 与合法字符，其余按 UTF-8 百分号编码。
  /// `#` 一律编码，避免文件名里的 `#` 被当成 fragment 截断。
  static String sanitizeUrl(String url) {
    final bytes = utf8.encode(url);
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b == 0x25 && i + 2 < bytes.length && _isHexChar(bytes[i + 1]) && _isHexChar(bytes[i + 2])) {
        sb
          ..writeCharCode(0x25)
          ..writeCharCode(bytes[i + 1])
          ..writeCharCode(bytes[i + 2]);
        i += 3;
        continue;
      }
      final ok = (b >= 0x61 && b <= 0x7A) ||
          (b >= 0x41 && b <= 0x5A) ||
          (b >= 0x30 && b <= 0x39) ||
          b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E ||
          b == 0x3A || b == 0x2F || b == 0x3F ||
          b == 0x5B || b == 0x5D || b == 0x40 ||
          b == 0x21 || b == 0x24 || b == 0x26 || b == 0x27 ||
          b == 0x28 || b == 0x29 || b == 0x2A || b == 0x2B ||
          b == 0x2C || b == 0x3B || b == 0x3D;
      if (ok) {
        sb.writeCharCode(b);
      } else {
        sb
          ..writeCharCode(0x25)
          ..writeCharCode(_hex.codeUnitAt(b >> 4))
          ..writeCharCode(_hex.codeUnitAt(b & 0x0F));
      }
      i++;
    }
    return sb.toString();
  }

  /// 对单个路径段做百分号编码。
  static String encodeSegment(String segment) {
    final bytes = utf8.encode(segment);
    final sb = StringBuffer();
    for (final v in bytes) {
      final ok = (v >= 0x61 && v <= 0x7A) ||
          (v >= 0x41 && v <= 0x5A) ||
          (v >= 0x30 && v <= 0x39) ||
          v == 0x2D || v == 0x2E || v == 0x5F || v == 0x7E;
      if (ok) {
        sb.writeCharCode(v);
      } else {
        sb
          ..writeCharCode(0x25)
          ..writeCharCode(_hex.codeUnitAt(v >> 4))
          ..writeCharCode(_hex.codeUnitAt(v & 0x0F));
      }
    }
    return sb.toString();
  }

  /// 百分号解码（不把 `+` 当空格）。
  static String percentDecode(String s) {
    final out = BytesBuilder(copy: false);
    final bytes = utf8.encode(s);
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b == 0x25 && i + 2 < bytes.length && _isHexChar(bytes[i + 1]) && _isHexChar(bytes[i + 2])) {
        final hi = int.parse(String.fromCharCode(bytes[i + 1]), radix: 16);
        final lo = int.parse(String.fromCharCode(bytes[i + 2]), radix: 16);
        out.addByte((hi << 4) | lo);
        i += 3;
      } else {
        out.addByte(b);
        i++;
      }
    }
    return utf8.decode(out.takeBytes(), allowMalformed: true);
  }
}

/// 条件写失败（ETag 不匹配 / 文件已存在）—— 说明别人刚改过，需要重新合并。
class PreconditionFailedException extends WebDavException {
  PreconditionFailedException() : super('文件已被其他设备修改');
}

class _DavResponse {
  const _DavResponse(this.status, this.headers, this.response);
  final int status;
  final HttpHeaders headers;
  final HttpClientResponse response;
}
