/// playlists.dart
///
/// 歌单与「我的喜欢」（0.0.27）。
///
/// 设计取舍：
/// - **「我的喜欢」就是一个内建歌单**（[favoritesId]），不单独存一份 ——
///   这样"收藏到喜欢"和"收藏到某个歌单"走同一条代码路径；
/// - 曲目只存 [Track.id]（本地路径 / 未来的远端 uri），不存整个 `Track`：
///   元数据可能变（重新扫描、刮削补全），存 id 才不会拿着一份过期数据；
/// - 目前落 `shared_preferences`（和音乐库记录一套）。**1 万首增量扫描**那轮
///   会连同 `library_store` 一起迁到 Drift，接口不用动。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「我的喜欢」的内建歌单 id。
const String favoritesId = 'favorites';

/// 一个歌单。
@immutable
class Playlist {
  /// 创建歌单。
  const Playlist({
    required this.id,
    required this.name,
    this.trackIds = const <String>[],
    this.isFavorites = false,
  });

  /// 唯一 id（内建收藏固定是 [favoritesId]）。
  final String id;

  /// 显示名。
  final String name;

  /// 曲目 id 列表（**按加入顺序**，播放时就是这个顺序）。
  final List<String> trackIds;

  /// 是否是「我的喜欢」。
  final bool isFavorites;

  /// 曲目数量。
  int get length => trackIds.length;

  Playlist copyWith({String? name, List<String>? trackIds}) => Playlist(
    id: id,
    name: name ?? this.name,
    trackIds: trackIds ?? this.trackIds,
    isFavorites: isFavorites,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'trackIds': trackIds,
    'isFavorites': isFavorites,
  };

  static Playlist? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? name = raw['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final List<String> ids = <String>[
      for (final Object? one
          in (raw['trackIds'] as List<Object?>? ?? const <Object?>[]))
        if (one is String && one.isNotEmpty) one,
    ];
    return Playlist(
      id: id,
      name: name,
      trackIds: ids,
      isFavorites: raw['isFavorites'] == true || id == favoritesId,
    );
  }
}

/// 全部歌单（**第一个永远是「我的喜欢」**）。
final playlistsProvider =
    AsyncNotifierProvider<PlaylistsController, List<Playlist>>(
      PlaylistsController.new,
    );

/// 歌单控制器。
class PlaylistsController extends AsyncNotifier<List<Playlist>> {
  static const String _key = 'library.playlists';

  @override
  Future<List<Playlist>> build() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_key);
      final List<Playlist> list = <Playlist>[];
      if (raw != null && raw.isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final Object? one in decoded) {
            final Playlist? p = Playlist.fromJson(one);
            if (p != null) list.add(p);
          }
        }
      }
      // 「我的喜欢」永远存在，且永远排第一
      final int favIndex = list.indexWhere((Playlist p) => p.isFavorites);
      if (favIndex < 0) {
        list.insert(
          0,
          const Playlist(id: favoritesId, name: '我喜欢的音乐', isFavorites: true),
        );
      } else if (favIndex != 0) {
        final Playlist fav = list.removeAt(favIndex);
        list.insert(0, fav);
      }
      return list;
    } catch (error) {
      debugPrint('[Playlists] 读取失败（用默认）：$error');
      return const <Playlist>[
        Playlist(id: favoritesId, name: '我喜欢的音乐', isFavorites: true),
      ];
    }
  }

  /// 新建歌单。
  Future<Playlist> create(String name) async {
    final List<Playlist> list = List<Playlist>.of(
      state.value ?? const <Playlist>[],
    );
    final Playlist playlist = Playlist(
      id: 'pl_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? '新歌单' : name.trim(),
    );
    list.add(playlist);
    await _commit(list);
    return playlist;
  }

  /// 创建一个导入歌单，并按文件中的顺序写入已匹配曲目。
  Future<Playlist> createImported(String name, List<String> trackIds) async {
    final String baseName = name.trim().isEmpty ? '导入歌单' : name.trim();
    final Set<String> names = <String>{
      for (final Playlist p in state.value ?? const <Playlist>[]) p.name,
    };
    String uniqueName = baseName;
    int suffix = 2;
    while (names.contains(uniqueName)) {
      uniqueName = '$baseName（导入 $suffix）';
      suffix++;
    }
    final Playlist playlist = Playlist(
      id: 'pl_${DateTime.now().microsecondsSinceEpoch}',
      name: uniqueName,
      trackIds: List<String>.unmodifiable(trackIds),
    );
    await _commit(<Playlist>[...(state.value ?? const <Playlist>[]), playlist]);
    return playlist;
  }

  /// 删除歌单（「我的喜欢」不给删）。
  Future<void> remove(String id) async {
    if (id == favoritesId) return;
    final List<Playlist> list = List<Playlist>.of(
      state.value ?? const <Playlist>[],
    )..removeWhere((Playlist p) => p.id == id);
    await _commit(list);
  }

  /// 重命名。
  Future<void> rename(String id, String name) async {
    final List<Playlist> list = <Playlist>[
      for (final Playlist p in state.value ?? const <Playlist>[])
        p.id == id ? p.copyWith(name: name) : p,
    ];
    await _commit(list);
  }

  /// 把曲目加进某个歌单（已在里面就忽略）。
  Future<void> addTrack(String playlistId, String trackId) async {
    final List<Playlist> list = <Playlist>[
      for (final Playlist p in state.value ?? const <Playlist>[])
        p.id == playlistId && !p.trackIds.contains(trackId)
            ? p.copyWith(trackIds: <String>[...p.trackIds, trackId])
            : p,
    ];
    await _commit(list);
  }

  /// 从歌单里移除曲目。
  Future<void> removeTrack(String playlistId, String trackId) async {
    final List<Playlist> list = <Playlist>[
      for (final Playlist p in state.value ?? const <Playlist>[])
        p.id == playlistId
            ? p.copyWith(
                trackIds: p.trackIds
                    .where((String id) => id != trackId)
                    .toList(),
              )
            : p,
    ];
    await _commit(list);
  }

  /// 收藏 / 取消收藏到「我的喜欢」。
  Future<bool> toggleFavorite(String trackId) async {
    final List<Playlist> list = state.value ?? const <Playlist>[];
    final Playlist? fav = _favoritesOf(list);
    final bool liked = fav?.trackIds.contains(trackId) ?? false;
    if (liked) {
      await removeTrack(favoritesId, trackId);
    } else {
      await addTrack(favoritesId, trackId);
    }
    return !liked;
  }

  /// 清空某个歌单（不动歌单本身）。
  Future<void> clear(String id) async {
    final List<Playlist> list = <Playlist>[
      for (final Playlist p in state.value ?? const <Playlist>[])
        p.id == id ? p.copyWith(trackIds: const <String>[]) : p,
    ];
    await _commit(list);
  }

  /// 按 id 取歌单。
  Playlist? byId(String id) {
    for (final Playlist p in state.value ?? const <Playlist>[]) {
      if (p.id == id) return p;
    }
    return null;
  }

  static Playlist? _favoritesOf(List<Playlist> list) {
    for (final Playlist p in list) {
      if (p.isFavorites) return p;
    }
    return null;
  }

  Future<void> _commit(List<Playlist> list) async {
    state = AsyncData<List<Playlist>>(list);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(<Object?>[for (final Playlist p in list) p.toJson()]),
      );
    } catch (error) {
      debugPrint('[Playlists] 保存失败：$error');
    }
  }
}

/// 「我的喜欢」的歌单（没有就返回空歌单）。
final favoritesProvider = Provider<Playlist>((ref) {
  final List<Playlist> list =
      ref.watch(playlistsProvider).value ?? const <Playlist>[];
  for (final Playlist p in list) {
    if (p.isFavorites) return p;
  }
  return const Playlist(id: favoritesId, name: '我喜欢的音乐', isFavorites: true);
});

/// 某首曲目是否已收藏（`select` 后只在变化时通知）。
final isFavoriteProvider = Provider.family<bool, String>((ref, String trackId) {
  final Playlist fav = ref.watch(favoritesProvider);
  return fav.trackIds.contains(trackId);
});
