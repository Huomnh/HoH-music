/// library_pool.dart
///
/// **曲库池**：只收录本地音乐库与明确配置的 WebDAV 曲库。
///
/// 为什么要有它：以前 `libraryTracksProvider` 直接读**播放队列**，
/// 于是"我切换一个来源，其他来源的歌就不见了"（搜个歌就把本地 50 首顶掉）。
/// 现在：
///   - **所有歌曲 / 歌手 / 专辑页读这个池子**，
///     不管当前在播什么，池子内容都稳定；
///   - 播放队列只是"当前在播什么"，和池子解耦；
///   - 在线搜索曲目与播放队列相互独立；播放过的在线歌曲不会自动加入所有歌曲。
///   - 在线曲目仍单独记在 `onlineLibraryProvider`，供收藏/歌单按需重解析。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart' show Track;
import 'library_store.dart';
import 'webdav_library.dart';
import 'local_scanner.dart';

/// **本地曲库**：按「播放设置 → 音乐库」里登记的文件夹 / 单曲扫描出来的曲目。
///
/// 与播放队列解耦：扫描只读元数据，不碰播放器。
final localLibraryProvider =
    AsyncNotifierProvider<LocalLibraryController, List<Track>>(
      LocalLibraryController.new,
    );

/// 本地曲库控制器。
class LocalLibraryController extends AsyncNotifier<List<Track>> {
  @override
  Future<List<Track>> build() async {
    // 目录变化时重新执行增量扫描；Drift 索引会避免重复解析标签。
    final List<LibraryEntry> entries = await ref.watch(libraryProvider.future);
    final LocalScanner scanner = LocalScanner();
    final List<String> roots = entries
        .map((LibraryEntry entry) => entry.path)
        .toList(growable: false);
    final List<Track> cached = roots.isEmpty
        ? const <Track>[]
        : await scanner.cached();
    unawaited(_refreshInBackground(scanner, roots));
    return cached;
  }

  Future<void> _refreshInBackground(
    LocalScanner scanner,
    List<String> roots,
  ) async {
    try {
      final List<Track> result = await scanner.scan(roots);
      if (ref.mounted) state = AsyncData<List<Track>>(result);
    } catch (_) {
      // 页面已经有缓存时，后台扫描失败不清空现有曲目。
    }
  }

  /// 手动重扫（设置页「刷新曲库」用）。
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

/// 统一曲库池。
final libraryPoolProvider = Provider<List<Track>>((ref) {
  final AsyncValue<Set<String>> hiddenState = ref.watch(
    hiddenLibraryTracksProvider,
  );
  if (!hiddenState.hasValue) return const <Track>[];
  final List<Track> local =
      ref.watch(localLibraryProvider).value ?? const <Track>[];
  final List<Track> dav =
      ref.watch(webDavLibraryProvider).value ?? const <Track>[];
  final Set<String> hidden = hiddenState.value!;

  final Map<String, Track> pool = <String, Track>{};
  for (final Track t in local) {
    if (!hidden.contains(t.id)) pool[t.id] = t;
  }
  for (final Track t in dav) {
    if (!hidden.contains(t.id)) pool[t.id] = t;
  }
  return pool.values.toList(growable: false);
});
