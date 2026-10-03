/// library_views.dart
///
/// 曲库页面：**所有歌曲 / 歌手 / 我的喜欢 / 歌单**。
///
/// 数据源是本地扫描曲目与显式配置的 WebDAV 曲库，不包含在线搜索历史/播放队列。
///
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart';
import '../../core/audio/player_providers.dart';
import '../../core/metadata/cover_art.dart';
import '../../core/source/host_search.dart';
import '../../core/source/source_host.dart';
import '../../core/source/source_models.dart';
import '../../core/source/source_store.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';
import 'library_pool.dart';
import 'library_store.dart';
import 'playlists.dart';
import 'pool_playback.dart';
import '../source/online_player.dart';

/// 曲库里的全部曲目（**页面唯一的数据接缝**）。
///
/// 指向本地 + WebDAV 曲庫；在线搜索历史和当前播放队列不属于此列表。
final libraryTracksProvider = Provider<List<Track>>((ref) {
  return ref.watch(libraryPoolProvider);
});

/// 歌单解析集：曲库内容 + 已被播放/收藏而持久化的在线曲目信息。
/// 在线歌曲只在明确加入歌单/收藏时出现在这些页面，不污染「所有歌曲」。
final playlistTracksProvider = Provider<List<Track>>((ref) {
  final List<Track> tracks = List<Track>.of(ref.watch(libraryTracksProvider));
  final online = ref.watch(onlineLibraryProvider).value ?? const [];
  final Map<String, int> indexById = <String, int>{
    for (int i = 0; i < tracks.length; i++) tracks[i].id: i,
  };
  for (final track in online) {
    final int? index = indexById[track.id];
    if (index == null) {
      indexById[track.id] = tracks.length;
      tracks.add(trackFromOnline(track));
      continue;
    }
    final Track existing = tracks[index];
    // 导入在线歌单时，某些旧索引只留下 id/时长；在线记录才有标题、歌手、
    // 专辑和平台信息。用完整元数据覆盖空字段，避免移动端歌单只显示“·”。
    if (existing.title.trim().isEmpty || existing.artist.trim().isEmpty) {
      tracks[index] = Track(
        id: existing.id,
        uri: existing.uri,
        title: existing.title.trim().isEmpty ? track.title : existing.title,
        artist: existing.artist.trim().isEmpty ? track.artist : existing.artist,
        album: existing.album.trim().isEmpty ? track.album : existing.album,
        duration:
            existing.duration ??
            (track.duration == Duration.zero ? null : track.duration),
        // 进入 onlineLibrary 的记录本身就是远程曲目；OnlineTrack 没有
        // 重复维护 isRemote 字段，统一由这里标记为远程。
        isRemote: true,
        source: existing.source ?? track.platformLabel,
        quality: existing.quality ?? track.quality,
      );
    }
  }
  return tracks;
});

/// 小标题样式（与外观设置页保持一致）。
const TextStyle _sectionLabel = TextStyle(
  color: Color(0x8CFFFFFF),
  fontSize: 11,
  fontWeight: FontWeight.w600,
  letterSpacing: 1.4,
);

/// 曲库页面的外壳：标题 + 提示 + 内容。
class _LibraryScaffold extends StatelessWidget {
  const _LibraryScaffold({
    required this.title,
    required this.hint,
    required this.child,
    this.trailing,
  });

  final String title;
  final String hint;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      initialSweepPhase: 0.75,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(title, style: _sectionLabel),
              const Spacer(),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 空状态。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.library_music_outlined,
            size: 34,
            color: const Color(0x66FFFFFF),
          ),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xB3FFFFFF),
              fontSize: 13,
              height: 1.6,
              shadows: <Shadow>[
                Shadow(color: Color(0x99000000), blurRadius: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  所有歌曲
// ════════════════════════════════════════════════════════════════

/// 曲目列表的正序 / 倒序（0.0.45，用户要求「所有歌曲右侧页加上正序和倒序」）。
///
/// 用 Riverpod `Notifier` 而不是页面内 `State`：切到别的页面再回来，
/// 排序选择还在（和搜索页保留状态一个道理）。
final trackSortDescProvider = NotifierProvider<TrackSortController, bool>(
  TrackSortController.new,
);

/// 排序控制器：`false` = 正序（默认），`true` = 倒序。
class TrackSortController extends Notifier<bool> {
  @override
  bool build() => false;

  /// 翻转。
  void toggle() => state = !state;
}

/// 「所有歌曲」：按音乐库池顺序列出全部曲目（可切正序 / 倒序）。
class AllSongsView extends ConsumerWidget {
  const AllSongsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Track> source = ref.watch(libraryTracksProvider);
    final bool desc = ref.watch(trackSortDescProvider);
    final List<Track> tracks = desc
        ? source.reversed.toList(growable: false)
        : source;
    if (source.isEmpty) {
      return const _LibraryScaffold(
        title: '所有歌曲',
        hint: '音乐库还是空的。去「播放设置 → 音乐库」添加文件夹或单曲。',
        child: _EmptyHint('还没有载入任何曲目'),
      );
    }
    return _LibraryScaffold(
      title: '所有歌曲',
      hint: '共 ${tracks.length} 首 · 点一行直接播放，点心形收藏到「我喜欢的音乐」',
      trailing: TextButton.icon(
        onPressed: () => ref.read(trackSortDescProvider.notifier).toggle(),
        icon: Icon(
          desc ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
          size: 15,
        ),
        label: Text(desc ? '倒序' : '正序'),
        style: TextButton.styleFrom(foregroundColor: Colors.white),
      ),
      child: _TrackList(tracks: tracks, allowRemoveFromLibrary: true),
    );
  }
}

/// 曲目列表（点击播放 + 收藏），被多个页面复用。
class _TrackList extends ConsumerWidget {
  const _TrackList({
    required this.tracks,
    this.showIndex = true,
    this.allowRemoveFromLibrary = false,
    this.removeFromPlaylistId,
    this.emptyHint = '这里还没有曲目',
  });

  final List<Track> tracks;
  final bool showIndex;
  final bool allowRemoveFromLibrary;
  final String? removeFromPlaylistId;
  final String emptyHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tracks.isEmpty) return _EmptyHint(emptyHint);
    final PlayerUiState state = ref.watch(playerControllerProvider);
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: tracks.length,
      itemBuilder: (BuildContext context, int index) {
        final Track track = tracks[index];
        return TrackRow(
          track: track,
          index: showIndex ? index + 1 : null,
          playing: state.currentTrack?.id == track.id,
          allowRemoveFromLibrary: allowRemoveFromLibrary,
          removeFromPlaylistId: removeFromPlaylistId,
          // 曲库页面（所有歌曲 / 专辑 / 歌手 / 歌单 / 我的喜欢）是
          // **替换队列**并播放这一份内容（用户要求的语义）。
          onTap: () async {
            try {
              final bool resolvingOnline = tracks.any(
                (Track item) => item.isRemote && item.uri.isEmpty,
              );
              if (resolvingOnline) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text('正在匹配歌单并准备完整播放队列…'),
                      duration: Duration(minutes: 2),
                    ),
                  );
              }
              final PoolPlayResult result = await playPoolTracks(
                ref,
                tracks,
                startIndex: index,
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              if (result.failed.isEmpty) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    result.played == 0
                        ? '播放失败：${result.failed.take(2).join('；')}'
                        : '部分歌曲无法播放：${result.failed.take(2).join('；')}',
                  ),
                  duration: const Duration(seconds: 5),
                ),
              );
            } catch (error) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('播放失败：$error')));
            }
          },
        );
      },
    );
  }
}

/// 一行曲目。
class TrackRow extends ConsumerStatefulWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.onTap,
    this.index,
    this.playing = false,
    this.allowRemoveFromLibrary = false,
    this.removeFromPlaylistId,
  });

  final Track track;
  final VoidCallback onTap;
  final int? index;
  final bool playing;
  final bool allowRemoveFromLibrary;
  final String? removeFromPlaylistId;

  @override
  ConsumerState<TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends ConsumerState<TrackRow> {
  bool _hovered = false;

  Future<void> _removeFromLibrary() async {
    await ref.read(hiddenLibraryTracksProvider.notifier).hide(widget.track.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已从所有歌曲移除，磁盘文件未删除'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => ref
              .read(hiddenLibraryTracksProvider.notifier)
              .restore(widget.track.id),
        ),
      ),
    );
  }

  Future<void> _removeFromPlaylist() async {
    final String? playlistId = widget.removeFromPlaylistId;
    if (playlistId == null || playlistId.isEmpty) return;
    await ref
        .read(playlistsProvider.notifier)
        .removeTrack(playlistId, widget.track.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已从当前列表移除，曲库文件未删除'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final bool compact = MediaQuery.sizeOf(context).width < 600;
    final bool liked = ref.watch(isFavoriteProvider(widget.track.id));
    final String title = widget.track.title.trim().isEmpty
        ? (widget.track.id.split(':').lastOrNull ?? '未知曲目')
        : widget.track.title;
    final String artist = widget.track.artist.trim().isEmpty
        ? '未知歌手'
        : widget.track.artist;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: widget.playing
                ? accent.primary.withValues(alpha: 0.16)
                : (_hovered ? Colors.white.withValues(alpha: 0.06) : null),
            border: widget.playing
                ? Border.all(color: accent.primary.withValues(alpha: 0.45))
                : null,
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 30,
                child: widget.playing
                    ? Icon(
                        Icons.equalizer_rounded,
                        size: 15,
                        color: accent.primary,
                      )
                    : Text(
                        compact && widget.index == null
                            ? ''
                            : (widget.index == null ? '·' : '${widget.index}'),
                        style: const TextStyle(
                          color: Color(0x8CFFFFFF),
                          fontSize: 11.5,
                        ),
                      ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.playing ? accent.primary : Colors.white,
                        fontSize: 13.5,
                        fontWeight: widget.playing
                            ? FontWeight.w600
                            : FontWeight.w400,
                        shadows: const <Shadow>[
                          Shadow(color: Color(0x99000000), blurRadius: 6),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.track.album.trim().isEmpty
                          ? artist
                          : '$artist · ${widget.track.album}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xB3FFFFFF),
                        fontSize: 11,
                        shadows: <Shadow>[
                          Shadow(color: Color(0x99000000), blurRadius: 6),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _format(widget.track.duration),
                style: const TextStyle(
                  color: Color(0xB3FFFFFF),
                  fontSize: 11.5,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: liked ? '取消收藏' : '收藏到我喜欢的音乐',
                onPressed: () => ref
                    .read(playlistsProvider.notifier)
                    .toggleFavorite(widget.track.id),
                icon: Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: 16,
                  color: liked
                      ? AppColors.neonMagenta
                      : const Color(0x99FFFFFF),
                ),
              ),
              // 手机窄屏优先保证歌名/歌手可见，把次要操作收起；桌面保留
              // 完整的加入队列/加入歌单按钮。
              if (!compact) ...<Widget>[
                _AddToQueueButton(tracks: <Track>[widget.track]),
                _AddToPlaylistButton(track: widget.track),
              ],
              if (widget.allowRemoveFromLibrary)
                IconButton(
                  tooltip: '从所有歌曲移除（不删除文件）',
                  onPressed: () => unawaited(_removeFromLibrary()),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: 17,
                    color: Color(0xB3FFFFFF),
                  ),
                )
              else if (widget.removeFromPlaylistId != null)
                IconButton(
                  tooltip: '从当前列表移除',
                  onPressed: () => unawaited(_removeFromPlaylist()),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: 17,
                    color: Color(0xB3FFFFFF),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _format(Duration? d) {
    if (d == null || d <= Duration.zero) return '--:--';
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }
}

/// 「添加到播放队列」按钮（0.0.40）。
///
/// 语义：**追加**到当前队列，不打断正在播的那首。
/// 传一批是为了让专辑 / 歌单页也能整份追加（现在每行只传自己那首）。
class _AddToQueueButton extends ConsumerWidget {
  const _AddToQueueButton({required this.tracks});

  /// 要追加的曲目。
  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: '添加到播放队列',
      onPressed: () async {
        // 纯"添加到播放队列"：只入队，不打断正在播的那首
        final PoolPlayResult result = await playPoolTracks(
          ref,
          tracks,
          append: true,
          autoPlay: false,
        );
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.played > 0
                  ? '已添加到播放队列（${result.played} 首）'
                  : '添加失败：${result.failed.join('；')}',
            ),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      icon: const Icon(
        Icons.playlist_add_rounded,
        size: 16,
        color: Color(0x99FFFFFF),
      ),
    );
  }
}

/// 「加到歌单」按钮：弹出歌单列表。
class _AddToPlaylistButton extends ConsumerWidget {
  const _AddToPlaylistButton({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: '加到歌单',
      onPressed: () => showDialog<void>(
        context: context,
        builder: (BuildContext context) => AddToPlaylistDialog(track: track),
      ),
      icon: const Icon(
        Icons.playlist_add_rounded,
        size: 17,
        color: Color(0x99FFFFFF),
      ),
    );
  }
}

/// 给任意曲目选择目标歌单；移动端播放列表和桌面曲库共用。
class AddToPlaylistDialog extends ConsumerWidget {
  /// 创建加歌单弹窗。
  const AddToPlaylistDialog({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<Playlist> playlists =
        ref.watch(playlistsProvider).value ?? const <Playlist>[];
    return AlertDialog(
      backgroundColor: AppColors.midnight,
      title: Text('把《${track.title}》加到…', style: const TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 320,
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final Playlist p in playlists)
              ListTile(
                dense: true,
                leading: Icon(
                  p.isFavorites ? Icons.favorite_rounded : Icons.queue_music,
                  size: 17,
                  color: p.isFavorites
                      ? AppColors.neonMagenta
                      : const Color(0xB3FFFFFF),
                ),
                title: Text(p.name, style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  '${p.length} 首',
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () {
                  ref.read(playlistsProvider.notifier).addTrack(p.id, track.id);
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已加入「${p.name}」'),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
              ),
            const Divider(),
            ListTile(
              dense: true,
              leading: const Icon(Icons.add_rounded, size: 17),
              title: const Text('新建歌单…', style: TextStyle(fontSize: 13)),
              onTap: () async {
                final String name = await _promptPlaylistName(context) ?? '';
                if (name.trim().isEmpty) return;
                final Playlist created = await ref
                    .read(playlistsProvider.notifier)
                    .create(name);
                await ref
                    .read(playlistsProvider.notifier)
                    .addTrack(created.id, track.id);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 输入歌单名。
Future<String?> _promptPlaylistName(BuildContext context) {
  final TextEditingController controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      backgroundColor: AppColors.midnight,
      title: const Text('新建歌单', style: TextStyle(fontSize: 14)),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '歌单名'),
        onSubmitted: (String value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('创建'),
        ),
      ],
    ),
  );
}

// ════════════════════════════════════════════════════════════════
//  专辑 / 歌手 —— 正方形卡片网格
// ════════════════════════════════════════════════════════════════

/// 卡片封面：专辑按「艺术家 + 专辑名」刮削，歌手按艺术家名刮削。
final _cardCoverProvider = FutureProvider.family<Uint8List?, String>((
  ref,
  String key,
) async {
  final List<String> parts = key.split('|');
  if (parts.length < 2) return null;
  Track? representative;
  if (parts.length >= 4) {
    for (final Track track in ref.read(libraryTracksProvider)) {
      if (track.id == parts[3]) {
        representative = track;
        break;
      }
    }
  }
  if (representative != null &&
      (ref.read(sourceScrapeProvider).value ?? false)) {
    try {
      // 先使用 iTunes 的专辑/歌手结果；自定义音源只作为多平台补充。
      final Uint8List? catalogCover = parts[0] == 'artist'
          ? await CoverArtService.instance.forArtist(parts[1])
          : await CoverArtService.instance.forAlbum(parts[2], parts[1]);
      if (catalogCover != null) return catalogCover;
      final List<OnlineTrack> matches = await HostSearch.instance
          .matchTrackCandidates(representative);
      for (final OnlineTrack match in matches) {
        final String? pic = await ref
            .read(sourceHostProvider.notifier)
            .fetchPic(match);
        if (pic != null) {
          final Uint8List? image = await CoverArtService.instance
              .downloadRemoteImage(pic);
          if (image != null) return image;
        }
      }
    } catch (_) {
      // 自定义音源不可用时继续走元数据封面兜底。
    }
  }
  if (parts[0] == 'album' && parts.length >= 3) {
    return CoverArtService.instance.forAlbum(parts[2], parts[1]);
  }
  if (parts[0] == 'artist') {
    return CoverArtService.instance.forArtist(parts[1]);
  }
  return null;
});

/// 正方形封面（没有封面时给一块渐变占位 + 首字母）。
class _SquareCover extends ConsumerWidget {
  const _SquareCover({required this.coverKey, required this.label});

  final String coverKey;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final Uint8List? bytes = ref.watch(_cardCoverProvider(coverKey)).value;
    final Widget placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[accent.secondary, accent.tertiary, accent.primary],
          stops: const <double>[0.0, 0.5, 1.0],
        ),
      ),
      child: Center(
        child: Text(
          label.isEmpty ? '?' : label.characters.first,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.72),
            fontSize: 30,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: bytes == null
          ? placeholder
          : Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                  placeholder,
            ),
    );
  }
}

/// 一张正方形卡片（封面 + 名字 + 数量）。
class _CoverCard extends StatelessWidget {
  const _CoverCard({
    required this.title,
    required this.subtitle,
    required this.coverKey,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String coverKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                    width: 0.8,
                  ),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x59000000),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: _SquareCover(coverKey: coverKey, label: title),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                shadows: <Shadow>[
                  Shadow(color: Color(0x99000000), blurRadius: 6),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xB3FFFFFF),
                fontSize: 11,
                shadows: <Shadow>[
                  Shadow(color: Color(0x99000000), blurRadius: 6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片网格 + 「点开某一组看曲目」的详情。
class _CardGridPage extends StatefulWidget {
  const _CardGridPage({
    required this.title,
    required this.hint,
    required this.groups,
    required this.coverKeyBuilder,
    this.emptyText = '还没有可以分组的曲目',
  });

  final String title;
  final String hint;

  /// 组名 → 曲目。
  final Map<String, List<Track>> groups;

  /// 组名 → 封面缓存 key。
  final String Function(String name, List<Track> tracks) coverKeyBuilder;
  final String emptyText;

  @override
  State<_CardGridPage> createState() => _CardGridPageState();
}

class _CardGridPageState extends State<_CardGridPage> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final String? open = _open;
    if (open != null && widget.groups.containsKey(open)) {
      return _LibraryScaffold(
        title: open,
        hint: '${widget.groups[open]!.length} 首 · 点一行直接播放',
        trailing: TextButton.icon(
          onPressed: () => setState(() => _open = null),
          icon: const Icon(Icons.arrow_back_rounded, size: 15),
          label: const Text('返回', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(foregroundColor: Colors.white),
        ),
        child: _TrackList(tracks: widget.groups[open]!, showIndex: false),
      );
    }

    if (widget.groups.isEmpty) {
      return _LibraryScaffold(
        title: widget.title,
        hint: widget.hint,
        child: _EmptyHint(widget.emptyText),
      );
    }

    final List<String> names = widget.groups.keys.toList()..sort();
    return _LibraryScaffold(
      title: widget.title,
      hint: '${widget.hint} · 共 ${names.length} 组，点封面看曲目',
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final int columns = (c.maxWidth / 178).floor().clamp(2, 8);
          return GridView.builder(
            padding: const EdgeInsets.only(bottom: 8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 14,
              mainAxisSpacing: 16,
              // 正方形封面 + 两行文字
              childAspectRatio: 0.74,
            ),
            itemCount: names.length,
            itemBuilder: (BuildContext context, int index) {
              final String name = names[index];
              final List<Track> tracks = widget.groups[name]!;
              return _CoverCard(
                title: name,
                subtitle: '${tracks.length} 首',
                coverKey: widget.coverKeyBuilder(name, tracks),
                onTap: () => setState(() => _open = name),
              );
            },
          );
        },
      ),
    );
  }
}

/// 按 [keyOf] 分组。
Map<String, List<Track>> _groupBy(
  List<Track> tracks,
  String Function(Track) keyOf,
) {
  final Map<String, List<Track>> groups = <String, List<Track>>{};
  for (final Track t in tracks) {
    (groups[keyOf(t)] ??= <Track>[]).add(t);
  }
  return groups;
}

/// **模糊分类**用的"第一个名字"（0.0.41 用户要求）。
///
/// 歌手 / 专辑字段经常是"多个人名"拼起来的：
/// `周杰伦、袁咏琳`、`A / B`、`A & B`、`A feat. B`、`A, B`、`A; B`。
/// 按整串分组会把同一批歌拆成一堆只差几个字的分类，
/// 所以分类时只取**第一个名字**（专辑同理）。
String primaryName(String raw) {
  final String text = raw.trim();
  if (text.isEmpty) return '';
  // 按常见分隔符切开，取第一段（顺序有讲究：先把 feat./ft. 之前的部分留下）
  final List<String> parts = text
      .split(
        RegExp(
          r'\s*(?:、|,|，|;|；|/|／|\||&|＆|\+|\s+feat\.?\s+|\s+ft\.?\s+|\s+with\s+)\s*',
          caseSensitive: false,
        ),
      )
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();
  return parts.isEmpty ? text : parts.first;
}

/// 「专辑」——正方形卡片，封面走刮削。
class AlbumsView extends ConsumerWidget {
  const AlbumsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Map<String, List<Track>> groups = _groupBy(
      ref.watch(libraryTracksProvider),
      // 模糊分类：专辑字段也常常是"多人 / 多版本"拼的，只按第一个名字分
      (Track t) => primaryName(t.album).isEmpty ? '未知专辑' : primaryName(t.album),
    );
    return _CardGridPage(
      title: '专辑',
      hint: '按专辑名分组',
      groups: groups,
      coverKeyBuilder: (String name, List<Track> tracks) =>
          'album|${tracks.first.artist}|$name|${tracks.first.id}',
      emptyText: '还没有可以分组的专辑',
    );
  }
}

/// 「歌手」——正方形卡片，封面取该歌手第一张专辑的图。
class ArtistsView extends ConsumerWidget {
  const ArtistsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Map<String, List<Track>> groups = _groupBy(
      ref.watch(libraryTracksProvider),
      // 模糊分类：`周杰伦、袁咏琳` 这种只按**第一个**人名归类（用户要求）
      (Track t) =>
          primaryName(t.artist).isEmpty ? '未知艺术家' : primaryName(t.artist),
    );
    return _CardGridPage(
      title: '歌手',
      hint: '按艺术家分组',
      groups: groups,
      coverKeyBuilder: (String name, List<Track> tracks) =>
          'artist|$name|${tracks.first.album}|${tracks.first.id}',
      emptyText: '还没有可以分组的歌手',
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  我的喜欢 / 歌单
// ════════════════════════════════════════════════════════════════

/// 「我的喜欢」。
class FavoritesView extends ConsumerWidget {
  const FavoritesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Playlist fav = ref.watch(favoritesProvider);
    final List<Track> all = ref.watch(playlistTracksProvider);
    final List<Track> tracks = _pick(all, fav.trackIds);
    return _LibraryScaffold(
      title: '我喜欢的音乐',
      hint: fav.length == 0
          ? '还没有收藏。在「所有歌曲」或「在线搜索」里点每行右边的心形就能收藏。'
          : '共 ${fav.length} 首 · 按收藏顺序播放',
      child: _TrackList(
        tracks: tracks,
        showIndex: false,
        removeFromPlaylistId: favoritesId,
        emptyHint: '还没有收藏的曲目',
      ),
    );
  }

  /// 按歌单里的 id 顺序取出曲目（列表里找不到的跳过）。
  static List<Track> _pick(List<Track> all, List<String> ids) {
    final Map<String, Track> byId = <String, Track>{
      for (final Track t in all) t.id: t,
    };
    return <Track>[
      for (final String id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }
}

/// 某个普通歌单。
class PlaylistView extends ConsumerWidget {
  const PlaylistView({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Playlist? playlist = ref
        .watch(playlistsProvider)
        .value
        ?.firstWhere(
          (Playlist p) => p.id == playlistId,
          orElse: () => const Playlist(id: '', name: '歌单'),
        );
    final List<Track> all = ref.watch(playlistTracksProvider);
    final List<Track> tracks = FavoritesView._pick(
      all,
      playlist?.trackIds ?? const <String>[],
    );
    return _LibraryScaffold(
      title: playlist?.name ?? '歌单',
      hint: tracks.isEmpty
          ? '这个歌单还是空的。在「所有歌曲」里点「加到歌单」把歌放进来。'
          : '共 ${tracks.length} 首 · 按加入顺序播放',
      trailing: playlist == null || playlist.id.isEmpty
          ? null
          : IconButton(
              tooltip: '删除歌单',
              onPressed: () =>
                  ref.read(playlistsProvider.notifier).remove(playlist.id),
              icon: const Icon(
                Icons.delete_outline_rounded,
                size: 18,
                color: Color(0x99FFFFFF),
              ),
            ),
      child: _TrackList(
        tracks: tracks,
        showIndex: false,
        removeFromPlaylistId: playlist?.id,
        emptyHint: '这个歌单还是空的',
      ),
    );
  }
}
