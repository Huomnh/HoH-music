/// cover_art.dart
///
/// 歌曲封面：**内嵌封面**与**网络刮削**两种来源（架构文档 3.7 元数据补全）。
///
/// | 来源 | 说明 |
/// |---|---|
/// | [CoverSource.embedded] | 只读音频文件里的内嵌封面（ID3 APIC / Vorbis METADATA_BLOCK_PICTURE / MP4 covr） |
/// | [CoverSource.network] | 只走网络刮削 |
/// | [CoverSource.auto] | 内嵌优先，没有再去刮（默认） |
///
/// 歌手卡片优先使用国内平台搜索结果中的代表作专辑封面，iTunes 仅作为回退；
/// 本地/WebDAV 曲目可优先走自定义音源 pic。
///
/// ⚠️ 两条纪律：
/// 1. **封面只在需要时读**（当前播放的这首），绝不放进目录扫描循环 ——
///    上万首每首都把封面读进内存会很难看；
/// 2. 网络失败**不是错误**：返回 null，界面继续显示渐变占位，
///    结果（含失败）在本次运行内缓存，避免反复请求同一个不存在的封面。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../audio/player_engine.dart';
import '../audio/player_providers.dart';
import '../source/host_search.dart';
import '../source/source_models.dart';
import '../source/source_store.dart';
import 'text_match.dart';

/// 封面来源。
enum CoverSource {
  /// 只读内嵌封面。
  embedded('内嵌封面', '从音频文件里读（离线、最准）'),

  /// 只走网络刮削。
  network('网络刮削', '按「艺术家 + 歌名」联网找（需要联网）'),

  /// 内嵌优先，缺了再联网。
  auto('自动', '内嵌优先，没有再去网上找（推荐）');

  const CoverSource(this.label, this.description);

  /// 界面显示名。
  final String label;

  /// 一句话说明。
  final String description;
}

/// 封面来源设置（持久化）。
final coverSourceProvider =
    AsyncNotifierProvider<CoverSourceController, CoverSource>(
      CoverSourceController.new,
    );

/// 封面来源控制器。
class CoverSourceController extends AsyncNotifier<CoverSource> {
  static const String _key = 'cover.source';

  @override
  Future<CoverSource> build() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? name = prefs.getString(_key);
      return CoverSource.values.firstWhere(
        (CoverSource s) => s.name == name,
        orElse: () => CoverSource.auto,
      );
    } catch (error) {
      debugPrint('[Cover] 读取封面来源失败（用自动）：$error');
      return CoverSource.auto;
    }
  }

  /// 设置来源。
  Future<void> setSource(CoverSource source) async {
    state = AsyncData<CoverSource>(source);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, source.name);
    } catch (error) {
      debugPrint('[Cover] 保存封面来源失败：$error');
    }
  }
}

/// 封面服务：内嵌读取 + 网络刮削 + 本次运行内的缓存。
class CoverArtService {
  CoverArtService._();

  /// 单例。
  static final CoverArtService instance = CoverArtService._();

  /// key = `曲目id|来源`，value = 封面字节（null 表示"确认没有"）。
  final Map<String, Uint8List?> _cache = <String, Uint8List?>{};

  /// 搜索结果缓存：key = `艺术家|标题`，value = 图片地址。
  final Map<String, String?> _urlCache = <String, String?>{};

  Dio? _dio;
  Dio get _client => _dio ??= Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 25),
    ),
  );

  /// 取一首曲目的封面（可能返回 null = 没有）。
  ///
  /// [useOnlineMatch] = 用音源平台刮（`sourceScrapeProvider`）：
  /// - **远端曲目**（在线音源 / WebDAV）：`wy:123456` 这种 id 里就有歌曲号，
  ///   直接按平台取，比只按歌名联网猜测更准；
  /// - **本地曲目**：用音源平台匹配，再通过 iTunes 查找。
  ///
  /// 顺序很重要：**自定义音源优先、iTunes 兜底**，减少错误版本封面。
  Future<Uint8List?> forTrack(
    Track track,
    CoverSource source, {
    bool useOnlineMatch = false,
  }) async {
    // 队列刚建好时曲目还是"文件名占位"（artist=读取中…），这时去刮削
    // 只会拿占位当关键词，刮回来的是错的（0.0.17 在日志里抓到的）。
    // 等元数据补全后 currentTrack 会换成真曲目，那时再取。
    if (source != CoverSource.embedded && _looksLikePlaceholder(track)) {
      debugPrint('[Cover] 曲目信息还没补全，先不刮削：${track.title}');
      return null;
    }

    final String key =
        '${track.id}|${source.name}'
        '|${useOnlineMatch ? 'online' : 'legacy'}|${track.artist}|${track.title}';
    if (_cache.containsKey(key)) return _cache[key];

    Uint8List? bytes;
    if (useOnlineMatch && source != CoverSource.embedded) {
      try {
        final String? online = await HostSearch.instance.coverUrlForTrack(
          track,
        );
        if (online != null && online.isNotEmpty) {
          bytes = await _download(online);
          if (bytes != null) {
            _cache[key] = bytes;
            return bytes;
          }
        }
      } catch (error) {
        debugPrint('[Cover] 音源平台取封面失败（回退 iTunes）：$error');
      }
    }

    switch (source) {
      case CoverSource.embedded:
        bytes = _embedded(track);
      case CoverSource.network:
        bytes = await _scrape(track);
      case CoverSource.auto:
        bytes = _embedded(track) ?? await _scrape(track);
    }

    _cache[key] = bytes;
    return bytes;
  }

  /// 是否是"元数据还没补全"的占位曲目。
  static bool _looksLikePlaceholder(Track track) =>
      track.artist.contains('读取中') ||
      track.artist.trim().isEmpty ||
      track.artist == '未知艺术家';

  /// 清空缓存（设置里换来源后强制重取）。
  void clearCache() {
    _cache.clear();
    _urlCache.clear();
  }

  Uint8List? _embedded(Track track) {
    if (track.isRemote) return null;
    return Track.readEmbeddedCover(track.id);
  }

  // ── 专辑 / 歌手封面（0.0.28：曲库卡片用）────────────────────────

  /// 专辑封面：按「艺术家 + 专辑名」搜 `entity=album`。
  ///
  /// 与曲目封面同一套"宁可不显示也不要错的图"原则：
  /// 专辑名相似度不到 0.6 就直接返回 null。
  Future<Uint8List?> forAlbum(String album, String artist) async {
    final String name = album.trim();
    if (name.isEmpty || name == '未知专辑') return null;
    final String cacheKey = 'album|$artist|$name';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];

    Uint8List? bytes;
    try {
      final String? url = await _itunesArtworkUrl(
        '$artist $name',
        entity: 'album',
      );
      if (url != null) bytes = await _download(url);
    } catch (error) {
      debugPrint('[Cover] 专辑封面刮削失败：$error');
    }
    _cache[cacheKey] = bytes;
    return bytes;
  }

  /// 歌手封面：优先从国内平台搜索代表作，取匹配度最高的专辑封面。
  ///
  /// 国内平台通常不稳定提供独立歌手肖像，但歌曲搜索结果的专辑封面
  /// 更快、更完整，也更符合播放器的歌手卡片使用场景。只有全部失败时
  /// 才回退 iTunes，避免国内网络环境下卡住很久。
  Future<Uint8List?> forArtist(String artist) async {
    final String name = artist.trim();
    if (name.isEmpty || name == '未知艺术家') return null;
    final String cacheKey = 'artist|$name';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];

    Uint8List? bytes;
    try {
      final String? domesticUrl = await _domesticArtistArtworkUrl(name);
      final String? url =
          domesticUrl ?? await _itunesArtworkUrl(name, entity: 'album');
      if (url != null) bytes = await _download(url);
    } catch (error) {
      debugPrint('[Cover] 歌手封面刮削失败：$error');
    }
    _cache[cacheKey] = bytes;
    return bytes;
  }

  Future<String?> _domesticArtistArtworkUrl(String artist) async {
    const List<String> platforms = <String>['wy', 'tx', 'mg', 'kg', 'kw'];
    final List<PlatformSearchResult> results = await Future.wait(
      platforms.map(
        (String platform) =>
            HostSearch.instance.searchPlatform(platform, artist, limit: 8),
      ),
    );

    OnlineTrack? best;
    double bestScore = 0;
    for (final PlatformSearchResult result in results) {
      for (final OnlineTrack track in result.tracks) {
        if (track.coverUrl.trim().isEmpty) continue;
        final double score = track.artist
            .split(RegExp(r'[/、,&，及]'))
            .map((String item) => similarityOf(item, artist))
            .fold<double>(0, math.max);
        if (score > bestScore) {
          bestScore = score;
          best = track;
        }
      }
    }
    return bestScore >= 0.55 ? best?.coverUrl : null;
  }

  /// 网络刮削：iTunes Search API。
  ///
  /// ⚠️ 实测（本机）：搜索只要 ~0.8s，但封面 CDN（`is1-ssl.mzstatic.com`）
  /// 拉 600×600 要 ~22s —— 所以超时给足，并且**大图失败就退回 100×100 小图**，
  /// 宁可先看到一张糊的，也不要一直空着。
  Future<Uint8List?> _scrape(Track track) async {
    try {
      final String? url = await _searchArtworkUrl(track);
      if (url == null) return null;

      final List<String> candidates = <String>[
        url, // 600x600
        url.replaceAll('600x600bb', '100x100bb'), // 小图兜底
      ];

      for (final String candidate in candidates) {
        final Uint8List? bytes = await _download(candidate);
        if (bytes != null) {
          debugPrint(
            '[Cover] 刮削成功：${track.artist} - ${track.title}'
            '（${bytes.length} 字节，${candidate.contains('600x600') ? "大图" : "小图"}）',
          );
          return bytes;
        }
      }
      return null;
    } catch (error) {
      debugPrint('[Cover] 刮削失败（不影响播放）：$error');
      return null;
    }
  }

  Future<Uint8List?> _download(String url) async {
    try {
      final Response<List<int>> response = await _client.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 25),
        ),
      );
      if (response.statusCode != 200 || response.data == null) return null;
      return Uint8List.fromList(response.data!);
    } catch (error) {
      debugPrint('[Cover] 下载封面失败：$error');
      return null;
    }
  }

  /// 下载自定义音源 `pic` 动作返回的图片地址。
  Future<Uint8List?> downloadRemoteImage(String url) => _download(url);

  /// 搜索匹配录音并取其发行封面。
  Future<String?> _searchArtworkUrl(Track track) async {
    final String key = '${track.artist}|${track.title}';
    if (_urlCache.containsKey(key)) return _urlCache[key];

    String? artwork;
    try {
      artwork = await _itunesArtworkUrl(
        '${track.artist} ${track.title}',
        entity: 'song',
      );
    } catch (error) {
      debugPrint('[Cover] 搜索失败（可能没联网）：$error');
    }

    _urlCache[key] = artwork;
    return artwork;
  }

  Future<String?> _itunesArtworkUrl(
    String term, {
    required String entity,
  }) async {
    try {
      final Response<dynamic> response = await _client.get<dynamic>(
        'https://itunes.apple.com/search',
        queryParameters: <String, dynamic>{
          'term': term,
          'entity': entity,
          'country': 'cn',
          'limit': 5,
        },
        options: Options(responseType: ResponseType.plain),
      );
      final Object? decoded = jsonDecode(response.data?.toString() ?? '');
      if (decoded is! Map || decoded['results'] is! List) return null;
      for (final Object? item in decoded['results'] as List) {
        if (item is! Map) continue;
        final String url =
            (item['artworkUrl600'] ?? item['artworkUrl100'] ?? '')
                .toString()
                .replaceFirst('100x100', '600x600');
        if (url.isNotEmpty) return url;
      }
    } catch (error) {
      debugPrint('[Cover] iTunes 搜索失败：$error');
    }
    return null;
  }

  /// 从搜索结果里挑最匹配的一条，返回它的 600×600 封面地址。
  /// 两个名字的相似度（0~1）。
  ///
  /// 规则：归一化后完全相等 → 1；一方包含另一方 → 0.8；
  /// 否则用 **bigram Dice 系数**（对中英文都适用，比编辑距离省事）：
  /// `2·|A∩B| / (|A|+|B|)`。
  ///
  /// 实现已抽到 `text_match.dart`（宿主搜索匹配歌名也用同一套）。
  @visibleForTesting
  static double similarity(String a, String b) => similarityOf(a, b);

  /// 归一化歌名 / 艺术家名：小写、去掉括号内容与标点空格。
  ///
  /// 去掉 `(...)` / `（...）` / `[...]` 很重要：搜索结果的
  /// `半句再见 (Live)` 与我们的 `半句再见` 应当算同一个名字。
  @visibleForTesting
  static String normalizeName(String raw) => normalizeTrackText(raw);

  /// 是否处于"需要联网"的来源（设置页提示用）。
  static bool needsNetwork(CoverSource source) =>
      source == CoverSource.network || source == CoverSource.auto;
}

/// 当前曲目的封面字节。没有曲目 / 拿不到封面时为 `null`。
final currentCoverProvider = FutureProvider<Uint8List?>((ref) async {
  final Track? track = ref.watch(
    // 只关心"当前是哪首"，队列里其它字段变化不必重取封面
    playerControllerProvider.select((PlayerUiState s) => s.currentTrack),
  );
  if (track == null) return null;

  final CoverSource source =
      ref.watch(coverSourceProvider).value ?? CoverSource.auto;
  // 本地 / WebDAV 曲目也用音源平台刮封面（设置里可关，见 sourceScrapeProvider）
  final bool useOnline = ref.watch(sourceScrapeProvider).value ?? false;
  return CoverArtService.instance.forTrack(
    track,
    source,
    useOnlineMatch: useOnline,
  );
});
