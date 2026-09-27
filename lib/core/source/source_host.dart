/// source_host.dart
///
/// **音源运行时宿主**：把登记表里"已启用"的脚本逐个装进 QuickJS 沙箱，
/// 然后对外提供两件事：
///   1. 现在到底有哪些平台可用（哪几个脚本能解析 `wy` / `tx` / …）；
///   2. `平台 + 歌曲 → 播放地址 / 歌词 / 封面`，**多脚本自动兜底**
///      （第一个脚本失败就换下一个，和 lx-music 的聚合行为一致）。
///
/// 每个脚本一个独立沙箱：脚本之间经常用同名顶层 `const`，
/// 丢进同一个运行时必然 `SyntaxError: redeclaration`。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lx_sandbox.dart';
import 'source_models.dart';
import 'source_store.dart';

/// 一个已装进沙箱的音源脚本。
class SourceRuntime {
  /// 创建运行时。
  SourceRuntime({
    required this.meta,
    required this.sandbox,
    required this.report,
  });

  /// 登记信息。
  final MusicSource meta;

  /// 沙箱。
  final LxSandbox sandbox;

  /// 加载结果（平台 / 动作 / 音质 / 失败原因）。
  final LxScriptReport report;

  /// 是否可用。
  bool get ok => report.ok;

  /// 脚本声明的音源。
  List<LxSourceInfo> get sources => report.sources;

  /// 这个脚本能不能解析某平台。
  bool supports(String platform, [String action = 'musicUrl']) => report.sources
      .any((LxSourceInfo s) => s.key == platform && s.actions.contains(action));

  /// 某平台支持的音质。
  List<String> qualitysFor(String platform) => report.sources
      .where((LxSourceInfo s) => s.key == platform)
      .expand((LxSourceInfo s) => s.qualitys)
      .toList(growable: false);
}

/// 宿主状态。
class SourceHostState {
  /// 创建状态。
  const SourceHostState({
    this.runtimes = const <SourceRuntime>[],
    this.loading = false,
  });

  /// 全部运行时（含加载失败的，界面要显示失败原因）。
  final List<SourceRuntime> runtimes;

  /// 是否正在加载。
  final bool loading;

  /// 可用的运行时。
  List<SourceRuntime> get ready =>
      runtimes.where((SourceRuntime r) => r.ok).toList(growable: false);

  /// 有加载失败原因的那些。
  List<SourceRuntime> get broken =>
      runtimes.where((SourceRuntime r) => !r.ok).toList(growable: false);

  /// 能解析某平台的脚本（保持登记顺序）。
  List<SourceRuntime> runtimesFor(
    String platform, [
    String action = 'musicUrl',
  ]) => ready
      .where((SourceRuntime r) => r.supports(platform, action))
      .toList(growable: false);

  /// 现在可用的平台集合（按常见顺序排）。
  List<String> get platforms {
    const List<String> order = <String>['wy', 'tx', 'kw', 'kg', 'mg', 'qs'];
    final Set<String> all = <String>{
      for (final SourceRuntime r in ready)
        for (final LxSourceInfo s in r.sources) s.key,
    };
    final List<String> sorted = <String>[
      for (final String k in order)
        if (all.contains(k)) k,
      ...all.where((String k) => !order.contains(k)),
    ];
    return sorted;
  }

  /// 现在可用的**主流音质**（只向界面暴露四档）。
  ///
  /// 音源内部的 `hires` / `master` 会统一映射到界面的 Hi-Res 档。
  List<String> get allQualitys {
    final Set<String> all = <String>{
      for (final SourceRuntime r in ready)
        for (final LxSourceInfo s in r.sources) ...s.qualitys,
    };
    return kCommonQualities
        .where((String q) {
          if (q == 'flac24bit') {
            return all.any(<String>{'flac24bit', 'hires', 'master'}.contains);
          }
          return all.contains(q);
        })
        .toList(growable: false);
  }

  /// 某个平台可用的音质（界面在搜索结果行上标注用）。
  List<String> qualitysFor(String platform) {
    final Set<String> all = <String>{
      for (final SourceRuntime r in runtimesFor(platform))
        ...r.qualitysFor(platform),
    };
    return kCommonQualities
        .where((String q) {
          if (q == 'flac24bit') {
            return all.any(<String>{'flac24bit', 'hires', 'master'}.contains);
          }
          return all.contains(q);
        })
        .toList(growable: false);
  }

  /// 一个可用音源都没有。
  bool get isEmpty => ready.isEmpty;

  /// 平台展示（`网易云 ← HYWmusic v1.0.3`）。
  String describePlatform(String platform) {
    final List<SourceRuntime> list = runtimesFor(platform);
    if (list.isEmpty) return '${platformLabel(platform)}：无可用音源';
    return '${platformLabel(platform)} ← '
        '${list.map((SourceRuntime r) => r.meta.name).join(' / ')}';
  }

  /// 搜索结果顶部的紧凑状态文案。
  ///
  /// 不能复用 [describePlatform]：用户导入很多聚合源时它会把全部脚本名
  /// 展开成几十行，挤掉真正的搜索结果；完整脚本名单只应在音源管理页展示。
  String describePlatformSummary(String platform) {
    final int count = runtimesFor(platform).length;
    return count == 0
        ? '${platformLabel(platform)}：无可用音源'
        : '${platformLabel(platform)}：$count 个可用音源';
  }
}

/// 解析结果。
class SourceResolveResult {
  /// 创建结果。
  const SourceResolveResult({
    required this.ok,
    this.url = '',
    this.provider = '',
    this.error = '',
    this.requestedQuality = '',
    this.resolvedQuality = '',
    this.format = '',
    this.contentType = '',
    this.fileSize = 0,
    this.bitrateKbps,
  });

  /// 是否成功。
  final bool ok;

  /// 播放地址（成功时）。
  final String url;

  /// 哪个音源给的（成功时，用于界面提示）。
  final String provider;

  /// 失败原因（把每个脚本的失败都串起来，便于排查）。
  final String error;

  /// 用户请求的档位与音源最终实际调用的档位。
  final String requestedQuality;
  final String resolvedQuality;

  /// 从 URL / Content-Type 解析出的实际封装格式，永远不会是 php。
  final String format;
  final String contentType;
  final int fileSize;
  final int? bitrateKbps;
}

/// 音源宿主 provider。
final sourceHostProvider =
    AsyncNotifierProvider<SourceHostController, SourceHostState>(
      SourceHostController.new,
    );

/// 音源宿主控制器。
class SourceHostController extends AsyncNotifier<SourceHostState> {
  List<SourceRuntime> _runtimes = <SourceRuntime>[];

  /// 单个脚本初始化超时。对照 LX 的请求默认 60 秒，这里给 20 秒，
  /// 避免跨境源首次初始化稍慢就被误判成“没有上报 inited”。
  static const Duration _scriptTimeout = Duration(seconds: 20);

  @override
  Future<SourceHostState> build() async {
    _disposeAll();
    ref.onDispose(_disposeAll);

    final List<MusicSource> all = await ref.watch(
      sourceRegistryProvider.future,
    );
    final List<MusicSource> enabled = all
        .where((MusicSource s) => s.enabled)
        .toList(growable: false);
    if (enabled.isEmpty) {
      _runtimes = <SourceRuntime>[];
      return const SourceHostState();
    }

    // 并行加载：脚本初始化普遍要发一次网络请求，串行会等到天荒地老。
    final List<SourceRuntime?> loaded = await Future.wait(enabled.map(_load));
    _runtimes = loaded.whereType<SourceRuntime>().toList(growable: false);
    return SourceHostState(runtimes: _runtimes);
  }

  Future<SourceRuntime?> _load(MusicSource meta) async {
    String? code;
    try {
      code = await ref.read(sourceRegistryProvider.notifier).readCode(meta.id);
    } catch (_) {
      code = null;
    }
    if (code == null || code.trim().isEmpty) return null;
    final LxSandbox sandbox = LxSandbox.create();
    try {
      final LxScriptReport report = await sandbox.loadScript(
        name: meta.name,
        code: code,
        path: meta.location,
        timeout: _scriptTimeout,
      );
      return SourceRuntime(meta: meta, sandbox: sandbox, report: report);
    } catch (_) {
      sandbox.dispose();
      return null;
    }
  }

  void _disposeAll() {
    for (final SourceRuntime r in _runtimes) {
      r.sandbox.dispose();
    }
    _runtimes = <SourceRuntime>[];
  }

  /// 重新加载所有启用的脚本（音源管理页的「重新加载」按钮）。
  Future<void> reload() async {
    ref.invalidateSelf();
    await future;
  }

  /// 当前所有脚本的加载报告（用于写回登记表）。
  Map<String, LxScriptReport> get reports => <String, LxScriptReport>{
    for (final SourceRuntime r in _runtimes) r.meta.id: r.report,
  };

  /// 首次解析前等一下宿主装载完成（每个脚本最长 20 秒）。
  ///
  /// 不等的话，用户在音源还在装的时候点播放，会看到
  /// 「还没有可用音源」这种**假报错**（其实只是还没装完）。
  Future<void> _ensureLoaded() async {
    if (_runtimes.isNotEmpty) return;
    try {
      await future;
    } catch (_) {
      // 装载失败的原因会体现在 state 里，这里不重复抛
    }
  }

  /// 解析播放地址。
  ///
  /// 顺序：支持该平台的每个脚本 → 每个脚本再按音质从高到低试。
  Future<SourceResolveResult> resolveMusicUrl(
    OnlineTrack track, {
    String? quality,
  }) async {
    await _ensureLoaded();
    final String wanted = quality ?? track.quality;
    final List<SourceRuntime> candidates = _runtimes
        .where((SourceRuntime r) => r.ok && r.supports(track.platform))
        .take(1)
        .toList(growable: false);
    if (candidates.isEmpty) {
      final List<String> available =
          (state.value ?? const SourceHostState()).platforms;
      return SourceResolveResult(
        ok: false,
        error: available.isEmpty
            ? '还没有可用音源：去「音源管理」导入脚本并加载'
            : '没有启用的音源支持「${platformLabel(track.platform)}」，'
                  '当前可用：${available.map(platformLabel).join('、')}',
      );
    }

    final List<String> errors = <String>[];
    // ⚠️ 0.0.57：音质改成**在外层循环**（用户反馈："选 flac 无损，放出来还是 mp3"）。
    //    旧逻辑是"每个源先按该源自己的音质顺序降级"，于是第一个源没有无损就
    //    立刻掉到 320k/mp3，后面的源根本没机会给无损。
    //    现在：先把想要的音质在**所有**候选源上试一遍，全失败才往下退一档。
    // UI / 下载明确传入档位时必须严格执行，不能悄悄降成低音质；
    // 内部自检或旧收藏没有指定档位时才允许兼容性降级。
    final List<String> ladder = quality != null
        ? <String>[wanted]
        : <String>[
            wanted,
            for (final String q in const <String>[
              'flac24bit',
              'flac',
              '320k',
              '192k',
              '128k',
            ])
              if (q != wanted) q,
          ];
    for (final String q in ladder) {
      final _BatchResolveResult batch = await _resolveQualityBatch(
        candidates,
        track,
        q,
      );
      if (batch.success != null) {
        final _UrlAttempt success = batch.success!;
        final String actual = formatOfUrl(success.url);
        return SourceResolveResult(
          ok: true,
          url: success.url,
          provider:
              '${success.runtime.meta.name} / ${qualityLabel(q)}'
              '${actual.isEmpty ? '' : '（实际 $actual）'}'
              '${q == wanted ? '' : ' ⚠️ $wanted 拿不到，已降级'}',
          requestedQuality: wanted,
          resolvedQuality: q,
          format: actual,
          bitrateKbps: success.bitrateKbps ?? bitrateOfUrl(success.url),
        );
      }
      errors.addAll(batch.errors);
    }
    return SourceResolveResult(ok: false, error: errors.join('；'));
  }

  /// 请求当前选中的唯一音源。
  Future<_BatchResolveResult> _resolveQualityBatch(
    List<SourceRuntime> candidates,
    OnlineTrack track,
    String quality,
  ) async {
    if (candidates.isEmpty) {
      return const _BatchResolveResult(errors: <String>[]);
    }

    final Completer<_UrlAttempt> winner = Completer<_UrlAttempt>();
    final List<String> errors = <String>[];
    final SourceRuntime runtime = candidates.first;
    unawaited(() async {
      final String? mapped = _sourceQualityFor(
        runtime.qualitysFor(track.platform),
        quality,
      );
      if (runtime.qualitysFor(track.platform).isNotEmpty && mapped == null) {
        errors.add('${runtime.meta.name}：不支持 ${qualityLabel(quality)}');
        winner.completeError(StateError('quality unsupported'));
        return;
      }
      try {
        final LxActionResult result = await runtime.sandbox
            .invoke(
              action: 'musicUrl',
              source: track.platform,
              quality: mapped ?? quality,
              musicInfo: track.toMusicInfo(qualityOverride: mapped ?? quality),
            )
            // 动态 LX 音源可能先访问远程配置再解析播放地址；8 秒会把
            // 网络正常但响应稍慢的源误判为失败。与沙箱请求链路保持一致。
            .timeout(const Duration(seconds: 25));
        final String? url = result.url;
        if (result.ok && url != null && url.isNotEmpty) {
          if (_looksLikePreview(url, result.data)) {
            errors.add('${runtime.meta.name}：返回试听地址');
          } else {
            final String? returnedQuality = result.returnedQuality;
            if (returnedQuality != null &&
                commonQualityOf(returnedQuality) != null &&
                commonQualityOf(returnedQuality) != commonQualityOf(quality)) {
              errors.add(
                '${runtime.meta.name}：实际返回 ${qualityLabel(returnedQuality)}',
              );
            } else if (!winner.isCompleted) {
              winner.complete(
                _UrlAttempt(
                  runtime: runtime,
                  url: url,
                  bitrateKbps: result.returnedBitrateKbps,
                ),
              );
              return;
            }
          }
        } else {
          errors.add(
            '${runtime.meta.name}：${result.error.isEmpty ? '没返回地址' : result.error}',
          );
        }
      } catch (error) {
        errors.add('${runtime.meta.name}：$error');
      }
      if (!winner.isCompleted) {
        winner.completeError(StateError('source failed'));
      }
    }());
    try {
      final _UrlAttempt result = await winner.future.timeout(
        const Duration(seconds: 27),
      );
      return _BatchResolveResult(success: result, errors: errors);
    } catch (_) {
      return _BatchResolveResult(errors: errors);
    }
  }

  /// 拒绝音源明确标记的试听 / 试用地址，继续尝试下一个音源。
  static bool _looksLikePreview(String url, Object? data) {
    final String lower = url.toLowerCase();
    if (RegExp(r'preview|free.?trial|sample|试听|试用').hasMatch(lower)) {
      return true;
    }
    if (data is Map) {
      for (final String key in const <String>[
        'freeTrialInfo',
        'free_trial_info',
        'preview',
        'isPreview',
        'isTrial',
      ]) {
        final Object? value = data[key];
        if (value != null && value != false && value.toString().isNotEmpty) {
          return true;
        }
      }
    }
    return false;
  }

  /// 将界面四档映射为不同 LX 音源脚本使用的内部名称。
  static String? _sourceQualityFor(List<String> supported, String quality) {
    if (supported.isEmpty) return null;
    if (quality != 'flac24bit') {
      return supported.contains(quality) ? quality : null;
    }
    for (final String alias in const <String>['flac24bit', 'hires', 'master']) {
      if (supported.contains(alias)) return alias;
    }
    return null;
  }

  /// 从播放地址里看**实际格式**（有些源说给无损、其实回的是 mp3）。
  ///
  /// 供界面提示：`网易云 / 无损 FLAC（实际 mp3）` —— 用户能一眼看出没拿到无损。
  ///
  /// 0.0.59 修：接口型地址（`…/kw.php?type=mp3`、`…/wy.php?type=flac`）的扩展名是
  /// **脚本名 `.php`**，不是音频格式 —— 以前会显示成"实际 php"（自检里抓到过）。
  /// 现在先看查询参数里的 `type=`/`format=`，再退回看路径扩展名。
  static String formatOfUrl(String url) {
    // ① 查询参数里的 type=/format=（音源接口最常见的写法）
    final int q = url.indexOf('?');
    if (q >= 0 && q + 1 < url.length) {
      final String query = url.substring(q + 1);
      for (final String key in const <String>['type', 'format', 'fmt']) {
        final RegExp re = RegExp('(?:^|&)$key=([a-zA-Z0-9]{2,5})(?:&|\$)');
        final String? value = re.firstMatch(query)?.group(1)?.toLowerCase();
        if (value != null && _isAudioFormat(value)) return value;
      }
    }
    // ② 路径扩展名
    final String path = q >= 0 ? url.substring(0, q) : url;
    final int dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    final String ext = path.substring(dot + 1).toLowerCase();
    if (ext.length > 4 || !RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return '';
    if (!_isAudioFormat(ext)) return ''; // `.php` / `.asp` 这类不是格式
    return ext;
  }

  /// 从音源 URL 的公开查询参数读取码率；没有就返回 null，绝不按选择档位臆测。
  static int? bitrateOfUrl(String url) {
    final Uri? parsed = Uri.tryParse(url);
    if (parsed == null) return null;
    for (final String key in const <String>[
      'bitrate',
      'bit_rate',
      'br',
      'kbps',
      'rate',
    ]) {
      final int? raw = int.tryParse(parsed.queryParameters[key] ?? '');
      if (raw == null || raw <= 0) continue;
      return raw >= 10000 ? (raw / 1000).round() : raw;
    }
    return null;
  }

  /// 是不是音频格式（用来挡掉 `.php` 这种接口后缀）。
  static bool _isAudioFormat(String value) => const <String>{
    'mp3',
    'flac',
    'm4a',
    'aac',
    'wav',
    'ape',
    'ogg',
    'opus',
    'wma',
    'mp4',
    'dsf',
    'dff',
    'aiff',
    'alac',
  }.contains(value);

  /// 取歌词（脚本的 `lyric` 动作；失败返回空串）。
  Future<String> fetchLyric(OnlineTrack track) async {
    await _ensureLoaded();
    final List<SourceRuntime> candidates = _runtimes
        .where((SourceRuntime r) => r.ok && r.supports(track.platform, 'lyric'))
        .toList(growable: false);
    for (final SourceRuntime runtime in candidates) {
      final LxActionResult result = await runtime.sandbox.invoke(
        action: 'lyric',
        source: track.platform,
        musicInfo: track.toMusicInfo(),
      );
      final Object? data = result.data;
      final String text = data is Map
          ? (data['lyric']?.toString() ?? '')
          : (data?.toString() ?? '');
      if (result.ok && text.trim().isNotEmpty) return text;
    }
    return '';
  }

  /// 按音源脚本的 `pic` 动作获取曲目封面，支持同平台脚本依次兜底。
  Future<String?> fetchPic(OnlineTrack track) async {
    await _ensureLoaded();
    final List<SourceRuntime> candidates = _runtimes
        .where((SourceRuntime r) => r.ok && r.supports(track.platform, 'pic'))
        .toList(growable: false);
    for (final SourceRuntime runtime in candidates) {
      final LxActionResult result = await runtime.sandbox.invoke(
        action: 'pic',
        source: track.platform,
        musicInfo: track.toMusicInfo(),
      );
      if (!result.ok) continue;
      final Object? data = result.data;
      final String url = data is Map
          ? (data['url'] ?? data['pic'] ?? data['picUrl'] ?? '').toString()
          : (data?.toString() ?? '');
      if (url.startsWith('https://') || url.startsWith('http://')) return url;
    }
    return null;
  }
}

class _UrlAttempt {
  const _UrlAttempt({
    required this.runtime,
    required this.url,
    this.bitrateKbps,
  });

  final SourceRuntime runtime;
  final String url;
  final int? bitrateKbps;
}

class _BatchResolveResult {
  const _BatchResolveResult({this.success, this.errors = const <String>[]});

  final _UrlAttempt? success;
  final List<String> errors;
}
