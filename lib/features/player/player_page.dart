/// player_page.dart
///
/// Flutter 桌面播放页：
///
/// ```
/// ┌──────────────────────────────────────────────────────────┐
/// │ Windows 标题栏（系统窗口按钮）                        │
/// ├───────────┬──────────────────────────────┬───────────────┤
/// │ 侧边栏     │ 播放器主区                    │ 播放队列       │
/// │ (玻璃)     │  封面 + 曲目信息 + 进度 + 控制 │ (玻璃，可收起) │
/// │           │  底部歌词条                   │               │
/// └───────────┴──────────────────────────────┴───────────────┘
///              背景由共享主题 provider 提供
/// ```
///
/// 队列不再是常驻的第三栏，而是**从右侧滑出的抽屉**，由控制栏的队列按钮切换。
/// 这样宽屏下主区更宽敞，窄窗口也不会被三栏挤扁。
///
/// 播放状态由 `PlayerEngine` 和 Riverpod providers 提供，曲库、音源和桌面
/// 系统集成通过独立模块接入。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/audio/player_engine.dart' show Track;
import '../../core/audio/player_providers.dart';
import '../../core/source/source_models.dart' show qualityLabel;
import '../../platforms/windows/desktop_window.dart';
import '../../shared/constants.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_background.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/theme/performance_tier.dart';
import '../../shared/widgets/widget_kit/blur_config_scope.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';
import '../library/library_views.dart';
import '../remote/webdav_view.dart';
import '../source/online_search_view.dart';
import '../source/source_manager_view.dart';
import '../source/download_manager_view.dart';
import '../library/playlists.dart';
import '../library/playlist_transfer.dart';
import '../library/pool_playback.dart';
import 'appearance_settings.dart';
import 'compact_player_settings.dart';
import 'cover_stage.dart';
import 'lyrics/lyrics_scene.dart';
import 'lyrics/lyrics_scene_registry.dart';
import 'lyrics/lyrics_view.dart';
import 'lyrics/lyrics_style.dart';
import 'player_layout_settings.dart';
import 'playback_settings.dart';
import 'version_info_view.dart';

/// 播放页。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  /// 紧凑播放器固定尺寸：新增歌词/桌面歌词快捷按钮后，260 高度会让
  /// 控制台底部溢出；284 保持紧凑比例，同时给底部控制和队列安全区留出空间。
  static const Size _compactWindowSize = Size(340, 284);

  /// 队列抽屉是否展开。
  bool _queueOpen = false;

  /// 紧凑播放器模式：只保留左上角播放控制区。
  bool _compactMode = false;
  bool _compactPinned = true;
  bool _compactTransitioning = false;
  Size _normalWindowSize = const Size(1280, 800);

  /// 右侧主区当前显示哪一页。
  ///
  /// 0.0.10 起设置不再是弹窗，而是与播放页并列的页面：
  /// 入口在左侧边栏「来源」下面，内容显示在右边，点左侧即可来回切。
  _MainView _view = _MainView.player;

  /// 当前显示的是哪个歌单（`_view == playlist` 时有效）。
  String _playlistId = '';

  @override
  void initState() {
    super.initState();
    // 调试用（仅 Debug）：`HOH_DEBUG_VIEW=allSongs` 之类直接打开某个页面，
    // 方便脚本截图，不用手点。
    if (!kReleaseMode) {
      const String name = String.fromEnvironment(
        'HOH_DEBUG_VIEW',
        defaultValue: '',
      );
      final String env = name.isNotEmpty
          ? name
          : (Platform.environment['HOH_DEBUG_VIEW'] ?? '');
      if (env.isNotEmpty) {
        for (final _MainView v in _MainView.values) {
          if (v.name == env) _view = v;
        }
      }
    }
  }

  void _toggleQueue() => setState(() => _queueOpen = !_queueOpen);
  void _closeQueue() {
    if (_queueOpen) setState(() => _queueOpen = false);
  }

  void _showSettings() {
    if (_view != _MainView.glassSettings) {
      setState(() => _view = _MainView.glassSettings);
    }
  }

  void _showPlaybackSettings() {
    if (_view != _MainView.playbackSettings) {
      setState(() => _view = _MainView.playbackSettings);
    }
  }

  void _showVersionInfo() {
    if (_view != _MainView.versionInfo) {
      setState(() => _view = _MainView.versionInfo);
    }
  }

  void _showPlayer() {
    if (_view != _MainView.player) {
      setState(() => _view = _MainView.player);
    }
  }

  /// 从任意控制区回到主播放页，让歌词入口在紧凑模式下也有明确去向。
  void _openLyricsPage() {
    if (_view != _MainView.player) {
      setState(() => _view = _MainView.player);
    }
    if (_compactMode) {
      _toggleCompactMode();
    }
  }

  /// 切到某个曲库页面 / 歌单（0.0.27）。
  void _showView(_MainView view, {String playlistId = ''}) {
    if (_view == view && _playlistId == playlistId) return;
    setState(() {
      _view = view;
      _playlistId = playlistId;
    });
  }

  Future<void> _showLyricsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.all(18),
        backgroundColor: Colors.transparent,
        child: SizedBox(
          width: 560,
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: GlassPanel(
            borderRadius: BorderRadius.circular(20),
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.lyrics_rounded, size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      '歌词',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '关闭歌词',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Expanded(child: LyricsPanel()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleCompactMode() async {
    if (_compactTransitioning) return;
    _compactTransitioning = true;
    final bool entering = !_compactMode;
    if (!DesktopWindow.isSupported) {
      if (mounted) setState(() => _compactMode = entering);
      _compactTransitioning = false;
      return;
    }
    try {
      if (entering) {
        // 先记住 Flutter 当前逻辑尺寸并切换内容，不能让 getSize 的平台通道
        // 决定按钮有没有视觉反馈；它失败时仍可用布局尺寸还原主窗口。
        _normalWindowSize = MediaQuery.sizeOf(context);
        if (mounted) {
          setState(() {
            _compactMode = true;
            _compactPinned = true;
          });
        }
        try {
          _normalWindowSize = await windowManager.getSize();
        } catch (_) {
          // 使用上面从布局读取的尺寸继续切换。
        }
        // 窗口插件的平台通道按顺序改约束，避免并行调用相互覆盖，造成
        // setSize 被旧的最大/最小尺寸拒绝，紧凑 UI 已切换但窗口不缩小。
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setResizable(false);
        await windowManager.setMinimumSize(_compactWindowSize);
        await windowManager.setMaximumSize(_compactWindowSize);
        await windowManager.setSize(_compactWindowSize);
        await _alignCompactWindow();
      } else {
        // 退出时也先恢复主内容，避免等待窗口还原期间出现“点了没反应”。
        if (mounted) setState(() => _compactMode = false);
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setMaximumSize(const Size(10000, 10000));
        await windowManager.setMinimumSize(const Size(960, 640));
        await windowManager.setResizable(true);
        await windowManager.setSize(_normalWindowSize);
        await windowManager.center();
      }
    } catch (_) {
      if (mounted) setState(() => _compactMode = !entering);
      // 平台 API 失败时把窗口状态也回滚到当前 UI 对应模式。
      try {
        if (entering) {
          await windowManager.setAlwaysOnTop(false);
          await windowManager.setMaximumSize(const Size(10000, 10000));
          await windowManager.setMinimumSize(const Size(960, 640));
          await windowManager.setResizable(true);
          await windowManager.setSize(_normalWindowSize);
        } else {
          await windowManager.setResizable(false);
          await windowManager.setMinimumSize(_compactWindowSize);
          await windowManager.setMaximumSize(_compactWindowSize);
          await windowManager.setSize(_compactWindowSize);
        }
      } catch (_) {}
    } finally {
      _compactTransitioning = false;
    }
  }

  Future<void> _alignCompactWindow() async {
    final CompactCorner corner = ref.read(compactCornerProvider);
    final Alignment alignment = switch (corner) {
      CompactCorner.topLeft => Alignment.topLeft,
      CompactCorner.topRight => Alignment.topRight,
      CompactCorner.bottomLeft => Alignment.bottomLeft,
      CompactCorner.bottomRight => Alignment.bottomRight,
    };
    await windowManager.setAlignment(alignment);
  }

  /// 窄窗口下用底部菜单替代隐藏的侧栏导航。
  void _showCompactNavigation(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassPanel(
            borderRadius: BorderRadius.circular(18),
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: const Text('正在播放'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showPlayer();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('外观设置'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showSettings();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.library_music_outlined),
                  title: const Text('播放设置'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showPlaybackSettings();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('版本说明'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showVersionInfo();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleCompactPinned() async {
    final bool next = !_compactPinned;
    if (DesktopWindow.isSupported) {
      try {
        await windowManager.setAlwaysOnTop(next);
      } catch (_) {
        return;
      }
    }
    if (mounted) setState(() => _compactPinned = next);
  }

  @override
  Widget build(BuildContext context) {
    final BlurConfig config = BlurConfigScope.of(context);
    final bool settingsOpen = _view != _MainView.player;
    final PlayerControlLayout controlLayout =
        ref.watch(playerControlLayoutProvider).value ??
        PlayerControlLayout.sidebar;
    final bool bottomControls = controlLayout == PlayerControlLayout.bottom;

    ref.listen<PlayerUiState>(playerControllerProvider, (
      PlayerUiState? previous,
      PlayerUiState next,
    ) {
      if (!next.completed) return;
      final PendingPlaylist? current = ref.read(pendingPlaylistProvider);
      if (current == null) return;
      final int nextIndex = current.activeIndex + 1;
      if (nextIndex >= current.tracks.length) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) playPendingPlaylistTrack(ref, current.tracks, nextIndex);
      });
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: <Widget>[
          // ① 背景（可在设置页换：内置场景或自定义图片）
          // 背景与歌词/鼠标交互隔离：只有切换背景（或曲目带来的主题色）才重绘底图。
          const Positioned.fill(child: RepaintBoundary(child: AppBackground())),

          // ② 主界面 / 紧凑播放器。窗口尺寸由平台层调整，内容切换用轻量
          // 淡入、缩放和位移衔接，避免重型全屏动画造成额外 GPU 负担。
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            // 不让旧的整页 UI 与新紧凑 UI 同时绘制，避免窗口切换时双倍
            // 玻璃/背景合成导致卡顿；新内容仍保留完整的淡入缩放动画。
            reverseDuration: Duration.zero,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder:
                (Widget? currentChild, List<Widget> previousChildren) => Stack(
                  fit: StackFit.expand,
                  children: <Widget>[...previousChildren, ?currentChild],
                ),
            transitionBuilder: (Widget child, Animation<double> animation) {
              final Animation<double> curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              );
              return RepaintBoundary(
                child: FadeTransition(
                  opacity: curved,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.975, end: 1).animate(curved),
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.018),
                        end: Offset.zero,
                      ).animate(curved),
                      child: child,
                    ),
                  ),
                ),
              );
            },
            child: _compactMode
                ? _CompactPlayer(
                    key: const ValueKey<String>('compact-player'),
                    queueOpen: _queueOpen,
                    pinned: _compactPinned,
                    onToggleQueue: _toggleQueue,
                    onTogglePinned: _toggleCompactPinned,
                    onExit: _toggleCompactMode,
                    onOpenPlayer: _openLyricsPage,
                  )
                : Column(
                    key: const ValueKey<String>('full-player'),
                    children: <Widget>[
                      _TitleBar(
                        settingsOpen: settingsOpen,
                        onToggleSettings: settingsOpen
                            ? _showPlayer
                            : _showSettings,
                        onShowNavigation: () => _showCompactNavigation(context),
                        compactMode: false,
                        onToggleCompact: _toggleCompactMode,
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          child: LayoutBuilder(
                            builder: (BuildContext context, BoxConstraints c) {
                              // 侧栏宽度分档（见 _sidebarWidthFor）；不足 600dp 时折叠到标题栏导航菜单。
                              final double viewportWidth = MediaQuery.sizeOf(
                                context,
                              ).width;
                              final bool showSidebar = viewportWidth >= 600;
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  if (showSidebar) ...<Widget>[
                                    SizedBox(
                                      width: _sidebarWidthFor(viewportWidth),
                                      child: _Sidebar(
                                        showConsole: !bottomControls,
                                        queueOpen: _queueOpen,
                                        onToggleQueue: _toggleQueue,
                                        view: _view,
                                        playlistId: _playlistId,
                                        onSelectSettings: _showSettings,
                                        onSelectPlaybackSettings:
                                            _showPlaybackSettings,
                                        onSelectVersionInfo: _showVersionInfo,
                                        onSelectPlayer: _showPlayer,
                                        onToggleCompact: _toggleCompactMode,
                                        onSelectView: _showView,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                  Expanded(
                                    child: AnimatedSwitcher(
                                      duration: const Duration(
                                        milliseconds: 360,
                                      ),
                                      // 旧页面立即退出树，避免快速连续点击时旧标题仍参与
                                      // 命中；新页面保留完整的淡入/横移动画。
                                      reverseDuration: Duration.zero,
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      layoutBuilder:
                                          (
                                            Widget? currentChild,
                                            List<Widget> previousChildren,
                                          ) => Stack(
                                            fit: StackFit.expand,
                                            children: <Widget>[
                                              ...previousChildren,
                                              ?currentChild,
                                            ],
                                          ),
                                      transitionBuilder:
                                          (
                                            Widget child,
                                            Animation<double> animation,
                                          ) {
                                            final Animation<double> curved =
                                                CurvedAnimation(
                                                  parent: animation,
                                                  curve: Curves.easeOutCubic,
                                                  reverseCurve:
                                                      Curves.easeInCubic,
                                                );
                                            return FadeTransition(
                                              opacity: curved,
                                              child: SlideTransition(
                                                position: Tween<Offset>(
                                                  begin: const Offset(0.025, 0),
                                                  end: Offset.zero,
                                                ).animate(curved),
                                                child: child,
                                              ),
                                            );
                                          },
                                      child: KeyedSubtree(
                                        key: ValueKey<String>(
                                          'main-view-${_view.name}',
                                        ),
                                        child: switch (_view) {
                                          _MainView.player => _PlayerPanel(
                                            onShowLyrics: _showLyricsDialog,
                                          ),
                                          _MainView.glassSettings =>
                                            const AppearanceSettingsView(),
                                          _MainView.playbackSettings =>
                                            const PlaybackSettingsView(),
                                          _MainView.versionInfo =>
                                            const VersionInfoView(),
                                          // 曲库页面（0.0.27）
                                          _MainView.allSongs =>
                                            const AllSongsView(),
                                          _MainView.albums =>
                                            const AlbumsView(),
                                          _MainView.artists =>
                                            const ArtistsView(),
                                          _MainView.favorites =>
                                            const FavoritesView(),
                                          _MainView.playlist => PlaylistView(
                                            playlistId: _playlistId,
                                          ),
                                          _MainView.webdav =>
                                            const WebDavView(),
                                          _MainView.onlineSearch =>
                                            const OnlineSearchView(),
                                          _MainView.sourceManager =>
                                            const SourceManagerView(),
                                          _MainView.downloads =>
                                            const DownloadManagerView(),
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 420),
                        curve: Curves.easeInOutCubic,
                        alignment: Alignment.bottomCenter,
                        clipBehavior: Clip.hardEdge,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          reverseDuration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder:
                              (Widget child, Animation<double> animation) =>
                                  FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0, 0.08),
                                        end: Offset.zero,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  ),
                          child: bottomControls
                              ? Padding(
                                  key: const ValueKey<String>(
                                    'bottom-control-layout',
                                  ),
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    0,
                                    12,
                                    12,
                                  ),
                                  child: _BottomControlBar(
                                    queueOpen: _queueOpen,
                                    onToggleQueue: _toggleQueue,
                                    onOpenPlayer: _showPlayer,
                                  ),
                                )
                              : const SizedBox.shrink(
                                  key: ValueKey<String>('no-bottom-controls'),
                                ),
                        ),
                      ),
                    ],
                  ),
          ),

          // ③ 队列抽屉（覆盖在主界面之上，从右侧滑出）
          _QueueDrawer(
            open: _queueOpen,
            // 队列打开时只遮住主区，左侧控制台仍可操作。
            leftInset: MediaQuery.sizeOf(context).width >= 600
                ? _sidebarWidthFor(MediaQuery.sizeOf(context).width) + 12
                : 0,
            // 底部布局和紧凑播放器都有固定控制区，队列只占用其上方空间，
            // 避免抽屉最后几首歌盖住播放、进度和音量按钮。
            bottomInset: _compactMode || bottomControls ? 124 : 0,
            blurSigma: config.blurSigma,
            blurEnabled: config.useBlur,
            showSweep: config.sweepEnabled && config.animationsEnabled,
            glowOpacity: config.glowStrength,
            tintOpacity: config.tintOpacity,
            onClose: _closeQueue,
          ),
        ],
      ),
    );
  }
}

class _CompactPlayer extends StatelessWidget {
  const _CompactPlayer({
    super.key,
    required this.queueOpen,
    required this.pinned,
    required this.onToggleQueue,
    required this.onTogglePinned,
    required this.onExit,
    required this.onOpenPlayer,
  });

  final bool queueOpen;
  final bool pinned;
  final VoidCallback onToggleQueue;
  final VoidCallback onTogglePinned;
  final VoidCallback onExit;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox.expand(
        child: GlassPanel(
          borderRadius: BorderRadius.circular(22),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DragToMoveArea(
                child: SizedBox(
                  height: 22,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      Tooltip(
                        message: pinned ? '取消置顶' : '置顶',
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 24,
                            height: 22,
                          ),
                          iconSize: 14,
                          onPressed: onTogglePinned,
                          icon: Icon(
                            pinned
                                ? Icons.push_pin_rounded
                                : Icons.push_pin_outlined,
                          ),
                        ),
                      ),
                      Tooltip(
                        message: '退出紧凑模式',
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 24,
                            height: 22,
                          ),
                          iconSize: 15,
                          onPressed: onExit,
                          icon: const Icon(Icons.open_in_full_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _Console(
                queueOpen: queueOpen,
                onToggleQueue: onToggleQueue,
                onOpenPlayer: onOpenPlayer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 侧栏宽度随窗口分档。
///
/// 历史：220（0.0.10）→ 320（0.0.21 控制台搬进来）→ 0.0.23 一度又收到 220，
/// 但控制台（黑胶 + 曲名 + 进度 + 走带按键 + 音量 + 队列）在 220 下明显挤，
/// 用户反馈「左侧的控制区有点窄了」，所以桌面宽度给到 **340**；
/// 窗口不够宽（<1000）时收到 [_Sidebar.minimumWidth] **260**，免得主区被挤没。
/// 再窄（<600）侧栏整体折叠到标题栏菜单，见 `PlayerPage.build`。
double _sidebarWidthFor(double viewportWidth) =>
    viewportWidth < 1000 ? _Sidebar.minimumWidth : 300;

/// 右侧主区显示的内容。
enum _MainView {
  /// 播放页（封面 / 曲目 / 进度 / 控制）。
  player,

  /// 外观设置页（背景 + 玻璃参数）。
  glassSettings,

  /// 播放设置页（音乐库扫描记录 + 启动行为）。
  playbackSettings,

  /// 版本说明和 GitHub 反馈入口。
  versionInfo,

  /// 曲库页面：所有歌曲 / 专辑 / 歌手 / 我的喜欢 / 某个歌单。
  allSongs,
  albums,
  artists,
  favorites,
  playlist,

  /// WebDAV（0.0.36）：配置 + 目录浏览 + 流式播放。
  webdav,

  /// 在线搜索（0.0.38）：宿主搜索多平台 → 音源解析地址 → 流式播放。
  onlineSearch,

  /// 音源管理（0.0.38）：导入 / 启用 / 删除 lx-music 格式的音源脚本。
  sourceManager,

  /// 在线歌曲下载任务与默认保存位置。
  downloads,
}

// ════════════════════════════════════════════════════════════════
//  标题栏
// ════════════════════════════════════════════════════════════════

/// HoH 自绘标题栏：窗口外框、圆角和按钮统一由 Flutter 控制。
class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.settingsOpen,
    required this.onToggleSettings,
    required this.onShowNavigation,
    required this.compactMode,
    required this.onToggleCompact,
  });

  final bool settingsOpen;
  final VoidCallback onToggleSettings;
  final VoidCallback onShowNavigation;
  final bool compactMode;
  final VoidCallback onToggleCompact;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return DragToMoveArea(
      child: Container(
        height: 40,
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: LinearGradient(
                  colors: <Color>[
                    accent.secondary,
                    accent.tertiary,
                    accent.primary,
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              AppConstants.appName,
              style: TextStyle(
                color: Color(0xD9FFFFFF),
                fontSize: 12,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Expanded(child: SizedBox.expand()),
            if (MediaQuery.sizeOf(context).width < 600) ...<Widget>[
              _TitleIconButton(
                tooltip: '导航',
                icon: Icons.menu_rounded,
                onTap: onShowNavigation,
              ),
              const SizedBox(width: 6),
            ],
            _GlassSettingsButton(active: settingsOpen, onTap: onToggleSettings),
            const SizedBox(width: 6),
            Tooltip(
              message: compactMode ? '退出紧凑模式' : '紧凑播放器',
              child: IconButton(
                iconSize: 17,
                onPressed: onToggleCompact,
                icon: Icon(
                  compactMode
                      ? Icons.open_in_full_rounded
                      : Icons.picture_in_picture_alt_rounded,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const _WindowButtons(),
          ],
        ),
      ),
    );
  }
}

class _TitleIconButton extends StatelessWidget {
  const _TitleIconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: IconButton(
      iconSize: 18,
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon),
    ),
  );
}

class _GlassSettingsButton extends StatefulWidget {
  const _GlassSettingsButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  State<_GlassSettingsButton> createState() => _GlassSettingsButtonState();
}

class _GlassSettingsButtonState extends State<_GlassSettingsButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool lit = widget.active || _hovered;
    return Tooltip(
      message: widget.active ? '返回播放页' : '外观设置',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.white.withValues(alpha: lit ? 0.14 : 0.06),
            ),
            child: Icon(
              Icons.tune_rounded,
              size: 14,
              color: lit ? Colors.white : const Color(0xB3FFFFFF),
            ),
          ),
        ),
      ),
    );
  }
}

/// 自绘窗口按钮，实际操作仍由 window_manager 执行。
class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> {
  int _hovered = -1;
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    _syncMaximized();
  }

  Future<void> _syncMaximized() async {
    if (!DesktopWindow.isSupported) return;
    try {
      final bool value = await windowManager.isMaximized();
      if (mounted) setState(() => _maximized = value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final List<IconData> icons = <IconData>[
      Icons.remove,
      _maximized ? Icons.fullscreen_exit : Icons.crop_square,
      Icons.close,
    ];
    const List<String> tooltips = <String>['最小化', '最大化 / 还原', '关闭'];
    return Row(
      children: List<Widget>.generate(icons.length, (int i) {
        final bool close = i == 2;
        final bool hovered = _hovered == i;
        return Tooltip(
          message: tooltips[i],
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = i),
            onExit: (_) => setState(() => _hovered = -1),
            child: GestureDetector(
              onTap: () => _onTap(i),
              child: Container(
                width: 44,
                height: 40,
                alignment: Alignment.center,
                color: hovered
                    ? (close
                          ? const Color(0xFFE81123)
                          : const Color(0x1FFFFFFF))
                    : Colors.transparent,
                child: Icon(
                  icons[i],
                  size: close ? 15 : 13,
                  color: hovered ? Colors.white : const Color(0xB3FFFFFF),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  Future<void> _onTap(int index) async {
    if (!DesktopWindow.isSupported) return;
    switch (index) {
      case 0:
        await windowManager.minimize();
      case 1:
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
        await _syncMaximized();
      case 2:
        await windowManager.close();
    }
  }
}

/// 侧边栏内容——对应设计稿的 `.sidebar`。
///
/// 0.0.10：设置不再是弹窗，而是页面入口；
/// 0.0.11 加「外观设置」，0.0.12 加「播放设置」（音乐库扫描记录 + 启动行为）；
/// 控制台默认位于侧边栏顶部；播放页布局切换为“底部控制”时，
/// 同一套控制逻辑会移到页面底部，右侧面板仍只负责歌曲信息与歌词。
///
/// 侧栏本身保持三段式：**控制台（可收起）/ 导航可滚动 / 设置入口固定底部**。
class _Sidebar extends ConsumerWidget {
  const _Sidebar({
    required this.showConsole,
    required this.queueOpen,
    required this.onToggleQueue,
    required this.view,
    required this.playlistId,
    required this.onSelectSettings,
    required this.onSelectPlaybackSettings,
    required this.onSelectVersionInfo,
    required this.onSelectPlayer,
    required this.onToggleCompact,
    required this.onSelectView,
  });

  /// 侧栏宽度见 [_sidebarWidthFor]（随窗口宽度分档）。
  /// 这里留一个常量给"最小宽度"用，别再往写死的 220 上收。
  static const double minimumWidth = 236;

  /// 是否把播放控制区放在侧栏顶部；底部布局会把同一套控制逻辑移到页面底部。
  final bool showConsole;

  /// 队列抽屉是否展开。
  final bool queueOpen;

  /// 切换队列抽屉。
  final VoidCallback onToggleQueue;

  /// 右侧主区当前显示哪一页。
  final _MainView view;

  /// 当前歌单（`view == playlist` 时有效）。
  final String playlistId;

  /// 打开外观设置页。
  final VoidCallback onSelectSettings;

  /// 打开播放设置页。
  final VoidCallback onSelectPlaybackSettings;

  /// 打开版本说明页。
  final VoidCallback onSelectVersionInfo;

  /// 切回播放页。
  final VoidCallback onSelectPlayer;

  /// 打开固定尺寸的紧凑播放器。
  final VoidCallback onToggleCompact;

  /// 切到某个曲库页面 / 歌单（0.0.27）。
  final void Function(_MainView view, {String playlistId}) onSelectView;

  /// 「音乐库」这一组：显示名 / 图标 / 对应页面。
  ///
  /// 0.0.40：**「正在播放」从这里拿掉** —— 用户要求"正在播放的入口改成点控制台"，
  /// 而它原来的位置让给「在线搜索」（用户原话：把在线搜索放在正在播放的位置）。
  static const List<(String, IconData, _MainView)> _library =
      <(String, IconData, _MainView)>[
        ('在线搜索', Icons.travel_explore_rounded, _MainView.onlineSearch),
        ('所有歌曲', Icons.library_music_outlined, _MainView.allSongs),
        ('歌手', Icons.person_outline, _MainView.artists),
      ];

  /// 「来源」这一组：**所有来源相关的东西都在这里**。
  ///
  /// 0.0.55：按用户要求把「音源管理」放回来（音源脚本 / 刮削开关 / 音乐库 /
  /// 缓存 / WebDAV 连接都在它和 WebDAV 页里），播放设置里那份已删除。
  static const List<(String, IconData, _MainView)> _sources =
      <(String, IconData, _MainView)>[
        ('音源管理', Icons.extension_outlined, _MainView.sourceManager),
        ('WebDAV', Icons.cloud_outlined, _MainView.webdav),
        ('下载管理', Icons.download_outlined, _MainView.downloads),
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BlurConfig config = BlurConfigScope.of(context);
    final AppAccent accent = AppAccent.of(context);

    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      blurSigma: config.blurSigma,
      blurEnabled: config.useBlur,
      showSweepAt: config.sweepEnabled && config.animationsEnabled,
      glowOpacity: config.glowStrength,
      glowColor: config.glowColor,
      tintOpacity: config.tintOpacity,
      // 三块面板的高光相位错开，对应设计稿的 .p1/.p2/.p3
      initialSweepPhase: 0.25,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      // 不再整栏一起滚。控制台按播放页布局可收起、设置入口固定在底部，
      // 只有中间那串导航会在窗口太矮时滚动——否则控制台一进来就把
      // 「外观设置 / 播放设置」挤出屏幕，用户根本点不到。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ── 控制台：黑胶 + 曲名 + 进度 + 控制按钮（可收起）──────────
          // 底部布局通过 AnimatedSize 将这一段平滑收起，导航不会瞬间跳位。
          AnimatedSize(
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.hardEdge,
            child: showConsole
                ? Column(
                    key: const ValueKey<String>('sidebar-control-layout'),
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _Console(
                        queueOpen: queueOpen,
                        onToggleQueue: onToggleQueue,
                        onOpenPlayer: onSelectPlayer,
                      ),
                      const SizedBox(height: 14),
                      const Divider(color: AppColors.divider, height: 1),
                    ],
                  )
                : const SizedBox(key: ValueKey<String>('no-sidebar-controls')),
          ),

          // ── 导航（可滚动）────────────────────────────────────────
          Expanded(
            // 底部渐隐：窗口不够高时导航会被截断，直接切断看着像画错了
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (Rect bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Colors.white, Colors.white, Color(0x00FFFFFF)],
                stops: <double>[0.0, 0.90, 1.0],
              ).createShader(bounds),
              child: SingleChildScrollView(
                // 切页回来也能记住导航的滚动位置
                key: const PageStorageKey<String>('sidebar-nav-scroll'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const _NavSection('音乐库'),
                    for (int i = 0; i < _library.length; i++)
                      _NavItem(
                        label: _library[i].$1,
                        icon: _library[i].$2,
                        active:
                            view == _library[i].$3 &&
                            (_library[i].$3 != _MainView.playlist ||
                                playlistId.isEmpty),
                        onTap: () => onSelectView(_library[i].$3),
                      ),
                    // ── 歌单：真的读用户歌单（0.0.27）─────────────────
                    _NavSection(
                      '歌单',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const PlaylistTransferButtons(),
                          IconButton(
                            tooltip: '新建歌单',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () async {
                              final String name =
                                  await _promptNewPlaylist(context) ?? '';
                              if (name.trim().isEmpty) return;
                              final Playlist created = await ref
                                  .read(playlistsProvider.notifier)
                                  .create(name);
                              onSelectView(
                                _MainView.playlist,
                                playlistId: created.id,
                              );
                            },
                            icon: const Icon(
                              Icons.add_rounded,
                              size: 15,
                              color: Color(0xB3FFFFFF),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final Playlist p
                        in ref.watch(playlistsProvider).value ??
                            const <Playlist>[])
                      _NavItem(
                        label: p.name,
                        icon: p.isFavorites
                            ? Icons.favorite_rounded
                            : Icons.queue_music_outlined,
                        // 歌单条目后面跟一个数量，比只有名字有用
                        trailing: Text(
                          '${p.length}',
                          style: const TextStyle(
                            color: Color(0x8CFFFFFF),
                            fontSize: 11,
                          ),
                        ),
                        active:
                            view == _MainView.playlist && playlistId == p.id,
                        onTap: () => onSelectView(
                          // 「我的喜欢」走专用页面（文案更贴切），其余走通用歌单页
                          p.isFavorites
                              ? _MainView.favorites
                              : _MainView.playlist,
                          playlistId: p.id,
                        ),
                      ),
                    const _NavSection('来源'),
                    for (int i = 0; i < _sources.length; i++)
                      _NavItem(
                        label: _sources[i].$1,
                        icon: _sources[i].$2,
                        active: view == _sources[i].$3,
                        onTap: () => onSelectView(_sources[i].$3),
                      ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
          ),

          // ── 设置入口（固定在最下面，与其它条目同一套排版）────────
          const Divider(color: AppColors.divider, height: 1),
          const SizedBox(height: 6),
          _NavItem(
            label: '外观设置',
            icon: Icons.tune_rounded,
            active: view == _MainView.glassSettings,
            onTap: onSelectSettings,
          ),
          _NavItem(
            label: '播放设置',
            icon: Icons.library_music_outlined,
            active: view == _MainView.playbackSettings,
            onTap: onSelectPlaybackSettings,
          ),
          _NavItem(
            label: '紧凑播放器',
            icon: Icons.picture_in_picture_alt_rounded,
            active: false,
            onTap: onToggleCompact,
          ),

          _NavItem(
            label: '版本说明',
            icon: Icons.info_outline_rounded,
            active: view == _MainView.versionInfo,
            onTap: onSelectVersionInfo,
          ),

          // 强调色目前取自背景，写在下面让人知道颜色是从哪来的
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                _AccentDot(color: accent.primary),
                const SizedBox(width: 4),
                _AccentDot(color: accent.tertiary),
                const SizedBox(width: 4),
                _AccentDot(color: accent.secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '主题色跟随${accent.source}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 输入新歌单名（侧边栏「歌单」组右上角的 + 用）。
Future<String?> _promptNewPlaylist(BuildContext context) {
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

/// 强调色示意小圆点。
class _AccentDot extends StatelessWidget {
  const _AccentDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: <BoxShadow>[
          BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 6),
        ],
      ),
    );
  }
}

/// 侧边栏顶部的**控制台**。
///
/// 0.0.21 把控制台从播放页底部搬到这里；0.0.22 按反馈**整体收小并重排**：
/// 循环 / 随机那个模式按钮挪到**曲名那一行的右边**，走带按键（上一首 /
/// 播放 / 下一首）单独居中一行，黑胶 76 → 60、各段间距一起收紧。
///
/// 可用宽度只有 296 逻辑像素（侧边栏 320 − 内边距）：
/// ```
///  ⬤ 60  曲名                    [↻]
///        艺术家 · 音质
///  ─────────●────────────────
///  1:23                  4:05
///      [◀]   [▶]   [▶]
///  [🔊 ───────────────] [播放队列]
/// ```
Future<void> _stepPendingPlaylist(
  BuildContext context,
  WidgetRef ref,
  PlayerController controller,
  int delta,
) async {
  final PendingPlaylist? pending = ref.read(pendingPlaylistProvider);
  if (pending == null) {
    if (delta < 0) {
      await controller.previous();
    } else {
      await controller.next();
    }
    return;
  }
  int target = pending.activeIndex + delta;
  if (target < 0 || target >= pending.tracks.length) {
    if (pending.tracks.isEmpty ||
        ref.read(playerControllerProvider).mode != PlaybackMode.repeatAll) {
      return;
    }
    target = delta < 0 ? pending.tracks.length - 1 : 0;
  }
  final PoolPlayResult result = await playPendingPlaylistTrack(
    ref,
    pending.tracks,
    target,
  );
  if (result.failed.isNotEmpty && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.failed.first)));
  }
}

class _Console extends ConsumerWidget {
  const _Console({
    required this.queueOpen,
    required this.onToggleQueue,
    required this.onOpenPlayer,
  });

  /// 队列抽屉是否展开。
  final bool queueOpen;

  /// 切换队列抽屉。
  final VoidCallback onToggleQueue;

  /// 打开「正在播放」页（点控制台 / 黑胶 / 歌名都算）。
  final VoidCallback onOpenPlayer;

  /// 黑胶直径（0.0.22 从 76 收到 60，「整体有点太大了」）。
  static const double _vinylSize = 60;

  /// 走带按键直径。
  static const double _transportSize = 40;

  /// 主播放键直径。
  static const double _playSize = 52;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final Track? track = state.currentTrack;
    final bool hasTrack = track != null;
    final Duration position =
        ref.watch(playbackPositionProvider).value ?? Duration.zero;
    // 时长为 0 时（未加载曲目）不显示进度
    final Duration total = state.duration > Duration.zero
        ? state.duration
        : (track?.duration ?? Duration.zero);
    final double progress = total.inMilliseconds > 0
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final PlayerController controller = ref.read(
      playerControllerProvider.notifier,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // ① 黑胶 + 曲名 / 艺术家 / 音质 + **播放模式按钮**（0.0.22 挪到这一行）
        //    0.0.40：整块可点 → 进「正在播放」页；歌名右边加了「我喜欢的」
        Row(
          children: <Widget>[
            // 黑胶 + 曲名区域：点一下进正在播放页（鼠标手型提示）
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onOpenPlayer,
                  child: Row(
                    children: <Widget>[
                      const VinylRecord(size: _vinylSize, labelRatio: 0.52),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    hasTrack ? track.title : '未在播放',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: hasTrack
                                          ? Colors.white
                                          : const Color(0x99FFFFFF),
                                      fontSize: 14.5,
                                      height: 1.18,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.2,
                                      shadows: <Shadow>[
                                        Shadow(
                                          color: accent.secondary.withValues(
                                            alpha: 0.45,
                                          ),
                                          blurRadius: 14,
                                        ),
                                        const Shadow(
                                          color: Color(0x99000000),
                                          blurRadius: 6,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (hasTrack) const SizedBox.shrink(),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              hasTrack ? track.artist : '先从「播放设置」添加音乐',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xD9FFFFFF),
                                fontSize: 11.5,
                                letterSpacing: 0.3,
                                shadows: <Shadow>[
                                  Shadow(
                                    color: Color(0x99000000),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                            ),
                            if (hasTrack) ...<Widget>[
                              const SizedBox(height: 2),
                              Text(
                                track.qualityLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: accent.primary.withValues(alpha: 0.92),
                                  fontSize: 10,
                                  letterSpacing: 0.3,
                                  shadows: const <Shadow>[
                                    Shadow(
                                      color: Color(0x99000000),
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _trackInfoLine(track),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0x99FFFFFF),
                                  fontSize: 9.5,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _LyricsActionButtons(onOpenLyrics: onOpenPlayer),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // 0.0.41：播放模式按钮挪到走带行（「下一首」右边），这里不再放第二个
          ],
        ),
        const SizedBox(height: 12),

        // ② 进度 + 时间
        _ProgressBar(
          progress: progress,
          position: position,
          total: total,
          enabled: hasTrack && total > Duration.zero,
          onSeek: (double ratio) {
            if (total > Duration.zero) {
              controller.seek(total * ratio);
            }
          },
        ),
        const SizedBox(height: 10),

        // ③ 走带按键：上一首 / 播放 · 暂停 / 下一首（居中）
        SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                // 0.0.41：喜欢放「上一首」左边，播放模式放「下一首」右边
                //（用户要求：这两个按钮都挪到上下首的两侧）
                if (hasTrack) _ConsoleFavoriteButton(trackId: track.id),
                const SizedBox(width: 6),
                _RoundButton(
                  icon: Icons.skip_previous_rounded,
                  diameter: _transportSize,
                  iconSize: 17,
                  enabled: hasTrack,
                  tooltip: '上一首',
                  onTap: () =>
                      _stepPendingPlaylist(context, ref, controller, -1),
                ),
                const SizedBox(width: 12),
                _PlayButton(
                  size: _playSize,
                  playing: state.playing,
                  buffering: state.buffering,
                  enabled: hasTrack,
                  onTap: controller.togglePlayPause,
                ),
                const SizedBox(width: 12),
                _RoundButton(
                  icon: Icons.skip_next_rounded,
                  diameter: _transportSize,
                  iconSize: 17,
                  enabled: hasTrack,
                  tooltip: '下一首',
                  onTap: () =>
                      _stepPendingPlaylist(context, ref, controller, 1),
                ),
                const SizedBox(width: 6),
                _RoundButton(
                  icon: _modeIcon(state.mode),
                  // 和喜欢按钮同尺寸（比上下首的 40 略小）
                  diameter: _sideButtonSize,
                  iconSize: 15,
                  // 顺序播放是"默认状态"，不算开启态
                  active: state.mode != PlaybackMode.sequential,
                  tooltip: '播放模式：${state.mode.label}（点击切换）',
                  onTap: controller.cyclePlaybackMode,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),

        // ④ 音量（占满整行）+ 队列
        Row(
          children: <Widget>[
            Expanded(
              child: _VolumeControl(
                volume: state.volume,
                onChanged: controller.setVolume,
              ),
            ),
            const SizedBox(width: 8),
            _QueueButton(active: queueOpen, onTap: onToggleQueue),
          ],
        ),
      ],
    );
  }
}

/// 页面底部控制区。
///
/// 与侧栏控制台共用同一套播放器状态、队列步进和进度逻辑；这里只改变
/// 信息密度与排布，不复制另一套播放后端。宽屏采用“曲目信息 / 走带 / 音量”
/// 三段式，窄屏自动变成两行，便于未来复用到移动端和 TV。
class _BottomControlBar extends ConsumerWidget {
  const _BottomControlBar({
    required this.queueOpen,
    required this.onToggleQueue,
    required this.onOpenPlayer,
  });

  final bool queueOpen;
  final VoidCallback onToggleQueue;
  final VoidCallback onOpenPlayer;

  static const double _vinylSize = 52;
  static const double _transportSize = 38;
  static const double _playSize = 50;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final Track? track = state.currentTrack;
    final bool hasTrack = track != null;
    final Duration position =
        ref.watch(playbackPositionProvider).value ?? Duration.zero;
    final Duration total = state.duration > Duration.zero
        ? state.duration
        : (track?.duration ?? Duration.zero);
    final double progress = total.inMilliseconds > 0
        ? (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final PlayerController controller = ref.read(
      playerControllerProvider.notifier,
    );

    Widget transport() => FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (hasTrack) _ConsoleFavoriteButton(trackId: track.id),
          const SizedBox(width: 6),
          _RoundButton(
            icon: Icons.skip_previous_rounded,
            diameter: _transportSize,
            iconSize: 17,
            enabled: hasTrack,
            tooltip: '上一首',
            onTap: () => _stepPendingPlaylist(context, ref, controller, -1),
          ),
          const SizedBox(width: 10),
          _PlayButton(
            size: _playSize,
            playing: state.playing,
            buffering: state.buffering,
            enabled: hasTrack,
            onTap: controller.togglePlayPause,
          ),
          const SizedBox(width: 10),
          _RoundButton(
            icon: Icons.skip_next_rounded,
            diameter: _transportSize,
            iconSize: 17,
            enabled: hasTrack,
            tooltip: '下一首',
            onTap: () => _stepPendingPlaylist(context, ref, controller, 1),
          ),
          const SizedBox(width: 6),
          _RoundButton(
            icon: _modeIcon(state.mode),
            diameter: _sideButtonSize,
            iconSize: 15,
            active: state.mode != PlaybackMode.sequential,
            tooltip: '播放模式：${state.mode.label}（点击切换）',
            onTap: controller.cyclePlaybackMode,
          ),
        ],
      ),
    );

    Widget summary() => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpenPlayer,
      child: Row(
        children: <Widget>[
          const VinylRecord(size: _vinylSize, labelRatio: 0.52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  hasTrack ? track.title : '未在播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: hasTrack ? Colors.white : const Color(0x99FFFFFF),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasTrack ? track.artist : '先添加音乐开始播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xCFFFFFFF),
                    fontSize: 11.5,
                  ),
                ),
                if (hasTrack) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    track.qualityLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: accent.primary, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    Widget progressBar() => _ProgressBar(
      progress: progress,
      position: position,
      total: total,
      enabled: hasTrack && total > Duration.zero,
      onSeek: (double ratio) {
        if (total > Duration.zero) controller.seek(total * ratio);
      },
    );

    return GlassPanel(
      borderRadius: BorderRadius.circular(18),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth < 720) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: summary()),
                    const SizedBox(width: 12),
                    _LyricsActionButtons(onOpenLyrics: onOpenPlayer),
                    const SizedBox(width: 8),
                    _QueueButton(active: queueOpen, onTap: onToggleQueue),
                  ],
                ),
                const SizedBox(height: 10),
                progressBar(),
                const SizedBox(height: 7),
                transport(),
                const SizedBox(height: 5),
                _VolumeControl(
                  volume: state.volume,
                  onChanged: controller.setVolume,
                ),
              ],
            );
          }

          return Row(
            children: <Widget>[
              SizedBox(width: 270, child: summary()),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    progressBar(),
                    const SizedBox(height: 7),
                    transport(),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              SizedBox(
                width: 190,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _VolumeControl(
                      volume: state.volume,
                      onChanged: controller.setVolume,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        _LyricsActionButtons(onOpenLyrics: onOpenPlayer),
                        const SizedBox(width: 8),
                        _QueueButton(active: queueOpen, onTap: onToggleQueue),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 播放控制区的歌词入口：用明确的歌词与桌面歌词图标降低首次使用门槛。
///
/// 两个按钮只操作共享 Flutter 状态：打开歌词页仍由当前控制区决定去向，
/// 桌面歌词开关由 [LyricsStyleController] 持久化；Windows 浮层宿主会自行
/// 响应这个偏好，其他平台可复用按钮和设置状态。
class _LyricsActionButtons extends ConsumerWidget {
  const _LyricsActionButtons({required this.onOpenLyrics});

  final VoidCallback onOpenLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LyricsStyle style =
        ref.watch(lyricsStyleProvider).value ?? const LyricsStyle();
    final LyricsStyleController controller = ref.read(
      lyricsStyleProvider.notifier,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RoundButton(
          icon: Icons.lyrics_rounded,
          diameter: _sideButtonSize,
          iconSize: 15,
          tooltip: '展开歌词页',
          onTap: onOpenLyrics,
        ),
        const SizedBox(width: 6),
        _RoundButton(
          icon: style.desktopOverlay
              ? Icons.desktop_windows_rounded
              : Icons.desktop_access_disabled_rounded,
          diameter: _sideButtonSize,
          iconSize: 15,
          active: style.desktopOverlay,
          tooltip: style.desktopOverlay ? '关闭桌面歌词' : '打开桌面歌词',
          onTap: () => controller.setDesktopOverlay(!style.desktopOverlay),
        ),
      ],
    );
  }
}

/// 播放模式 → 图标（只有一个模式按钮，图标随模式变化）。
/// 控制台的"两侧小按钮"直径（喜欢 / 播放模式）。
///
/// 用户要求（0.0.42）：这两个按钮**比上下首略小一点**，而且样式要一致
/// （都用 `_RoundButton` 的圆形玻璃，不再一个是 IconButton、一个是圆形按钮）。
const double _sideButtonSize = 34;

/// 控制台的「我喜欢的」按钮。
///
/// 0.0.42：改成和播放模式按钮**同款**（都用 `_RoundButton` 的圆形玻璃，
/// 直径 `_sideButtonSize` 比上下首的 40 略小），喜欢时点亮成强调色。
class _ConsoleFavoriteButton extends ConsumerWidget {
  const _ConsoleFavoriteButton({required this.trackId});

  /// 曲目 id（本地路径 / `平台:歌曲id` / `dav:路径` 都行）。
  final String trackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool liked = ref.watch(isFavoriteProvider(trackId));
    return _RoundButton(
      icon: liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      diameter: _sideButtonSize,
      iconSize: 15,
      active: liked,
      tooltip: liked ? '取消喜欢' : '加入我的喜欢',
      onTap: () => ref.read(playlistsProvider.notifier).toggleFavorite(trackId),
    );
  }
}

IconData _modeIcon(PlaybackMode mode) => switch (mode) {
  PlaybackMode.sequential => Icons.playlist_play_rounded,
  PlaybackMode.repeatAll => Icons.repeat_rounded,
  PlaybackMode.repeatOne => Icons.repeat_one_rounded,
  PlaybackMode.shuffle => Icons.shuffle_rounded,
};

/// 侧边栏分组标题。
class _NavSection extends StatelessWidget {
  const _NavSection(this.title, {this.trailing});

  final String title;

  /// 右侧附加内容（例如歌单组的「新建歌单」按钮）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 5),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0x99FFFFFF),
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.6,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 侧边栏条目。
///
/// [onTap] 为空时只是个静态条目（当前没有对应页面）；
/// 有回调时整条可点，用作页面切换（例如「玻璃效果设置」）。
class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    this.active = false,
    this.onTap,
    this.trailing,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;

  /// 右侧附加内容（歌单曲目数这类）。
  final Widget? trailing;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: widget.active
                ? LinearGradient(
                    colors: <Color>[
                      accent.secondary.withValues(alpha: 0.18),
                      accent.tertiary.withValues(alpha: 0.12),
                    ],
                  )
                : null,
            color: _hovered && !widget.active
                ? Colors.white.withValues(alpha: 0.06)
                : null,
            border: widget.active
                ? Border.all(color: Colors.white.withValues(alpha: 0.08))
                : null,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                widget.icon,
                size: 15,
                color: widget.active
                    ? accent.secondary
                    : const Color(0xBFFFFFFF),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: widget.active || _hovered
                        ? Colors.white
                        : const Color(0xBFFFFFFF),
                    fontWeight: widget.active
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  播放器主区
// ════════════════════════════════════════════════════════════════

/// 播放器主面板——对应设计稿的 `.player`。
///
/// 0.0.21：**进度条与控制按钮全部搬去左侧控制台**，这里只剩主内容，
/// 于是封面可以更大、歌词能占满整个面板高度：
///
/// ```
/// ┌────────────┬──────────────────────────────┐
/// │            │  曲名 / 艺术家 / 专辑 / 音质   │
/// │   封面      │                              │
/// │            │  歌词（滚动，当前行高亮）      │
/// └────────────┴──────────────────────────────┘
/// ```
class _PlayerPanel extends ConsumerWidget {
  const _PlayerPanel({required this.onShowLyrics});

  final VoidCallback onShowLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LyricsStyle style =
        ref.watch(lyricsStyleProvider).value ?? const LyricsStyle();
    final LyricsSceneDefinition? definition = lyricsSceneDefinitionFor(
      style.layout,
    );
    return definition?.builder(onShowLyrics: onShowLyrics) ??
        LyricsScene(mode: style.layout, onShowLyrics: onShowLyrics);
  }
}

String _trackInfoLine(Track track) {
  // 在线地址没有本地媒体文件，码率即使来自音源/URL 也不作为用户信息
  // 展示；在线只显示用户选择的音质档位。下载完成并重新进入本地曲库后，
  // 才显示文件解析器读取到的真实码率。
  if (track.isRemote) {
    final List<String> onlineParts = <String>[];
    if (track.source != null && track.source!.isNotEmpty) {
      onlineParts.add(track.source!);
    }
    // 音质已经由上方的 qualityLabel 单独显示，这一行仅保留来源，避免
    // 在线曲目重复显示音质，也不显示在线码率。
    return onlineParts.join(' · ');
  }

  final List<String> parts = <String>[track.format];
  if (track.bitrateKbps != null) {
    parts.add('${track.bitrateKbps} kbps');
  } else if (track.isRemote) {
    parts.add('码率未提供');
  }
  if (track.source != null && track.source!.isNotEmpty) {
    parts.add(track.source!);
  }
  if (track.genre != null && track.genre!.isNotEmpty) {
    parts.add(track.genre!);
  }
  if (track.quality != null && track.quality!.isNotEmpty) {
    parts.add(qualityLabel(track.quality!));
  }
  return parts.join(' · ');
}

/// 把时长格式化成 `m:ss`。
String _formatDuration(Duration d) {
  if (d <= Duration.zero) return '0:00';
  final int minutes = d.inMinutes;
  final int seconds = d.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// 进度条 + 时间。
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.progress,
    required this.position,
    required this.total,
    required this.enabled,
    required this.onSeek,
  });

  final double progress;
  final Duration position;
  final Duration total;
  final bool enabled;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _ProgressTrack(progress: progress, enabled: enabled, onSeek: onSeek),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              _formatDuration(position),
              style: const TextStyle(
                color: Color(0xC0FFFFFF),
                fontSize: 11,
                letterSpacing: 0.4,
              ),
            ),
            Text(
              _formatDuration(total),
              style: const TextStyle(
                color: Color(0xC0FFFFFF),
                fontSize: 11,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 进度轨道。悬停显示拖拽圆点，点击 / 拖动可跳转。
class _ProgressTrack extends StatefulWidget {
  const _ProgressTrack({
    required this.progress,
    required this.enabled,
    required this.onSeek,
  });

  final double progress;
  final bool enabled;
  final ValueChanged<double> onSeek;

  @override
  State<_ProgressTrack> createState() => _ProgressTrackState();
}

class _ProgressTrackState extends State<_ProgressTrack> {
  bool _hovered = false;
  bool _dragging = false;
  double? _dragProgress;

  /// 把本地 x 坐标换算成 0~1 的播放比例。
  void _seekTo(double dx, double width) {
    if (!widget.enabled || width <= 0) return;
    final double value = (dx / width).clamp(0.0, 1.0);
    setState(() {
      _dragProgress = value;
    });
    widget.onSeek(value);
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;

        final double targetProgress = _dragProgress ?? widget.progress;

        return MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTapDown: (TapDownDetails d) {
              _dragging = true;
              _seekTo(d.localPosition.dx, width);
            },
            onTapUp: (_) {
              _dragging = false;
              setState(() => _dragProgress = null);
            },
            onTapCancel: () {
              _dragging = false;
              setState(() => _dragProgress = null);
            },
            onHorizontalDragStart: (_) => _dragging = true,
            onHorizontalDragUpdate: (DragUpdateDetails d) =>
                _seekTo(d.localPosition.dx, width),
            onHorizontalDragEnd: (_) {
              _dragging = false;
              setState(() => _dragProgress = null);
            },
            child: SizedBox(
              // 0.0.22：点击/拖动热区从 14 收到 12，控制台整体更紧凑
              height: 12,
              child: Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Container(
                      height: 4,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                    ),
                    AnimatedPositioned(
                      duration: _dragging
                          ? Duration.zero
                          : const Duration(milliseconds: 150),
                      curve: Curves.easeOutCubic,
                      left: 0,
                      right: width * (1 - targetProgress),
                      top: 4,
                      height: 4,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: LinearGradient(
                            colors: <Color>[
                              accent.primary,
                              accent.tertiary,
                              accent.secondary,
                            ],
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: accent.primary.withValues(alpha: 0.42),
                              blurRadius: 7,
                            ),
                          ],
                        ),
                      ),
                    ),
                    AnimatedPositioned(
                      duration: _dragging
                          ? Duration.zero
                          : const Duration(milliseconds: 150),
                      curve: Curves.easeOutCubic,
                      left: (width - 16) * targetProgress,
                      top: 0,
                      width: 16,
                      height: 12,
                      child: Center(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 160),
                          opacity: _hovered || _dragging ? 1 : 0,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 140),
                            width: _hovered || _dragging ? 14 : 10,
                            height: _hovered || _dragging ? 14 : 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: accent.primary.withValues(alpha: 0.58),
                                  blurRadius: 9,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 圆形按钮。
class _RoundButton extends StatefulWidget {
  const _RoundButton({
    required this.icon,
    this.diameter = 44,
    this.iconSize = 16,
    this.enabled = true,
    this.active = false,
    this.tooltip,
    this.onTap,
  });

  final IconData icon;

  /// 直径。0.0.22 起可调 —— 侧边栏控制台里用 32（模式）/ 40（上下首）。
  final double diameter;

  /// 图标尺寸。
  final double iconSize;

  final bool enabled;

  /// 是否处于"已开启"状态（随机 / 循环这类开关型按钮）。
  final bool active;

  /// 悬停提示。
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final double size = widget.diameter;
    final double iconSize = widget.iconSize;
    final bool lit = widget.enabled && (_hovered || _pressed);
    final bool highlighted = widget.enabled && widget.active;

    final Widget button = MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: widget.enabled
            ? (_) => setState(() => _pressed = true)
            : null,
        onTapUp: widget.enabled
            ? (_) => setState(() => _pressed = false)
            : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedScale(
          scale: _pressed ? 0.9 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutBack,
          child: Opacity(
            opacity: widget.enabled ? 1.0 : 0.45,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: highlighted
                    ? accent.primary.withValues(alpha: 0.20)
                    : Colors.white.withValues(alpha: lit ? 0.14 : 0.08),
                border: Border.all(
                  color: highlighted
                      ? accent.primary.withValues(alpha: 0.75)
                      : Colors.white.withValues(alpha: 0.2),
                  width: highlighted ? 1.2 : 0.5,
                ),
                boxShadow: highlighted
                    ? AppColors.neonGlow(
                        accent.primary,
                        strength: 0.3,
                        radius: 12,
                      )
                    : null,
              ),
              child: Icon(
                widget.icon,
                size: iconSize,
                color: highlighted ? accent.primary : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );

    final String? tooltip = widget.tooltip;
    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }
}

/// 主播放按钮：更大、渐变填充、带霓虹光晕。图标随播放状态切换。
class _PlayButton extends StatefulWidget {
  const _PlayButton({
    required this.playing,
    required this.buffering,
    required this.enabled,
    required this.onTap,
    this.size = 60,
  });

  final bool playing;
  final bool buffering;
  final bool enabled;
  final VoidCallback onTap;

  /// 直径。0.0.22 起可调：侧边栏控制台里用 52（原来写死 60 偏大）。
  final double size;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: widget.enabled
            ? (_) => setState(() => _pressed = true)
            : null,
        onTapUp: widget.enabled
            ? (_) => setState(() => _pressed = false)
            : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedScale(
          scale: _pressed ? 0.9 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutBack,
          child: Opacity(
            opacity: widget.enabled ? 1.0 : 0.5,
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    accent.secondary,
                    accent.tertiary,
                    accent.primary,
                  ],
                  stops: const <double>[0.0, 0.6, 1.0],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3),
                  width: 0.5,
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: accent.secondary.withValues(alpha: 0.5),
                    blurRadius: widget.size * 0.5,
                  ),
                  BoxShadow(
                    color: const Color(0x73000000),
                    blurRadius: widget.size * 0.46,
                    offset: Offset(0, widget.size * 0.17),
                  ),
                ],
              ),
              child: widget.buffering
                  ? Padding(
                      padding: EdgeInsets.all(widget.size * 0.3),
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      widget.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: widget.size * 0.5,
                      color: Colors.white,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 音量控制（0.0.21 起放在控制台最后一行，滑块占满剩余宽度）。
class _VolumeControl extends StatelessWidget {
  const _VolumeControl({required this.volume, required this.onChanged});

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Icon(Icons.volume_up_rounded, size: 16, color: Color(0x99FFFFFF)),
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: 16,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: Colors.white.withValues(alpha: 0.7),
                inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(value: volume, onChanged: onChanged),
            ),
          ),
        ),
      ],
    );
  }
}

/// 队列开关按钮——点击展开 / 收起右侧播放队列抽屉。
class _QueueButton extends StatefulWidget {
  const _QueueButton({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  State<_QueueButton> createState() => _QueueButtonState();
}

class _QueueButtonState extends State<_QueueButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final bool lit = widget.active || _hovered;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: widget.active
                ? LinearGradient(
                    colors: <Color>[
                      accent.secondary.withValues(alpha: 0.25),
                      accent.tertiary.withValues(alpha: 0.20),
                    ],
                  )
                : null,
            color: widget.active
                ? null
                : Colors.white.withValues(alpha: lit ? 0.12 : 0.07),
            border: Border.all(
              color: Colors.white.withValues(
                alpha: widget.active ? 0.35 : 0.18,
              ),
            ),
            boxShadow: widget.active
                ? <BoxShadow>[
                    BoxShadow(
                      color: accent.secondary.withValues(alpha: 0.35),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                widget.active
                    ? Icons.queue_music_rounded
                    : Icons.queue_music_outlined,
                size: 14,
                color: widget.active ? accent.secondary : Colors.white,
              ),
              const SizedBox(width: 6),
              Text(
                widget.active ? '收起队列' : '播放队列',
                style: TextStyle(
                  color: widget.active ? Colors.white : Colors.white,
                  fontSize: 11.5,
                  fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  播放队列抽屉
// ════════════════════════════════════════════════════════════════

/// 播放队列抽屉。
///
/// 从右侧滑出覆盖在主区之上，对应设计稿原本常驻的第三栏。
class _QueueDrawer extends StatelessWidget {
  const _QueueDrawer({
    required this.open,
    required this.leftInset,
    required this.bottomInset,
    required this.blurSigma,
    required this.blurEnabled,
    required this.showSweep,
    required this.glowOpacity,
    required this.tintOpacity,
    required this.onClose,
  });

  final bool open;
  final double leftInset;
  final double bottomInset;
  final double blurSigma;
  final bool blurEnabled;
  final bool showSweep;
  final double glowOpacity;
  final double tintOpacity;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // 半透明遮罩：点击空白处关闭
        Positioned(
          left: leftInset,
          top: 0,
          right: 0,
          bottom: bottomInset,
          child: IgnorePointer(
            ignoring: !open,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: open ? 1 : 0,
              child: GestureDetector(
                onTap: onClose,
                child: Container(color: Colors.black.withValues(alpha: 0.28)),
              ),
            ),
          ),
        ),

        // 抽屉本体
        AnimatedPositioned(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          top: 0,
          bottom: bottomInset,
          right: open ? 0 : -_QueuePanel.width,
          width: _QueuePanel.width,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
            child: _QueuePanel(
              blurSigma: blurSigma,
              blurEnabled: blurEnabled,
              showSweep: showSweep,
              glowOpacity: glowOpacity,
              tintOpacity: tintOpacity,
              onClose: onClose,
            ),
          ),
        ),
      ],
    );
  }
}

/// 队列面板内容。订阅真实播放队列。
class _QueuePanel extends ConsumerWidget {
  const _QueuePanel({
    required this.blurSigma,
    required this.blurEnabled,
    required this.showSweep,
    required this.glowOpacity,
    required this.tintOpacity,
    required this.onClose,
  });

  /// 抽屉宽度。滑出时按此值计算偏移。
  static const double width = 320;

  final double blurSigma;
  final bool blurEnabled;
  final bool showSweep;
  final double glowOpacity;
  final double tintOpacity;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final PendingPlaylist? pending = ref.watch(pendingPlaylistProvider);
    final List<Track> tracks = pending?.tracks ?? state.queue;
    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      blurSigma: blurSigma,
      blurEnabled: blurEnabled,
      showSweepAt: showSweep,
      glowOpacity: glowOpacity,
      tintOpacity: tintOpacity,
      initialSweepPhase: 0.75,
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 12, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                const Text(
                  '播放队列',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${tracks.length} 首',
                  style: const TextStyle(
                    color: Color(0x73FFFFFF),
                    fontSize: 11,
                  ),
                ),
                const Spacer(),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onClose,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.close_rounded,
                        size: 16,
                        color: Color(0x99FFFFFF),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: tracks.isEmpty
                ? const _EmptyQueueHint()
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: tracks.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Track t = tracks[index];
                      return _QueueItem(
                        index: index + 1,
                        title: t.title,
                        artist: t.artist,
                        duration: _formatDuration(t.duration ?? Duration.zero),
                        // 待解析歌单是展示队列，底层播放器此时只载入当前
                        // 单曲，不能再用底层 currentIndex（通常为 0）判断。
                        active: pending != null
                            ? index == pending.activeIndex
                            : index == state.currentIndex,
                        onTap: () async {
                          if (pending != null) {
                            await playPendingPlaylistTrack(
                              ref,
                              pending.tracks,
                              index,
                            );
                          } else {
                            await ref
                                .read(playerControllerProvider.notifier)
                                .playAt(index);
                          }
                        },
                        onRemove: () => ref
                            .read(playerControllerProvider.notifier)
                            .removeQueueAt(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 队列为空时的提示。
class _EmptyQueueHint extends StatelessWidget {
  const _EmptyQueueHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.queue_music_rounded, size: 34, color: Color(0x4DFFFFFF)),
            SizedBox(height: 12),
            Text(
              '队列是空的',
              style: TextStyle(color: Color(0x99FFFFFF), fontSize: 12.5),
            ),
            SizedBox(height: 4),
            Text(
              '在左侧点「打开音乐」选择本地文件',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0x66FFFFFF), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

/// 队列单条。点击即播放该曲。
class _QueueItem extends StatefulWidget {
  const _QueueItem({
    required this.index,
    required this.title,
    required this.artist,
    required this.duration,
    required this.active,
    required this.onTap,
    required this.onRemove,
  });

  final int index;
  final String title;
  final String artist;
  final String duration;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  State<_QueueItem> createState() => _QueueItemState();
}

class _QueueItemState extends State<_QueueItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: widget.active
                ? const LinearGradient(
                    colors: <Color>[Color(0x26FF2E88), Color(0x147B2FF7)],
                  )
                : null,
            color: _hovered && !widget.active
                ? Colors.white.withValues(alpha: 0.06)
                : null,
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 20,
                child: widget.active
                    ? const Icon(
                        Icons.play_arrow_rounded,
                        size: 13,
                        color: Color(0xFFFF2E88),
                      )
                    : Text(
                        '${widget.index}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0x66FFFFFF),
                          fontSize: 11,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.active
                            ? Colors.white
                            : const Color(0xD9FFFFFF),
                        fontSize: 12,
                        fontWeight: widget.active
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0x80FFFFFF),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                widget.duration,
                style: const TextStyle(color: Color(0x66FFFFFF), fontSize: 10),
              ),
              IconButton(
                tooltip: '从播放队列移除',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                padding: EdgeInsets.zero,
                onPressed: widget.onRemove,
                icon: const Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: Color(0x99FFFFFF),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
