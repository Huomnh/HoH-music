/// online_player.dart
///
/// 「搜到歌 → 解析地址 → 流式播放」的收口处（0.0.40 起统一走池子播放）。
///
/// 为什么单独一个文件：搜索页与在线曲目行都要用同一套逻辑；
/// 真正的解析/追加/替换语义在 `library/pool_playback.dart` —— 这里的职责只有
/// 「把在线曲目记进在线曲目表（地址会过期，歌名不会）」再交给池子播放。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart' show Track;
import '../../core/source/source_models.dart';
import '../../core/source/source_store.dart';
import '../library/pool_playback.dart';

/// 在线曲目转换为播放用 Track。播放地址不持久化，点播时由池播放流程重新解析。
Track trackFromOnline(OnlineTrack online) => Track(
  id: online.id,
  uri: '',
  title: online.title,
  artist: online.artist,
  album: online.album,
  duration: online.duration == Duration.zero ? null : online.duration,
  isRemote: true,
  source: online.platformLabel,
  genre: online.tags.isEmpty ? null : online.tags.first,
  quality: online.quality,
);

/// 一次"在线播放"的结果。
class OnlinePlayResult {
  /// 创建结果。
  const OnlinePlayResult({
    this.played = 0,
    this.failed = const <String>[],
    this.providers = const <String>[],
  });

  /// 成功进队列的曲目数。
  final int played;

  /// 失败明细（`歌名：原因`）。
  final List<String> failed;

  /// 用到的音源（去重后的展示名）。
  final List<String> providers;

  /// 是否全部成功。
  bool get ok => played > 0 && failed.isEmpty;
}

/// 播放在线曲目。
///
/// [append] = true（搜索页 / 在线曲目行的默认语义）→ **追加到播放队列**；
/// false → 替换队列。
/// [autoPlay] = false 时只入队不跳过去播（「添加到播放队列」按钮用）。
Future<OnlinePlayResult> playOnlineTracks(
  WidgetRef ref,
  List<OnlineTrack> tracks, {
  bool append = true,
  bool autoPlay = true,
  String? quality,
  void Function(int done, int total, String title)? onProgress,
}) async {
  if (tracks.isEmpty) return const OnlinePlayResult();

  // 先记住曲目信息：地址会过期，但"这首是什么歌"要留下来
  // （收藏 / 歌单 / 下次点播都靠它重新解析地址）。
  await ref.read(onlineLibraryProvider.notifier).remember(tracks);

  final PoolPlayResult result = await playPoolTracks(
    ref,
    tracks.map(trackFromOnline).toList(growable: false),
    append: append,
    autoPlay: autoPlay,
    quality: quality,
    onProgress: onProgress,
  );
  return OnlinePlayResult(
    played: result.played,
    failed: result.failed,
    providers: result.providers,
  );
}
