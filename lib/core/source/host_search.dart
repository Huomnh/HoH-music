/// host_search.dart
///
/// **宿主搜索层**：自定义音源脚本只提供 `musicUrl` / `lyric` / `pic`，
/// **没有 `search`** —— 所以"搜什么歌"必须由宿主自己做，搜完把
/// 平台原始字段塞进 `info.musicInfo` 交给脚本。
///
/// 目前支持（和 lx-music 一样按平台搜）：
///
/// | 平台 | 搜索 | 歌词 | 封面 | 备注 |
/// |---|---|---|---|---|
/// | 网易云 `wy` | ✅ | ✅ | ✅ | 中文曲库最全，首选 |
/// | QQ音乐 `tx` | ✅ | ✅ | ✅（按 albumMid 拼图床） | |
/// | 酷狗 `kg` | ✅ | ✅（两段式） | ⚠️ 平台不给，退回按歌名刮 | |
/// | 酷我 `kw` | ✅ | ✅ | ⚠️ 同上 | 老接口返回的是「单引号对象」，要容错解析 |
/// | 咪咕 `mg` | ✅ | ✅ | ✅ | |
///
/// ⚠️ 全部是**非官方接口**（各平台没有公开 API）：只做只读搜索/详情/歌词，
/// 带正常 `Referer`/`User-Agent`，并限速 150ms/次。合规性请自行判断。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../audio/player_engine.dart' show Track;
import '../metadata/text_match.dart';
import 'source_cache.dart';
import 'source_models.dart';

/// 宿主能搜的平台（按推荐顺序）。
const List<String> kSearchablePlatforms = <String>[
  'wy',
  'tx',
  'kg',
  'kw',
  'mg',
];

/// 一次分页搜索的结果。
class PlatformSearchResult {
  /// 创建结果。
  const PlatformSearchResult({
    this.tracks = const <OnlineTrack>[],
    this.total = 0,
    this.page = 1,
    this.limit = 30,
    this.error = '',
  });

  /// 本页曲目。
  final List<OnlineTrack> tracks;

  /// 平台报的总数（0 = 不知道）。界面用它显示「共 N 首」。
  final int total;

  /// 页码（从 1 开始）。
  final int page;

  /// 每页数量。
  final int limit;

  /// 失败原因（空 = 成功；失败时 [tracks] 为空）。
  final String error;

  /// 还有没有下一页（按"本页拿满了"判断）。
  bool get hasMore => tracks.length >= limit && error.isEmpty;
}

/// 一次搜索的结果（含"用的哪家、有没有降级"的说明）。
class SearchOutcome {
  /// 创建结果。
  const SearchOutcome({
    required this.tracks,
    required this.provider,
    this.note = '',
    this.total = 0,
    this.hasMore = false,
    this.page = 1,
  });

  /// 搜到的曲目。
  final List<OnlineTrack> tracks;

  /// 实际生效的来源（`网易云` / `全部平台` …）。
  final String provider;

  /// 提示（例如某个平台搜索失败）。
  final String note;

  /// 平台报的总数。
  final int total;

  /// 还有没有下一页。
  final bool hasMore;

  /// 当前页码。
  final int page;

  /// 是否为空结果。
  bool get isEmpty => tracks.isEmpty;
}

/// Public 芸音歌单的基本信息，用于歌单导入而不是播放地址解析。
class NeteasePlaylistInfo {
  const NeteasePlaylistInfo({
    required this.id,
    required this.name,
    required this.tracks,
  });

  final String id;
  final String name;
  final List<OnlineTrack> tracks;
}

/// Public 鹅音歌单的基本信息。与芸音模型分开，避免不同平台字段结构混用。
class QqPlaylistInfo {
  const QqPlaylistInfo({
    required this.id,
    required this.name,
    required this.tracks,
    this.shareUrl = '',
  });

  final String id;
  final String name;
  final List<OnlineTrack> tracks;
  final String shareUrl;
}

/// 宿主搜索 / 刮削服务（单例）。
class HostSearch {
  HostSearch._();

  /// 单例。
  static final HostSearch instance = HostSearch._();

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// 手机 UA：咪咕 / 酷狗的移动接口只认它。
  static const String _uaMobile =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 '
      'Safari/604.1';

  Dio? _dio;

  /// 上一次操作失败的原因（界面用来提示）。
  String lastError = '';

  /// 两次请求之间的最小间隔（非官方接口，别打太猛）。
  static const Duration _minInterval = Duration(milliseconds: 150);
  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

  final Map<String, String?> _lyricCache = <String, String?>{};
  final Map<String, String?> _coverCache = <String, String?>{};
  final Map<String, OnlineTrack?> _matchCache = <String, OnlineTrack?>{};

  Dio get _client => _dio ??= Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      responseType: ResponseType.json,
      headers: <String, String>{'User-Agent': _ua},
      validateStatus: (int? code) => code != null && code < 500,
    ),
  );

  /// 释放 HTTP 资源（测试 / 退出时用）。
  void dispose() {
    _dio?.close(force: true);
    _dio = null;
  }

  Future<void> _throttle() async {
    final Duration since = DateTime.now().difference(_lastRequestAt);
    if (since < _minInterval) {
      await Future<void>.delayed(_minInterval - since);
    }
    _lastRequestAt = DateTime.now();
  }

  Future<Response<dynamic>> _get(
    String url, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    String referer = '',
    ResponseType? responseType,
    bool? followRedirects,
    int? maxRedirects,
  }) async {
    await _throttle();
    return _client.get<dynamic>(
      url,
      queryParameters: query,
      options: Options(
        responseType: responseType,
        headers: <String, String>{
          if (referer.isNotEmpty) 'Referer': referer,
          ...?headers,
        },
        followRedirects: followRedirects,
        maxRedirects: maxRedirects,
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════
  //  统一入口
  // ════════════════════════════════════════════════════════════════

  /// 搜一个平台（分页）。
  Future<PlatformSearchResult> searchPlatform(
    String platform,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final String trimmed = keyword.trim();
    if (trimmed.isEmpty) return const PlatformSearchResult();
    try {
      switch (platform) {
        case 'wy':
          return await _searchNetease(trimmed, page: page, limit: limit);
        case 'tx':
          return await _searchQQ(trimmed, page: page, limit: limit);
        case 'kg':
          return await _searchKugou(trimmed, page: page, limit: limit);
        case 'kw':
          return await _searchKuwo(trimmed, page: page, limit: limit);
        case 'mg':
          return await _searchMigu(trimmed, page: page, limit: limit);
        default:
          return PlatformSearchResult(error: '不支持的平台：$platform');
      }
    } catch (error) {
      return PlatformSearchResult(error: _humanize(error));
    }
  }

  /// **多平台一起搜**（`platforms` 里的并行发，谁先回来先算谁的）。
  ///
  /// 结果按平台顺序拼：同平台的排在一起，界面上靠平台标签区分。
  Future<SearchOutcome> searchAll(
    List<String> platforms,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    final String trimmed = keyword.trim();
    if (trimmed.isEmpty || platforms.isEmpty) {
      return const SearchOutcome(tracks: <OnlineTrack>[], provider: '—');
    }
    final List<PlatformSearchResult> results = await Future.wait(
      platforms.map(
        (String p) => searchPlatform(p, trimmed, page: page, limit: limit),
      ),
    );

    final List<OnlineTrack> tracks = <OnlineTrack>[];
    final List<String> ok = <String>[];
    final List<String> failed = <String>[];
    int total = 0;
    for (int i = 0; i < platforms.length; i++) {
      final PlatformSearchResult r = results[i];
      final String label = platformLabel(platforms[i]);
      if (r.error.isEmpty) {
        ok.add('$label ${r.tracks.length}');
        tracks.addAll(r.tracks);
        total += r.total;
      } else {
        failed.add('$label：${r.error}');
      }
    }
    final bool hasMore = results.any((PlatformSearchResult r) => r.hasMore);
    return SearchOutcome(
      tracks: tracks,
      provider: platforms.length == 1 ? platformLabel(platforms.first) : '全部平台',
      note: <String>[
        if (ok.isNotEmpty) '成功：${ok.join(' / ')}',
        if (failed.isNotEmpty) '失败：${failed.join('；')}',
      ].join('　'),
      total: total,
      hasMore: hasMore,
      page: page,
    );
  }

  /// 单平台搜索。失败时直接返回平台错误，避免返回没有完整播放能力的试听结果。
  Future<SearchOutcome> search(
    String keyword, {
    String platform = 'wy',
    int limit = 30,
    int page = 1,
  }) async {
    final PlatformSearchResult primary = await searchPlatform(
      platform,
      keyword,
      page: page,
      limit: limit,
    );
    if (primary.error.isEmpty && primary.tracks.isNotEmpty) {
      return SearchOutcome(
        tracks: primary.tracks,
        provider: platformLabel(platform),
        total: primary.total,
        hasMore: primary.hasMore,
        page: page,
      );
    }
    lastError = primary.error.isEmpty ? '没有匹配的歌曲' : primary.error;
    if (platform != 'wy') {
      return SearchOutcome(
        tracks: const <OnlineTrack>[],
        provider: platformLabel(platform),
        note: lastError,
        page: page,
      );
    }
    return SearchOutcome(
      tracks: const <OnlineTrack>[],
      provider: platformLabel(platform),
      note: lastError,
      page: page,
    );
  }

  // ════════════════════════════════════════════════════════════════
  //  各平台搜索
  // ════════════════════════════════════════════════════════════════

  /// 网易云搜索。兼容旧 `/api/search/get/web` 与备用 `cloudsearch`。
  Future<PlatformSearchResult> _searchNetease(
    String keyword, {
    required int page,
    required int limit,
  }) async {
    final int offset = (page - 1) * limit;
    final Response<dynamic> res = await _get(
      'https://music.163.com/api/search/get/web',
      query: <String, dynamic>{
        's': keyword,
        'type': 1,
        'limit': limit,
        'offset': offset,
        'total': true,
      },
      referer: 'https://music.163.com/',
      headers: <String, String>{'Cookie': 'appver=8.9.70; os=pc'},
    );
    Map<String, dynamic> body = _asMap(res.data);
    List<OnlineTrack> tracks = parseNeteaseSearch(body);
    int total = _totalOfNetease(body);
    if (tracks.isEmpty) {
      final Response<dynamic> alt = await _client.post<dynamic>(
        'https://music.163.com/api/cloudsearch/pc',
        data: <String, dynamic>{
          's': keyword,
          'type': 1,
          'limit': limit,
          'offset': offset,
          'total': true,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: <String, String>{
            'Referer': 'https://music.163.com/',
            'Cookie': 'appver=8.9.70; os=pc',
          },
        ),
      );
      body = _asMap(alt.data);
      tracks = parseNeteaseSearch(body);
      total = _totalOfNetease(body);
    }
    return PlatformSearchResult(
      tracks: tracks,
      total: total,
      page: page,
      limit: limit,
    );
  }

  /// QQ音乐搜索（`client_search_cp`，`new_json=1` 给的是清洗过的字段）。
  Future<PlatformSearchResult> _searchQQ(
    String keyword, {
    required int page,
    required int limit,
  }) async {
    final Response<dynamic> res = await _get(
      'https://c.y.qq.com/soso/fcgi-bin/client_search_cp',
      query: <String, dynamic>{
        'w': keyword,
        'p': page,
        'n': limit,
        'cr': 1,
        'new_json': 1,
        'format': 'json',
        'platform': 'yqq.json',
      },
      referer: 'https://y.qq.com/',
    );
    final Map<String, dynamic> body = _asMap(res.data);
    return PlatformSearchResult(
      tracks: parseQQSearch(body),
      total:
          _asMap(_asMap(body['data'])['song'])['totalnum'] as int? ??
          int.tryParse(
            _asMap(_asMap(body['data'])['song'])['totalnum']?.toString() ?? '',
          ) ??
          0,
      page: page,
      limit: limit,
    );
  }

  /// 酷狗搜索（`mobilecdn` 老接口，不需要签名）。
  ///
  /// ⚠️ 走 **http**：本机到 `mobilecdn.kugou.com` 的 https 证书是
  /// 主机名不匹配（`CERTIFICATE_VERIFY_FAILED: Hostname mismatch`），
  /// 实测 http 正常（返回 `data.info[]`）。
  Future<PlatformSearchResult> _searchKugou(
    String keyword, {
    required int page,
    required int limit,
  }) async {
    final Response<dynamic> res = await _get(
      'http://mobilecdn.kugou.com/api/v3/search/song',
      query: <String, dynamic>{
        'format': 'json',
        'keyword': keyword,
        'page': page,
        'pagesize': limit,
        'showtype': 1,
      },
      headers: <String, String>{'User-Agent': _uaMobile},
      referer: 'http://m.kugou.com/',
    );
    final Map<String, dynamic> body = _asMap(res.data);
    final Map<String, dynamic> data = _asMap(body['data']);
    return PlatformSearchResult(
      tracks: parseKugouSearch(body),
      total: int.tryParse(data['total']?.toString() ?? '') ?? 0,
      page: page,
      limit: limit,
    );
  }

  /// 酷我搜索（`search.kuwo.cn/r.s`，返回的是单引号对象字面量）。
  Future<PlatformSearchResult> _searchKuwo(
    String keyword, {
    required int page,
    required int limit,
  }) async {
    final Response<dynamic> res = await _get(
      'http://search.kuwo.cn/r.s',
      query: <String, dynamic>{
        'all': keyword,
        'ft': 'music',
        'itemset': 'web_2013',
        'client': 'kt',
        'pn': page - 1,
        'rn': limit,
        'rformat': 'json',
        'encoding': 'utf8',
      },
      referer: 'http://www.kuwo.cn/',
    );
    // dio 按 JSON 解析会失败（不是合法 JSON），所以这里的 data 往往是 String
    final String raw = res.data is String
        ? res.data as String
        : jsonEncode(res.data);
    final Map<String, dynamic> body = looseObjectToMap(raw);
    return PlatformSearchResult(
      tracks: parseKuwoSearch(body),
      total: int.tryParse(body['TOTAL']?.toString() ?? '') ?? 0,
      page: page,
      limit: limit,
    );
  }

  /// 咪咕搜索（**v2 接口**：老的 `m.music.migu.cn/.../scr_search_tag` 已经
  /// 301 到 v5 页面、拿不到数据了）。
  ///
  /// 这个接口的好处：结果里直接带 `lyricUrl` 和平台标签。
  Future<PlatformSearchResult> _searchMigu(
    String keyword, {
    required int page,
    required int limit,
  }) async {
    final Response<dynamic> res = await _get(
      'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do',
      query: <String, dynamic>{
        'text': keyword,
        'pageNo': page,
        'pageSize': limit,
        'isCopyright': 1,
        'sort': 1,
        'searchSwitch':
            '{"song":1,"album":0,"singer":0,"tagSong":0,'
            '"mvSong":0,"bestShow":1,"songlist":0}',
      },
      headers: <String, String>{
        'User-Agent': _uaMobile,
        'channel': '014000D',
        'ua': 'Android_migu',
        'version': '5.1',
      },
    );
    final Map<String, dynamic> body = _asMap(res.data);
    final Map<String, dynamic> data = _asMap(body['songResultData']);
    return PlatformSearchResult(
      tracks: parseMiguSearch(body),
      total: int.tryParse(data['totalCount']?.toString() ?? '') ?? 0,
      page: page,
      limit: limit,
    );
  }

  // ════════════════════════════════════════════════════════════════
  //  歌词
  // ════════════════════════════════════════════════════════════════

  /// （0.0.52）**中文翻译歌词的那套逻辑已按用户要求整体删除**，准备推倒重做。
  ///
  /// 删掉的是：`extractTranslation` / `mergeTranslation` / `hasTranslation` /
  /// `_findTranslation`，以及 `lyricFor` 里的 `preferTranslation` 分支。
  /// **各平台的普通歌词抓取全部保留**（`neteaseLyric` / `qqLyric` /
  /// `kugouLyric` / `kuwoLyric` / `miguLyric` 一个没动）。
  /// 重做时的契约见 `docs/项目进度交接.md`「歌词翻译（待重建）」一节。

  /// 把翻译行**按时间戳合进原文**的旧实现已删除（0.0.52）。
  /// 见上面那段说明：翻译逻辑整体推倒重做。

  /// 找一份**单独的翻译**的旧实现已删除（0.0.52，翻译逻辑推倒重做）。

  /// 按平台取歌词（LRC）。取不到返回 `null`。
  ///
  /// 0.0.52：**翻译相关的分支已按用户要求删除**（准备重新构建），
  /// 现在只做"本平台拿不到 → 换别的平台再找一次"这一层兜底。
  Future<String?> lyricFor(
    OnlineTrack track, {
    bool crossPlatform = true,
  }) async {
    // 缓存键带版本号：生成逻辑一变就 +1，避免命中旧逻辑的持久化缓存
    final String key = '${track.id}|v3';
    if (_lyricCache.containsKey(key)) return _lyricCache[key];
    final String? cached = await SourceCache.instance.lyric(key);
    if (cached != null) {
      _lyricCache[key] = cached;
      return cached;
    }

    String? text = await _lyricFromPlatform(track);

    if ((text == null || text.trim().isEmpty) && crossPlatform) {
      final OnlineTrack? other = await _matchOtherPlatform(track);
      if (other != null) text = await _lyricFromPlatform(other);
    }
    _lyricCache[key] = text;
    // 写磁盘缓存（失败/空的不写，免得把"没有歌词"永久记下来）
    if (text != null && text.trim().isNotEmpty) {
      await SourceCache.instance.putLyric(key, text);
    }
    return text;
  }

  /// 歌词里有没有**翻译行**的判定已删除（0.0.52，翻译逻辑推倒重做）。

  /// 只问这一个平台要歌词（不做跨平台兜底）。
  Future<String?> _lyricFromPlatform(OnlineTrack track) async {
    try {
      // 咪咕的结果自带歌词地址，直接下就行
      if (track.lyricUrl.isNotEmpty) {
        final String? direct = await _fetchText(track.lyricUrl);
        final String? cleaned = _cleanLrc(direct);
        if (cleaned != null) return cleaned;
      }
      return switch (track.platform) {
        'wy' => await neteaseLyric(track.songId),
        'tx' => await qqLyric(track.songId),
        'kg' => await kugouLyric(track.songId),
        'kw' => await kuwoLyric(track.songId),
        'mg' => await miguLyric(track.songId, copyrightId: track.songId),
        _ => null,
      };
    } catch (error) {
      lastError = _humanize(error);
      return null;
    }
  }

  /// 换个平台找同一首歌（用于歌词 / 封面的跨平台兜底）。
  ///
  /// [prefer] 指定优先试哪个平台（搬翻译歌词时优先网易云）。
  Future<OnlineTrack?> _matchOtherPlatform(
    OnlineTrack track, {
    String? prefer,
  }) async {
    // ⚠️ 查询词要用**清洗过的**歌名：酷我返回的名字里有 `&nbsp;` 和
    //    「(KTV版伴奏)」这类后缀，直接拿去搜会把结果带偏（实测踩到）。
    final String title = cleanQuery(track.title);
    if (title.isEmpty) return null;
    final List<String> others = <String>[
      if (prefer != null && prefer != track.platform) prefer,
      for (final String p in const <String>['wy', 'tx', 'kg', 'mg', 'kw'])
        if (p != track.platform && p != prefer) p,
    ];
    for (final String platform in others) {
      final PlatformSearchResult result = await searchPlatform(
        platform,
        '$title ${track.artist}'.trim(),
        limit: 5,
      );
      for (final OnlineTrack candidate in result.tracks) {
        // 门槛 0.8：归一化后"一方包含另一方"就算（`晴天` vs `晴天 Live`），
        // 再严就会出现"酷我搜到的是 KTV 版 → 兜底全失败 → 没词没封面"。
        if (similarityOf(candidate.title, title) < 0.8) continue;
        if (track.artist.trim().isNotEmpty &&
            artistSimilarity(candidate.artist, track.artist) < 0.5) {
          continue;
        }
        return candidate;
      }
    }
    return null;
  }

  /// 直接下文本（咪咕的 `lyricUrl`）。
  Future<String?> _fetchText(String url) async {
    if (url.isEmpty) return null;
    try {
      final Response<dynamic> res = await _get(
        url,
        responseType: ResponseType.plain,
        headers: <String, String>{'User-Agent': _uaMobile},
      );
      final Object? data = res.data;
      return data?.toString();
    } catch (error) {
      lastError = _humanize(error);
      return null;
    }
  }

  /// 网易云歌词（带翻译）。
  Future<String?> neteaseLyric(String songId) async {
    if (songId.isEmpty) return null;
    final Response<dynamic> res = await _get(
      'https://music.163.com/api/song/lyric',
      query: <String, dynamic>{'id': songId, 'lv': -1, 'tv': -1, 'kv': -1},
      referer: 'https://music.163.com/',
      headers: <String, String>{'Cookie': 'appver=8.9.70; os=pc'},
    );
    return parseNeteaseLyric(_asMap(res.data));
  }

  /// QQ音乐歌词（返回的是 JSONP，要脱壳）。
  ///
  /// ⚠️ 这些附加参数不是可选的：少了 `loginUin/hostUin/inCharset/outCharset/
  /// notice/platform/needNewCode` 会被判 403（实测）。
  Future<String?> qqLyric(String songMid) async {
    if (songMid.isEmpty) return null;
    final Response<dynamic> res = await _get(
      'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
      query: <String, dynamic>{
        'songmid': songMid,
        'format': 'json',
        'nobase64': 1,
        'g_tk': 5381,
        'loginUin': 0,
        'hostUin': 0,
        'inCharset': 'utf8',
        'outCharset': 'utf-8',
        'notice': 0,
        'platform': 'yqq',
        'needNewCode': 0,
      },
      referer: 'https://y.qq.com/portal/player.html',
    );
    final Map<String, dynamic> body = _asMap(_stripJsonp(res.data));
    return _cleanLrc(body['lyric']?.toString());
  }

  /// 酷狗歌词：先按 hash 搜歌词 id，再下载（两段式，平台就这么设计的）。
  Future<String?> kugouLyric(String hash) async {
    if (hash.isEmpty) return null;
    final Response<dynamic> res = await _get(
      'https://krcs.kugou.com/search',
      query: <String, dynamic>{
        'ver': 1,
        'man': 'yes',
        'client': 'mobi',
        'keyword': '',
        'duration': '',
        'hash': hash,
      },
      headers: <String, String>{'User-Agent': _uaMobile},
    );
    final Map<String, dynamic> body = _asMap(res.data);
    final Object? candidates = body['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final Map<String, dynamic> first = _asMap(candidates.first);
    final String id = first['id']?.toString() ?? '';
    final String accesskey = first['accesskey']?.toString() ?? '';
    if (id.isEmpty || accesskey.isEmpty) return null;

    final Response<dynamic> dl = await _get(
      'https://lyrics.kugou.com/download',
      query: <String, dynamic>{
        'ver': 1,
        'client': 'pc',
        'id': id,
        'accesskey': accesskey,
        'fmt': 'lrc',
        'charset': 'utf8',
      },
      headers: <String, String>{'User-Agent': _uaMobile},
    );
    final Map<String, dynamic> dlBody = _asMap(dl.data);
    final String content = dlBody['content']?.toString() ?? '';
    if (content.isEmpty) return null;
    // content 是 base64 的 LRC
    try {
      return _cleanLrc(
        utf8.decode(base64.decode(content), allowMalformed: true),
      );
    } catch (_) {
      return null;
    }
  }

  /// 酷我歌词。
  Future<String?> kuwoLyric(String rid) async {
    if (rid.isEmpty) return null;
    // 有的音源给的是 `MUSIC_6289602`，接口要纯数字
    final String musicId = rid.replaceAll(RegExp(r'[^0-9]'), '');
    if (musicId.isEmpty) return null;
    final Response<dynamic> res = await _get(
      'http://m.kuwo.cn/newh5/singles/songinfoandlrc',
      query: <String, dynamic>{'musicId': musicId},
      referer: 'http://m.kuwo.cn/',
    );
    final Map<String, dynamic> body = _asMap(res.data);
    final Object? list = _asMap(body['data'])['lrclist'];
    if (list is! List || list.isEmpty) return null;
    final StringBuffer buffer = StringBuffer();
    for (final Object? item in list) {
      final Map<String, dynamic> line = _asMap(item);
      final String time = line['time']?.toString() ?? '';
      final String text = line['lineLyric']?.toString() ?? '';
      if (time.isEmpty || text.isEmpty) continue;
      final double seconds = double.tryParse(time) ?? 0;
      final int minutes = seconds ~/ 60;
      final double rest = seconds - minutes * 60;
      buffer.writeln(
        '[${minutes.toString().padLeft(2, '0')}:'
        '${rest.toStringAsFixed(2).padLeft(5, '0')}]$text',
      );
    }
    final String lrc = buffer.toString();
    return lrc.trim().isEmpty ? null : lrc;
  }

  /// 咪咕歌词。
  Future<String?> miguLyric(String songId, {String copyrightId = ''}) async {
    final String id = copyrightId.isNotEmpty ? copyrightId : songId;
    if (id.isEmpty) return null;
    final Response<dynamic> res = await _get(
      'https://music.migu.cn/v3/api/music/audioPlayer/getLyric',
      query: <String, dynamic>{'copyrightId': id},
      headers: <String, String>{'User-Agent': _uaMobile},
      referer: 'https://music.migu.cn/',
    );
    final Map<String, dynamic> body = _asMap(res.data);
    return _cleanLrc(body['lyric']?.toString());
  }

  // ════════════════════════════════════════════════════════════════
  //  封面
  // ════════════════════════════════════════════════════════════════

  /// 按平台取封面地址（取不到返回 `null`）。
  ///
  /// 平台没给封面（酷我 / 部分酷狗结果）时，**换个平台按歌名+歌手再找一次**，
  /// 免得"能播但光秃秃一片灰"。
  Future<String?> coverUrlFor(
    OnlineTrack track, {
    bool crossPlatform = true,
  }) async {
    final String key = track.id;
    if (_coverCache.containsKey(key)) return _coverCache[key];
    String? url = track.coverUrl.isEmpty ? null : track.coverUrl;
    if (url == null) {
      try {
        url = switch (track.platform) {
          'wy' => await _neteaseCoverUrl(track.songId),
          'tx' => qqCoverUrl(track.albumId),
          'kg' => null, // 搜索结果里没有 union_cover 时只能换平台找
          'kw' => null, // 酷我搜索接口不返回封面
          'mg' => null,
          _ => null,
        };
      } catch (error) {
        lastError = _humanize(error);
      }
    }
    if ((url == null || url.isEmpty) && crossPlatform) {
      final OnlineTrack? other = await _matchOtherPlatform(track);
      if (other != null && other.coverUrl.isNotEmpty) url = other.coverUrl;
      if (url == null && other != null) {
        url = switch (other.platform) {
          'wy' => await _neteaseCoverUrl(other.songId),
          'tx' => qqCoverUrl(other.albumId),
          'kg' => other.coverUrl.isEmpty ? null : other.coverUrl,
          _ => null,
        };
      }
    }
    _coverCache[key] = url;
    return url;
  }

  /// 网易云封面（要走一次详情接口）。
  Future<String?> _neteaseCoverUrl(String songId) async {
    if (songId.isEmpty) return null;
    final Response<dynamic> res = await _get(
      'https://music.163.com/api/song/detail',
      query: <String, dynamic>{'ids': '[$songId]'},
      referer: 'https://music.163.com/',
      headers: <String, String>{'Cookie': 'appver=8.9.70; os=pc'},
    );
    final Object? songs = _asMap(res.data)['songs'];
    if (songs is! List || songs.isEmpty) return null;
    final Map<String, dynamic> album = _asMap(_asMap(songs.first)['album']);
    final String url = album['picUrl']?.toString() ?? '';
    return url.isEmpty ? null : url;
  }

  /// QQ音乐封面（按 albumMid 拼图床，不需要额外请求）。
  static String? qqCoverUrl(String albumMid) {
    if (albumMid.isEmpty) return null;
    return 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg';
  }

  /// 网易云单曲详情（封面、专辑、时长）。取不到返回 `null`。
  Future<OnlineTrack?> neteaseDetail(String songId) async {
    try {
      final Response<dynamic> res = await _get(
        'https://music.163.com/api/song/detail',
        query: <String, dynamic>{'ids': '[$songId]'},
        referer: 'https://music.163.com/',
        headers: <String, String>{'Cookie': 'appver=8.9.70; os=pc'},
      );
      final Object? songs = _asMap(res.data)['songs'];
      if (songs is! List || songs.isEmpty) return null;
      return _neteaseSongToTrack(_asMap(songs.first));
    } catch (error) {
      lastError = _humanize(error);
      return null;
    }
  }

  /// 读取公开网易云歌单。只读取标题和曲目元数据，不读取播放 URL。
  Future<NeteasePlaylistInfo?> neteasePlaylist(String playlistId) async {
    final String id = playlistId.trim();
    if (!RegExp(r'^\d+$').hasMatch(id)) return null;
    try {
      // The web page endpoint only returns a small preview. The v6 endpoint
      // includes the complete trackIds list; full song objects are fetched in
      // a second request below.
      final Response<dynamic> response = await _get(
        'https://music.163.com/api/v6/playlist/detail',
        query: <String, dynamic>{'id': id},
        referer: 'https://music.163.com/',
      );
      final Map<String, dynamic> body = _asMap(response.data);
      final Map<String, dynamic> playlist = _asMap(
        body['playlist'] ?? body['result'],
      );
      if (playlist.isEmpty) return null;
      final List<OnlineTrack> tracks = <OnlineTrack>[];
      final Set<String> seen = <String>{};
      final Object? rawTracks = playlist['tracks'];
      if (rawTracks is List) {
        for (final Object? raw in rawTracks) {
          final OnlineTrack track = _neteaseSongToTrack(_asMap(raw));
          if (track.songId.isNotEmpty && seen.add(track.songId)) {
            tracks.add(track);
          }
        }
      }
      final List<String> trackIds = <String>[];
      final Object? rawIds = playlist['trackIds'];
      if (rawIds is List) {
        for (final Object? raw in rawIds) {
          final String songId = raw is Map
              ? raw['id']?.toString() ?? ''
              : raw.toString();
          if (RegExp(r'^\d+$').hasMatch(songId)) trackIds.add(songId);
        }
      }
      final List<String> missingIds = trackIds
          .where((String songId) => !seen.contains(songId))
          .toList(growable: false);
      for (int offset = 0; offset < missingIds.length; offset += 100) {
        final List<String> batch = missingIds.skip(offset).take(100).toList();
        final Response<dynamic> detail = await _get(
          'https://music.163.com/api/song/detail',
          query: <String, dynamic>{'ids': '[${batch.join(',')}]'},
          referer: 'https://music.163.com/',
        );
        final Object? rawSongs = _asMap(detail.data)['songs'];
        if (rawSongs is! List) continue;
        for (final Object? raw in rawSongs) {
          final OnlineTrack track = _neteaseSongToTrack(_asMap(raw));
          if (track.songId.isNotEmpty && seen.add(track.songId)) {
            tracks.add(track);
          }
        }
      }
      return NeteasePlaylistInfo(
        id: id,
        name: playlist['name']?.toString() ?? '网易云歌单',
        tracks: tracks,
      );
    } catch (error) {
      lastError = error.toString();
      return null;
    }
  }

  /// 解析公开芸音歌单链接，再读取歌单详情。
  ///
  /// 除了网页链接，这里也支持电脑端/手机端分享出来的 `163cn.tv` 短链。
  /// 短链本身没有歌单 ID，Dio 会跟随 HTTP 跳转；同时检查最终 URI、每一跳
  /// 的 Location 和落地 HTML 中的 canonical/og:url，避免只依赖某一种分享页。
  Future<NeteasePlaylistInfo?> neteasePlaylistFromUrl(String url) async {
    final String input = _normalizeNeteaseShareUrl(url);
    final String? directId = extractNeteasePlaylistId(input);
    if (directId != null) return neteasePlaylist(directId);
    try {
      final Response<dynamic> response = await _get(
        input,
        referer: 'https://music.163.com/',
        responseType: ResponseType.plain,
        headers: <String, String>{
          'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        followRedirects: true,
        maxRedirects: 8,
      );
      final String html = response.data?.toString() ?? '';
      final String redirectText = <String>[
        response.realUri.toString(),
        for (final RedirectRecord redirect in response.redirects)
          redirect.location.toString(),
      ].join('\n');
      final String? id =
          extractNeteasePlaylistId(redirectText) ??
          extractNeteasePlaylistId(html);
      return id == null ? null : await neteasePlaylist(id);
    } catch (error) {
      lastError = _humanize(error);
      return null;
    }
  }

  /// 从芸音网页、`163cn.tv` 短链、重定向地址或页面元数据中提取歌单 ID。
  ///
  /// 保留为纯函数便于单测。分享页可能多次 URL 编码，最多解码三次，
  /// 兼容 `playlist?id=...`、`/playlist/<id>`、canonical、og:url 和 JSON 字段。
  @visibleForTesting
  static String? extractNeteasePlaylistId(String value) {
    String text = _normalizeNeteaseShareUrl(value);
    for (int index = 0; index < 3; index++) {
      String decoded;
      try {
        decoded = Uri.decodeFull(text);
      } on FormatException {
        break;
      }
      if (decoded == text) break;
      text = _normalizeNeteaseShareUrl(decoded);
    }
    final List<RegExp> patterns = <RegExp>[
      RegExp(r'(?:playlist|playlist%2f)[/\\]{0,2}(\d+)', caseSensitive: false),
      RegExp(r'[?#&](?:id|playlistId)=(\d+)', caseSensitive: false),
      RegExp(
        r'"(?:playlistId|playlist_id|id)"\s*:\s*"?(\d+)',
        caseSensitive: false,
      ),
      RegExp(r'(?:playlist|歌单)[^\d]{0,80}(\d+)', caseSensitive: false),
    ];
    for (final RegExp pattern in patterns) {
      final RegExpMatch? match = pattern.firstMatch(text);
      final String? id = match?.group(1);
      if (id != null && RegExp(r'^\d+$').hasMatch(id)) return id;
    }
    return null;
  }

  static String _normalizeNeteaseShareUrl(String value) => value
      .trim()
      .replaceAll(r'\&', '&')
      .replaceAll(r'\_', '_')
      .replaceAll('&amp;', '&')
      .replaceAll(r'\/', '/')
      .replaceAll(r'\u002F', '/')
      .replaceAll(r'\u0026', '&');

  /// 读取公开鹅音歌单。只读取标题和曲目元数据，不读取播放 URL。
  ///
  /// 分享短链通常会先返回网页，再由页面指向真实的 `disstid`；调用方负责
  /// 从链接中提取 ID。该接口返回完整 songlist，曲目顺序保持不变。
  Future<QqPlaylistInfo?> qqPlaylist(String playlistId) async {
    final String id = playlistId.trim();
    if (!RegExp(r'^\d+$').hasMatch(id)) return null;
    try {
      final Response<dynamic> response = await _get(
        'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg',
        query: <String, dynamic>{
          'disstid': id,
          'format': 'json',
          'outCharset': 'utf8',
          'type': 1,
          'json': 1,
          'utf8': 1,
          'onlysong': 0,
          'new_format': 1,
        },
        referer: 'https://y.qq.com/',
      );
      final Map<String, dynamic> body = _asMap(_stripJsonp(response.data));
      final Map<String, dynamic> playlist = _asMap(
        (body['cdlist'] is List && (body['cdlist'] as List).isNotEmpty)
            ? (body['cdlist'] as List).first
            : body['playlist'],
      );
      if (playlist.isEmpty) return null;
      final List<OnlineTrack> tracks = parseQQPlaylist(playlist);
      if (tracks.isEmpty) return null;
      return QqPlaylistInfo(
        id: id,
        name: playlist['dissname']?.toString() ?? '鹅音歌单',
        tracks: tracks,
      );
    } catch (error) {
      lastError = _humanize(error);
      return null;
    }
  }

  /// 解析鹅音分享页/短链，再读取公开歌单详情。
  ///
  /// `c6.y.qq.com/base/fcgi-bin/u?...` 这类链接没有把歌单 ID 放在 query
  /// 中，页面会在 HTML 的 canonical/og:url 中给出 `/playlist/<id>`。
  Future<QqPlaylistInfo?> qqPlaylistFromUrl(String url) async {
    final String input = _normalizeQqShareUrl(url);
    final String? directId = extractQqPlaylistId(input);
    if (directId != null) return qqPlaylist(directId);
    try {
      final Response<dynamic> response = await _get(
        input,
        referer: 'https://y.qq.com/',
        responseType: ResponseType.plain,
        headers: <String, String>{
          'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
      );
      final String html = response.data?.toString() ?? '';
      final String redirectText = <String>[
        response.realUri.toString(),
        for (final RedirectRecord redirect in response.redirects)
          redirect.location.toString(),
      ].join('\n');
      final String? id =
          extractQqPlaylistId(redirectText) ?? extractQqPlaylistId(html);
      return id == null ? null : await qqPlaylist(id);
    } catch (error) {
      lastError = _humanize(error);
      return null;
    }
  }

  /// 从鹅音网页、电脑端短分享页或页面元数据中提取歌单 ID。
  ///
  /// 电脑端分享的 `c6.y.qq.com/base/fcgi-bin/u?...` 参数是短 token，
  /// 不能直接当成歌单 ID；短页通常会把真实地址放到 og:url、canonical
  /// 或脚本中的 `/playlist/<id>`。保留为纯函数便于单测和后续适配页面变更。
  @visibleForTesting
  static String? extractQqPlaylistId(String value) {
    String text = _normalizeQqShareUrl(value);
    // 短链页面经常把真实链接再包一层 query/JSON；最多解码三次，
    // 避免对普通中文歌名做无意义的重复转换。
    for (int index = 0; index < 3; index++) {
      final String decoded = Uri.decodeFull(text);
      if (decoded == text) break;
      text = _normalizeQqShareUrl(decoded);
    }
    final List<RegExp> patterns = <RegExp>[
      RegExp(r'playlist(?:[/\\]){1,2}(\d+)', caseSensitive: false),
      RegExp(r'playlist%2f(\d+)', caseSensitive: false),
      RegExp(r'[?&](?:id|disstid)=(\d+)', caseSensitive: false),
      RegExp(r'"(?:playlistId|dissid)"\s*:\s*"?(\d+)', caseSensitive: false),
    ];
    for (final RegExp pattern in patterns) {
      final RegExpMatch? match = pattern.firstMatch(text);
      final String? id = match?.group(1);
      if (id != null && RegExp(r'^\d+$').hasMatch(id)) return id;
    }
    return null;
  }

  static String _normalizeQqShareUrl(String value) => value
      .trim()
      .replaceAll(r'\&', '&')
      .replaceAll(r'\_', '_')
      .replaceAll('&amp;', '&')
      .replaceAll(r'\/', '/')
      .replaceAll(r'\u002F', '/')
      .replaceAll('\\u0026', '&');

  /// 兼容旧名（`wy` 专用路径）。
  Future<String?> neteaseCoverUrl(String songId) => _neteaseCoverUrl(songId);

  /// 下载图片字节（封面用）。带正常 UA/Referer，避免图床挑客户端。
  Future<Uint8List?> fetchBytes(String url, {Duration? timeout}) async {
    if (url.isEmpty) return null;
    try {
      final Response<List<int>> res = await _client.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: timeout ?? const Duration(seconds: 15),
          headers: <String, String>{
            'User-Agent': _ua,
            'Referer': 'https://music.163.com/',
          },
        ),
      );
      final List<int>? bytes = res.data;
      if (bytes == null || bytes.isEmpty) return null;
      return Uint8List.fromList(bytes);
    } catch (error) {
      lastError = _humanize(error);
      return null;
    }
  }

  // ════════════════════════════════════════════════════════════════
  //  本地 / WebDAV 曲目 → 用音源平台刮信息
  // ════════════════════════════════════════════════════════════════

  /// 用「歌名 + 歌手」在平台上找一首最像的（用于给**本地 / WebDAV** 曲目
  /// 刮封面和歌词 —— 这两样平台上有，且音源脚本也能给）。
  ///
  /// **模糊匹配**（0.0.40 按用户要求放宽）：本地文件的文件名千奇百怪
  /// （`01. 晴天 - 周杰伦.flac` / `晴天_周杰伦_320K.mp3`…），所以
  /// 查询词先清洗（去序号、括号后缀、码率噪声），判定也不再要求"很像"：
  /// 综合分 ≥0.55 且歌名相似度 ≥0.45 就认，宁可偶尔挂错也别整片空白
  /// （用户原话：做模糊刮削，不用太死）。
  Future<OnlineTrack?> matchTrack(
    Track track, {
    List<String>? platforms,
  }) async {
    final String title = cleanQuery(smartTitleOf(track));
    if (title.isEmpty) return null;
    final String cacheKey =
        '${normalizeTrackText(title)}|${normalizeTrackText(track.artist)}';
    if (_matchCache.containsKey(cacheKey)) return _matchCache[cacheKey];
    // 磁盘缓存（0.0.44）：本地/WebDAV 曲目重启后不用再按歌名匹配一遍
    final OnlineTrack? cached = await SourceCache.instance.match(cacheKey);
    if (cached != null) {
      _matchCache[cacheKey] = cached;
      return cached;
    }

    final List<String> candidates =
        platforms ?? const <String>['wy', 'tx', 'mg', 'kg', 'kw'];
    OnlineTrack? best;
    double bestScore = 0;
    for (final String platform in candidates) {
      final PlatformSearchResult result = await searchPlatform(
        platform,
        '$title ${track.artist}'.trim(),
        limit: 10,
      );
      for (final OnlineTrack candidate in result.tracks) {
        final double nameScore = similarityOf(candidate.title, title);
        final double artistScore = track.artist.trim().isEmpty
            ? 0.7 // 本地文件没有歌手信息时别直接否掉
            : artistSimilarity(candidate.artist, track.artist);
        final double score = nameScore * 0.6 + artistScore * 0.4;
        // 模糊刮削（用户要求"不用那么精准"）：歌名 ≥0.35、综合 ≥0.45 就认。
        // 宁可偶尔挂错，也别整片空白 —— 挂错了用户能看出来并换歌，空白只能干瞪眼。
        if (nameScore < 0.35 || score < 0.45) continue;
        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
      if (best != null && bestScore >= 0.9) break; // 已经很稳了，不用再问别家
    }
    _matchCache[cacheKey] = best;
    if (best != null) {
      await SourceCache.instance.putMatch(cacheKey, best);
    }
    return best;
  }

  /// 返回多个平台的最佳匹配，供封面交叉比较，避免固定使用单一平台首图。
  Future<List<OnlineTrack>> matchTrackCandidates(
    Track track, {
    List<String>? platforms,
  }) async {
    final String title = cleanQuery(smartTitleOf(track));
    if (title.isEmpty) return const <OnlineTrack>[];
    final List<(OnlineTrack, double)> scored = <(OnlineTrack, double)>[];
    final List<String> sources =
        platforms ?? const <String>['tx', 'mg', 'kg', 'kw', 'wy'];
    for (final String platform in sources) {
      final PlatformSearchResult result = await searchPlatform(
        platform,
        '$title ${track.artist}'.trim(),
        limit: 10,
      );
      double platformBest = 0;
      OnlineTrack? platformTrack;
      for (final OnlineTrack candidate in result.tracks) {
        final double nameScore = similarityOf(candidate.title, title);
        final double artistScore = track.artist.trim().isEmpty
            ? 0.7
            : artistSimilarity(candidate.artist, track.artist);
        final double score = nameScore * 0.6 + artistScore * 0.4;
        if (nameScore >= 0.45 && score >= 0.52 && score > platformBest) {
          platformBest = score;
          platformTrack = candidate;
        }
      }
      if (platformTrack != null) scored.add((platformTrack, platformBest));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return <OnlineTrack>[for (final (OnlineTrack item, _) in scored) item];
  }

  /// 本地文件的"歌名"清洗：文件名常常把歌手 / 码率 / 序号都塞在标题里。
  ///
  /// 例：`01. 晴天 - 周杰伦 320K` → `晴天`（若标题里带 `-`，取更像歌名的那半）。
  @visibleForTesting
  static String smartTitleOf(Track track) {
    String title = track.title.trim();
    // 下划线常被当分隔符用（`晴天_周杰伦_320K`），先换成空格
    title = title.replaceAll('_', ' ');
    // 去掉开头的序号：`01.` `01 ` `1-` `[01]`
    title = title.replaceFirst(
      RegExp(r'^\s*[\[\(]?\d{1,3}[\]\)]?\s*[.\-_、]\s*'),
      '',
    );
    // 去掉常见噪声词（Dart 的 RegExp 不支持内联 `(?i)`，要用 caseSensitive）
    title = title.replaceAll(
      RegExp(
        r'\b(flac|ape|wav|mp3|320k|128k|320|hires|hi-res|'
        r'lossless|official|mv|demo|remaster(ed)?|hq|sq)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    // `歌手 - 歌名` / `歌名 - 歌手`：如果本地有 tag 歌手，且其中一半包含它，
    // 就把另一半当歌名（文件名把歌手放前面是最常见的写法）。
    final List<String> parts = title
        .split(RegExp(r'\s+[-–—]\s+'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (parts.length == 2 && track.artist.trim().isNotEmpty) {
      final double firstIsArtist = similarityOf(parts[0], track.artist);
      final double secondIsArtist = similarityOf(parts[1], track.artist);
      if (firstIsArtist > 0.5 && firstIsArtist > secondIsArtist) {
        title = parts[1];
      } else if (secondIsArtist > 0.5 && secondIsArtist > firstIsArtist) {
        title = parts[0];
      }
    }
    return title.trim();
  }

  /// 给一首**本地 / WebDAV 曲目**取歌词（先用平台上匹配到的歌，再取它的歌词）。
  Future<String?> lyricForTrack(Track track) async {
    final (String platform, String songId) = splitTrackId(track.id);
    if (platform.isNotEmpty && songId.isNotEmpty) {
      // 在线曲目：id 里就有平台和歌曲号
      return lyricFor(
        OnlineTrack(platform: platform, songId: songId, title: track.title),
      );
    }
    final OnlineTrack? matched = await matchTrack(track);
    if (matched == null) return null;
    return lyricFor(matched);
  }

  /// **歌手照片**（歌曲封面实在刮不到时的兜底，用户要求）。
  ///
  /// 走网易云的歌手搜索（`type=100`），拿第一条的 `picUrl`。
  Future<String?> artistPhotoUrl(String artist) async {
    final String name = _firstArtist(artist);
    if (name.isEmpty) return null;
    final String key = 'artist|$name';
    if (_coverCache.containsKey(key)) return _coverCache[key];
    String? url;
    try {
      final Response<dynamic> res = await _get(
        'https://music.163.com/api/search/get/web',
        query: <String, dynamic>{
          's': name,
          'type': 100,
          'limit': 1,
          'offset': 0,
        },
        referer: 'https://music.163.com/',
        headers: <String, String>{'Cookie': 'appver=8.9.70; os=pc'},
      );
      final Object? artists = _asMap(_asMap(res.data)['result'])['artists'];
      if (artists is List && artists.isNotEmpty) {
        final String pic = _asMap(artists.first)['picUrl']?.toString() ?? '';
        if (pic.isNotEmpty) url = pic;
      }
    } catch (error) {
      lastError = _humanize(error);
    }
    _coverCache[key] = url;
    return url;
  }

  /// 给一首**本地 / WebDAV 曲目**取封面地址。
  Future<String?> coverUrlForTrack(Track track) async {
    final (String platform, String songId) = splitTrackId(track.id);
    if (platform.isNotEmpty && songId.isNotEmpty) {
      final String? online = await coverUrlFor(
        OnlineTrack(platform: platform, songId: songId, title: track.title),
      );
      if (online != null && online.isNotEmpty) return online;
    } else {
      final List<OnlineTrack> matches = await matchTrackCandidates(track);
      for (final OnlineTrack matched in matches) {
        final String? cover = await coverUrlFor(matched);
        if (cover != null && cover.isNotEmpty) return cover;
      }
    }
    // 不再退回歌手头像：把歌手头像当歌曲封面会出现平台 Logo / 错图。
    return null;
  }

  // ════════════════════════════════════════════════════════════════
  //  纯解析（可单测）
  // ════════════════════════════════════════════════════════════════

  /// 把 `平台:歌曲id` 拆开（拆不开就平台为空）。
  ///
  /// ⚠️ 不能只找第一个冒号：`D:\音乐\a.flac` 会被当成平台 `D`。
  /// 所以要求冒号前只能是**短字母数字标识**（`wy` / `tx` / `qsvip`），
  /// 且冒号后不能是路径（含 `\` / `/` 就否掉）。
  static (String, String) splitTrackId(String id) {
    final int colon = id.indexOf(':');
    if (colon <= 0 || colon == id.length - 1) return ('', '');
    final String prefix = id.substring(0, colon);
    final String rest = id.substring(colon + 1);
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,15}$').hasMatch(prefix)) {
      return ('', '');
    }
    if (rest.contains('\\') || rest.contains('/')) return ('', '');
    return (prefix, rest);
  }

  /// 解析网易云搜索响应。
  static List<OnlineTrack> parseNeteaseSearch(Map<String, dynamic> body) {
    final Object? songs =
        _asMap(body['result'])['songs'] ?? body['songs']; // 备用端点没有 result 这层
    if (songs is! List) return const <OnlineTrack>[];
    final List<OnlineTrack> out = <OnlineTrack>[];
    for (final Object? raw in songs) {
      final OnlineTrack track = _neteaseSongToTrack(_asMap(raw));
      if (track.songId.isNotEmpty) out.add(track);
    }
    return out;
  }

  static int _totalOfNetease(Map<String, dynamic> body) {
    final Map<String, dynamic> result = _asMap(body['result']);
    return int.tryParse(result['songCount']?.toString() ?? '') ?? 0;
  }

  static OnlineTrack _neteaseSongToTrack(Map<String, dynamic> song) {
    final Map<String, dynamic> album = _asMap(song['album'] ?? song['al']);
    final Object? artistsRaw = song['artists'] ?? song['ar'];
    final List<String> artists = <String>[];
    if (artistsRaw is List) {
      for (final Object? a in artistsRaw) {
        final String name = _asMap(a)['name']?.toString() ?? '';
        if (name.isNotEmpty) artists.add(name);
      }
    }
    return OnlineTrack(
      platform: 'wy',
      songId: song['id']?.toString() ?? '',
      title: song['name']?.toString() ?? '',
      artist: artists.join(' / '),
      album: album['name']?.toString() ?? '',
      albumId: album['id']?.toString() ?? '',
      duration: Duration(
        milliseconds:
            int.tryParse(song['duration']?.toString() ?? '') ??
            int.tryParse(song['dt']?.toString() ?? '') ??
            0,
      ),
      coverUrl: album['picUrl']?.toString() ?? '',
    );
  }

  /// 解析 QQ音乐搜索响应（`new_json=1`）。
  static List<OnlineTrack> parseQQSearch(Map<String, dynamic> body) {
    final Map<String, dynamic> song = _asMap(_asMap(body['data'])['song']);
    final Object? list = song['list'];
    if (list is! List) return const <OnlineTrack>[];
    final List<OnlineTrack> out = <OnlineTrack>[];
    for (final Object? raw in list) {
      final Map<String, dynamic> item = _asMap(raw);
      final String mid =
          item['mid']?.toString() ?? item['songmid']?.toString() ?? '';
      if (mid.isEmpty) continue;
      final List<String> singers = <String>[];
      final Object? singerRaw = item['singer'];
      if (singerRaw is List) {
        for (final Object? s in singerRaw) {
          final String name = _asMap(s)['name']?.toString() ?? '';
          if (name.isNotEmpty) singers.add(name);
        }
      }
      final Map<String, dynamic> album = _asMap(item['album']);
      final String albumMid = album['mid']?.toString() ?? '';
      out.add(
        OnlineTrack(
          platform: 'tx',
          songId: mid,
          title: item['name']?.toString() ?? item['title']?.toString() ?? '',
          artist: singers.join(' / '),
          album: album['name']?.toString() ?? '',
          albumId: albumMid,
          duration: Duration(
            seconds: int.tryParse(item['interval']?.toString() ?? '') ?? 0,
          ),
          coverUrl: qqCoverUrl(albumMid) ?? '',
        ),
      );
    }
    return out;
  }

  /// 解析 QQ 歌单详情里的 `songlist`，兼容接口返回的数字 ID、MID 和旧字段。
  @visibleForTesting
  static List<OnlineTrack> parseQQPlaylist(Map<String, dynamic> playlist) {
    final Object? list = playlist['songlist'];
    if (list is! List) return const <OnlineTrack>[];
    final List<OnlineTrack> out = <OnlineTrack>[];
    final Set<String> seen = <String>{};
    for (final Object? raw in list) {
      final Map<String, dynamic> item = _asMap(raw);
      final String mid =
          item['mid']?.toString() ?? item['songmid']?.toString() ?? '';
      final String numericId = item['id']?.toString() ?? '';
      final String songId = mid.isNotEmpty ? mid : numericId;
      if (songId.isEmpty || !seen.add(songId)) continue;
      final List<String> singers = <String>[];
      final Object? singerRaw = item['singer'];
      if (singerRaw is List) {
        for (final Object? singer in singerRaw) {
          final String name = _asMap(singer)['name']?.toString() ?? '';
          if (name.isNotEmpty) singers.add(name);
        }
      }
      final Map<String, dynamic> album = _asMap(item['album']);
      final String albumMid =
          album['mid']?.toString() ?? album['pmid']?.toString() ?? '';
      final Map<String, dynamic> file = _asMap(item['file']);
      out.add(
        OnlineTrack(
          platform: 'tx',
          songId: songId,
          title: item['name']?.toString() ?? item['title']?.toString() ?? '',
          artist: singers.join(' / '),
          album: album['name']?.toString() ?? album['title']?.toString() ?? '',
          albumId: albumMid,
          duration: Duration(
            seconds: int.tryParse(item['interval']?.toString() ?? '') ?? 0,
          ),
          coverUrl: qqCoverUrl(albumMid) ?? '',
          extra: <String, dynamic>{
            'songId': numericId,
            'songmid': mid,
            'media_mid': file['media_mid']?.toString() ?? '',
            'albumId': albumMid,
            'album_mid': albumMid,
          },
        ),
      );
    }
    return out;
  }

  /// 解析酷狗搜索响应（`mobilecdn`）。
  static List<OnlineTrack> parseKugouSearch(Map<String, dynamic> body) {
    final Object? info = _asMap(body['data'])['info'];
    if (info is! List) return const <OnlineTrack>[];
    final List<OnlineTrack> out = <OnlineTrack>[];
    for (final Object? raw in info) {
      final Map<String, dynamic> item = _asMap(raw);
      final String hash = item['hash']?.toString() ?? '';
      if (hash.isEmpty) continue;
      out.add(
        OnlineTrack(
          platform: 'kg',
          songId: hash,
          title: item['songname']?.toString() ?? '',
          artist: item['singername']?.toString() ?? '',
          album: (item['album_name'] ?? item['albumname'])?.toString() ?? '',
          albumId: item['album_id']?.toString() ?? '',
          duration: Duration(
            seconds: int.tryParse(item['duration']?.toString() ?? '') ?? 0,
          ),
          // 酷狗封面在 `trans_param.union_cover` 里，形如
          // `http://imge.kugou.com/stdmusic/{size}/2023....jpg` —— 把 {size} 换掉即可。
          coverUrl: _kugouCover(item),
          // 酷狗各音源要的字段不一样：把搜索响应里的 hash 系列与数字 id 都带上，
          // 不然会出现「酷狗所有音源均获取失败 / 缺少 songId」。
          extra: <String, dynamic>{
            'hash': hash,
            '320hash': item['320hash']?.toString() ?? '',
            'sqhash': item['sqhash']?.toString() ?? '',
            'audio_id': item['audio_id']?.toString() ?? '',
            'audioId': item['audio_id']?.toString() ?? '',
            'album_audio_id': item['album_audio_id']?.toString() ?? '',
            'albumAudioId': item['album_audio_id']?.toString() ?? '',
            'albumId': item['album_id']?.toString() ?? '',
            'album_id': item['album_id']?.toString() ?? '',
            // 有些音源把数字 audio_id 当 songId 用
            'songId': item['audio_id']?.toString() ?? hash,
          },
        ),
      );
    }
    return out;
  }

  /// 酷狗封面：`trans_param.union_cover` 里的 `{size}` 换成 240。
  static String _kugouCover(Map<String, dynamic> item) {
    final String raw =
        _asMap(item['trans_param'])['union_cover']?.toString() ?? '';
    if (raw.isEmpty) return '';
    return raw.replaceAll('{size}', '240');
  }

  /// 解析酷我搜索响应（`abslist`）。
  static List<OnlineTrack> parseKuwoSearch(Map<String, dynamic> body) {
    final Object? list = body['abslist'];
    if (list is! List) return const <OnlineTrack>[];
    final List<OnlineTrack> out = <OnlineTrack>[];
    for (final Object? raw in list) {
      final Map<String, dynamic> item = _asMap(raw);
      final String rid =
          (item['MUSICRID'] ?? item['musicrid'])?.toString() ?? '';
      if (rid.isEmpty) continue;
      out.add(
        OnlineTrack(
          platform: 'kw',
          songId: rid,
          title: (item['SONGNAME'] ?? item['name'])?.toString() ?? '',
          artist: (item['ARTIST'] ?? item['artist'])?.toString() ?? '',
          album: (item['ALBUM'] ?? item['album'])?.toString() ?? '',
          albumId: (item['ALBUMID'] ?? item['albumid'])?.toString() ?? '',
          duration: Duration(
            seconds:
                int.tryParse(
                  (item['DURATION'] ?? item['duration'])?.toString() ?? '',
                ) ??
                0,
          ),
        ),
      );
    }
    return out;
  }

  /// 解析咪咕搜索响应（v2：`songResultData.result[]`；兼容老的 `musics[]`）。
  static List<OnlineTrack> parseMiguSearch(Map<String, dynamic> body) {
    Object? list = _asMap(body['songResultData'])['result'];
    list ??= body['musics'] ?? body['data'];
    if (list is Map) list = _asMap(list)['musics'];
    if (list is! List) return const <OnlineTrack>[];
    final List<OnlineTrack> out = <OnlineTrack>[];
    for (final Object? raw in list) {
      final Map<String, dynamic> item = _asMap(raw);
      final String copyrightId =
          item['copyrightId']?.toString() ?? item['id']?.toString() ?? '';
      if (copyrightId.isEmpty) continue;
      out.add(
        OnlineTrack(
          platform: 'mg',
          songId: copyrightId,
          title: item['name']?.toString() ?? item['songName']?.toString() ?? '',
          artist: _miguSingers(item),
          album: _miguAlbumName(item),
          albumId: _miguAlbumId(item),
          coverUrl:
              item['cover']?.toString() ?? item['albumImgs']?.toString() ?? '',
          lyricUrl: item['lyricUrl']?.toString() ?? '',
          tags: _stringList(item['tags']),
          // 咪咕各音源要的字段不一样：数字 id / contentId / copyrightId 都带上，
          // 且 `songId` 给数字 id（实测有音源就是查这个，给 copyrightId 会报"缺少 songId"）
          extra: <String, dynamic>{
            'id': item['id']?.toString() ?? copyrightId,
            'songId': item['id']?.toString() ?? copyrightId,
            'songmid': copyrightId,
            'copyrightId': copyrightId,
            'contentId': item['contentId']?.toString() ?? '',
            'resourceType': item['resourceType']?.toString() ?? '2',
            'albumId': _miguAlbumId(item),
          },
        ),
      );
    }
    return out;
  }

  static String _miguSingers(Map<String, dynamic> item) {
    final Object? singers = item['singers'];
    if (singers is List) {
      final List<String> names = <String>[];
      for (final Object? s in singers) {
        final String name = _asMap(s)['name']?.toString() ?? '';
        if (name.isNotEmpty) names.add(name);
      }
      if (names.isNotEmpty) return names.join(' / ');
    }
    return item['singerName']?.toString() ?? item['singer']?.toString() ?? '';
  }

  static String _miguAlbumName(Map<String, dynamic> item) {
    final Object? albums = item['albums'];
    if (albums is List && albums.isNotEmpty) {
      final String name = _asMap(albums.first)['name']?.toString() ?? '';
      if (name.isNotEmpty) return name;
    }
    return item['albumName']?.toString() ?? '';
  }

  static String _miguAlbumId(Map<String, dynamic> item) {
    final Object? albums = item['albums'];
    if (albums is List && albums.isNotEmpty) {
      final String id = _asMap(albums.first)['id']?.toString() ?? '';
      if (id.isNotEmpty) return id;
    }
    return item['albumId']?.toString() ?? '';
  }

  /// 解析网易云歌词响应：原文与翻译保留相同时间戳，交给 Lyrics 统一同步滚动。
  static String? parseNeteaseLyric(Map<String, dynamic> body) {
    final String lrc = _asMap(body['lrc'])['lyric']?.toString() ?? '';
    if (lrc.trim().isEmpty) return null;
    final String tlyric = _asMap(body['tlyric'])['lyric']?.toString() ?? '';
    if (tlyric.trim().isEmpty) return lrc;
    return '$lrc\n$tlyric';
  }

  // ════════════════════════════════════════════════════════════════
  //  工具
  // ════════════════════════════════════════════════════════════════

  /// 把「单引号对象字面量」（酷我等老接口）尽量转成 Map。
  ///
  /// 直接 `replaceAll("'", '"')` 在歌名里有撇号时会崩，所以：
  /// 先按 `'` 转双引号试 JSON，失败就退化成"按 key 正则抠字段"。
  @visibleForTesting
  static Map<String, dynamic> looseObjectToMap(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) return <String, dynamic>{};
    final String swapped = trimmed
        .replaceAll(RegExp(r"\\'"), "'")
        .replaceAll('"', r'\"')
        .replaceAll("'", '"');
    try {
      final Object? decoded = jsonDecode(swapped);
      if (decoded is Map) return _asMap(decoded);
    } on FormatException {
      // 落到下面的正则兜底
    }
    // 兜底：把 abslist 里的每条 {} 抠出来，逐字段取值
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    final RegExp itemPattern = RegExp(r'\{([^{}]*)\}');
    for (final RegExpMatch m in itemPattern.allMatches(trimmed)) {
      final String body = m.group(1) ?? '';
      final Map<String, dynamic> item = <String, dynamic>{};
      // ⚠️ 酷我这里的 key 是**带引号**的：`'SONGNAME':'晴天'`，
      // 所以正则必须允许 key 外面那对引号（0.0.39 靠单测才发现）。
      for (final RegExpMatch kv in RegExp(
        r"'?([A-Za-z_]+)'?\s*:\s*'([^']*)'",
      ).allMatches(body)) {
        item[kv.group(1)!] = kv.group(2)!;
      }
      if (item.isNotEmpty) items.add(item);
    }
    return <String, dynamic>{'abslist': items};
  }

  /// 脱 JSONP 外壳（QQ 音乐歌词接口返回 `MusicJsonCallback({...})`）。
  static Object? _stripJsonp(Object? data) {
    if (data is Map || data is List) return data;
    final String text = data?.toString() ?? '';
    final int start = text.indexOf('(');
    final int end = text.lastIndexOf(')');
    if (start >= 0 && end > start) {
      final String inner = text.substring(start + 1, end);
      try {
        return jsonDecode(inner);
      } on FormatException {
        return null;
      }
    }
    return data;
  }

  /// 歌词清洗：去掉 `[00:00.000] 此歌曲为没有填词的纯音乐` 这类占位。
  static String? _cleanLrc(String? raw) {
    if (raw == null) return null;
    final String text = raw.replaceAll('\r\n', '\n').trim();
    if (text.isEmpty) return null;
    if (!text.contains('[')) return null;
    return text;
  }

  /// 把异常翻译成人话（网络类错误直接说清楚，别丢一堆栈）。
  static String _humanize(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return '请求超时（本机网络到该站不稳）';
        case DioExceptionType.connectionError:
          return '连不上（${error.message ?? '网络不可达'}）';
        case DioExceptionType.badResponse:
          return 'HTTP ${error.response?.statusCode}';
        case DioExceptionType.badCertificate:
          return '证书校验失败';
        case DioExceptionType.cancel:
          return '请求已取消';
        case DioExceptionType.transformTimeout:
          return '响应解析超时';
        case DioExceptionType.unknown:
          return '网络错误：${error.message ?? error.error ?? '未知'}';
      }
    }
    return error.toString();
  }

  /// 把平台返回的脏歌名洗成适合当搜索关键词的样子：
  /// 去 HTML 实体、去 `(Live)` / `(KTV版伴奏)` 这类括号后缀。
  @visibleForTesting
  static String cleanQuery(String raw) => raw
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'[\(\[（【].*?[\)\]）】]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// 歌手名相似度：**先按第一个名字比**（0.0.46）。
  ///
  /// 为什么要这样：平台之间的歌手串写法不一样 ——
  /// 本地/网盘是 `Morgan Wallen、Grand Theft Auto VI`，网易云可能只写 `Morgan Wallen`；
  /// 直接用整串比会判成"不像"，于是**翻译歌词/封面就取不到了**。
  static double artistSimilarity(String a, String b) {
    final double direct = similarityOf(a, b);
    final double byFirst = similarityOf(_firstArtist(a), _firstArtist(b));
    return direct > byFirst ? direct : byFirst;
  }

  /// 取"第一个歌手"（`A、B` / `A / B` / `A feat. B` → `A`）。
  static String _firstArtist(String raw) => raw
      .split(
        RegExp(
          r'\s*(?:、|,|，|;|；|/|／|\||&|＆|\+|\s+feat\.?\s+|\s+ft\.?\s+|\s+with\s+)\s*',
          caseSensitive: false,
        ),
      )
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .fold<String>('', (String acc, String s) => acc.isEmpty ? s : acc);

  /// 字符串列表归一化。
  static List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .map((Object? e) => e.toString())
          .where((String e) => e.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }

  /// `Map` 归一化（dio 有时给 `Map<dynamic, dynamic>`）。
  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) {
      return value.map(
        (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
      );
    }
    if (value is String && value.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(value);
        if (decoded is Map) {
          return decoded.map(
            (Object? k, Object? v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          );
        }
      } on FormatException {
        // 不是 JSON，忽略
      }
    }
    return <String, dynamic>{};
  }
}
