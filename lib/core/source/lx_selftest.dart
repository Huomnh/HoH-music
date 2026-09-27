import 'dart:io';

import 'lx_sandbox.dart';

/// 自定义音源（LX 格式脚本）的真机自检。
///
/// 为什么要有这个东西：QuickJS 沙箱里脚本的失败方式很安静 ——
/// 脚本能在 `flutter analyze` 下"编译通过"、跑起来也不抛异常，
/// 但就是不上报 `inited`。只有把它们真跑一遍、把每个脚本的结论打出来，
/// 才能判断是「宿主缺 API」还是「脚本本身需要联网/被墙」。
///
/// 触发方式（都不影响正常启动，Release 下是死代码）：
/// ```
/// HOH_SOURCE_SELFTEST=1                 # 用默认目录
/// HOH_SOURCE_SELFTEST=D:\my\sources     # 指定目录
/// HOH_SOURCE_ONLY=念心                    # 只测文件名含该字串的脚本
/// HOH_SOURCE_LIMIT=5                    # 最多测几个
/// HOH_SOURCE_TRACE=1                    # 打印每个脚本大小
/// HOH_SOURCE_INVOKE=0                   # 只测「能否 inited」，不试播放地址
/// ```
/// 日志同时写 `build/source-selftest.log`（默认路径，可用 `HOH_SOURCE_LOG` 覆盖）。
///
/// ⚠️ 这个 GUI 子系统的 exe 上，PowerShell 的 `2> file` **只收到 stdout 的内容**，
/// 所以自检自己写日志文件，别只依赖 shell 重定向。
class SourceSelfTestResult {
  const SourceSelfTestResult({
    required this.total,
    required this.inited,
    required this.usable,
    required this.invoked,
    required this.urlOk,
  });

  final int total;
  final int inited;
  final int usable;
  final int invoked;
  final int urlOk;

  String get summary =>
      '共 $total 个脚本：上报 inited $inited 个，'
      '声明了可用音源 $usable 个；试取播放地址 $invoked 次，成功 $urlOk 次';
}

/// 默认的脚本目录（用户机器上的实测目录；不存在就让调用方显式指定）。
const String _defaultSourceDir =
    r'E:\【刺客边风】LX-Music-Desktop v2.12.6\音源接口_2026.09.08\V260908';

/// 从环境变量 / 命令行解析是否要跑自检，返回脚本目录（不跑返回 null）。
///
/// 只在 Debug 下生效，避免 Release 包被误触发。
String? resolveSourceSelfTestDir(List<String> args) {
  if (!_isDebug) return null;
  final fromArgs = args
      .where((a) => a.startsWith('--source-selftest'))
      .map((a) => a.contains('=') ? a.split('=').sublist(1).join('=') : '')
      .toList();
  if (fromArgs.isNotEmpty) {
    return fromArgs.first.isEmpty ? _defaultSourceDir : fromArgs.first;
  }
  final env = Platform.environment['HOH_SOURCE_SELFTEST'];
  if (env == null || env.isEmpty || env == '0' || env == 'false') return null;
  if (env == '1' || env == 'true') return _defaultSourceDir;
  return env;
}

bool get _isDebug {
  var debug = false;
  assert(() {
    debug = true;
    return true;
  }());
  return debug;
}

File? _logFile;

/// 日志落盘路径（默认 `build/source-selftest.log`，可用 `HOH_SOURCE_LOG` 覆盖）。
String get _logPath =>
    Platform.environment['HOH_SOURCE_LOG'] ?? 'build/source-selftest.log';

void _log(String line) {
  final file = _logFile;
  if (file != null) {
    try {
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志写不进去也不能影响自检本身
    }
  }
  stderr.writeln(line);
  stdout.writeln(line);
}

/// 跑一遍自检。返回统计结果，同时把详细过程打到日志。
Future<SourceSelfTestResult> runSourceSelfTest(
  String dirPath, {
  Duration perScriptTimeout = const Duration(seconds: 20),
}) async {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    _log('[音源自检] 目录不存在：$dirPath');
    return const SourceSelfTestResult(
      total: 0,
      inited: 0,
      usable: 0,
      invoked: 0,
      urlOk: 0,
    );
  }

  try {
    _logFile = File(_logPath);
    _logFile!.writeAsStringSync('', mode: FileMode.write, flush: true);
  } catch (_) {
    _logFile = null;
  }

  final trace = Platform.environment['HOH_SOURCE_TRACE'] == '1';
  final only = Platform.environment['HOH_SOURCE_ONLY'] ?? '';
  final limit =
      int.tryParse(Platform.environment['HOH_SOURCE_LIMIT'] ?? '') ?? 0;
  final doInvoke = Platform.environment['HOH_SOURCE_INVOKE'] != '0';

  var files =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.js'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (only.isNotEmpty) {
    files = files.where((f) => f.path.contains(only)).toList();
  }
  if (limit > 0 && files.length > limit) {
    files = files.sublist(0, limit);
  }

  _log('==================== 音源自检开始 ====================');
  _log('[音源自检] 日志文件：${_logFile == null ? '(写不进去，只用控制台)' : _logPath}');
  _log('[音源自检] 目录：$dirPath');
  _log('[音源自检] 脚本 ${files.length} 个（trace=$trace invoke=$doInvoke）');
  _log('');

  // 先确认 shim 里那几个纯 JS 工具算得对（算错了音源签名就全废）。
  _log('---- 宿主工具自检（md5 / base64 / buffer）----');
  final utilsSandbox = LxSandbox.create();
  try {
    final result = await utilsSandbox.utilsSelfTest();
    const expectMd5Abc = '900150983cd24fb0d6963f7d28e17f72';
    final md5Abc = result['md5_abc']?.toString() ?? '';
    final b64Round = result['b64_round']?.toString() ?? '';
    final hexRound = result['hex_round']?.toString() ?? '';
    _log(
      '  md5("abc")   = $md5Abc'
      '  ${md5Abc == expectMd5Abc ? '✅' : '❌ 期望 $expectMd5Abc'}',
    );
    _log('  md5("晴天")  = ${result['md5_cn']}');
    _log('  b64("晴天")  = ${result['b64_cn']}');
    _log('  b64 往返     = $b64Round  ${b64Round == '晴天-周杰伦' ? '✅' : '❌'}');
    _log(
      '  buffer→hex   = $hexRound'
      '  ${hexRound == '486f48' ? '✅' : '❌ 期望 486f48'}',
    );
    if (result.isEmpty) _log('  ❌ 宿主工具自检没有返回结果（shim 通道不通）');
  } finally {
    utilsSandbox.dispose();
  }
  _log('');

  var initedCount = 0;
  var usableCount = 0;
  var invokedCount = 0;
  var urlOkCount = 0;

  for (var i = 0; i < files.length; i++) {
    final file = files[i];
    final name = file.path.split(Platform.pathSeparator).last;
    final index = '${i + 1}/${files.length}';
    _log('---- [$index] $name ----');
    String code;
    try {
      final bytes = file.readAsBytesSync();
      if (!LxSandbox.isUtf8Bytes(bytes)) {
        _log(
          '  ⚠️ 不是 UTF-8 编码（GBK？）—— 宽容解码后中文串会变占位符，'
          '大概率语法错误；这份脚本要转成 UTF-8 才能用',
        );
      }
      code = LxSandbox.decodeScriptBytes(bytes);
    } catch (e) {
      _log('  ❌ 读取失败：$e');
      continue;
    }
    if (trace) {
      _log('  大小 ${code.length} 字符');
    }

    final sandbox = LxSandbox.create();
    try {
      final report = await sandbox.loadScript(
        name: name,
        code: code,
        path: file.path,
        timeout: perScriptTimeout,
      );
      if (report.scriptInfoName.isNotEmpty) {
        _log(
          '  元信息：${report.scriptInfoName}'
          '${report.scriptInfoAuthor.isEmpty ? '' : ' / ${report.scriptInfoAuthor}'}'
          '${report.scriptInfoVersion.isEmpty ? '' : ' v${report.scriptInfoVersion}'}',
        );
      }
      _log(
        '  ${report.summary}  （${report.elapsedMs}ms，宿主请求 ${sandbox.requestCount} 次）',
      );
      for (final request in sandbox.requestDiagnostics) {
        _log('    · 请求诊断：$request');
      }
      _log('    · rawScript.trim() MD5：${sandbox.currentScriptRawHash}');
      if (report.gotInited) initedCount++;
      if (report.ok) usableCount++;
      for (final s in report.sources) {
        _log(
          '    · ${s.name}  标识=${s.key}  动作=${s.actions.join(',')}'
          '  音质=${s.qualitys.join(',')}',
        );
      }
      if (sandbox.lastUpdateAlert.isNotEmpty) {
        _log('  ℹ️ 脚本弹了更新提示：${sandbox.lastUpdateAlert}');
      }

      if (doInvoke && report.ok) {
        final target = report.sources.firstWhere(
          (s) => s.canMusicUrl,
          orElse: () => report.sources.first,
        );
        final sample = sampleMusicInfoFor(target.key);
        final quality = target.qualitys.contains('320k')
            ? '320k'
            : (target.qualitys.isNotEmpty ? target.qualitys.first : '128k');
        _log('  → 试取播放地址：${target.name} / $quality');
        final urlResult = await sandbox.invoke(
          action: 'musicUrl',
          source: target.key,
          quality: quality,
          musicInfo: sample,
        );
        invokedCount++;
        if (urlResult.ok && urlResult.url != null) {
          urlOkCount++;
          _log('    ✅ ${urlResult.url}');
        } else if (urlResult.ok) {
          _log('    ⚠️ 调用成功但没拿到 URL：${urlResult.data}');
        } else {
          _log('    ❌ ${urlResult.error}');
        }
        if (target.actions.contains('lyric')) {
          final lyric = await sandbox.invoke(
            action: 'lyric',
            source: target.key,
            musicInfo: sample,
          );
          if (lyric.ok) {
            final text = lyric.data is Map
                ? (lyric.data as Map)['lyric']?.toString() ?? ''
                : lyric.data?.toString() ?? '';
            _log('    ${text.isEmpty ? '⚠️ 歌词为空' : '✅ 歌词 ${text.length} 字'}');
          } else {
            _log('    ❌ 歌词：${lyric.error}');
          }
        }
        if (target.actions.contains('pic')) {
          final pic = await sandbox.invoke(
            action: 'pic',
            source: target.key,
            musicInfo: sample,
          );
          if (pic.ok) {
            final text = pic.data?.toString() ?? '';
            _log('    ${text.isEmpty ? '⚠️ 封面为空' : '✅ 封面 ${text.length} 字符'}');
          } else {
            _log('    ❌ 封面：${pic.error}');
          }
        }
      }
    } catch (e) {
      _log('  ❌ 沙箱异常：$e');
    } finally {
      sandbox.dispose();
    }
    _log('');
  }

  final result = SourceSelfTestResult(
    total: files.length,
    inited: initedCount,
    usable: usableCount,
    invoked: invokedCount,
    urlOk: urlOkCount,
  );
  _log('[音源自检] ${result.summary}');
  _log('==================== 音源自检结束 ====================');
  return result;
}

/// 试取播放地址用的示例歌曲信息。
///
/// 各平台字段名不同（LX 的 musicInfo 就是各平台原始字段），这里给一份
/// 「看起来像真的」的样本：`songmid`/`hash`/`albumId` 都给上，
/// 目的是**验证请求桥和签名链路**，而不是真的要下到某首歌。
Map<String, dynamic> sampleMusicInfoFor(String sourceKey) {
  switch (sourceKey) {
    case 'tx':
      return <String, dynamic>{
        'songmid': '0039MnYb0qxYhV',
        'name': '晴天',
        'singer': '周杰伦',
        'albumId': '002fRO0N4FftzY',
        'albumMid': '002fRO0N4FftzY',
        'hash': '',
        'source': 'tx',
        'type': '320k',
      };
    case 'kw':
      return <String, dynamic>{
        'songmid': '6289602',
        'hash': 'cbcb2b1f6e6b1b0ecf5b6c8f1c9f0a1b',
        'name': '晴天',
        'singer': '周杰伦',
        'albumId': '6289601',
        'source': 'kw',
        'type': '320k',
      };
    case 'kg':
      return <String, dynamic>{
        'songmid': '',
        'hash': 'cbcb2b1f6e6b1b0ecf5b6c8f1c9f0a1b',
        'name': '晴天',
        'singer': '周杰伦',
        'albumId': '1234567',
        'source': 'kg',
        'type': '320k',
      };
    case 'mg':
      return <String, dynamic>{
        'songmid': '6008310HJ4U',
        'name': '晴天',
        'singer': '周杰伦',
        'albumId': '6008310HJ4U',
        'source': 'mg',
        'type': '320k',
      };
    default: // wy 及其它
      return <String, dynamic>{
        'songmid': '186016',
        'songId': '186016',
        'name': '晴天',
        'singer': '周杰伦',
        'albumId': '185809',
        'albumMid': '185809',
        'hash': '',
        'source': sourceKey,
        'type': '320k',
      };
  }
}
