/// Import/export for the portable HoH playlist file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart';
import '../../core/source/host_search.dart';
import '../../core/source/source_models.dart';
import '../../core/source/source_store.dart';
import 'library_views.dart' show playlistTracksProvider;
import 'playlists.dart';

class PlaylistTransferResult {
  const PlaylistTransferResult({
    required this.playlistName,
    required this.imported,
    required this.skipped,
    this.unresolved = 0,
    this.created = true,
  });

  final String playlistName;
  final int imported;
  final int skipped;
  final int unresolved;
  final bool created;
}

enum _PlaylistImportMode { file, netease, qq }

/// Exports the selected playlist as a versioned JSON `.hohplaylist` file.
/// The extension is intentionally portable and does not contain temporary
/// playback URLs or audio bytes.
Future<void> exportPlaylist({
  required Playlist playlist,
  required Iterable<Track> tracks,
}) async {
  final Map<String, Track> byId = <String, Track>{
    for (final Track track in tracks) track.id: track,
  };
  final List<Map<String, Object?>> items = <Map<String, Object?>>[];
  for (int index = 0; index < playlist.trackIds.length; index++) {
    final String id = playlist.trackIds[index];
    final Track? track = byId[id];
    items.add(<String, Object?>{
      'order': index,
      'id': id,
      'title': track?.title ?? id,
      'artist': track?.artist ?? '',
      'album': track?.album ?? '',
      'durationMs': track?.duration?.inMilliseconds,
      'source': track?.source,
      'quality': track?.quality,
      'isRemote': track?.isRemote ?? id.contains(':'),
    });
  }
  final Map<String, Object?> payload = <String, Object?>{
    'format': 'hoh-playlist',
    'version': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'playlist': <String, Object?>{
      'id': playlist.id,
      'name': playlist.name,
      'isFavorites': playlist.isFavorites,
    },
    'tracks': items,
  };
  final Uri? path = await FilePicker.saveFile(
    dialogTitle: '导出 HoH music 歌单',
    fileName: '${_safeFileName(playlist.name)}.hohplaylist',
    bytes: utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)),
  );
  // file_picker 13 may return null after a successful native save dialog;
  // bytes are already handed to the platform, so there is nothing else to do.
  debugPrint('[PlaylistTransfer] 已导出 ${playlist.name}：$path');
}

/// Imports a `.hohplaylist` file and matches entries against the current
/// local/online playlist index. Existing IDs are preferred; title + artist +
/// album is the safe fallback. Unmatched entries are skipped and reported.
Future<PlaylistTransferResult?> importPlaylist(
  BuildContext context,
  WidgetRef ref,
) async {
  final TextEditingController urlController = TextEditingController();
  final _PlaylistImportMode? mode = await showDialog<_PlaylistImportMode>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('导入歌单'),
      content: const Text('请选择来源。不同来源使用各自的歌单接口和字段解析。'),
      actions: <Widget>[
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_PlaylistImportMode.file),
          child: const Text('HoH 文件'),
        ),
        OutlinedButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_PlaylistImportMode.netease),
          child: const Text('芸音链接'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_PlaylistImportMode.qq),
          child: const Text('鹅音链接'),
        ),
      ],
    ),
  );
  if (mode == null) return null;

  if (mode == _PlaylistImportMode.file) {
    urlController.dispose();
    return _importHoHPlaylistFile(ref);
  }

  if (!context.mounted) return null;
  final String platformName = mode == _PlaylistImportMode.qq ? '鹅音' : '芸音';
  final String? input = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text('导入$platformName歌单'),
      content: TextField(
        controller: urlController,
        autofocus: true,
        decoration: InputDecoration(
          labelText: '$platformName歌单链接',
          hintText: mode == _PlaylistImportMode.qq
              ? '支持 y.qq.com 或 c6.y.qq.com 分享链接'
              : '支持 music.163.com 或 163cn.tv 分享链接',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(urlController.text),
          child: const Text('读取并导入'),
        ),
      ],
    ),
  );
  if (!context.mounted) return null;
  urlController.dispose();
  if (input == null || input.trim().isEmpty) return null;
  return mode == _PlaylistImportMode.qq
      ? _importQqPlaylist(input, ref)
      : _importNeteasePlaylist(input, ref);
}

Future<PlaylistTransferResult> _importNeteasePlaylist(
  String input,
  WidgetRef ref,
) async {
  final String normalized = input.trim().replaceAll(r'\&', '&');
  if (!_isNeteasePlaylistUrl(normalized)) {
    throw const FormatException('芸音歌单链接格式无效');
  }
  final NeteasePlaylistInfo? info = await HostSearch.instance
      .neteasePlaylistFromUrl(normalized);
  if (info == null || info.tracks.isEmpty) {
    throw const FormatException('芸音歌单读取失败，可能是私密歌单或接口暂时不可用');
  }
  return _rememberImportedPlaylist(ref, info.name, info.tracks);
}

Future<PlaylistTransferResult> _importQqPlaylist(
  String input,
  WidgetRef ref,
) async {
  final String normalized = input.trim().replaceAll(r'\&', '&');
  if (!_isQqPlaylistUrl(normalized)) {
    throw const FormatException('鹅音歌单链接格式无效');
  }
  final QqPlaylistInfo? info = await HostSearch.instance.qqPlaylistFromUrl(
    normalized,
  );
  if (info == null || info.tracks.isEmpty) {
    throw const FormatException('鹅音歌单读取失败，可能是私密歌单或接口暂时不可用');
  }
  return _rememberImportedPlaylist(ref, info.name, info.tracks);
}

Future<PlaylistTransferResult> _rememberImportedPlaylist(
  WidgetRef ref,
  String name,
  List<OnlineTrack> tracks,
) async {
  await ref.read(onlineLibraryProvider.notifier).remember(tracks);
  final Playlist created = await ref
      .read(playlistsProvider.notifier)
      .createImported(name, <String>[for (final OnlineTrack t in tracks) t.id]);
  return PlaylistTransferResult(
    playlistName: created.name,
    imported: tracks.length,
    skipped: 0,
  );
}

Future<PlaylistTransferResult?> _importHoHPlaylistFile(WidgetRef ref) async {
  final List<PlatformFile> files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: <String>['hohplaylist', 'json'],
    dialogTitle: '选择 HoH music 歌单文件',
  );
  if (files.isEmpty || files.first.path == null) return null;
  final dynamic decoded = jsonDecode(
    await File(files.first.path!).readAsString(),
  );
  if (decoded is! Map) throw const FormatException('歌单文件结构无效');
  final Map<String, dynamic> payload = decoded.cast<String, dynamic>();
  if (payload['format'] != 'hoh-playlist' || payload['version'] != 1) {
    throw const FormatException('不是受支持的 HoH 歌单文件');
  }
  final Map<String, dynamic> playlistData =
      (payload['playlist'] as Map?)?.cast<String, dynamic>() ??
      <String, dynamic>{};
  final String originalName = (playlistData['name'] as String?)?.trim() ?? '';
  final String name = originalName.isEmpty ? '导入歌单' : originalName;
  final List<dynamic> rawTracks = payload['tracks'] is List
      ? payload['tracks'] as List<dynamic>
      : const <dynamic>[];
  final List<Track> available = ref.read(playlistTracksProvider);
  final Map<String, Track> byId = <String, Track>{
    for (final Track track in available) track.id: track,
  };
  final Map<String, Track> byMeta = <String, Track>{
    for (final Track track in available)
      _matchKey(track.title, track.artist, track.album): track,
  };
  final List<String> matchedIds = <String>[];
  int skipped = 0;
  for (final dynamic raw in rawTracks) {
    if (raw is! Map) {
      skipped++;
      continue;
    }
    final Map<Object?, Object?> item = raw;
    final String id = item['id'] is String ? item['id'] as String : '';
    final String title = item['title'] is String ? item['title'] as String : '';
    final String artist = item['artist'] is String
        ? item['artist'] as String
        : '';
    final String album = item['album'] is String ? item['album'] as String : '';
    final Track? match = byId[id] ?? byMeta[_matchKey(title, artist, album)];
    if (match == null) {
      skipped++;
    } else if (!matchedIds.contains(match.id)) {
      matchedIds.add(match.id);
    }
  }
  final Playlist created = await ref
      .read(playlistsProvider.notifier)
      .createImported(name, matchedIds);
  return PlaylistTransferResult(
    playlistName: created.name,
    imported: matchedIds.length,
    skipped: skipped,
  );
}

bool _isNeteasePlaylistUrl(String input) {
  final Uri? uri = Uri.tryParse(input);
  final String host = uri?.host.toLowerCase() ?? '';
  return host == '163cn.tv' ||
      host.endsWith('.163cn.tv') ||
      host == 'music.163.com' ||
      host.endsWith('.music.163.com');
}

bool _isQqPlaylistUrl(String input) {
  final Uri? uri = Uri.tryParse(input);
  final String host = uri?.host.toLowerCase() ?? '';
  return host.endsWith('y.qq.com') ||
      (host.endsWith('qq.com') && input.contains('/playlist'));
}

String _matchKey(String title, String artist, String album) =>
    '${_normalize(title)}|${_normalize(artist)}|${_normalize(album)}';

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\u3000]+'), '')
    .replaceAll(RegExp(r'[\(（].*?[\)）]'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

String _safeFileName(String value) {
  final String clean = value.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  return clean.isEmpty ? 'hoh-playlist' : clean;
}

/// Compact controls shown next to the playlist section heading.
class PlaylistTransferButtons extends ConsumerWidget {
  const PlaylistTransferButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: '导入歌单',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: () async {
            try {
              final PlaylistTransferResult? result = await importPlaylist(
                context,
                ref,
              );
              if (!context.mounted || result == null) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    '已导入「${result.playlistName}」：${result.imported} 首'
                    '${result.skipped > 0 ? '，跳过 ${result.skipped} 首' : ''}'
                    '${result.unresolved > 0 ? '，${result.unresolved} 首未完成在线搜索匹配' : ''}',
                  ),
                ),
              );
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('导入失败：$error')));
              }
            }
          },
          icon: const Icon(Icons.file_upload_outlined, size: 15),
          color: const Color(0xB3FFFFFF),
        ),
        IconButton(
          tooltip: '导出歌单',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: () => _showExportPicker(context, ref),
          icon: const Icon(Icons.file_download_outlined, size: 15),
          color: const Color(0xB3FFFFFF),
        ),
      ],
    );
  }

  Future<void> _showExportPicker(BuildContext context, WidgetRef ref) async {
    final List<Playlist> playlists =
        ref.read(playlistsProvider).value ?? const <Playlist>[];
    if (playlists.isEmpty) return;
    final Playlist? selected = await showDialog<Playlist>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('选择要导出的歌单'),
        children: <Widget>[
          for (final Playlist playlist in playlists)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(playlist),
              child: Text('${playlist.name}（${playlist.length} 首）'),
            ),
        ],
      ),
    );
    if (selected == null) return;
    final Map<String, Track> byId = <String, Track>{
      for (final Track track in ref.read(playlistTracksProvider))
        track.id: track,
    };
    try {
      await exportPlaylist(
        playlist: selected,
        tracks: selected.trackIds
            .map((String id) => byId[id])
            .whereType<Track>(),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已导出「${selected.name}」')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$error')));
      }
    }
  }
}
