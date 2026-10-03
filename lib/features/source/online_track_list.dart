/// online_track_list.dart
///
/// 在线曲目的**行**与**列表**（搜索页和「我的喜欢 / 歌单」共用）。
///
/// 行 = 封面 + 歌名 + 歌手·专辑 + 时长 + 收藏 + 播放。
/// 点播放时**当场解析地址**（在线地址会过期，不能缓存），再流式播放。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_providers.dart';
import '../../core/source/host_search.dart';
import '../../core/source/source_models.dart';
import '../../core/source/source_host.dart';
import '../../core/source/source_store.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';
import '../library/playlists.dart';
import 'download_manager.dart';
import 'online_player.dart';
import 'source_widgets.dart';

/// 封面字节（按在线曲目 id 缓存）。网易云封面优先，拿不到再退回搜索结果里的地址。
final onlineCoverProvider = FutureProvider.family<Uint8List?, String>((
  ref,
  String id,
) async {
  final (String platform, String songId) = HostSearch.splitTrackId(id);
  if (platform != 'wy' || songId.isEmpty) return null;
  String? url = await HostSearch.instance.neteaseCoverUrl(songId);
  if (url == null || url.isEmpty) return null;
  // 网易云图床支持 ?param=长x宽，取小图省流量
  if (url.contains('music.126.net') && !url.contains('?')) {
    url = '$url?param=120y120';
  }
  return HostSearch.instance.fetchBytes(url);
});

/// 一行在线曲目。
class OnlineTrackRow extends ConsumerStatefulWidget {
  /// 创建一行。
  const OnlineTrackRow({
    super.key,
    required this.track,
    this.index,
    this.playing = false,
    this.onPlay,
    this.quality,
  });

  /// 曲目。
  final OnlineTrack track;

  /// 序号（可空）。
  final int? index;

  /// 是否正在播这首。
  final bool playing;

  /// 自定义播放回调（搜索页要显示解析进度）；不传则直接解析并播放。
  final VoidCallback? onPlay;

  /// 搜索页当前选中的音质；收藏列表未指定时使用曲目记忆的档位。
  final String? quality;

  @override
  ConsumerState<OnlineTrackRow> createState() => _OnlineTrackRowState();
}

class _OnlineTrackRowState extends ConsumerState<OnlineTrackRow> {
  bool _hovered = false;
  bool _busy = false;

  Future<void> _play() async {
    if (widget.onPlay != null) {
      widget.onPlay!();
      return;
    }
    setState(() => _busy = true);
    // 搜索 / 在线来源点播 = **追加到播放队列**（用户要求的语义）
    final OnlinePlayResult result = await playOnlineTracks(ref, <OnlineTrack>[
      widget.track,
    ], quality: widget.quality ?? widget.track.quality);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.played == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('播放失败：${result.failed.join('；')}'),
          duration: const Duration(seconds: 6),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// 「添加到播放队列」：同样是追加，但**不打断**当前播放（点行本身会追加并跳过去播）。
  Future<void> _enqueue() async {
    setState(() => _busy = true);
    final OnlinePlayResult result = await playOnlineTracks(
      ref,
      <OnlineTrack>[widget.track],
      append: true,
      quality: widget.quality ?? widget.track.quality,
      // 「添加到播放队列」= 只入队，不打断当前播放
      autoPlay: false,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.played > 0
              ? '已添加到播放队列：${widget.track.title}'
              : '添加失败：${result.failed.join('；')}',
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _toggleFavorite() async {
    final bool nowLiked = await ref
        .read(playlistsProvider.notifier)
        .toggleFavorite(widget.track.id);
    // 收藏时把曲目信息也记下来，这样「我的喜欢」里能重新解析地址再播
    if (nowLiked) {
      await ref.read(onlineLibraryProvider.notifier).remember(<OnlineTrack>[
        widget.track,
      ]);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowLiked ? '已加入我的喜欢' : '已从我的喜欢移除'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _download() async {
    final SourceHostState host =
        ref.read(sourceHostProvider).value ?? const SourceHostState();
    final List<String> qualities = host.qualitysFor(widget.track.platform);
    final String? quality = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const ListTile(title: Text('选择下载音质')),
            for (final String q
                in qualities.isEmpty
                    ? <String>[widget.quality ?? widget.track.quality]
                    : qualities)
              ListTile(
                leading: const Icon(Icons.high_quality_outlined),
                title: Text(qualityLabel(q)),
                subtitle: Text(q),
                onTap: () => Navigator.of(context).pop(q),
              ),
          ],
        ),
      ),
    );
    if (quality == null || !mounted) return;
    // 下载任务由应用级 provider 持有，离开搜索页不会中断。
    unawaited(
      ref
          .read(downloadManagerProvider.notifier)
          .start(widget.track, quality: quality),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已开始下载，任务可在「下载管理」中查看'),
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final bool compact = MediaQuery.sizeOf(context).width < 600;
    final OnlineTrack track = widget.track;
    final bool liked = ref.watch(isFavoriteProvider(track.id));
    final Uint8List? cover = ref.watch(onlineCoverProvider(track.id)).value;
    // 正在播这首就高亮（和曲库列表一致的观感）
    final bool playing =
        widget.playing ||
        ref.watch(
              playerControllerProvider.select(
                (PlayerUiState s) => s.currentTrack?.id,
              ),
            ) ==
            track.id;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _busy ? null : _play,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            color: playing
                ? accent.primary.withValues(alpha: 0.16)
                : (_hovered
                      ? Colors.white.withValues(alpha: 0.07)
                      : Colors.white.withValues(alpha: 0.025)),
            border: playing
                ? Border.all(color: accent.primary.withValues(alpha: 0.45))
                : Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: <Widget>[
              if (widget.index != null)
                SizedBox(
                  width: 24,
                  child: Text(
                    '${widget.index}',
                    style: const TextStyle(
                      color: Color(0x8CFFFFFF),
                      fontSize: 11.5,
                    ),
                  ),
                ),
              SourceCover(bytes: cover, fallbackUrl: track.coverUrl, size: 46),
              const SizedBox(width: 10),
              Expanded(
                flex: compact ? 1 : 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      track.title.isEmpty ? '（未知曲名）' : track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      <String>[
                        if (track.artist.isNotEmpty) track.artist,
                        if (track.album.isNotEmpty) track.album,
                        if ((widget.quality ?? '').isNotEmpty)
                          qualityLabel(widget.quality!),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0x99FFFFFF),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatDuration(track.duration),
                style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 11),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: liked ? '取消喜欢' : '加入我的喜欢',
                onPressed: _toggleFavorite,
                icon: Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: 17,
                  color: liked
                      ? AppColors.neonMagenta
                      : const Color(0x99FFFFFF),
                ),
              ),
              if (!compact) ...<Widget>[
                IconButton(
                  tooltip: '添加到播放队列',
                  onPressed: _busy ? null : _enqueue,
                  icon: const Icon(
                    Icons.playlist_add_rounded,
                    size: 18,
                    color: Color(0x99FFFFFF),
                  ),
                ),
                IconButton(
                  tooltip: '下载到本地',
                  onPressed: _busy ? null : _download,
                  icon: const Icon(
                    Icons.download_rounded,
                    size: 18,
                    color: Color(0x99FFFFFF),
                  ),
                ),
              ],
              const SizedBox(width: 2),
              if (_busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.primary.withValues(alpha: 0.18),
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 18,
                    color: accent.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一串在线曲目（按 id 过滤本地记着的在线曲目信息）。
class OnlineTrackList extends ConsumerWidget {
  /// 创建列表。
  const OnlineTrackList({
    super.key,
    required this.trackIds,
    this.title = '在线曲目',
    this.emptyHint = '',
  });

  /// 要显示的 id 集合（顺序按这个来）。
  final List<String> trackIds;

  /// 小节标题。
  final String title;

  /// 空时的提示（空字符串则不显示）。
  final String emptyHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<OnlineTrack> all =
        ref.watch(onlineLibraryProvider).value ?? const <OnlineTrack>[];
    final Map<String, OnlineTrack> byId = <String, OnlineTrack>{
      for (final OnlineTrack t in all) t.id: t,
    };
    final List<OnlineTrack> tracks = <OnlineTrack>[
      for (final String id in trackIds)
        if (byId[id] != null) byId[id]!,
    ];
    if (tracks.isEmpty) {
      return emptyHint.isEmpty
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                emptyHint,
                style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
              ),
            );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 10, bottom: 4),
          child: Text(
            '$title（${tracks.length}）',
            style: const TextStyle(
              color: Color(0x8CFFFFFF),
              fontSize: 10.5,
              letterSpacing: 1.6,
            ),
          ),
        ),
        for (int i = 0; i < tracks.length; i++)
          OnlineTrackRow(track: tracks[i], index: i + 1),
      ],
    );
  }
}

/// `mm:ss`。
String _formatDuration(Duration duration) {
  if (duration <= Duration.zero) return '--:--';
  final int minutes = duration.inMinutes;
  final String seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
