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
  // 曲库页播放时先"欠着"的在线曲目（播放开始后再后台解析）
  final List<OnlineTrack> pendingOnline = <OnlineTrack>[];

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
    // 现在：曲库页（!append）先只播**不需要解析**的本地/网盘曲目，
    // 在线曲目收集起来，等播放开始后在后台解析并追加进队列。
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

  // 后台把"欠着"的在线曲目解析出来，追加到队列末尾（不打断当前播放）。
  // 这样点歌是**立刻**开始响的，在线那几十首慢慢补。
  if (pendingOnline.isNotEmpty) {
    unawaited(
      _appendOnlineInBackground(
        ref,
        pendingOnline,
        host: host,
        quality: quality,
      ),
    );
  }

  if (ready.isEmpty) {
    return PoolPlayResult(failed: failed, appended: append);
  }

  // ⚠️ 下标必须**按曲目 id 重新定位**（0.0.45 修的真 bug）：
  //    `startIndex` 是"池子列表"里的下标，而池子里有需要现解析的**在线曲目**，
  //    它们不进 `ready`（本地/网盘优先播）—— 直接拿池子下标去点 ready，
  //    就会"点第 60 行，播的却是第 60 个能直接播的"，看着像随机乱播。
  //    用户反馈"随机播放下选歌不是选中那首、放几首后又正常"就是这个。
  final String clickedId = (startIndex >= 0 && startIndex < tracks.length)
      ? tracks[startIndex].id
      : '';
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
  // 几百首 Playlist 把第一声音乐拖到很晚；剩余歌曲由播放器后台补齐。
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

  // 点的如果是"需要现解析"的在线曲目：**只解析这一首**，立刻播它，
  // 其余在线曲目仍旧后台补（"点啥放啥"，且不用等几十次网络请求）。
  for (final OnlineTrack pending in pendingOnline) {
    if (pending.id != clickedId) continue;
    final SourceResolveResult resolved = await host.resolveMusicUrl(
      pending,
      quality: quality,
    );
    if (resolved.ok && resolved.url.isNotEmpty) {
      await controller.playRemoteTracks(<Track>[
        Track(
          id: pending.id,
          uri: resolved.url,
          title: pending.title,
          artist: pending.artist,
          album: pending.album,
          duration: pending.duration == Duration.zero ? null : pending.duration,
          isRemote: true,
          formatOverride: '',
          source: pending.platformLabel,
          genre: pending.tags.isEmpty ? null : pending.tags.first,
          quality: quality ?? pending.quality,
        ),
      ], httpHeaders: _kUaHeaders);
      return PoolPlayResult(played: 1, providers: <String>[resolved.provider]);
    }
    failed.add('${pending.title}：${resolved.error}');
    break;
  }
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

/// 两份列表是不是同一批曲目（按 id 顺序比）。
bool _sameIds(List<Track> a, List<Track> b) {
  if (a.length != b.length || a.isEmpty) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
}

/// 后台解析在线曲目并追加到队列（曲库页点歌后的"补货"）。
///
/// 为什么不在播放前做：每首要发 1~2 个网络请求，几十首就是十几秒，
/// 用户点一下歌要等这么久（0.0.43 用户反馈的就是这个）。
Future<void> _appendOnlineInBackground(
  WidgetRef ref,
  List<OnlineTrack> online, {
  required SourceHostController host,
  String? quality,
}) async {
  final List<Track> resolved = <Track>[];
  for (final OnlineTrack t in online) {
    final SourceResolveResult result = await host.resolveMusicUrl(
      t,
      quality: quality,
    );
    if (!result.ok || result.url.isEmpty) continue;
    resolved.add(
      Track(
        id: t.id,
        uri: result.url,
        title: t.title,
        artist: t.artist,
        album: t.album,
        duration: t.duration == Duration.zero ? null : t.duration,
        isRemote: true,
        formatOverride: '',
        source: t.platformLabel,
        genre: t.tags.isEmpty ? null : t.tags.first,
        quality: quality ?? t.quality,
      ),
    );
  }
  if (resolved.isEmpty) return;
  await ref
      .read(playerControllerProvider.notifier)
      .enqueueTracks(resolved, httpHeaders: _kUaHeaders);
}

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
