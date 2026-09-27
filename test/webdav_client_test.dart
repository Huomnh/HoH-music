import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hoh_music/core/remote/webdav_client.dart';

/// WebDAV 客户端的纯解析测试（**不联网**）。
///
/// 样例取自真实服务器常见的几种写法，专门覆盖"各家 href 不一样"这个坑：
/// 绝对 URL / 相对路径 / 中文未编码 / 命名空间前缀 `D:` 与 `d:` 混用。
void main() {
  group('WebDavConfig', () {
    test('地址规范化与鉴权头', () {
      const WebDavConfig cfg = WebDavConfig(
        baseUrl: 'https://dav.example.com/music/',
        username: 'u',
        password: 'p',
      );
      expect(cfg.normalizedBase, 'https://dav.example.com/music');
      expect(cfg.isValid, isTrue);
      expect(
        cfg.authHeaders['Authorization'],
        'Basic ${base64Encode(utf8.encode('u:p'))}',
      );

      expect(const WebDavConfig(baseUrl: 'ftp://x').isValid, isFalse);
      expect(const WebDavConfig(baseUrl: 'x').isValid, isFalse);
      // 匿名时不带 Authorization
      expect(const WebDavConfig(baseUrl: 'https://x').authHeaders, isEmpty);
    });
  });

  group('parseMultiStatus', () {
    const String xml = '''
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/music/</D:href>
    <D:propstat><D:prop>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/music/%E5%8D%8A%E5%8F%A5%E5%86%8D%E8%A7%81.flac</D:href>
    <D:propstat><D:prop>
      <D:resourcetype/>
      <D:getcontentlength>31457280</D:getcontentlength>
      <D:getlastmodified>Wed, 24 Sep 2026 10:00:00 GMT</D:getlastmodified>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <d:response>
    <d:href>https://dav.example.com/dav/music/%E4%B8%93%E8%BE%91/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/></d:resourcetype>
    </d:prop></d:propstat>
  </d:response>
</D:multistatus>
''';

    test('解析出条目：跳过目录自身、区分目录、解码中文、认出音频', () {
      final List<WebDavEntry> entries = WebDavClient.parseMultiStatus(
        xml,
        base: 'https://dav.example.com/dav',
        // 请求的就是 /music，服务器把它自己也返回了一次 —— 要滤掉
        selfPath: '/music/',
      );

      // 目录自身（/dav/music/）会被去掉，剩两个
      expect(entries, hasLength(2));

      final WebDavEntry file = entries.first;
      expect(file.name, '半句再见.flac');
      expect(file.path, '/music/半句再见.flac');
      expect(file.isDirectory, isFalse);
      expect(file.size, 31457280);
      expect(file.modified, isNotNull);
      expect(file.looksLikeAudio, isTrue);

      final WebDavEntry dir = entries[1];
      expect(dir.name, '专辑');
      expect(dir.isDirectory, isTrue);
      expect(dir.looksLikeAudio, isFalse);
      // 绝对 href 里的服务器前缀（/dav）要被剥掉
      expect(dir.path, '/music/专辑/');
    });

    test('空响应 / 垃圾输入不会抛异常', () {
      expect(WebDavClient.parseMultiStatus(''), isEmpty);
      expect(WebDavClient.parseMultiStatus('<html>not dav</html>'), isEmpty);
    });
  });

  group('条目', () {
    test('looksLikeAudio 只认音频扩展名', () {
      WebDavEntry entry(String name) =>
          WebDavEntry(name: name, path: '/$name', isDirectory: false);
      expect(entry('a.mp3').looksLikeAudio, isTrue);
      expect(entry('A.FLAC').looksLikeAudio, isTrue);
      expect(entry('cover.jpg').looksLikeAudio, isFalse);
      expect(entry('readme.txt').looksLikeAudio, isFalse);
    });
  });
}
