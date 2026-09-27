/// webdav_client.dart
///
/// **WebDAV 客户端**（0.0.33）—— 「来源 → WebDAV」要用。
///
/// 只做三件事，但都做扎实：
/// 1. **连接测试**：`PROPFIND` + `Depth: 0`，看是否 207；
/// 2. **列目录**：`PROPFIND` + `Depth: 1`，解析出条目（名字 / 是否目录 / 大小 / 修改时间）；
/// 3. **下载**：GET 成字节（播放先走"下载到本地再播"，避免去赌 mpv 的鉴权行为）。
///
/// ⚠️ XML 解析说明：Dart 没有内置 XML 解析器，本项目也**不想为这一件事引依赖**，
/// 而 WebDAV 的响应结构固定、我们只要几个字段（`href` / `getcontentlength` /
/// `getlastmodified` / `resourcetype/collection`），所以用**正则**解析，
/// 并且**命名空间前缀大小写都吃**（`<D:response>` / `<d:response>` / 无前缀）。
/// 这条取舍写在文档里，等以后真需要完整 XML 能力再换 `xml` 包。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// WebDAV 连接参数。
@immutable
class WebDavConfig {
  /// 创建配置。
  const WebDavConfig({
    required this.baseUrl,
    this.username = '',
    this.password = '',
  });

  /// 服务器地址，例如 `https://dav.example.com/dav`（不带尾斜杠也行）。
  final String baseUrl;

  /// 用户名（可空 = 匿名 / 只用 token）。
  final String username;

  /// 密码。
  final String password;

  /// 规范化后的地址（去掉尾部斜杠）。
  String get normalizedBase {
    String url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// 是否够用来发起请求。
  bool get isValid => normalizedBase.startsWith('http');

  /// 带鉴权的请求头。
  Map<String, String> get authHeaders {
    if (username.isEmpty && password.isEmpty) return const <String, String>{};
    final String token = base64Encode(utf8.encode('$username:$password'));
    return <String, String>{'Authorization': 'Basic $token'};
  }
}

/// 目录里的一个条目。
@immutable
class WebDavEntry {
  /// 创建条目。
  const WebDavEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
    this.modified,
  });

  /// 显示名（从 href 里取最后一段并 URL 解码）。
  final String name;

  /// 相对服务器根的路径（以 `/` 开头）。
  final String path;

  /// 是否目录。
  final bool isDirectory;

  /// 字节数（目录为 0）。
  final int size;

  /// 修改时间（解析不出来就是 null）。
  final DateTime? modified;

  /// 是否像音频文件（给"只显示能播的"用）。
  bool get looksLikeAudio {
    final String lower = name.toLowerCase();
    for (final String ext in <String>[
      '.mp3',
      '.flac',
      '.wav',
      '.m4a',
      '.aac',
      '.ogg',
      '.opus',
      '.alac',
    ]) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }
}

/// WebDAV 操作失败。
class WebDavException implements Exception {
  /// 创建异常。
  WebDavException(this.message, {this.statusCode});

  /// 说明。
  final String message;

  /// HTTP 状态码（如果有）。
  final int? statusCode;

  @override
  String toString() => 'WebDavException(${statusCode ?? '-'}): $message';
}

/// WebDAV 客户端。
class WebDavClient {
  /// 创建客户端。
  WebDavClient(this.config, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 30),
              // 207 Multi-Status 是正常的，别当失败
              validateStatus: (int? code) => code != null && code < 500,
            ),
          );

  /// 连接参数。
  final WebDavConfig config;

  final Dio _dio;

  /// 连接测试：`PROPFIND` + `Depth: 0`。
  ///
  /// 返回 `(ok, 说明)`：说明直接给用户看，所以写人话。
  Future<({bool ok, String message})> testConnection() async {
    if (!config.isValid) {
      return (ok: false, message: '地址要以 http:// 或 https:// 开头');
    }
    try {
      final Response<String> response = await _dio.request<String>(
        config.normalizedBase,
        options: Options(
          method: 'PROPFIND',
          headers: <String, Object?>{
            ...config.authHeaders,
            'Depth': '0',
            'Content-Type': 'application/xml; charset=utf-8',
          },
          responseType: ResponseType.plain,
        ),
      );
      final int code = response.statusCode ?? 0;
      if (code == 207 || code == 200) {
        return (ok: true, message: '连接成功（HTTP $code）');
      }
      if (code == 401 || code == 403) {
        return (ok: false, message: '账号或密码不对（HTTP $code）');
      }
      if (code == 404) {
        return (ok: false, message: '地址不存在（HTTP 404），检查路径');
      }
      if (code == 405) {
        return (ok: false, message: '这个地址不支持 WebDAV（HTTP 405，PROPFIND 被拒）');
      }
      return (ok: false, message: '服务器返回 HTTP $code');
    } catch (error) {
      return (ok: false, message: '连不上：$error');
    }
  }

  /// 列目录（`Depth: 1`）。[path] 为空 = 根。
  Future<List<WebDavEntry>> list([String path = '']) async {
    final String url = _join(path);
    final Response<String> response = await _dio.request<String>(
      url,
      options: Options(
        method: 'PROPFIND',
        headers: <String, Object?>{
          ...config.authHeaders,
          'Depth': '1',
          'Content-Type': 'application/xml; charset=utf-8',
        },
        responseType: ResponseType.plain,
      ),
    );
    final int code = response.statusCode ?? 0;
    if (code != 207 && code != 200) {
      throw WebDavException('列目录失败', statusCode: code);
    }
    return parseMultiStatus(
      response.data ?? '',
      base: config.normalizedBase,
      // 把"被请求的那个目录自己"滤掉（服务器总会把它一起返回）
      selfPath: path,
    );
  }

  /// 下载一个文件。
  Future<Uint8List> download(String path) async {
    final Response<List<int>> response = await _dio.get<List<int>>(
      _join(path),
      options: Options(
        headers: config.authHeaders,
        responseType: ResponseType.bytes,
      ),
    );
    if (response.statusCode != 200 || response.data == null) {
      throw WebDavException('下载失败', statusCode: response.statusCode);
    }
    return Uint8List.fromList(response.data!);
  }

  /// 直接给播放器用的地址（把账号密码放进 URL，mpv 认这种写法）。
  ///
  /// ⚠️ **不能对绝对路径用 `Uri.resolve`**：那会把服务器的基础路径
  /// （123 云盘是 `/webdav`）整个替换掉，生成 `https://host/%E7%94%B5...`
  /// 这种 404 地址 —— 0.0.34 用真实服务器联调时抓到的。
  /// 所以这里手工把"基础路径 + 相对路径"拼起来。
  String streamUrl(String path) {
    final Uri? base = Uri.tryParse(config.normalizedBase);
    if (base == null) return _join(path);

    final String clean = path.startsWith('/') ? path : '/$path';
    final String basePath = base.path;
    final String encoded = encodePath(clean);
    final String fullPath = basePath.isEmpty
        ? encoded
        : '$basePath${encoded == '/' ? '/' : encoded}';

    return base
        .replace(
          path: fullPath,
          userInfo: config.username.isEmpty
              ? ''
              : '${config.username}:${config.password}',
        )
        .toString();
  }

  String _join(String path) {
    final String clean = path.startsWith('/') ? path : '/$path';
    return '${config.normalizedBase}${clean == '/' ? '' : encodePath(clean)}';
  }

  /// 路径归一化：**先按段解码、再按段编码**。
  ///
  /// 为什么不能直接拼：服务器返回的 href 有的编码中文、有的不编码，
  /// 目录里还可能真的有 `%` 这种字符。直接拼或直接 decode 都会踩
  /// `Illegal percent encoding in URI`（0.0.40 递归扫描网盘时实测到）。
  /// 按段处理能同时吃下"已编码"和"未编码"两种输入。
  @visibleForTesting
  static String encodePath(String path) => path
      .split('/')
      .map(
        (String segment) =>
            segment.isEmpty ? '' : Uri.encodeComponent(safeDecode(segment)),
      )
      .join('/');

  /// 宽容解码：坏的百分号编码原样返回，不抛异常。
  static String safeDecode(String value) {
    if (!value.contains('%')) return value;
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return value;
    } on FormatException {
      return value;
    }
  }

  // ── XML 解析（正则版，见文件头说明）────────────────────────────

  /// 解析 `207 Multi-Status` 响应。
  ///
  /// [base] 用来把绝对 href 收敛成相对路径（不同服务器返回的 href 差异很大：
  /// 有的给绝对 URL、有的给相对路径、有的**不编码中文**）。
  /// [selfPath] 是"被请求的那个目录"，服务器会把它自己也返回一次，这里滤掉。
  @visibleForTesting
  static List<WebDavEntry> parseMultiStatus(
    String xml, {
    String base = '',
    String? selfPath,
  }) {
    final List<WebDavEntry> entries = <WebDavEntry>[];
    final RegExp responseRe = RegExp(
      r'<(?:[A-Za-z0-9]+:)?response\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9]+:)?response>',
      caseSensitive: false,
    );

    for (final RegExpMatch match in responseRe.allMatches(xml)) {
      final String block = match.group(1) ?? '';
      final String? href = _tagText(block, 'href');
      if (href == null || href.isEmpty) continue;

      final bool isDirectory = RegExp(
        r'<(?:[A-Za-z0-9]+:)?collection\b',
        caseSensitive: false,
      ).hasMatch(block);
      final int size =
          int.tryParse(_tagText(block, 'getcontentlength') ?? '') ?? 0;
      final DateTime? modified = _parseDate(_tagText(block, 'getlastmodified'));

      final String path = _toRelativePath(href, base);
      final String name = _nameOf(path);
      if (name.isEmpty) continue; // 根目录条目（以 / 结尾且没名字）跳过
      if (selfPath != null && _samePath(path, selfPath)) continue; // 目录自己

      entries.add(
        WebDavEntry(
          name: name,
          path: path,
          isDirectory: isDirectory,
          size: size,
          modified: modified,
        ),
      );
    }
    return entries;
  }

  /// 解析修改时间。
  ///
  /// ⚠️ WebDAV 服务器给的多半是 **RFC 1123 的 HTTP 日期**（`Wed, 24 Sep 2026 10:00:00 GMT`），
  /// 而 Dart 的 `DateTime.tryParse` **只认 ISO-8601** —— 直接扔进去会得到 null。
  /// 所以这里两种都试。
  static DateTime? _parseDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final String text = raw.trim();
    final DateTime? iso = DateTime.tryParse(text);
    if (iso != null) return iso;

    final RegExpMatch? m = RegExp(
      r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(text);
    if (m == null) return null;
    const List<String> months = <String>[
      'jan',
      'feb',
      'mar',
      'apr',
      'may',
      'jun',
      'jul',
      'aug',
      'sep',
      'oct',
      'nov',
      'dec',
    ];
    final int month = months.indexOf(m.group(2)!.toLowerCase());
    if (month < 0) return null;
    return DateTime.utc(
      int.parse(m.group(3)!),
      month + 1,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    ).toLocal();
  }

  /// 取某个标签的文本（命名空间前缀大小写都吃）。
  static String? _tagText(String block, String tag) {
    final RegExpMatch? m = RegExp(
      '<(?:[A-Za-z0-9]+:)?$tag\\b[^>]*>([\\s\\S]*?)</(?:[A-Za-z0-9]+:)?$tag>',
      caseSensitive: false,
    ).firstMatch(block);
    if (m == null) return null;
    return m.group(1)?.trim();
  }

  /// 把 href 收敛成"以 / 开头、不含服务器前缀"的路径。
  ///
  /// ⚠️ 前缀剥离对**相对 href 也要做**：很多服务器返回的是"从服务器根算起"的
  /// `/dav/music/x.flac`，而用户填的地址是 `https://host/dav` ——
  /// 不剥掉 `/dav` 的话，条目路径会和请求路径对不上（自检里踩到过）。
  ///
  /// ⚠️ **XML 实体必须解码**：文件名里的 `&` 在 XML 里写作 `&amp;`，
  /// 不解码就会拼出一个错的 URL（123 云盘联调时 `…&amp;王嘉尔….wav` 直接 404）。
  static String _toRelativePath(String href, String base) {
    String path = _unescapeXml(href.trim());
    if (path.startsWith('http://') || path.startsWith('https://')) {
      path = Uri.tryParse(path)?.path ?? path;
    }
    // ⚠️ 用宽容解码：服务器给的 href 里可能带"孤立的 %"（文件名里就有 %），
    //    `Uri.decodeFull` 会直接抛 `Illegal percent encoding in URI`，
    //    整个递归扫描就断了（0.0.40 扫网盘时实测到）。
    path = safeDecode(path);

    if (base.isNotEmpty) {
      final String prefix = Uri.tryParse(base)?.path ?? '';
      final String trimmed = prefix.endsWith('/') && prefix.length > 1
          ? prefix.substring(0, prefix.length - 1)
          : prefix;
      if (trimmed.isNotEmpty &&
          trimmed != '/' &&
          (path == trimmed || path.startsWith('$trimmed/'))) {
        path = path.substring(trimmed.length);
      }
    }

    if (!path.startsWith('/')) path = '/$path';
    return path;
  }

  /// 解 XML 实体。⚠️ `&amp;` **必须最后替换**，否则 `&amp;lt;` 会被二次解码。
  static String _unescapeXml(String raw) => raw
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&amp;', '&');

  static String _nameOf(String path) {
    String clean = path;
    while (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    final int slash = clean.lastIndexOf('/');
    return slash < 0 ? clean : clean.substring(slash + 1);
  }

  /// 两条路径是否指同一个目录（只归一斜杠 —— 两边都已经解码过了，
  /// ⚠️ 别再 `Uri.decodeFull` 一次：中文路径再解一次会抛 "Illegal percent encoding"）。
  static bool _samePath(String a, String b) {
    String norm(String p) {
      String s = p.trim();
      while (s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
      if (!s.startsWith('/')) s = '/$s';
      return s;
    }

    return norm(a) == norm(b);
  }
}
