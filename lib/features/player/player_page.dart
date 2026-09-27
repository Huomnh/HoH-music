/// player_page.dart
///
/// Flutter 桌面播放页：
///
/// ```
/// ┌──────────────────────────────────────────────────────────┐
/// │ 标题栏（应用图标 + 名称 + 窗口按钮）                        │
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
import 'appearance_settings.dart';
import 'compact_player_settings.dart';
import 'cover_stage.dart';
import 'lyrics/lyrics_scene.dart';
import 'lyrics/lyrics_scene_registry.dart';
import 'lyrics/lyrics_view.dart';
import 'lyrics/lyrics_style.dart';
import 'playback_settings.dart';

/// 播放页。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  /// 固定窗口尺寸：与左侧控制台的实际内容高度匹配，不再随歌词或曲名变化。
  static const Size _compactWindowSize = Size(340, 260);

  /// 队列抽屉是否展开。
  bool _queueOpen = false;

  /// 紧凑播放器模式：只保留左上角播放控制区。
  bool _compactMode = false;
  bool _compactPinned = true;
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

  void _showPlayer() {
    if (_view != _MainView.player) {
      setState(() => _view = _MainView.player);
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
    if (!DesktopWindow.isSupported) {
      setState(() => _compactMode = !_compactMode);
      return;
    }
    try {
      if (!_compactMode) {
        _normalWindowSize = await windowManager.getSize();
        _compactPinned = true;
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setMinimumSize(_compactWindowSize);
        await windowManager.setMaximumSize(_compactWindowSize);
        await windowManager.setResizable(false);
        await windowManager.setSize(_compactWindowSize);
        await _alignCompactWindow();
        if (mounted) setState(() => _compactMode = true);
      } else {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setMinimumSize(const Size(960, 640));
        await windowManager.setMaximumSize(const Size(10000, 10000));
        await windowManager.setResizable(true);
        await windowManager.setSize(_normalWindowSize);
        await windowManager.center();
        if (mounted) setState(() => _compactMode = false);
      }
    } catch (_) {
      if (mounted) setState(() => _compactMode = !_compactMode);
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

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: <Widget>[
          // ① 背景（可在设置页换：内置场景或自定义图片）
          // 背景与歌词/鼠标交互隔离：只有切换背景（或曲目带来的主题色）才重绘底图。
          const Positioned.fill(child: RepaintBoundary(child: AppBackground())),

          // ② 主界面 / 紧凑播放器。只做轻量淡入，避免大面积缩放。
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (Widget child, Animation<double> animation) =>
                FadeTransition(opacity: animation, child: child),
            child: _compactMode
                ? _CompactPlayer(
                    key: const ValueKey<String>('compact-player'),
                    queueOpen: _queueOpen,
                    pinned: _compactPinned,
                    onToggleQueue: _toggleQueue,
                    onTogglePinned: _toggleCompactPinned,
                    onExit: _toggleCompactMode,
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
                                        queueOpen: _queueOpen,
                                        onToggleQueue: _toggleQueue,
                                        view: _view,
                                        playlistId: _playlistId,
                                        onSelectSettings: _showSettings,
                                        onSelectPlaybackSettings:
                                            _showPlaybackSettings,
                                        onSelectPlayer: _showPlayer,
                                        onSelectView: _showView,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                  Expanded(
                                    child: switch (_view) {
                                      _MainView.player => _PlayerPanel(
                                        onShowLyrics: _showLyricsDialog,
                                      ),
                                      _MainView.glassSettings =>
                                        const AppearanceSettingsView(),
                                      _MainView.playbackSettings =>
                                        const PlaybackSettingsView(),
                                      // 曲库页面（0.0.27）
                                      _MainView.allSongs =>
                                        const AllSongsView(),
                                      _MainView.albums => const AlbumsView(),
                                      _MainView.artists => const ArtistsView(),
                                      _MainView.favorites =>
                                        const FavoritesView(),
                                      _MainView.playlist => PlaylistView(
                                        playlistId: _playlistId,
                                      ),
                                      _MainView.webdav => const WebDavView(),
                                      _MainView.onlineSearch =>
                                        const OnlineSearchView(),
                                      _MainView.sourceManager =>
                                        const SourceManagerView(),
                                      _MainView.downloads =>
                                        const DownloadManagerView(),
                                    },
                                  ),
                                ],
                              );
                            },
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
              ],
            ),
          ),
        ),
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
  });

  final bool queueOpen;
  final bool pinned;
  final VoidCallback onToggleQueue;
  final VoidCallback onTogglePinned;
  final VoidCallback onExit;

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
                onOpenPlayer: () {},
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

/// 标题栏——对应设计稿的 `.titlebar`。
///
/// 原生窗口边框已由 `DesktopWindow.setup()` 去掉，所以这条栏就是窗口唯一的框：
/// - 空白区域可拖动窗口、双击最大化 / 还原
/// - 右侧按钮真正控制窗口（最小化 / 最大化还原 / 关闭）
///
/// 0.0.10：去掉了「高端 / 均衡 / 省电」切换器（性能档位改为桌面端自动判定），
/// 齿轮改为**切换右侧主区显示设置页**，不再是弹窗。
class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.settingsOpen,
    required this.onToggleSettings,
    required this.onShowNavigation,
    required this.compactMode,
    required this.onToggleCompact,
  });

  /// 右侧主区当前是否显示设置页。
  final bool settingsOpen;

  /// 点击齿轮：在播放页与设置页之间切换。
  final VoidCallback onToggleSettings;
  final VoidCallback onShowNavigation;
  final bool compactMode;
  final VoidCallback onToggleCompact;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    // ⚠️ 拖动区域必须显式铺满整条标题栏。
    //
    // 「只能拖左上角」的根因有两层：
    // 1. 手写的 GestureDetector 用默认的 deferToChild —— 只有子组件**绘制到的
    //    像素**才响应手势，标题栏中间那片空白根本没有命中区域；
    // 2. 换成 DragToMoveArea 后仍不对：它是 StatelessWidget，尺寸只包裹自己的
    //    child，而 Row 里的 Spacer 不产生命中区域，所以拖动范围依然只有
    //    图标和文字那几小块。
    //
    // 现在用 Container 显式给出全宽，并给一个**透明但存在**的底色
    // （color 非 null 才会参与命中测试），整条栏就都能拖了。
    return DragToMoveArea(
      child: Container(
        height: 40,
        // 透明但存在 —— 让整条区域可命中
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: <Widget>[
            // 应用图标：三色渐变圆角方块（颜色跟随背景强调色）
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
            Text(
              AppConstants.appName,
              style: const TextStyle(
                color: Color(0xD9FFFFFF),
                fontSize: 12,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w500,
              ),
            ),
            // 中间留白用 Expanded 而非 Spacer：Spacer 只是 SizedBox.shrink 的
            // 包装，不产生可命中的绘制；Expanded 里的 SizedBox.expand 会撑满
            // 这块空间，配合上面的透明 color 让中间区域也能拖动。
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

/// 外观设置入口。挂在标题栏上，作为侧边栏入口的快捷方式
/// （窗口太窄时侧边栏会被隐藏，这里仍然能进设置）。
class _GlassSettingsButton extends StatefulWidget {
  const _GlassSettingsButton({required this.active, required this.onTap});

  /// 设置页是否正显示。
  final bool active;

  /// 点击回调。
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

/// 窗口按钮（最小化 / 最大化还原 / 关闭）。真正控制窗口。
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
    } catch (_) {
      // 窗口未就绪时忽略
    }
  }

  @override
  Widget build(BuildContext context) {
    // 图标随最大化状态切换：口 / 还原
    final List<IconData> icons = <IconData>[
      Icons.remove,
      _maximized ? Icons.fullscreen_exit : Icons.crop_square,
      Icons.close,
    ];
    const List<String> tooltips = <String>['最小化', '最大化 / 还原', '关闭'];

    return Row(
      children: List<Widget>.generate(icons.length, (int i) {
        final bool isClose = i == 2;
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
                    ? (isClose
                          ? const Color(0xFFE81123)
                          : const Color(0x1FFFFFFF))
                    : Colors.transparent,
                child: Icon(
                  icons[i],
                  size: i == 2 ? 15 : 13,
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

// ════════════════════════════════════════════════════════════════
//  侧边栏
// ════════════════════════════════════════════════════════════════

/// 侧边栏内容——对应设计稿的 `.sidebar`。
///
/// 0.0.10：设置不再是弹窗，而是页面入口；
/// 0.0.11 加「外观设置」，0.0.12 加「播放设置」（音乐库扫描记录 + 启动行为）；
/// **0.0.21：控制台搬到侧边栏顶部**（原来的「打开文件夹 / 添加单曲」两个按钮撤掉，
/// 它们现在只在「播放设置」里），右侧面板只负责歌曲信息与歌词。
///
/// 这一栏现在是三段式：**控制台固定顶部 / 导航可滚动 / 设置入口固定底部**。
class _Sidebar extends ConsumerWidget {
  const _Sidebar({
    required this.queueOpen,
    required this.onToggleQueue,
    required this.view,
    required this.playlistId,
    required this.onSelectSettings,
    required this.onSelectPlaybackSettings,
    required this.onSelectPlayer,
    required this.onSelectView,
  });

  /// 侧栏宽度见 [_sidebarWidthFor]（随窗口宽度分档）。
  /// 这里留一个常量给"最小宽度"用，别再往写死的 220 上收。
  static const double minimumWidth = 236;

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

  /// 切回播放页。
  final VoidCallback onSelectPlayer;

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
      // 0.0.21：不再整栏一起滚。控制台固定在顶部、设置入口固定在底部，
      // 只有中间那串导航会在窗口太矮时滚动——否则控制台一进来就把
      // 「外观设置 / 播放设置」挤出屏幕，用户根本点不到。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ── 控制台：黑胶 + 曲名 + 进度 + 控制按钮（固定）──────────
          // 0.0.40：**点控制台就是进「正在播放」页**（用户要求把入口挪到这里）
          _Console(
            queueOpen: queueOpen,
            onToggleQueue: onToggleQueue,
            onOpenPlayer: onSelectPlayer,
          ),
          const SizedBox(height: 14),
          const Divider(color: AppColors.divider, height: 1),

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
                      trailing: IconButton(
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
                  onTap: controller.previous,
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
                  onTap: controller.next,
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
    switch (style.layout) {
      case LyricsLayoutMode.flowline:
        final LyricsSceneDefinition? definition = lyricsSceneDefinitionFor(
          style.layout,
        );
        return definition?.builder(onShowLyrics: onShowLyrics) ??
            LyricsScene(mode: style.layout, onShowLyrics: onShowLyrics);
      case LyricsLayoutMode.scrollingList:
        break;
    }

    final BlurConfig config = BlurConfigScope.of(context);
    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      blurSigma: config.blurSigma,
      blurEnabled: config.useBlur,
      showSweepAt: config.sweepEnabled && config.animationsEnabled,
      glowOpacity: config.glowStrength,
      glowColor: config.glowColor,
      tintOpacity: config.tintOpacity,
      initialSweepPhase: 0.5,
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: _PlayerBody(onShowLyrics: onShowLyrics),
    );
  }
}

/// 封面 + 曲目信息 + 歌词。宽窗口左右排，窄窗口上下堆叠。
class _PlayerBody extends StatelessWidget {
  const _PlayerBody({required this.onShowLyrics});

  final VoidCallback onShowLyrics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool showLyrics = MediaQuery.sizeOf(context).width >= 800;
        final bool wide = constraints.maxWidth > 760 && showLyrics;
        // 封面随空间缩放，始终处于 180~320dp 的设计范围内。
        final double coverSize = wide
            ? (constraints.maxHeight * 0.40).clamp(176.0, 260.0)
            : (constraints.maxWidth * 0.52).clamp(180.0, 320.0);

        final Widget cover = CoverStage(size: coverSize);
        const Widget info = _TrackInfo(centered: false);

        if (!wide) {
          // 窄窗口：封面在上、信息在下、歌词占剩余空间
          return Column(
            children: <Widget>[
              cover,
              const SizedBox(height: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    info,
                    const SizedBox(height: 12),
                    if (showLyrics)
                      const Expanded(child: LyricsPanel())
                    else
                      _LyricsDialogButton(onTap: onShowLyrics),
                  ],
                ),
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: constraints.maxWidth * 0.39,
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: (constraints.maxWidth * 0.34).clamp(260.0, 380.0),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      cover,
                      const SizedBox(height: 24),
                      const _TrackInfo(centered: true),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 28),
            Expanded(child: const LyricsPanel(centered: true)),
          ],
        );
      },
    );
  }
}

class _LyricsDialogButton extends StatelessWidget {
  const _LyricsDialogButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.lyrics_rounded, size: 17),
        label: const Text('打开歌词'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: accent.primary.withValues(alpha: 0.55)),
        ),
      ),
    );
  }
}

/// 曲目信息（标题 / 艺术家 / 专辑 / 音质）。
class _TrackInfo extends ConsumerWidget {
  const _TrackInfo({this.centered = false});

  final bool centered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    // 主题提取色先与深色玻璃底混合，再挑选 WCAG 对比度更高的文字色。
    final Color accentSafeText = AppAccent.safeTextOn(
      Color.alphaBlend(accent.primary.withValues(alpha: 0.22), Colors.black),
    );
    final PlayerUiState state = ref.watch(playerControllerProvider);
    final Track? track = state.currentTrack;
    final bool hasTrack = track != null;

    return Column(
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          hasTrack ? track.title : '未在播放',
          textAlign: centered ? TextAlign.center : TextAlign.start,
          maxLines: centered ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            // 主题色由封面/自定义图提取时先经对比度校验，避免亮色主题白字不可读。
            color: hasTrack ? accentSafeText : const Color(0x99FFFFFF),
            fontSize: centered ? 28 : 34,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
            height: 1.12,
            shadows: <Shadow>[
              Shadow(
                color: accent.secondary.withValues(alpha: 0.55),
                blurRadius: 24,
              ),
              const Shadow(color: Color(0x99000000), blurRadius: 6),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          hasTrack ? track.artist : '用左上角的控制台播放，音乐从「播放设置」里添加',
          textAlign: centered ? TextAlign.center : TextAlign.start,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Color(0xD9FFFFFF),
            fontSize: centered ? 14 : 16,
            letterSpacing: 0.6,
            shadows: <Shadow>[Shadow(color: Color(0xB3000000), blurRadius: 8)],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          hasTrack ? track.album : '支持 MP3 / FLAC / WAV / M4A / OGG / OPUS',
          textAlign: centered ? TextAlign.center : TextAlign.start,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Color(0xB3FFFFFF),
            fontSize: centered ? 12 : 13,
            letterSpacing: 0.4,
            shadows: <Shadow>[Shadow(color: Color(0x99000000), blurRadius: 6)],
          ),
        ),

        // 音质 / 格式信息（0.0.16 新增）
        if (hasTrack) ...<Widget>[
          const SizedBox(height: 10),
          _QualityBadge(
            label: track.qualityLabel,
            details:
                '${_trackInfoLine(track)}\n${track.isRemote ? track.uri : track.id}',
            accent: accent,
          ),
          const SizedBox(height: 8),
          Text(
            _trackInfoLine(track),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xB3FFFFFF),
              fontSize: 11,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ],
    );
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

/// 音质徽标：本地文件显示解析到的技术信息；在线曲目只显示音质档位。
class _QualityBadge extends StatelessWidget {
  const _QualityBadge({
    required this.label,
    required this.accent,
    this.details,
  });

  final String label;
  final AppAccent accent;
  final String? details;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: details ?? label,
      waitDuration: const Duration(milliseconds: 300),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          color: Colors.black.withValues(alpha: 0.28),
          border: Border.all(color: accent.primary.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.graphic_eq_rounded, size: 12, color: accent.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.94),
                fontSize: 11.5,
                letterSpacing: 0.3,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                shadows: const <Shadow>[
                  Shadow(color: Color(0x99000000), blurRadius: 4),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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

  /// 把本地 x 坐标换算成 0~1 的播放比例。
  void _seekTo(double dx, double width) {
    if (!widget.enabled || width <= 0) return;
    widget.onSeek((dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;

        return MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTapDown: (TapDownDetails d) => _seekTo(d.localPosition.dx, width),
            onHorizontalDragUpdate: (DragUpdateDetails d) =>
                _seekTo(d.localPosition.dx, width),
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
                    FractionallySizedBox(
                      widthFactor: widget.progress,
                      child: Container(
                        height: 4,
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
                              color: accent.primary.withValues(alpha: 0.6),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: FractionallySizedBox(
                        widthFactor: widget.progress,
                        alignment: Alignment.centerLeft,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 180),
                            opacity: _hovered ? 1 : 0,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 140),
                              width: _hovered ? 16 : 10,
                              height: _hovered ? 16 : 10,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                                boxShadow: <BoxShadow>[
                                  BoxShadow(
                                    color: Color(0xE6FFFFFF),
                                    blurRadius: 12,
                                  ),
                                  BoxShadow(
                                    color: Color(0xB300E5FF),
                                    blurRadius: 24,
                                  ),
                                ],
                              ),
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
    required this.blurSigma,
    required this.blurEnabled,
    required this.showSweep,
    required this.glowOpacity,
    required this.tintOpacity,
    required this.onClose,
  });

  final bool open;
  final double leftInset;
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
          bottom: 0,
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
          bottom: 0,
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
    final List<Track> tracks = state.queue;

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
                        active: index == state.currentIndex,
                        onTap: () => ref
                            .read(playerControllerProvider.notifier)
                            .playAt(index),
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
