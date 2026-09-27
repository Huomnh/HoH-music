/// source_cache.dart
///
/// **在线曲目 / 歌曲信息的持久化缓存**（0.0.44）。
///
/// 为什么要它：以前这些全是**内存缓存**（`HostSearch` 里的几个 Map），
/// 关掉应用就没了 —— 下次启动再刮一遍封面歌词、再按歌名匹配一遍，
/// 既慢又费流量（用户要求："在线曲目或者歌曲信息什么的做个缓存"）。
///
/// 缓存什么（都放 `shared_preferences`，键前缀 `cache.`）：
/// | 键 | 内容 | 为什么能缓存 |
/// |---|---|---|
/// | `cache.lyrics` | `曲目id → LRC 文本` | 歌词不会变 |
/// | `cache.match` | `歌名\\|歌手 → 匹配到的在线曲目` | "这首歌是哪个平台的哪首"不会变 |
/// | `cache.coverUrls` | `键 → 封面地址` | 地址是稳定的图床链接 |
///
/// **不缓存播放地址**：那是会过期的直链，缓存了只会拿到 403/404。
///
/// 有容量上限（避免 prefs 无限膨胀），超了就丢最早写入的（Map 插入顺序）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'source_models.dart';

/// 缓存统计（设置页展示用）。
class SourceCacheStats {
  /// 创建统计。
  const SourceCacheStats({
    this.lyrics = 0,
    this.matches = 0,
    this.covers = 0,
    this.bytes = 0,
  });

  /// 歌词条数。
  final int lyrics;

  /// 刮削匹配条数。
  final int matches;

  /// 封面地址条数。
  final int covers;

  /// 占用字节（估算：各条目的文本长度之和）。
  final int bytes;

  /// 一共多少条。
  int get entries => lyrics + matches + covers;

  /// 是否为空（设置页用来禁用按钮）。
  bool get isEmpty => entries == 0;

  /// 人话大小。
  String get sizeLabel {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}

/// 持久化缓存（单例）。
class SourceCache {
  SourceCache._();

  /// 单例。
  static final SourceCache instance = SourceCache._();

  static const String _lyricsKey = 'cache.lyrics';
  static const String _matchKey = 'cache.match';
  static const String _coverKey = 'cache.coverUrls';

  /// 容量上限（超了丢最早的写入）。
  static const int _maxLyrics = 400;
  static const int _maxMatches = 600;
  static const int _maxCovers = 600;

  Map<String, String>? _lyrics;
  Map<String, String>? _matches;
  Map<String, String>? _covers;

  Future<Map<String, String>> _load(String key) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (Object? k, Object? v) =>
              MapEntry<String, String>(k.toString(), v.toString()),
        );
      }
    } on FormatException {
      // 坏了就当空缓存
    }
    return <String, String>{};
  }

  Future<void> _save(String key, Map<String, String> data, int max) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    // 超上限先丢最早的
    while (data.length > max) {
      data.remove(data.keys.first);
    }
    await prefs.setString(key, jsonEncode(data));
  }

  Map<String, String> _trim(Map<String, String> data, int max) {
    while (data.length > max) {
      data.remove(data.keys.first);
    }
    return data;
  }

  // ── 歌词 ────────────────────────────────────────────────────────

  /// 读歌词缓存时顺手清掉**旧版本键**（0.0.48）。
  ///
  /// 键里带生成逻辑的版本号（见 `host_search.dart` 的 `|v2`）。旧版本的条目
  /// 是"没有翻译合并"时的结果，留着只会让用户觉得"翻译一直没生效"，
  /// 而且白占空间 —— 读取时发现是旧版就丢掉。
  static const String _lyricKeyVersion = '|v2';

  /// 取缓存的歌词（没有返回 null）。
  Future<String?> lyric(String trackId) async {
    if (trackId.isEmpty) return null;
    _lyrics ??= await _load(_lyricsKey);
    final String? hit = _lyrics![trackId];
    if (hit != null && !trackId.endsWith(_lyricKeyVersion)) {
      // 旧版键：丢弃并异步落盘（不阻塞本次读取）
      _lyrics!.remove(trackId);
      unawaited(_save(_lyricsKey, _lyrics!, _maxLyrics));
      return null;
    }
    return (hit == null || hit.trim().isEmpty) ? null : hit;
  }

  /// 写歌词缓存。
  Future<void> putLyric(String trackId, String lrc) async {
    if (trackId.isEmpty || lrc.trim().isEmpty) return;
    _lyrics ??= await _load(_lyricsKey);
    _lyrics![trackId] = lrc;
    await _save(_lyricsKey, _trim(_lyrics!, _maxLyrics), _maxLyrics);
  }

  // ── 刮削匹配（"这首歌是哪个平台的哪首"）─────────────────────────

  /// 取匹配结果。
  Future<OnlineTrack?> match(String cacheKey) async {
    if (cacheKey.isEmpty) return null;
    _matches ??= await _load(_matchKey);
    final String? raw = _matches![cacheKey];
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return OnlineTrack.fromJson(
          decoded.map(
            (Object? k, Object? v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          ),
        );
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// 写匹配结果。
  Future<void> putMatch(String cacheKey, OnlineTrack track) async {
    if (cacheKey.isEmpty) return;
    _matches ??= await _load(_matchKey);
    _matches![cacheKey] = jsonEncode(track.toJson());
    await _save(_matchKey, _trim(_matches!, _maxMatches), _maxMatches);
  }

  // ── 封面地址 ────────────────────────────────────────────────────

  /// 取封面地址。
  Future<String?> cover(String key) async {
    if (key.isEmpty) return null;
    _covers ??= await _load(_coverKey);
    final String? hit = _covers![key];
    return (hit == null || hit.isEmpty) ? null : hit;
  }

  /// 写封面地址。
  Future<void> putCover(String key, String url) async {
    if (key.isEmpty || url.isEmpty) return;
    _covers ??= await _load(_coverKey);
    _covers![key] = url;
    await _save(_coverKey, _trim(_covers!, _maxCovers), _maxCovers);
  }

  // ── 统计 / 清理 ─────────────────────────────────────────────────

  /// 当前占用情况。
  Future<SourceCacheStats> stats() async {
    _lyrics ??= await _load(_lyricsKey);
    _matches ??= await _load(_matchKey);
    _covers ??= await _load(_coverKey);
    int bytes = 0;
    for (final String v in _lyrics!.values) {
      bytes += v.length;
    }
    for (final String v in _matches!.values) {
      bytes += v.length;
    }
    for (final String v in _covers!.values) {
      bytes += v.length;
    }
    return SourceCacheStats(
      lyrics: _lyrics!.length,
      matches: _matches!.length,
      covers: _covers!.length,
      bytes: bytes,
    );
  }

  /// **清空缓存**（设置页的按钮）。返回清掉了多少条。
  Future<int> clear() async {
    final SourceCacheStats before = await stats();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lyricsKey);
    await prefs.remove(_matchKey);
    await prefs.remove(_coverKey);
    _lyrics = <String, String>{};
    _matches = <String, String>{};
    _covers = <String, String>{};
    return before.entries;
  }
}
