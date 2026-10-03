/// mobile_app_shell.dart
///
/// Android 端的移动应用壳层。
///
/// Windows 端保留桌面侧栏和窗口控制；Android 端采用更符合手机使用习惯的
/// 底部导航、单列内容、迷你播放条和全屏播放页。播放引擎、曲库、音源、歌单
/// 与歌词 provider 均复用桌面实现，平台差异只停留在 UI 组织层。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart';
import '../../core/audio/player_providers.dart';
import '../../core/metadata/cover_art.dart';
import '../library/library_views.dart';
import '../library/playlists.dart';
import '../library/playlist_transfer.dart';
import '../library/pool_playback.dart';
import '../player/appearance_settings.dart';
import '../player/cover_stage.dart';
import '../player/playback_settings.dart';
import '../player/version_info_view.dart';
import '../source/online_search_view.dart';
import '../source/source_manager_view.dart';
import 'android_karaoke_lyrics.dart';
import '../../shared/constants.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_background.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';

/// Android 主壳层。
class MobileAppShell extends ConsumerStatefulWidget {
  /// 创建 Android 主壳层。
  const MobileAppShell({super.key});

  @override
  ConsumerState<MobileAppShell> createState() => _MobileAppShellState();
}

class _MobileAppShellState extends ConsumerState<MobileAppShell> {
  int _tab = 0;
  bool _playerExpanded = false;
  String? _libraryPlaylistId;
  bool _focusDiscoverSearch = false;

  static const List<String> _titles = <String>['首页', '发现', '我的', '设置'];

  @override
  Widget build(BuildContext context) {
    ref.listen<PlayerUiState>(playerControllerProvider, (
      PlayerUiState? previous,
      PlayerUiState next,
    ) {
      if (!next.completed) return;
      final PendingPlaylist? current = ref.read(pendingPlaylistProvider);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (current != null) {
          unawaited(stepPendingPlaylist(ref, delta: 1, automatic: true));
        } else if (next.mode == PlaybackMode.shuffle) {
          unawaited(ref.read(playerControllerProvider.notifier).next());
        }
      });
    });
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: Stack(
        children: <Widget>[
          const Positioned.fill(child: RepaintBoundary(child: AppBackground())),
          SafeArea(
            bottom: false,
            child: Column(
              children: <Widget>[
                _MobileTopBar(title: _titles[_tab], onOpenPlayer: _openPlayer),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: KeyedSubtree(
                      key: ValueKey<int>(_tab),
                      child: _buildTab(),
                    ),
                  ),
                ),
                _MobileMiniPlayer(onTap: _openPlayer),
                _MobileBottomNavigation(
                  selectedIndex: _tab,
                  onSelected: (int index) => setState(() => _tab = index),
                ),
              ],
            ),
          ),
          if (_playerExpanded)
            Positioned.fill(
              child: _MobileNowPlaying(
                onClose: () => setState(() => _playerExpanded = false),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTab() {
    return switch (_tab) {
      0 => _MobileHomeView(
        onOpenLibrary: () => setState(() => _tab = 2),
        onOpenPlayer: _openPlayer,
        onOpenDiscover: () => setState(() {
          _tab = 1;
          _focusDiscoverSearch = true;
        }),
        onOpenSearch: () => setState(() {
          _tab = 1;
          _focusDiscoverSearch = true;
        }),
        onImportPlaylist: _importPlaylist,
        onOpenPlaylist: (String id) => setState(() {
          _libraryPlaylistId = id;
          _tab = 2;
        }),
      ),
      1 => _MobileDiscoverView(focusSearch: _focusDiscoverSearch),
      2 => _MobileLibraryView(initialPlaylistId: _libraryPlaylistId),
      _ => const _MobileSettingsView(),
    };
  }

  void _openPlayer() => setState(() => _playerExpanded = true);

  Future<void> _importPlaylist() async {
    try {
      final PlaylistTransferResult? result = await importPlaylist(context, ref);
      if (!mounted || result == null) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导入「${result.playlistName}」')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$error')));
    }
  }
}

class _MobileTopBar extends StatelessWidget {
  const _MobileTopBar({required this.title, required this.onOpenPlayer});

  final String title;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Image.asset(
              AppConstants.logoAsset,
              width: 28,
              height: 28,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[accent.secondary, accent.primary],
                  ),
                ),
                child: const SizedBox(width: 28, height: 28),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          IconButton(
            tooltip: '打开正在播放',
            onPressed: onOpenPlayer,
            icon: const VinylRecord(size: 34, labelRatio: 0.5),
          ),
        ],
      ),
    );
  }
}

class _MobileHomeView extends ConsumerWidget {
  const _MobileHomeView({
    required this.onOpenLibrary,
    required this.onOpenPlayer,
    required this.onOpenDiscover,
    required this.onOpenPlaylist,
    required this.onOpenSearch,
    required this.onImportPlaylist,
  });

  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenPlayer;
  final VoidCallback onOpenDiscover;
  final ValueChanged<String> onOpenPlaylist;
  final VoidCallback onOpenSearch;
  final VoidCallback onImportPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final Track? track = state.currentTrack;
    final AppAccent accent = AppAccent.of(context);
    final List<Playlist> playlists =
        ref.watch(playlistsProvider).value ?? const <Playlist>[];
    final List<Playlist> customPlaylists = playlists
        .where((Playlist playlist) => !playlist.isFavorites)
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: <Widget>[
        if (track == null)
          _EmptyMobileHome(accent: accent, onOpenDiscover: onOpenDiscover)
        else ...<Widget>[
          _MobileWelcomeCard(track: track, accent: accent, onTap: onOpenPlayer),
        ],
        const SizedBox(height: 18),
        const _MobileSectionTitle(title: '快捷入口'),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: _QuickAction(
                icon: Icons.favorite_rounded,
                title: '我喜欢',
                color: accent.secondary,
                onTap: onOpenLibrary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _QuickAction(
                icon: Icons.library_music_rounded,
                title: '本地曲库',
                color: accent.primary,
                onTap: onOpenLibrary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: _QuickAction(
                icon: Icons.search_rounded,
                title: '快捷搜索',
                color: accent.primary,
                onTap: onOpenSearch,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _QuickAction(
                icon: Icons.file_upload_outlined,
                title: '导入歌单',
                color: accent.secondary,
                onTap: onImportPlaylist,
              ),
            ),
          ],
        ),
        if (customPlaylists.isNotEmpty) ...<Widget>[
          const SizedBox(height: 20),
          const _MobileSectionTitle(title: '我的歌单'),
          const SizedBox(height: 10),
          for (final Playlist playlist in customPlaylists)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _HomePlaylistShortcut(
                playlist: playlist,
                onTap: () => onOpenPlaylist(playlist.id),
              ),
            ),
        ],
      ],
    );
  }
}

class _EmptyMobileHome extends StatelessWidget {
  const _EmptyMobileHome({required this.accent, required this.onOpenDiscover});

  final AppAccent accent;
  final VoidCallback onOpenDiscover;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      borderRadius: BorderRadius.circular(24),
      padding: const EdgeInsets.fromLTRB(22, 34, 22, 34),
      child: Column(
        children: <Widget>[
          Icon(Icons.headphones_rounded, size: 62, color: accent.primary),
          const SizedBox(height: 16),
          const Text(
            '准备好开始听歌了吗？',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            '前往“发现”搜索歌曲，或在“我的”中查看本地曲库。',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textTertiary, height: 1.5),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onOpenDiscover,
            icon: const Icon(Icons.explore_rounded),
            label: const Text('去发现歌曲'),
          ),
        ],
      ),
    );
  }
}

class _MobileWelcomeCard extends StatelessWidget {
  const _MobileWelcomeCard({
    required this.track,
    required this.accent,
    required this.onTap,
  });

  final Track track;
  final AppAccent accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: GlassPanel(
        borderRadius: BorderRadius.circular(24),
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '正在播放',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                const CoverStage(size: 92),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        track.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: accent.primary),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        track.album,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileDiscoverView extends StatelessWidget {
  const _MobileDiscoverView({this.focusSearch = false});

  final bool focusSearch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: OnlineSearchView(autoFocus: focusSearch),
    );
  }
}

class _MobileLibraryView extends ConsumerStatefulWidget {
  const _MobileLibraryView({this.initialPlaylistId});

  final String? initialPlaylistId;

  @override
  ConsumerState<_MobileLibraryView> createState() => _MobileLibraryViewState();
}

class _MobileLibraryViewState extends ConsumerState<_MobileLibraryView> {
  String? _selectedPlaylistId;
  bool _showAllSongs = false;

  @override
  void initState() {
    super.initState();
    _selectedPlaylistId = widget.initialPlaylistId;
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider).value ?? const <Playlist>[];
    if (_selectedPlaylistId != null) {
      final bool exists = playlists.any(
        (Playlist playlist) => playlist.id == _selectedPlaylistId,
      );
      if (!exists) _selectedPlaylistId = null;
    }
    if (_selectedPlaylistId != null) {
      return Column(
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _selectedPlaylistId = null),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('返回我的曲库'),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: PlaylistView(playlistId: _selectedPlaylistId!),
            ),
          ),
        ],
      );
    }
    if (_showAllSongs) {
      return Column(
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showAllSongs = false),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('返回我的歌单'),
            ),
          ),
          const Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: AllSongsView(),
            ),
          ),
        ],
      );
    }
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  '我的歌单',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: '新建歌单',
                onPressed: _createPlaylist,
                icon: const Icon(Icons.add_rounded),
              ),
              IconButton(
                tooltip: '导入歌单',
                onPressed: _importPlaylist,
                icon: const Icon(Icons.file_upload_outlined),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            children: <Widget>[
              for (final Playlist playlist in playlists)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: playlist.isFavorites
                      ? _LargePlaylistCard(
                          playlist: playlist,
                          onTap: () =>
                              setState(() => _selectedPlaylistId = playlist.id),
                        )
                      : _SwipeToDeletePlaylistCard(
                          playlist: playlist,
                          onTap: () =>
                              setState(() => _selectedPlaylistId = playlist.id),
                          onDelete: () => _deletePlaylist(playlist),
                        ),
                ),
              _LargePlaylistCard(
                playlist: const Playlist(id: 'all-songs', name: '所有歌曲'),
                icon: Icons.library_music_rounded,
                onTap: () => setState(() => _showAllSongs = true),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _createPlaylist() async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => const _CreatePlaylistDialog(),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;
    final Playlist playlist = await ref
        .read(playlistsProvider.notifier)
        .create(name);
    if (mounted) setState(() => _selectedPlaylistId = playlist.id);
  }

  Future<void> _importPlaylist() async {
    try {
      final PlaylistTransferResult? result = await importPlaylist(context, ref);
      if (!mounted || result == null) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导入「${result.playlistName}」')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$error')));
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除歌单？'),
        content: Text('将删除「${playlist.name}」，歌曲文件不会被删除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await ref.read(playlistsProvider.notifier).remove(playlist.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已删除歌单「${playlist.name}」')));
  }
}

class _CreatePlaylistDialog extends StatefulWidget {
  const _CreatePlaylistDialog();

  @override
  State<_CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<_CreatePlaylistDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建歌单'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        decoration: const InputDecoration(hintText: '歌单名称'),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('创建'),
        ),
      ],
    );
  }
}

class _LargePlaylistCard extends StatelessWidget {
  const _LargePlaylistCard({
    required this.playlist,
    required this.onTap,
    this.icon,
  });

  final Playlist playlist;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: GlassPanel(
        borderRadius: BorderRadius.circular(20),
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                color: accent.primary.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(16),
              ),
              child: SizedBox(
                width: 64,
                height: 64,
                child: Icon(
                  icon ??
                      (playlist.isFavorites
                          ? Icons.favorite_rounded
                          : Icons.queue_music_rounded),
                  color: accent.primary,
                  size: 30,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${playlist.length} 首歌曲 · 点击打开',
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: accent.primary),
          ],
        ),
      ),
    );
  }
}

/// 移动端歌单卡片的左滑删除容器。
///
/// 不引入第三方 Slidable，避免为一个低频手势增加额外依赖；左滑后保留
/// 垃圾桶按钮，用户需要再次点击确认，避免误触直接删除歌单。
class _SwipeToDeletePlaylistCard extends StatefulWidget {
  const _SwipeToDeletePlaylistCard({
    required this.playlist,
    required this.onTap,
    required this.onDelete,
  });

  final Playlist playlist;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_SwipeToDeletePlaylistCard> createState() =>
      _SwipeToDeletePlaylistCardState();
}

class _SwipeToDeletePlaylistCardState
    extends State<_SwipeToDeletePlaylistCard> {
  bool _revealed = false;

  void _handleDrag(DragUpdateDetails details) {
    if (details.delta.dx < -2 && !_revealed) {
      setState(() => _revealed = true);
    } else if (details.delta.dx > 2 && _revealed) {
      setState(() => _revealed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: _handleDrag,
      onHorizontalDragEnd: (_) {},
      onTap: _revealed ? () => setState(() => _revealed = false) : null,
      child: Row(
        children: <Widget>[
          Expanded(
            child: _LargePlaylistCard(
              playlist: widget.playlist,
              onTap: widget.onTap,
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: _revealed ? 68 : 0,
            margin: EdgeInsets.only(left: _revealed ? 8 : 0),
            child: _revealed
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: .88),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: IconButton(
                      tooltip: '删除歌单',
                      onPressed: widget.onDelete,
                      color: Colors.white,
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _HomePlaylistShortcut extends StatelessWidget {
  const _HomePlaylistShortcut({required this.playlist, required this.onTap});

  final Playlist playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: GlassPanel(
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(Icons.queue_music_rounded, color: accent.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${playlist.length} 首 · 点击打开歌单',
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileSettingsView extends StatefulWidget {
  const _MobileSettingsView();

  @override
  State<_MobileSettingsView> createState() => _MobileSettingsViewState();
}

class _MobileSettingsViewState extends State<_MobileSettingsView> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    if (_page == 1) {
      return _MobileSubPage(
        title: '外观设置',
        onBack: () => setState(() => _page = 0),
        child: const AppearanceSettingsView(),
      );
    }
    if (_page == 2) {
      return _MobileSubPage(
        title: '播放设置',
        onBack: () => setState(() => _page = 0),
        child: const PlaybackSettingsView(),
      );
    }
    if (_page == 3) {
      return _MobileSubPage(
        title: '音源管理',
        onBack: () => setState(() => _page = 0),
        child: const SourceManagerView(scrollable: true),
      );
    }
    if (_page == 4) {
      return _MobileSubPage(
        title: '版本说明',
        onBack: () => setState(() => _page = 0),
        child: const VersionInfoView(),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: <Widget>[
        const _MobileSectionTitle(title: '应用设置'),
        const SizedBox(height: 8),
        _SettingsTile(
          icon: Icons.palette_outlined,
          title: '外观设置',
          subtitle: '背景、玻璃、字体与歌词样式',
          onTap: () => setState(() => _page = 1),
        ),
        _SettingsTile(
          icon: Icons.tune_rounded,
          title: '播放设置',
          subtitle: '启动行为、音频输出与快捷键',
          onTap: () => setState(() => _page = 2),
        ),
        _SettingsTile(
          icon: Icons.extension_rounded,
          title: '音源管理',
          subtitle: '导入并启用在线音乐音源',
          onTap: () => setState(() => _page = 3),
        ),
        _SettingsTile(
          icon: Icons.info_outline_rounded,
          title: '版本说明',
          subtitle: '版本信息、更新和反馈入口',
          onTap: () => setState(() => _page = 4),
        ),
      ],
    );
  }
}

class _MobileSubPage extends StatelessWidget {
  const _MobileSubPage({
    required this.title,
    required this.onBack,
    required this.child,
  });

  final String title;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
            label: Text(title),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: child,
          ),
        ),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return GlassPanel(
      borderRadius: BorderRadius.circular(18),
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon, color: accent.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}

class _MobileMiniPlayer extends ConsumerWidget {
  const _MobileMiniPlayer({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final Track? track = state.currentTrack;
    if (track == null) return const SizedBox(height: 8);
    final PlayerController controller = ref.read(
      playerControllerProvider.notifier,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: GlassPanel(
        borderRadius: BorderRadius.circular(18),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          children: <Widget>[
            const _MiniCover(),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: onTap,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              onPressed: () => stepPendingPlaylist(ref, delta: -1),
              icon: const Icon(Icons.skip_previous_rounded),
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            ),
            IconButton.filled(
              onPressed: controller.togglePlayPause,
              icon: Icon(
                state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 38, height: 38),
            ),
            IconButton(
              onPressed: () => stepPendingPlaylist(ref, delta: 1),
              icon: const Icon(Icons.skip_next_rounded),
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniCover extends ConsumerWidget {
  const _MiniCover();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Uint8List? cover = ref.watch(currentCoverProvider).value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: cover == null
          ? const ColoredBox(
              color: Color(0x334C65B8),
              child: SizedBox(
                width: 42,
                height: 42,
                child: Icon(Icons.music_note_rounded, size: 20),
              ),
            )
          : Image.memory(cover, width: 42, height: 42, fit: BoxFit.cover),
    );
  }
}

class _MobileNowPlaying extends ConsumerWidget {
  const _MobileNowPlaying({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final Track? track = state.currentTrack;
    final PlayerController controller = ref.read(
      playerControllerProvider.notifier,
    );
    return Material(
      color: const Color(0xF20A0D1B),
      child: SafeArea(
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
                const Expanded(
                  child: Center(
                    child: Text(
                      '正在播放',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.more_horiz_rounded),
                ),
              ],
            ),
            Expanded(
              child: track == null
                  ? const Center(child: Text('队列是空的'))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(26, 18, 26, 28),
                      child: Column(
                        children: <Widget>[
                          const SizedBox(height: 12),
                          const CoverStage(size: 290),
                          const SizedBox(height: 24),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              track.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${track.artist} · ${track.album}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: accent.primary),
                            ),
                          ),
                          const SizedBox(height: 20),
                          const SizedBox(
                            height: 220,
                            child: AndroidKaraokeLyrics(),
                          ),
                          const SizedBox(height: 10),
                          _MobileProgress(),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: <Widget>[
                              IconButton(
                                tooltip: '加入喜欢',
                                onPressed: () => ref
                                    .read(playlistsProvider.notifier)
                                    .toggleFavorite(track.id),
                                icon: Icon(
                                  ref.watch(isFavoriteProvider(track.id))
                                      ? Icons.favorite_rounded
                                      : Icons.favorite_border_rounded,
                                ),
                                style: IconButton.styleFrom(
                                  side: BorderSide(
                                    color: accent.primary.withValues(
                                      alpha: 0.65,
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '上一首',
                                onPressed: () =>
                                    stepPendingPlaylist(ref, delta: -1),
                                icon: const Icon(Icons.skip_previous_rounded),
                                iconSize: 34,
                              ),
                              IconButton.filled(
                                onPressed: controller.togglePlayPause,
                                icon: Icon(
                                  state.playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                                iconSize: 34,
                                style: IconButton.styleFrom(
                                  fixedSize: const Size(68, 68),
                                ),
                              ),
                              IconButton(
                                tooltip: '下一首',
                                onPressed: () =>
                                    stepPendingPlaylist(ref, delta: 1),
                                icon: const Icon(Icons.skip_next_rounded),
                                iconSize: 34,
                              ),
                              IconButton(
                                tooltip: '播放列表',
                                onPressed: () => _showMobileQueue(
                                  context,
                                  ref,
                                  state,
                                  controller,
                                ),
                                icon: const Icon(Icons.queue_music_rounded),
                                style: IconButton.styleFrom(
                                  side: BorderSide(
                                    color: accent.primary.withValues(
                                      alpha: 0.65,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showMobileQueue(
  BuildContext context,
  WidgetRef ref,
  PlayerUiState state,
  PlayerController controller,
) async {
  final PendingPlaylist? pending = ref.read(pendingPlaylistProvider);
  final List<Track> tracks = pending?.tracks ?? state.queue;
  final int activeIndex = pending?.activeIndex ?? state.currentIndex;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .65,
        child: Column(
          children: <Widget>[
            ListTile(
              title: Text('播放列表（${tracks.length}）'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    tooltip: '播放顺序：${state.mode.label}',
                    onPressed: () => ref
                        .read(playerControllerProvider.notifier)
                        .cyclePlaybackMode(),
                    icon: Icon(_mobileModeIcon(state.mode)),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (BuildContext context, int index) {
                  final Track track = tracks[index];
                  return ListTile(
                    selected: index == activeIndex,
                    leading: Text('${index + 1}'),
                    title: Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () async {
                      if (pending != null) {
                        await playPendingPlaylistTrack(
                          ref,
                          pending.tracks,
                          index,
                        );
                      } else {
                        await controller.playAt(index);
                      }
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

IconData _mobileModeIcon(PlaybackMode mode) => switch (mode) {
  PlaybackMode.sequential => Icons.playlist_play_rounded,
  PlaybackMode.repeatAll => Icons.repeat_rounded,
  PlaybackMode.repeatOne => Icons.repeat_one_rounded,
  PlaybackMode.shuffle => Icons.shuffle_rounded,
};

class _MobileProgress extends ConsumerWidget {
  const _MobileProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final Duration position =
        ref.watch(playbackPositionProvider).value ?? Duration.zero;
    final double max = state.duration.inMilliseconds.toDouble();
    final double value = max <= 0
        ? 0
        : position.inMilliseconds.clamp(0, max).toDouble();
    final PlayerController controller = ref.read(
      playerControllerProvider.notifier,
    );
    return Column(
      children: <Widget>[
        Slider(
          value: value,
          min: 0,
          max: max > 0 ? max : 1,
          onChanged: max <= 0
              ? null
              : (double next) =>
                    controller.seek(Duration(milliseconds: next.round())),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              _format(position),
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
            ),
            Text(
              _format(state.duration),
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _format(Duration value) =>
      '${value.inMinutes.toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
}

class _MobileBottomNavigation extends StatelessWidget {
  const _MobileBottomNavigation({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelected,
      backgroundColor: const Color(0xD90D1120),
      indicatorColor: accent.primary.withValues(alpha: 0.20),
      destinations: const <NavigationDestination>[
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: '首页',
        ),
        NavigationDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore_rounded),
          label: '发现',
        ),
        NavigationDestination(
          icon: Icon(Icons.library_music_outlined),
          selectedIcon: Icon(Icons.library_music_rounded),
          label: '我的',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings_rounded),
          label: '设置',
        ),
      ],
    );
  }
}

class _MobileSectionTitle extends StatelessWidget {
  const _MobileSectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
  );
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.title,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: GlassPanel(
      borderRadius: BorderRadius.circular(18),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: <Widget>[
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );
}
