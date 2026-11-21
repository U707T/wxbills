import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/webdav/webdav_client.dart';

void main() {
  test('PROPFIND 返回其他源的 href 时拒绝解析', () {
    final client = WebDavClient('https://dav.example.test/dav/wxbills');
    addTearDown(client.close);

    expect(
      () => client.resolve(
        'https://attacker.example.test/private.jpg',
        'https://dav.example.test/dav/wxbills/',
      ),
      throwsA(isA<WebDavException>()),
    );
    expect(
      client.resolve('bills.json', 'https://dav.example.test/dav/wxbills/'),
      'https://dav.example.test/dav/wxbills/bills.json',
    );
  });

  test('同源重定向仍可正常使用', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var authorization = '';
    server.listen((request) async {
      if (request.uri.path == '/source') {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/target');
        await request.response.close();
        return;
      }
      authorization =
          request.headers.value(HttpHeaders.authorizationHeader) ?? '';
      request.response.add([1, 2, 3]);
      await request.response.close();
    });

    final client = WebDavClient(
      'http://127.0.0.1:${server.port}',
      username: 'alice',
      password: 'secret',
    );
    try {
      final result = await client.get('http://127.0.0.1:${server.port}/source');
      expect(result.bytes, [1, 2, 3]);
      expect(
        authorization,
        'Basic ${base64.encode(utf8.encode('alice:secret'))}',
      );
    } finally {
      client.close();
      await server.close(force: true);
    }
  });

  test('跨源重定向在转发认证信息或请求数据前被拒绝', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var targetRequests = 0;
    target.listen((request) async {
      targetRequests++;
      await request.drain<void>();
      await request.response.close();
    });

    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    source.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${target.port}/collect',
        );
      await request.response.close();
    });

    final client = WebDavClient(
      'http://127.0.0.1:${source.port}',
      username: 'alice',
      password: 'secret',
    );
    try {
      await expectLater(
        client.put(
          'http://127.0.0.1:${source.port}/upload',
          utf8.encode('private bill snapshot'),
          createOnly: true,
        ),
        throwsA(isA<WebDavException>()),
      );
      expect(targetRequests, 0, reason: '账号凭据与账单内容不得发送到重定向目标');
    } finally {
      client.close();
      await source.close(force: true);
      await target.close(force: true);
    }
  });
}
