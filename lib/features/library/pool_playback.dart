/// pool_playback.dart
///
/// 池子里的曲目怎么播（0.0.40）——**播放语义在这里统一**：
///
/// | 从哪播 | 行为 |
/// |---|---|
/// | 在线搜索 / WebDAV / 其他"来源" | **追加到播放队列**（不打断当前播放） |
/// | 歌单 / 歌手 / 专辑 / 所有歌曲 | **替换队列**（只播这一份内容） |
///
/// 另外负责把"只有 id、没有地址"的曲目补上地址：
///   - **在线曲目**（`平台:歌曲id`）：现解析 `musicUrl`（地址会过期，不能缓存）；
///   - **WebDAV 曲目**：缓存里 `uri` 是空的，按当前配置重建 `streamUrl`。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart' show Track;
import '../../core/audio/player_providers.dart';
import '../../core/remote/webdav_client.dart';
import '../../core/remote/webdav_sources.dart';
import '../../core/source/host_search.dart';
import '../../core/source/source_host.dart';
import '../../core/source/source_models.dart';
import '../../core/source/source_store.dart';

/// 一次播放的结果。
class PoolPlayResult {
  /// 创建结果。
  const PoolPlayResult({
    this.played = 0,
    this.failed = const <String>[],
    this.providers = const <String>[],
    this.appended = false,
  });

  /// 成功进队列的数量。
  final int played;

  /// 失败明细。
  final List<String> failed;

  /// 用到的音源。
  final List<String> providers;

  /// 是追加还是替换。
  final bool appended;

  /// 是否全部成功。
  bool get ok => played > 0 && failed.isEmpty;
}

/// 歌单的“待解析队列”。队列先展示完整曲目，但在线地址只在播放某一首时解析。
class PendingPlaylist {
  const PendingPlaylist({required this.tracks, this.activeIndex = -1});

  final List<Track> tracks;
  final int activeIndex;

  PendingPlaylist copyWith({List<Track>? tracks, int? activeIndex}) =>
      PendingPlaylist(
        tracks: tracks ?? this.tracks,
        activeIndex: activeIndex ?? this.activeIndex,
      );
}

class PendingPlaylistController extends Notifier<PendingPlaylist?> {
  int _requestSerial = 0;

  @override
  PendingPlaylist? build() => null;

  void setPending(PendingPlaylist? value) => state = value;

  int beginRequest() => ++_requestSerial;

  bool isCurrent(int request, int index) =>
      request == _requestSerial && state?.activeIndex == index;
}

final pendingPlaylistProvider =
    NotifierProvider<PendingPlaylistController, PendingPlaylist?>(
      PendingPlaylistController.new,
    );

final math.Random _pendingPlaylistRandom = math.Random();

/// 按统一播放模式步进“待解析歌单”。
///
/// 在线歌单首次播放时，底层播放器只会暂时载入当前已经解析好的那一首，
/// 但 [pendingPlaylistProvider] 保存了完整歌单。桌面端和 Android 端都必须
/// 从这里切歌，否则 Android 直接调用 `player.next()` 只能看到这一首。
Future<PoolPlayResult> stepPendingPlaylist(
  WidgetRef ref, {
  required int delta,
  bool automatic = false,
}) async {
  final PendingPlaylist? pending = ref.read(pendingPlaylistProvider);
  final PlayerController controller = ref.read(
    playerControllerProvider.notifier,
  );
  if (pending == null) {
    if (delta < 0) {
      await controller.previous();
    } else {
      await controller.next();
    }
    return const PoolPlayResult(played: 1);
  }
  if (pending.tracks.isEmpty || pending.activeIndex < 0) {
    return const PoolPlayResult();
  }

  final PlaybackMode mode = ref.read(playerControllerProvider).mode;
  final int length = pending.tracks.length;
  int target;
  if (automatic && mode == PlaybackMode.repeatOne) {
    target = pending.activeIndex;
  } else if (mode == PlaybackMode.shuffle && length > 1) {
    target = pending.activeIndex;
    while (target == pending.activeIndex) {
      target = _pendingPlaylistRandom.nextInt(length);
    }
  } else {
    target = pending.activeIndex + delta;
    if (target < 0 || target >= length) {
      if (mode == PlaybackMode.repeatAll ||
          (automatic && mode == PlaybackMode.repeatOne)) {
        target = delta < 0 ? length - 1 : 0;
      } else {
        return const PoolPlayResult();
      }
    }
  }
  return playPendingPlaylistTrack(ref, pending.tracks, target);
}

int _targetGeneration = 0;
final Map<String, Future<OnlineTrack>> _matchingInFlight =
    <String, Future<OnlineTrack>>{};

/// 播放池子里的曲目。
///
/// [append] = true → 追加到队列（搜索 / WebDAV / 其他来源）；
/// false → 替换队列（歌单 / 专辑 / 歌手 / 所有歌曲）。
Future<PoolPlayResult> playPoolTracks(
  WidgetRef ref,
  List<Track> tracks, {
  bool append = false,
  int startIndex = 0,
  bool autoPlay = true,
  String? quality,
  void Function(int done, int total, String title)? onProgress,
}) async {
  _targetGeneration++;
  tracks = _dedupePoolTracks(tracks);
  if (tracks.isEmpty) return const PoolPlayResult();

  // 0.0.41 快路径：**队列已经是这份内容就只跳过去**，不重建播放列表。
  // 用户反馈"从所有歌曲选歌播放反应有点慢" —— 每次点一首歌都重新
  // `player.open(100+ 首的 Playlist)` 确实慢。
  if (!append) {
    final List<Track> current = ref.read(playerControllerProvider).queue;
    if (current.length == tracks.length &&
        current.isNotEmpty &&
        current.first.id == tracks.first.id &&
        current.last.id == tracks.last.id) {
      await ref
          .read(playerControllerProvider.notifier)
          .playAt(startIndex.clamp(0, current.length - 1));
      return const PoolPlayResult(played: 1);
    }
  }

  final List<OnlineTrack> onlinePool =
      ref.read(onlineLibraryProvider).value ?? const <OnlineTrack>[];
  final Map<String, OnlineTrack> onlineById = <String, OnlineTrack>{
    for (final OnlineTrack t in onlinePool) t.id: t,
  };
  final SourceHostController host = ref.read(sourceHostProvider.notifier);
  // 曲目 id → 它属于哪个源（多源时鉴权头不一样）
  final Map<String, String> davSourceIds = <String, String>{};

  final List<Track> ready = <Track>[];
  final List<String> failed = <String>[];
  final List<String> providers = <String>[];
  // 曲库页播放时需要现搜索/解析的在线曲目
  final List<OnlineTrack> pendingOnline = <OnlineTrack>[];
  final String clickedId = (startIndex >= 0 && startIndex < tracks.length)
      ? tracks[startIndex].id
      : '';

  for (int i = 0; i < tracks.length; i++) {
    final Track track = tracks[i];
    onProgress?.call(i, tracks.length, track.title);

    // ① 已经有地址（本地文件 / WebDAV 已重建 / 在线已解析）
    if (track.uri.isNotEmpty) {
      ready.add(track);
      continue;
    }

    if (track.id.startsWith('dav:')) {
      // id 是 `dav:<源id>:<路径>`（0.0.53 多源）；旧格式 `dav:<路径>` 也兼容
      final (String sourceId, String path) = splitDavId(track.id);
      final WebDavSource? source = sourceId.isEmpty
          ? _firstEnabledSource(ref)
          : ref
                .read(webDavSourcesProvider)
                .value
                ?.where((WebDavSource s) => s.id == sourceId)
                .firstOrNull;
      final WebDavClient? client = clientFor(source);
      if (client == null) {
        failed.add('${track.title}：WebDAV 源没配置好');
        continue;
      }
      ready.add(
        Track(
          id: track.id,
          uri: client.streamUrl(path),
          title: track.title,
          artist: track.artist,
          album: track.album,
          duration: track.duration,
          isRemote: true,
        ),
      );
      // 这一首属于哪个源（入队时要用它的鉴权头）
      if (source != null) davSourceIds[track.id] = source.id;
      continue;
    }

    // ③ 在线曲目：需要**现解析地址**（网络！）
    //
    // ⚠️ 0.0.43 性能修复：从「所有歌曲」点歌时**不要**在这里解析。
    // 池子里有几十首在线曲目，逐个解析 = 点一下要等十几秒
    //（用户反馈："所有歌曲里选中播放的速度很慢"）。
    // 曲库页（!append）把在线曲目收集起来，稍后统一解析，确保打开队列时完整。
    final OnlineTrack? online = onlineById[track.id];
    if (online == null) {
      failed.add('${track.title}：找不到这首的来源信息');
      continue;
    }
    if (!append) {
      pendingOnline.add(online);
      continue;
    }
    final SourceResolveResult resolved = await host.resolveMusicUrl(
      online,
      quality: quality,
    );
    if (!resolved.ok || resolved.url.isEmpty) {
      failed.add('${online.title}：${resolved.error}');
      continue;
    }
    if (resolved.provider.isNotEmpty) providers.add(resolved.provider);

    String? lyric = await HostSearch.instance.lyricFor(online);
    if (lyric == null || lyric.trim().isEmpty) {
      final String fromSource = await host.fetchLyric(online);
      if (fromSource.trim().isNotEmpty) lyric = fromSource;
    }
    ready.add(
      Track(
        id: online.id,
        uri: resolved.url,
        title: online.title,
        artist: online.artist,
        album: online.album,
        duration: online.duration == Duration.zero ? null : online.duration,
        isRemote: true,
        lyrics: lyric,
        // URL 后缀/查询参数不是文件签名；在线播放阶段只显示未验证，
        // 下载完成后再按真实容器更新本地曲目。
        formatOverride: '',
        source: online.platformLabel,
        genre: online.tags.isEmpty ? null : online.tags.first,
        quality: quality ?? online.quality,
      ),
    );
  }

  onProgress?.call(tracks.length, tracks.length, '');

  // 歌单播放规则：播放器队列面板先展示完整歌单；只匹配并解析被点击的歌曲。
  // 手动点队列下一首或当前曲目播放完成后，再按需解析对应曲目。
  if (!append && pendingOnline.isNotEmpty) {
    final List<Track> pendingTracks = <Track>[
      for (final Track track in tracks) track,
    ];
    ref
        .read(pendingPlaylistProvider.notifier)
        .setPending(
          PendingPlaylist(tracks: pendingTracks, activeIndex: startIndex),
        );
    final PoolPlayResult first = await playPendingPlaylistTrack(
      ref,
      pendingTracks,
      startIndex,
      quality: quality,
    );
    return PoolPlayResult(
      played: first.played,
      failed: first.failed,
      providers: first.providers,
    );
  }

  // 非在线待解析歌单播放时，清掉上一张歌单的按需状态，避免队列抽屉
  // 或下一首按钮继续引用旧歌单。
  if (!append) {
    ref.read(pendingPlaylistProvider.notifier).setPending(null);
  }

  if (ready.isEmpty) {
    return PoolPlayResult(failed: failed, appended: append);
  }

  // ⚠️ 下标必须**按曲目 id 重新定位**（0.0.45 修的真 bug）：
  //    `startIndex` 是"池子列表"里的下标，而池子里有需要现解析的**在线曲目**，
  //    它们不进 `ready`（本地/网盘优先播）—— 直接拿池子下标去点 ready，
  //    就会"点第 60 行，播的却是第 60 个能直接播的"，看着像随机乱播。
  //    用户反馈"随机播放下选歌不是选中那首、放几首后又正常"就是这个。
  int readyIndex = clickedId.isEmpty
      ? 0
      : ready.indexWhere((Track t) => t.id == clickedId);
  if (readyIndex < 0) readyIndex = 0;
  readyIndex = readyIndex.clamp(0, ready.length - 1);

  // 追加模式下：点的那首在 `others`/`davTracks` 里的位置（autoPlayIndex 用）
  final int readyOffset = readyIndex;

  // 快路径之二（0.0.43）：队列已经就是这份"能直接播的"列表 → 只跳过去。
  // 第二次点同一页的歌时走的就是这里，不再重建播放列表。
  if (!append && _sameIds(ref.read(playerControllerProvider).queue, ready)) {
    await ref.read(playerControllerProvider.notifier).playAt(readyIndex);
    return const PoolPlayResult(played: 1);
  }

  // 所有歌曲通常都是本地文件：首播只打开点中的文件，避免一次性构建
  // 几百首 Playlist 把第一声音乐拖到很晚；在线歌单则已在上方补齐完整队列。
  if (!append &&
      pendingOnline.isEmpty &&
      ready.every((Track t) => !t.isRemote && t.uri.isNotEmpty)) {
    await ref
        .read(playerControllerProvider.notifier)
        .playLocalTracksFast(ready, startIndex: readyIndex, autoPlay: autoPlay);
    return PoolPlayResult(
      played: ready.length,
      failed: failed,
      providers: providers.toSet().toList(growable: false),
    );
  }

  final PlayerController controller = ref.read(
    playerControllerProvider.notifier,
  );

  // ⚠️ WebDAV 要带 Basic 鉴权头，在线直链只要个正常 UA —— **不能混在一个批次里**，
  //    否则会把网盘账号密码发给第三方 CDN。
  final List<Track> davTracks = ready
      .where((Track t) => t.id.startsWith('dav:'))
      .toList(growable: false);
  final List<Track> others = ready
      .where((Track t) => !t.id.startsWith('dav:'))
      .toList(growable: false);
  // 多源（0.0.53）：网盘曲目按**源**分组，每组的鉴权头不一样
  final Map<String, List<Track>> davGroups = <String, List<Track>>{};
  for (final Track t in davTracks) {
    (davGroups[davSourceIds[t.id] ?? ''] ??= <Track>[]).add(t);
  }
  final List<List<Track>> davBatches = davGroups.values.toList(growable: false);
  Map<String, String>? headersOfBatch(List<Track> batch) => batch.isEmpty
      ? null
      : _davHeadersFor(ref, davSourceIds[batch.first.id] ?? '');

  if (append) {
    // 点播语义：**追加到队列，然后跳到那一首直接播**（"点啥放啥"）。
    final int othersCount = others.length;
    if (others.isNotEmpty) {
      await controller.enqueueTracks(
        others,
        httpHeaders: _kUaHeaders,
        autoPlayIndex: autoPlay && readyOffset < othersCount
            ? readyOffset
            : null,
      );
    }
    int davSeen = othersCount;
    for (final List<Track> batch in davBatches) {
      final int indexInBatch = batch.indexWhere((Track t) => t.id == clickedId);
      await controller.enqueueTracks(
        batch,
        httpHeaders: headersOfBatch(batch),
        autoPlayIndex: autoPlay && indexInBatch >= 0 ? indexInBatch : null,
      );
      davSeen += batch.length;
    }
    debugPrint(
      '[Pool] 追加播放：本地/在线 ${others.length} 首 + 网盘 ${davTracks.length} 首'
      '（davSeen=$davSeen）',
    );
  } else {
    // ⚠️ 0.0.48 修的真 bug：替换队列时 `player.open(index:)` **只作用在第一批**。
    //    所以要点中的那首所在的批次排到最前（0.0.53 起网盘还按源分了组）。
    final bool clickedInDav = davTracks.any((Track t) => t.id == clickedId);
    final List<Track> firstBatch;
    final List<Track>? firstBatchDavSource;
    final List<List<Track>> trailing;
    if (clickedInDav && others.isNotEmpty) {
      final int groupIndex = davBatches.indexWhere(
        (List<Track> b) => b.any((Track t) => t.id == clickedId),
      );
      firstBatch = groupIndex >= 0 ? davBatches[groupIndex] : davBatches.first;
      firstBatchDavSource = firstBatch;
      trailing = <List<Track>>[
        others,
        for (final List<Track> b in davBatches)
          if (!identical(b, firstBatch)) b,
      ];
    } else if (others.isNotEmpty) {
      firstBatch = others;
      firstBatchDavSource = null;
      trailing = <List<Track>>[for (final List<Track> b in davBatches) b];
    } else if (davBatches.isNotEmpty) {
      firstBatch = davBatches.first;
      firstBatchDavSource = firstBatch;
      trailing = davBatches.skip(1).toList(growable: false);
    } else {
      firstBatch = const <Track>[];
      firstBatchDavSource = null;
      trailing = const <List<Track>>[];
    }

    int firstIndex = firstBatch.indexWhere((Track t) => t.id == clickedId);
    if (firstIndex < 0) firstIndex = 0;
    await controller.playRemoteTracks(
      firstBatch,
      httpHeaders: firstBatchDavSource == null
          ? _kUaHeaders
          : headersOfBatch(firstBatchDavSource),
      startIndex: firstIndex.clamp(
        0,
        firstBatch.isEmpty ? 0 : firstBatch.length - 1,
      ),
    );
    for (final List<Track> batch in trailing) {
      await controller.enqueueTracks(batch, httpHeaders: headersOfBatch(batch));
    }
  }
  return PoolPlayResult(
    played: ready.length,
    failed: failed,
    providers: providers.toSet().toList(growable: false),
    appended: append,
  );
}

/// 只解析并播放待解析队列中的一首。下一首由自动播放、控制栏下一首或队列点击调用。
Future<PoolPlayResult> playPendingPlaylistTrack(
  WidgetRef ref,
  List<Track> tracks,
  int index, {
  String? quality,
}) async {
  if (index < 0 || index >= tracks.length) {
    return const PoolPlayResult(failed: <String>['歌曲位置无效']);
  }
  final Track sourceTrack = tracks[index];
  final PendingPlaylistController pendingController = ref.read(
    pendingPlaylistProvider.notifier,
  );
  final int request = pendingController.beginRequest();
  final int generation = ++_targetGeneration;
  pendingController.setPending(
    PendingPlaylist(tracks: tracks, activeIndex: index),
  );
  if (sourceTrack.uri.isNotEmpty) {
    await ref.read(playerControllerProvider.notifier).playRemoteTracks(<Track>[
      sourceTrack,
    ], httpHeaders: _kUaHeaders);
    unawaited(
      _prefetchAdjacentPending(
        ref,
        tracks,
        index,
        generation: generation,
        quality: quality,
      ),
    );
    return const PoolPlayResult(played: 1);
  }
  final OnlineTrack? online = ref
      .read(onlineLibraryProvider)
      .value
      ?.where((OnlineTrack t) => t.id == sourceTrack.id)
      .firstOrNull;
  if (online == null) {
    return PoolPlayResult(failed: <String>['${sourceTrack.title}：找不到在线来源信息']);
  }
  final OnlineTrack prepared = await _prepareOnlineTrack(ref, online);
  final SourceResolveResult resolved = await ref
      .read(sourceHostProvider.notifier)
      .resolveMusicUrl(prepared, quality: quality);
  if (!resolved.ok || resolved.url.isEmpty) {
    return PoolPlayResult(
      failed: <String>['${prepared.title}：${resolved.error}'],
    );
  }
  if (!pendingController.isCurrent(request, index)) {
    return const PoolPlayResult(failed: <String>['已切换到新的目标歌曲']);
  }
  final Track playable = _remoteTrack(prepared, resolved.url, quality: quality);
  final List<Track> nextTracks = List<Track>.of(tracks)..[index] = playable;
  ref
      .read(pendingPlaylistProvider.notifier)
      .setPending(PendingPlaylist(tracks: nextTracks, activeIndex: index));
  await ref.read(playerControllerProvider.notifier).playRemoteTracks(<Track>[
    playable,
  ], httpHeaders: _kUaHeaders);
  unawaited(
    _prefetchAdjacentPending(
      ref,
      nextTracks,
      index,
      generation: generation,
      quality: quality,
    ),
  );
  return PoolPlayResult(played: 1, providers: <String>[resolved.provider]);
}

Future<void> _prefetchAdjacentPending(
  WidgetRef ref,
  List<Track> tracks,
  int activeIndex, {
  required int generation,
  String? quality,
}) async {
  for (final int index in <int>[activeIndex - 1, activeIndex + 1]) {
    if (generation != _targetGeneration) return;
    if (index < 0 || index >= tracks.length || tracks[index].uri.isNotEmpty) {
      continue;
    }
    final OnlineTrack? online = ref
        .read(onlineLibraryProvider)
        .value
        ?.where((OnlineTrack t) => t.id == tracks[index].id)
        .firstOrNull;
    if (online == null) continue;
    final OnlineTrack prepared = await _prepareOnlineTrack(ref, online);
    final SourceResolveResult result = await ref
        .read(sourceHostProvider.notifier)
        .resolveMusicUrl(prepared, quality: quality);
    if (generation != _targetGeneration) return;
    if (!result.ok || result.url.isEmpty) continue;
    final PendingPlaylist? current = ref.read(pendingPlaylistProvider);
    if (current == null || current.tracks.length != tracks.length) return;
    final List<Track> updated = List<Track>.of(current.tracks)
      ..[index] = _remoteTrack(prepared, result.url, quality: quality);
    ref
        .read(pendingPlaylistProvider.notifier)
        .setPending(
          PendingPlaylist(tracks: updated, activeIndex: current.activeIndex),
        );
  }
}

/// 两份列表是不是同一批曲目（按 id 顺序比）。
bool _sameIds(List<Track> a, List<Track> b) {
  if (a.length != b.length || a.isEmpty) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
}

/// 导入歌单的曲目没有搜索结果里的平台扩展字段，首次播放时按需补全。
Future<OnlineTrack> _prepareOnlineTrack(
  WidgetRef ref,
  OnlineTrack original,
) async {
  if (original.extra.isNotEmpty) return original;
  final Future<OnlineTrack>? running = _matchingInFlight[original.id];
  if (running != null) return running;
  final Future<OnlineTrack> future = _prepareOnlineTrackUncached(ref, original);
  _matchingInFlight[original.id] = future;
  try {
    return await future;
  } finally {
    if (identical(_matchingInFlight[original.id], future)) {
      _matchingInFlight.remove(original.id);
    }
  }
}

Future<OnlineTrack> _prepareOnlineTrackUncached(
  WidgetRef ref,
  OnlineTrack original,
) async {
  final OnlineTrack? matched = await HostSearch.instance.matchTrack(
    Track(
      id: original.id,
      uri: '',
      title: original.title,
      artist: original.artist,
      album: original.album,
      duration: original.duration == Duration.zero ? null : original.duration,
      isRemote: true,
    ),
    platforms: <String>[original.platform],
  );
  if (matched == null) return original;
  await ref.read(onlineLibraryProvider.notifier).remember(<OnlineTrack>[
    matched,
  ]);
  return matched;
}

Track _remoteTrack(OnlineTrack track, String url, {String? quality}) => Track(
  id: track.id,
  uri: url,
  title: track.title,
  artist: track.artist,
  album: track.album,
  duration: track.duration == Duration.zero ? null : track.duration,
  isRemote: true,
  formatOverride: '',
  source: track.platformLabel,
  genre: track.tags.isEmpty ? null : track.tags.first,
  quality: quality ?? track.quality,
);

/// 歌单播放只保留一次曲目：优先按稳定 ID 去重，在线曲目再按标题/歌手/专辑
/// 去重，避免同一首歌因平台返回重复 ID 或重复版本多次进入队列。
List<Track> _dedupePoolTracks(List<Track> input) {
  final Set<String> ids = <String>{};
  final Set<String> onlineKeys = <String>{};
  final List<Track> result = <Track>[];
  for (final Track track in input) {
    if (!ids.add(track.id)) continue;
    if (track.isRemote) {
      final String key = _poolText(
        '${track.title}|${track.artist}|${track.album}',
      );
      if (!onlineKeys.add(key)) continue;
    }
    result.add(track);
  }
  return result;
}

String _poolText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\u3000]+'), '')
    .replaceAll(RegExp(r'[\(（].*?[\)）]'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// 第一个启用的源（兼容旧 `dav:<路径>` 格式）。
WebDavSource? _firstEnabledSource(WidgetRef ref) => ref
    .read(webDavSourcesProvider)
    .value
    ?.where((WebDavSource s) => s.enabled)
    .firstOrNull;

/// 某个源 id 的播放头（Basic 鉴权 + UA）。
Map<String, String>? _davHeadersFor(WidgetRef ref, String sourceId) {
  final WebDavSource? source = sourceId.isEmpty
      ? _firstEnabledSource(ref)
      : ref
            .read(webDavSourcesProvider)
            .value
            ?.where((WebDavSource s) => s.id == sourceId)
            .firstOrNull;
  if (source == null) return null;
  return <String, String>{
    ...source.config.authHeaders,
    'User-Agent': _kUaHeaders['User-Agent']!,
  };
}

/// 在线直链的请求头：只给个正常 UA，**不要**带任何凭据。
const Map<String, String> _kUaHeaders = <String, String>{
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 '
      'Safari/537.36 HoH-music/0.0.40',
};
