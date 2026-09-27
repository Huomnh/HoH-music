import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';

import 'lx_shim_js.dart';

/// 一个音源脚本里声明的音源（`lx.send('inited', { sources: {...} })` 的内容）。
class LxSourceInfo {
  const LxSourceInfo({
    required this.key,
    required this.name,
    required this.type,
    required this.actions,
    required this.qualitys,
  });

  /// 脚本内部用的音源标识，调用时要原样传回。
  final String key;

  /// 展示名（如「网易云」「QQ音乐」）。
  final String name;

  /// 目前只有 `music`。
  final String type;

  /// 支持的动作：`musicUrl` / `lyric` / `pic`（**没有 search**）。
  final List<String> actions;

  /// 支持的音质标识：`128k` / `320k` / `flac` / `flac24bit` 等。
  final List<String> qualitys;

  bool get canMusicUrl => actions.contains('musicUrl');

  @override
  String toString() => '$name($key)[${actions.join('/')}]';
}

/// 单个脚本的加载结果 —— 自检和音源管理页都用它。
class LxScriptReport {
  LxScriptReport({
    required this.name,
    required this.path,
    this.scriptInfoName = '',
    this.scriptInfoAuthor = '',
    this.scriptInfoVersion = '',
    this.gotInited = false,
    this.status,
    this.message = '',
    this.error = '',
    this.sources = const [],
    this.elapsedMs = 0,
  });

  final String name;

  /// 脚本文件路径或 URL（自检时用于打印）。
  final String path;

  final String scriptInfoName;
  final String scriptInfoAuthor;
  final String scriptInfoVersion;

  /// 脚本有没有主动 `send('inited', …)`。
  final bool gotInited;

  /// inited 里的 `status`。**null 表示脚本没写这个字段** ——
  /// 按 LX 的约定，没写就等于成功（大量音源只发 `{sources: {…}}`），
  /// 只有显式 `status: false` 才算初始化失败。
  final bool? status;

  /// inited 里的 `message`（失败原因常常写在这）。
  final String message;

  /// 脚本执行期抛出的错误（QuickJS 报的）。
  final String error;

  final List<LxSourceInfo> sources;
  final int elapsedMs;

  bool get statusOk => status != false;

  bool get ok => gotInited && statusOk && sources.isNotEmpty;

  /// 一行摘要，供日志使用。
  String get summary {
    if (error.isNotEmpty) return '❌ 脚本报错：$error';
    if (!gotInited) {
      return '⚠️ 脚本执行完但没有上报 inited（${error.isEmpty ? '可能依赖未实现的 LX API、请求失败或初始化超时' : error}）';
    }
    if (!statusOk) {
      return '❌ inited status=false${message.isEmpty ? '' : '：$message'}';
    }
    if (sources.isEmpty) return '❌ inited 里 sources 为空';
    return '✅ 可用音源 ${sources.length} 个：${sources.join('，')}';
  }
}

/// 宿主调用脚本处理器（musicUrl / lyric / pic）的结果。
class LxActionResult {
  const LxActionResult({required this.ok, this.data, this.error = ''});

  final bool ok;
  final Object? data;
  final String error;

  /// musicUrl 结果里取 URL（脚本可能返回字符串，也可能返回 `{url: …}`）。
  String? get url {
    final d = data;
    if (d is String) return d.isEmpty ? null : d;
    if (d is Map) {
      final u = d['url'];
      if (u is String && u.isNotEmpty) return u;
      if (u is List && u.isNotEmpty) return u.first?.toString();
    }
    return null;
  }

  /// 某些音源会返回 `{url, quality}`，用于校验是否真的拿到了请求档位。
  String? get returnedQuality {
    final d = data;
    if (d is Map) {
      final Object? value = d['quality'] ?? d['type'] ?? d['format'];
      return value?.toString();
    }
    return null;
  }

  /// 某些音源会在结果对象里返回真实码率（单位可能是 bit/s 或 kbps）。
  int? get returnedBitrateKbps {
    final Object? value = data is Map
        ? (data as Map)['bitrate'] ??
              (data as Map)['bit_rate'] ??
              (data as Map)['br'] ??
              (data as Map)['kbps']
        : null;
    final int? raw = int.tryParse(value?.toString() ?? '');
    if (raw == null || raw <= 0) return null;
    return raw >= 10000 ? (raw / 1000).round() : raw;
  }

  @override
  String toString() => ok ? 'ok(${data.runtimeType})' : 'failed($error)';
}

/// QuickJS 音源沙箱：吃 LX Music 格式的 `.js` 脚本，对外只暴露
/// 「加载脚本 → 列音源 → 要播放地址 / 歌词 / 封面」这几件事。
///
/// 刻意不做的事：不提供 `search`（LX 的音源接口本来就没有 search，搜索由宿主自己做），
/// 不给脚本文件系统权限，所有网络请求都经宿主 Dart 侧发出（可统一限速 / 打日志）。
class LxSandbox {
  LxSandbox._(this._rt) {
    _rt.onMessage('hoh_inited', _onInited);
    _rt.onMessage('hoh_request', _onRequest);
    _rt.onMessage('hoh_result', _onResult);
    _rt.onMessage('hoh_utils_test', (args) => _utilsTestResult = _asMap(args));
    _rt.onMessage('hoh_pong', (_) {});
    _rt.onMessage('hoh_update_alert', (args) {
      final m = _asMap(args);
      _lastUpdateAlert = (m?['payload'] as Map?)?['message']?.toString() ?? '';
    });
    _rt.onMessage('hoh_log', (args) {});
    _rt.onMessage('hoh_error', (args) {
      final m = _asMap(args);
      _scriptErrors.add(m?['error']?.toString() ?? '未知');
    });
  }

  /// 创建一个沙箱（含 shim）。`xhr: false`：不要 flutter_js 自带的 fetch，
  /// 网络一律走我们的 `lx.request` 桥。
  static LxSandbox create({HttpClient? httpClient}) {
    final rt = getJavascriptRuntime(xhr: false);
    final sandbox = LxSandbox._(rt);
    sandbox._http = httpClient ?? (HttpClient()..autoUncompress = true);
    final shim = rt.evaluate(lxShimJs);
    if (shim.isError) {
      throw StateError('音源 shim 注入失败：${shim.stringResult}');
    }
    return sandbox;
  }

  final JavascriptRuntime _rt;
  late final HttpClient _http;

  /// 脚本上报的 inited 原始内容。
  Map<String, dynamic>? _inited;
  Map<String, dynamic>? _utilsTestResult;
  final Map<String, LxActionResult> _results = <String, LxActionResult>{};
  final List<String> _scriptErrors = <String>[];
  final List<String> _requestDiagnostics = <String>[];
  final Map<String, HttpClientRequest> _activeRequests =
      <String, HttpClientRequest>{};
  String _lastUpdateAlert = '';
  int _invokeSeq = 0;
  int _requestCount = 0;

  /// 宿主实际发出的请求数（自检 / 日志用）。
  int get requestCount => _requestCount;

  /// 最近一次脚本加载期间的请求诊断（只记录主机、状态和错误）。
  List<String> get requestDiagnostics => List.unmodifiable(_requestDiagnostics);

  /// 当前脚本元信息中的原始脚本校验值（自检诊断用）。
  String get currentScriptRawHash {
    final result = _rt.evaluate(
      'lx.utils.crypto.md5(lx.currentScriptInfo.rawScript.trim())',
    );
    return result.isError
        ? 'error:${result.stringResult}'
        : result.stringResult;
  }

  /// 脚本里未被 init 捕获的异常。
  List<String> get scriptErrors => List.unmodifiable(_scriptErrors);

  String get lastUpdateAlert => _lastUpdateAlert;

  /// 严格判断脚本是不是 UTF-8。
  ///
  /// 实测有一批音源脚本是 **GBK** 编码的。宽容解码能让它们"读进来"，
  /// 但中文串会变成替换字符 `U+FFFD` → 字符串字面量直接语法错误，
  /// 所以对非 UTF-8 脚本要**明确告诉用户去转码**，而不是假装支持。
  static bool isUtf8Bytes(List<int> bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// 读脚本内容：音源脚本**不保证是 UTF-8**（实测有 GBK 编码的），
  /// 所以宽容解码 —— 坏字节变占位符，但脚本结构和 URL/密钥（都是 ASCII）保住，
  /// 总比整个脚本读不进来强。同时吃掉 UTF-8 BOM。
  static String decodeScriptBytes(List<int> bytes) {
    var data = bytes;
    if (data.length >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF) {
      data = data.sublist(3);
    }
    return utf8.decode(data, allowMalformed: true);
  }

  // ── 宿主通道：JS → Dart ─────────────────────────────────────────

  void _onInited(dynamic args) {
    final m = _asMap(args);
    final payload = m?['payload'];
    if (payload is Map) {
      _inited = payload.map((k, v) => MapEntry(k.toString(), v));
    } else {
      _inited = <String, dynamic>{'status': false, 'message': 'inited 内容不是对象'};
    }
  }

  void _onRequest(dynamic args) {
    final m = _asMap(args);
    if (m == null) return;
    if (m['kind'] == 'cancel') {
      _activeRequests.remove(m['id']?.toString())?.abort();
      return;
    }
    // ⚠️ 必须异步处理：这个回调是 QuickJS 在 evaluate() 里同步回调上来的，
    // 在回调里再次 evaluate（投递结果）会重入运行时。
    Future.microtask(() => _performRequest(m));
  }

  void _onResult(dynamic args) {
    final m = _asMap(args);
    if (m == null) return;
    final id = m['id']?.toString() ?? '';
    _results[id] = LxActionResult(
      ok: m['ok'] == true,
      data: m['data'],
      error: m['error']?.toString() ?? '',
    );
  }

  static Map<String, dynamic>? _asMap(dynamic args) {
    if (args is Map) return args.map((k, v) => MapEntry(k.toString(), v));
    return null;
  }

  // ── 宿主 → 脚本 投递 ────────────────────────────────────────────

  void _deliver(Map<String, dynamic> msg) {
    final literal = jsonEncode(jsonEncode(msg));
    final res = _rt.evaluate('__hohDeliver($literal)');
    if (res.isError) _scriptErrors.add('投递失败：${res.stringResult}');
    _pump();
  }

  /// 把待执行的微任务（Promise.then / async 里的后续）跑掉。
  /// QuickJS 不会自己跑作业队列，`executePendingJob` 一次跑一个。
  void _pump([int rounds = 30]) {
    for (var i = 0; i < rounds; i++) {
      final left = _rt.executePendingJob();
      if (left <= 0) break;
    }
  }

  /// 等到条件成立（期间不断跑微任务 + 让 setTimeout 有机会触发）。
  Future<void> _waitFor(bool Function() done, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (!done() && DateTime.now().isBefore(deadline)) {
      _pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _pump(80);
  }

  // ── 加载脚本 ────────────────────────────────────────────────────

  /// 加载一个 LX 格式音源脚本，等它上报 inited。
  Future<LxScriptReport> loadScript({
    required String name,
    required String code,
    String path = '',
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final sw = Stopwatch()..start();
    _inited = null;
    _scriptErrors.clear();
    _requestDiagnostics.clear();
    _lastUpdateAlert = '';

    final headerInfo = _parseScriptHeader(code);

    _rt.evaluate(
      'lx.currentScriptInfo.name = ${jsonEncode(headerInfo['name'] ?? name)};'
      'lx.currentScriptInfo.description = ${jsonEncode(headerInfo['description'] ?? '')};'
      'lx.currentScriptInfo.version = ${jsonEncode(headerInfo['version'] ?? '')};'
      'lx.currentScriptInfo.author = ${jsonEncode(headerInfo['author'] ?? '')};'
      'lx.currentScriptInfo.homepage = ${jsonEncode(headerInfo['homepage'] ?? '')};'
      // LX 音源会用 currentScriptInfo.rawScript.trim() 做脚本完整性校验；
      // 保持与官方宿主一致，否则带文件末尾换行的脚本会被远端判定为被修改。
      'lx.currentScriptInfo.rawScript = ${jsonEncode(code.trim())}; 1',
    );

    final res = _rt.evaluate(code, sourceUrl: 'lx-source://$name');
    _pump();
    final evalError = res.isError ? res.stringResult : '';

    await _waitFor(() => _inited != null, timeout);

    final inited = _inited;
    final payload = inited ?? const <String, dynamic>{};
    final sources = <LxSourceInfo>[];
    final rawSources = payload['sources'];
    if (rawSources is Map) {
      rawSources.forEach((key, value) {
        if (value is! Map) return;
        sources.add(
          LxSourceInfo(
            key: key.toString(),
            name: value['name']?.toString() ?? key.toString(),
            type: value['type']?.toString() ?? '',
            actions: _stringList(value['actions']),
            qualitys: _stringList(value['qualitys']),
          ),
        );
      });
    }

    final scriptInfo = _scriptInfoMap();
    final rawStatus = payload['status'];
    return LxScriptReport(
      name: name,
      path: path,
      scriptInfoName: scriptInfo['name']?.toString() ?? '',
      scriptInfoAuthor: scriptInfo['author']?.toString() ?? '',
      scriptInfoVersion: scriptInfo['version']?.toString() ?? '',
      gotInited: inited != null,
      status: rawStatus is bool ? rawStatus : null,
      message: payload['message']?.toString() ?? '',
      error: evalError.isNotEmpty
          ? evalError
          : (_scriptErrors.isEmpty ? '' : _scriptErrors.join(' | ')),
      sources: sources,
      elapsedMs: sw.elapsedMilliseconds,
    );
  }

  /// LX 在执行脚本前会把头部注释中的元信息注入 currentScriptInfo。
  ///
  /// 这不执行脚本，只读取常见的 `@name/@version/...` 行。某些受保护
  /// 音源会用 `currentScriptInfo.version` 选择远程 vinfo 配置；如果只在
  /// 脚本执行后读取元信息，会错过初始化阶段的版本选择。
  static Map<String, String> _parseScriptHeader(String code) {
    final result = <String, String>{};
    for (final key in <String>[
      'name',
      'description',
      'version',
      'author',
      'homepage',
    ]) {
      final match = RegExp(
        r'@' + key + r'\s+([^\r\n*]+)',
        caseSensitive: false,
      ).firstMatch(code);
      final value = match?.group(1)?.trim();
      if (value != null && value.isNotEmpty) result[key] = value;
    }
    return result;
  }

  /// 脚本自己声明的元信息（有的脚本会 `lx.currentScriptInfo.name = '…'`）。
  Map<String, dynamic> _scriptInfoMap() {
    final res = _rt.evaluate('JSON.stringify(lx.currentScriptInfo || {})');
    if (res.isError) return const {};
    try {
      final decoded = jsonDecode(res.stringResult);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } on FormatException {
      // 脚本改了 currentScriptInfo 的结构，忽略
    }
    return const {};
  }

  static List<String> _stringList(Object? value) {
    if (value is List) {
      return value.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
    return const [];
  }

  // ── 调用脚本处理器 ──────────────────────────────────────────────

  /// 调用脚本的 `request` 处理器。
  ///
  /// ⚠️ 参数形状必须照 LX 的约定来（这一点搞错会被误判成「音源不支持」）：
  /// ```
  /// musicUrl → { source, action:'musicUrl', info: { type:'320k', musicInfo:{…} } }
  /// lyric    → { source, action:'lyric',    info: { musicInfo:{…} } }
  /// pic      → { source, action:'pic',      info: { musicInfo:{…} } }
  /// ```
  /// 音源脚本普遍写的是 `info.musicInfo` / `info.type`，不是把歌曲字段摊在 `info` 上。
  Future<LxActionResult> invoke({
    required String action,
    required String source,
    String quality = '',
    Map<String, dynamic> musicInfo = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final id = 'i${++_invokeSeq}';
    _results.remove(id);
    final info = <String, dynamic>{'musicInfo': musicInfo};
    if (action == 'musicUrl') info['type'] = quality;
    _deliver(<String, dynamic>{
      'kind': 'invoke',
      'id': id,
      'action': action,
      'source': source,
      'quality': quality,
      'info': info,
    });
    await _waitFor(() => _results.containsKey(id), timeout);
    return _results.remove(id) ??
        const LxActionResult(ok: false, error: '脚本没有在超时前返回结果');
  }

  /// 顺手测一下 shim 里那几个纯 JS 工具（md5 / base64 / buffer）算得对不对。
  Future<Map<String, dynamic>> utilsSelfTest({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _utilsTestResult = null;
    _deliver(<String, dynamic>{'kind': 'utilsTest'});
    await _waitFor(() => _utilsTestResult != null, timeout);
    return _utilsTestResult ?? const <String, dynamic>{};
  }

  // ── 请求桥 ──────────────────────────────────────────────────────

  Future<void> _performRequest(Map<String, dynamic> msg) async {
    final id = msg['id']?.toString() ?? '';
    final requestUrl = msg['url']?.toString() ?? '';
    String? error;
    Map<String, dynamic>? resp;
    Object? body;
    try {
      _requestCount++;
      final url = requestUrl;
      final uri = Uri.parse(url);
      final method = (msg['method']?.toString() ?? 'GET').toUpperCase();
      final req = await _http.openUrl(method, uri);
      _activeRequests[id] = req;

      final headers = msg['headers'];
      final seenHeaders = <String>{};
      if (headers is Map) {
        headers.forEach((k, v) {
          if (v == null) return;
          try {
            req.headers.set(k.toString(), v.toString());
            seenHeaders.add(k.toString().toLowerCase());
          } on HttpException {
            // 非法头名（脚本写错）忽略，别整个请求挂掉
          }
        });
      }
      if (!seenHeaders.contains('user-agent')) {
        req.headers.set('user-agent', _defaultUserAgent);
      }

      final form = msg['form'];
      final formData = msg['formData'];
      final rawBody = msg['body'];
      if (formData is Map && formData.isNotEmpty) {
        final boundary = '----HoHMusic${DateTime.now().microsecondsSinceEpoch}';
        req.headers.set(
          'content-type',
          'multipart/form-data; boundary=$boundary',
        );
        req.add(_buildMultipart(formData, boundary));
      } else if (form is Map && form.isNotEmpty) {
        req.headers.set('content-type', 'application/x-www-form-urlencoded');
        req.add(
          utf8.encode(
            form.entries
                .map(
                  (e) =>
                      '${Uri.encodeQueryComponent(e.key.toString())}'
                      '=${Uri.encodeQueryComponent(e.value?.toString() ?? '')}',
                )
                .join('&'),
          ),
        );
      } else if (rawBody is String && rawBody.isNotEmpty) {
        req.add(utf8.encode(rawBody));
      }

      // LX 官方默认 response_timeout 为 60 秒；音源初始化经常需要跨境
      // 请求，30 秒会把本来能工作的源误判成失败。
      final requestedTimeout = (msg['timeout'] as num?)?.toInt() ?? 0;
      final timeoutMs = requestedTimeout > 0
          ? requestedTimeout.clamp(1, 60000).toInt()
          : 60000;
      final future = req.close();
      final res = await future.timeout(Duration(milliseconds: timeoutMs));

      final bytes = await _readAll(res);
      final text = utf8.decode(bytes, allowMalformed: true);
      final respHeaders = <String, dynamic>{};
      res.headers.forEach((name, values) {
        respHeaders[name] = values.length == 1 ? values.first : values;
      });
      body = _tryJson(text) ?? text;
      resp = <String, dynamic>{
        'statusCode': res.statusCode,
        'statusMessage': res.reasonPhrase,
        'headers': respHeaders,
        'bytes': bytes.length,
        // LX 音源普遍使用 callback 的第二个参数 resp.body；
        // 同时保留第三参数 body，兼容两种写法。
        'body': body,
      };
    } catch (e) {
      error = e.toString();
    }
    final host = Uri.tryParse(requestUrl)?.host ?? requestUrl;
    final bodyShape = body is Map
        ? 'body keys=${body.keys.map((key) => key.toString()).take(12).join(',')}'
        : 'body=${body.runtimeType}';
    _requestDiagnostics.add(
      error == null
          ? '$host → ${resp?['statusCode'] ?? 'no-status'} ($bodyShape)'
          : '$host → error: $error',
    );
    _activeRequests.remove(id);
    _deliver(<String, dynamic>{
      'kind': 'response',
      'id': id,
      'error': error,
      'resp': resp,
      'body': body,
    });
  }

  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 HoH-music/0.0.36';

  static Object? _tryJson(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final first = trimmed.codeUnitAt(0);
    if (first != 0x7b && first != 0x5b && first != 0x22) return null; // { [ "
    try {
      return jsonDecode(trimmed);
    } on FormatException {
      return null;
    }
  }

  static Future<List<int>> _readAll(HttpClientResponse res) async {
    final chunks = <int>[];
    await for (final chunk in res) {
      chunks.addAll(chunk);
    }
    return chunks;
  }

  /// lx 的 `formData`：值可以是字符串，也可以是 `{value, options:{filename, contentType}}`，
  /// 还可以是 `lx.utils.buffer.from(...)` 的替身对象（我们序列化成 `{__hohBuf, v}`）。
  static List<int> _buildMultipart(
    Map<dynamic, dynamic> formData,
    String boundary,
  ) {
    final out = <int>[];
    void write(String s) => out.addAll(utf8.encode(s));
    formData.forEach((key, value) {
      var filename = '';
      var contentType = '';
      Object? content = value;
      if (value is Map) {
        final opts = value['options'];
        if (opts is Map) {
          filename = opts['filename']?.toString() ?? '';
          contentType = opts['contentType']?.toString() ?? '';
        }
        content = value.containsKey('value') ? value['value'] : value;
      }
      write('--$boundary\r\n');
      write(
        'Content-Disposition: form-data; name="$key"'
        '${filename.isEmpty ? '' : '; filename="$filename"'}\r\n',
      );
      if (contentType.isNotEmpty) write('Content-Type: $contentType\r\n');
      write('\r\n');
      if (content is Map && content['__hohBuf'] == true) {
        final v = content['v']?.toString() ?? '';
        out.addAll(v.codeUnits.map((c) => c & 0xff));
      } else {
        write(content?.toString() ?? '');
      }
      write('\r\n');
    });
    write('--$boundary--\r\n');
    return out;
  }

  void dispose() {
    try {
      _http.close(force: true);
    } catch (_) {
      // 忽略：关闭失败不影响退出
    }
    try {
      _rt.dispose();
    } catch (_) {
      // 忽略：dispose 内部偶发空指针，不影响进程
    }
  }
}
