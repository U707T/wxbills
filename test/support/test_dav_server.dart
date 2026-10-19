import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

/// 一个够用的内存 WebDAV 服务器，专门给同步测试用。
///
/// 实现了同步路径上真正会被调用的方法：
///   PROPFIND（Depth 0/1）、GET、PUT（含 `If-Match` / `If-None-Match`）、
///   MKCOL、DELETE、HEAD。
/// 另外可以注入故障（例如强制 ETag 冲突、注入 500）来验证重试与合并逻辑。
class TestDavServer {
  TestDavServer._(this._server, this.root);

  final HttpServer _server;
  final String root;

  /// path -> 内容（目录用 null 表示，以 `/` 结尾）
  final Map<String, List<int>?> files = {};

  /// 每个路径的 ETag（用内容哈希模拟，写一次换一个）
  final Map<String, String> etags = {};

  int _etagSeq = 0;

  /// 统计各方法的调用次数（验证「已是最新时不重复上传」）。
  final Map<String, int> calls = {};

  /// 按路径统计 PUT / GET 次数（验证「同一份文件不会被重复传输」）。
  final Map<String, int> putCounts = {};
  final Map<String, int> getCounts = {};

  int putCount(String path) => putCounts[path] ?? 0;
  int getCount(String path) => getCounts[path] ?? 0;

  /// 让服务端像坚果云 / 部分 Nextcloud 那样返回弱 ETag（`W/"..."`）。
  /// 客户端必须按强校验发 If-Match，否则永远 412。
  bool weakEtags = false;

  /// 严格实现：`If-Match` 里带 `W/` 前缀直接 412（RFC 7232 要求强比较）。
  /// 客户端如果原样透传弱 ETag，就会永远冲突。
  bool strictIfMatch = false;

  /// 置为非 0 时，接下来 N 次 PUT 会先被「别的设备」抢先写一次，
  /// 用来验证客户端会重新下载 → 重新合并 → 再写。
  int forceConflictOnPut = 0;

  /// 置为 true 时所有请求返回 500（验证错误处理）。
  bool failEverything = false;

  String get url => 'http://127.0.0.1:${_server.port}/dav';

  static Future<TestDavServer> start({String root = '/dav'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dav = TestDavServer._(server, root);
    dav.files['$root/'] = null;
    server.listen(dav._handle);
    return dav;
  }

  Future<void> stop() => _server.close(force: true);

  /// 直接塞一个文件（模拟另一台设备已经上传过）。
  void putFile(String path, List<int> bytes) {
    files[path] = bytes;
    etags[path] = _nextEtag();
  }

  List<int>? getFile(String path) => files[path];

  int callCount(String method) => calls[method] ?? 0;

  String _nextEtag() => '"etag-${++_etagSeq}"';

  String _emit(String etag) => weakEtags ? 'W/$etag' : etag;

  /// 比较 ETag 时忽略弱前缀（服务端实现通常也是这么宽容的）。
  static String _strong(String? etag) {
    var e = (etag ?? '').trim();
    if (e.startsWith('W/')) e = e.substring(2).trim();
    return e;
  }

  Future<void> _handle(HttpRequest request) async {
    final method = request.method.toUpperCase();
    calls[method] = (calls[method] ?? 0) + 1;

    if (failEverything) {
      request.response.statusCode = 500;
      await request.response.close();
      return;
    }

    // Basic 认证：用户名密码固定 alice/secret
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (auth == null || auth != 'Basic ${base64.encode(utf8.encode('alice:secret'))}') {
      request.response.statusCode = 401;
      request.response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="dav"');
      await request.response.close();
      return;
    }

    final path = _normalize(request.uri.path);
    try {
      switch (method) {
        case 'PROPFIND':
          await _propfind(request, path);
        case 'GET':
          await _get(request, path);
        case 'HEAD':
          await _head(request, path);
        case 'PUT':
          await _put(request, path);
        case 'MKCOL':
          await _mkcol(request, path);
        case 'DELETE':
          await _delete(request, path);
        default:
          request.response.statusCode = 405;
          await request.response.close();
      }
    } catch (e) {
      request.response.statusCode = 500;
      request.response.write('server error: $e');
      await request.response.close();
    }
  }

  String _normalize(String p) {
    var path = p;
    if (!path.startsWith(root)) path = '$root$path';
    return path;
  }

  Future<void> _propfind(HttpRequest request, String path) async {
    final depth = request.headers.value('depth') ?? '0';
    final key = files.containsKey(path) || path.endsWith('/') ? path : path;
    if (!files.containsKey(key)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final entries = <String>[];
    if (key.endsWith('/')) {
      entries.add(key);
      if (depth != '0') {
        for (final k in files.keys) {
          if (k == key) continue;
          final parent = k.substring(0, k.lastIndexOf('/', k.length - 2) + 1);
          if (parent == key) entries.add(k);
        }
      }
    } else {
      entries.add(key);
    }

    final sb = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus xmlns:D="DAV:">');
    for (final e in entries) {
      final isDir = e.endsWith('/');
      final bytes = files[e];
      sb.write('<D:response><D:href>${_encodePath(e)}</D:href><D:propstat><D:prop>');
      sb.write(isDir
          ? '<D:resourcetype><D:collection/></D:resourcetype>'
          : '<D:resourcetype/>');
      if (!isDir) {
        sb.write('<D:getcontentlength>${bytes?.length ?? 0}</D:getcontentlength>');
        final etag = etags[e];
        if (etag != null) sb.write('<D:getetag>${_emit(etag)}</D:getetag>');
      }
      sb.write('<D:getlastmodified>Mon, 19 Oct 2026 04:00:00 GMT</D:getlastmodified>');
      sb.write('</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>');
    }
    sb.write('</D:multistatus>');

    request.response.statusCode = 207;
    request.response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
    request.response.write(sb.toString());
    await request.response.close();
  }

  String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  Future<void> _get(HttpRequest request, String path) async {
    getCounts[path] = (getCounts[path] ?? 0) + 1;
    final bytes = files[path];
    if (bytes == null) {
      request.response.statusCode = files.containsKey(path) ? 405 : 404;
      await request.response.close();
      return;
    }
    final etag = etags[path];
    if (etag != null) {
      request.response.headers.set(HttpHeaders.etagHeader, _emit(etag));
    }
    request.response.headers.contentType = ContentType('application', 'json');
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _head(HttpRequest request, String path) async {
    if (!files.containsKey(path) || files[path] == null) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final etag = etags[path];
    if (etag != null) request.response.headers.set(HttpHeaders.etagHeader, etag);
    await request.response.close();
  }

  Future<void> _put(HttpRequest request, String path) async {
    putCounts[path] = (putCounts[path] ?? 0) + 1;
    final body = await _readAll(request);

    // 模拟「另一台设备刚好先写了」：本次请求必然拿到 412
    if (forceConflictOnPut > 0) {
      forceConflictOnPut--;
      files[path] = utf8.encode('{"v":2,"bills":[]}');
      etags[path] = _nextEtag();
      request.response.statusCode = 412;
      await request.response.close();
      return;
    }

    final ifMatch = request.headers.value(HttpHeaders.ifMatchHeader);
    final ifNone = request.headers.value(HttpHeaders.ifNoneMatchHeader);
    final current = etags[path];

    if (ifNone == '*') {
      if (files.containsKey(path)) {
        request.response.statusCode = 412;
        await request.response.close();
        return;
      }
    } else if (ifMatch != null && ifMatch.isNotEmpty) {
      final weak = ifMatch.trim().startsWith('W/');
      if (current == null ||
          weak && strictIfMatch ||
          _strong(ifMatch) != _strong(current)) {
        request.response.statusCode = 412;
        await request.response.close();
        return;
      }
    }

    files[path] = body;
    final etag = _nextEtag();
    etags[path] = etag;
    request.response.headers.set(HttpHeaders.etagHeader, _emit(etag));
    request.response.statusCode = current == null ? 201 : 204;
    await request.response.close();
  }

  Future<void> _mkcol(HttpRequest request, String path) async {
    if (files.containsKey(path)) {
      request.response.statusCode = 405;
      await request.response.close();
      return;
    }
    files[path] = null;
    request.response.statusCode = 201;
    await request.response.close();
  }

  Future<void> _delete(HttpRequest request, String path) async {
    if (!files.containsKey(path)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    files.remove(path);
    etags.remove(path);
    request.response.statusCode = 204;
    await request.response.close();
  }

  Future<List<int>> _readAll(HttpRequest request) async {
    final builder = BytesBuilder();
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
