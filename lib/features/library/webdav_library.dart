/// webdav_library.dart
///
/// **WebDAV 网盘音乐库**（0.0.40 起，0.0.53 支持**多源**）。
///
/// 用户要求：
/// - WebDAV 要**进音乐库**（不只是「来源」页里的一个浏览器）；
/// - **每次启动自动连接**，并且**和本地音乐一起加载**；
/// - 可以保存**多个**网盘连接，随时增删（`webdav_sources.dart`）；
/// - 播放仍然**不落盘**，每次从网盘流式取。
///
/// 曲目 id 形如 **`dav:<源id>:<路径>`**；缓存按源分开存（`webdav.cache.<源id>`）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/audio/player_engine.dart' show Track;
import '../../core/remote/webdav_client.dart';
import '../../core/remote/webdav_sources.dart';

/// 扫描限制：目录层数 / 单源文件总数上限（防巨型网盘把启动卡死）。
const int _kMaxDepth = 6;
const int _kMaxFiles = 3000;

/// 一次同步的结果。
class WebDavSyncResult {
  /// 创建结果。
  const WebDavSyncResult({this.tracks = 0, this.ok = false, this.message = ''});

  /// 扫到多少首。
  final int tracks;

  /// 是否成功。
  final bool ok;

  /// 人话说明。
  final String message;
}

/// 网盘曲库（所有已启用源聚合；启动自动同步）。
final webDavLibraryProvider =
    AsyncNotifierProvider<WebDavLibraryController, List<Track>>(
      WebDavLibraryController.new,
    );

/// 网盘曲库控制器。
class WebDavLibraryController extends AsyncNotifier<List<Track>> {
  /// 上一次同步的说明（界面提示用）。
  String lastMessage = '';

  @override
  Future<List<Track>> build() async {
    final List<WebDavSource> sources = await ref.watch(
      webDavSourcesProvider.future,
    );
    final List<Track> cached = <Track>[];
    for (final WebDavSource s in sources) {
      if (!s.enabled) continue;
      cached.addAll(await _readCache(s.id));
    }
    if (cached.isNotEmpty) {
      // 先把缓存显示出来，再后台刷新（启动不被网盘拖住）
      Future<void>.microtask(refresh);
      return cached;
    }
    await refresh();
    return _loadAllCaches();
  }

  /// 同步**所有**启用的源（串行：网盘接口对并发不友好）。
  Future<WebDavSyncResult> refresh({String? onlySourceId}) async {
    final List<WebDavSource> sources =
        ref.read(webDavSourcesProvider).value ?? const <WebDavSource>[];
    final List<WebDavSource> targets = <WebDavSource>[
      for (final WebDavSource s in sources)
        if (s.enabled && (onlySourceId == null || s.id == onlySourceId)) s,
    ];
    if (targets.isEmpty) {
      lastMessage = '还没有配置 WebDAV（去「播放设置 → 音源与刮削来源」添加）';
      state = const AsyncData<List<Track>>(<Track>[]);
      return WebDavSyncResult(ok: false, message: lastMessage);
    }

    int total = 0;
    final List<String> failed = <String>[];
    for (final WebDavSource source in targets) {
      if (!source.autoSync && onlySourceId == null) continue;
      final WebDavClient? client = clientFor(source);
      if (client == null) {
        failed.add('${source.name}：配置不完整');
        continue;
      }
      try {
        final ({bool ok, String message}) probe = await client.testConnection();
        if (!probe.ok) {
          failed.add('${source.name}：${probe.message}');
          continue;
        }
        final List<Track> tracks = <Track>[];
        await _walk(source, client, source.root, 0, tracks);
        await _writeCache(source.id, tracks);
        total += tracks.length;
        debugPrint('[WebDAV库] ${source.name} 同步完成：${tracks.length} 首');
      } catch (error) {
        failed.add('${source.name}：$error');
      }
    }

    final List<Track> all = await _loadAllCaches();
    state = AsyncData<List<Track>>(all);
    lastMessage = failed.isEmpty
        ? '已同步 $total 首（来自 ${targets.length} 个源）'
        : '同步 $total 首；失败：${failed.join('；')}';
    return WebDavSyncResult(
      tracks: total,
      ok: failed.isEmpty,
      message: lastMessage,
    );
  }

  /// 递归扫描（有层数与总数上限）。
  Future<void> _walk(
    WebDavSource source,
    WebDavClient client,
    String path,
    int depth,
    List<Track> out,
  ) async {
    if (depth > _kMaxDepth || out.length >= _kMaxFiles) return;
    final List<WebDavEntry> entries = await client.list(path);
    for (final WebDavEntry entry in entries) {
      if (out.length >= _kMaxFiles) return;
      if (entry.isDirectory) {
        await _walk(source, client, entry.path, depth + 1, out);
        continue;
      }
      if (!entry.looksLikeAudio) continue;
      out.add(trackFromDavEntry(entry, source));
    }
  }

  /// 读某个源的缓存。
  Future<List<Track>> _readCache(String sourceId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return _decode(prefs.getString(_cacheKey(sourceId)), sourceId);
  }

  Future<void> _writeCache(String sourceId, List<Track> tracks) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey(sourceId), _encode(tracks));
  }

  Future<List<Track>> _loadAllCaches() async {
    final List<WebDavSource> sources =
        ref.read(webDavSourcesProvider).value ?? const <WebDavSource>[];
    final List<Track> out = <Track>[];
    for (final WebDavSource s in sources) {
      if (!s.enabled) continue;
      out.addAll(await _readCache(s.id));
    }
    return out;
  }

  /// 删除某个源的缓存（删源时调用）。
  Future<void> clearSourceCache(String sourceId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey(sourceId));
    state = AsyncData<List<Track>>(await _loadAllCaches());
  }

  static String _cacheKey(String sourceId) => 'webdav.cache.$sourceId';

  static String _encode(List<Track> tracks) =>
      jsonEncode(<Map<String, dynamic>>[
        for (final Track t in tracks)
          <String, dynamic>{
            'path': splitDavId(t.id).$2,
            'title': t.title,
            'artist': t.artist,
            'album': t.album,
          },
      ]);

  static List<Track> _decode(String? raw, String sourceId) {
    if (raw == null || raw.isEmpty) return const <Track>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <Track>[];
      final List<Track> out = <Track>[];
      for (final Object? item in decoded) {
        if (item is! Map) continue;
        final String path = item['path']?.toString() ?? '';
        if (path.isEmpty) continue;
        out.add(
          Track(
            id: davTrackId(sourceId, path),
            // uri 先留空：真正播放时由 `pool_playback` 用当前配置重建
            uri: '',
            title: item['title']?.toString() ?? '',
            artist: item['artist']?.toString() ?? 'WebDAV',
            album: item['album']?.toString() ?? 'WebDAV',
            isRemote: true,
          ),
        );
      }
      return out;
    } on FormatException {
      return const <Track>[];
    }
  }
}

/// 曲目 id：`dav:<源id>:<路径>`。
String davTrackId(String sourceId, String path) => 'dav:$sourceId:$path';

/// 由 WebDAV 条目造一条曲目：曲名取文件名，艺术家取上级目录名。
Track trackFromDavEntry(WebDavEntry entry, WebDavSource source) {
  final String folder = _parentName(entry.path);
  return Track(
    id: davTrackId(source.id, entry.path),
    uri: WebDavClient(source.config).streamUrl(entry.path),
    title: davTitleOf(entry.name),
    artist: folder.isEmpty ? source.name : folder,
    album: folder.isEmpty ? source.name : folder,
    fileSize: entry.size > 0 ? entry.size : null,
    isRemote: true,
  );
}

/// 文件名 → 曲名（去掉扩展名，把 `_` 之类还原成空格好看点）。
String davTitleOf(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  final String base = dot > 0 ? fileName.substring(0, dot) : fileName;
  return base.replaceAll('_', ' ').trim();
}

String _parentName(String path) {
  final List<String> parts = path
      .split('/')
      .where((String s) => s.isNotEmpty)
      .toList();
  if (parts.length < 2) return '';
  // 用宽容解码：网盘里的目录名可能带 `%`，`Uri.decodeComponent` 会直接抛
  return WebDavClient.safeDecode(parts[parts.length - 2]);
}
