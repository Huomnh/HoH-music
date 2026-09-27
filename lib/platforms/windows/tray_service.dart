/// tray_service.dart
///
/// 系统托盘（Windows）。
///
/// 提供的能力：
/// - **托盘图标**：用 `assets/icons/tray.ico`（运行时释放到临时目录，
///   因为原生侧要的是文件路径，不是 Flutter 资源）；
/// - **右键菜单**：显示 / 隐藏窗口、播放 / 暂停、上一首、下一首、退出；
/// - **左键单击**：显示 / 隐藏窗口；**双击**：显示并聚焦；
/// - **关闭按钮 → 收进托盘**：由 [TrayHost] 打开 `preventClose` 后接管，
///   真正退出走托盘菜单的「退出」。
///
/// ⚠️ 这里用的是 `tray_manager` 0.7 的**新 FFI API**（`package:nativeapi`），
/// 不是被标记为 `@Deprecated` 的 `trayManager` 单例 —— 后者在 0.7 上
/// 使用会产生弃用告警，而本项目要求 `flutter analyze` 零问题。
///
/// ⚠️ 托盘是**可选能力**：创建失败（原生库缺失、被系统策略拦住等）时
/// 只打日志并返回 false，界面照常可用，而且**不会**打开 `preventClose`，
/// 否则用户会因为「关闭按钮被吃掉 + 没有托盘可点」而无法退出。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import '../../core/audio/player_engine.dart';
import '../../core/audio/player_providers.dart';
import '../../shared/constants.dart';
import 'desktop_window.dart';

/// 诊断日志走 stderr：`debugPrint` 带节流、启动早期会丢行。
void _log(String message) => stderr.writeln('[Tray] $message');

/// 托盘菜单要回调到 UI 层的动作。
///
/// 平台层不直接依赖 Riverpod —— 由 [TrayHost] 把播放器动作注进来。
class TrayActions {
  const TrayActions({
    required this.onTogglePlay,
    required this.onNext,
    required this.onPrevious,
    required this.onQuit,
  });

  /// 播放 / 暂停。
  final VoidCallback onTogglePlay;

  /// 下一首。
  final VoidCallback onNext;

  /// 上一首。
  final VoidCallback onPrevious;

  /// 退出应用。
  final VoidCallback onQuit;
}

/// 系统托盘。
class TrayService {
  TrayService._();

  /// 单例。托盘图标全进程只应有一个。
  static final TrayService instance = TrayService._();

  /// 当前平台是否支持托盘。
  ///
  /// 只做 Windows —— 其它平台要在各自阶段单独验证（见架构文档第五章）。
  static bool get isSupported => !kIsWeb && Platform.isWindows;

  tray.TrayIcon? _icon;
  tray.Menu? _menu;
  tray.Image? _image;
  final List<tray.MenuItem> _items = <tray.MenuItem>[];
  tray.MenuItem? _playPauseItem;

  /// 托盘是否已创建成功。
  bool get isReady => _icon != null;

  /// 创建托盘图标与右键菜单。
  ///
  /// 返回是否成功。**失败不代表应用出错**，只是没有托盘。
  Future<bool> setup({required TrayActions actions}) async {
    if (!isSupported) {
      _log('当前平台不支持，跳过');
      return false;
    }
    if (_icon != null) return true;

    // 组件测试里既没有原生托盘库，也没有 path_provider 插件，
    // 直接跳过，避免在 `flutter test` 里刷一堆无关异常。
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      _log('测试环境，跳过');
      return false;
    }

    try {
      final tray.TrayIcon? icon = tray.TrayIcon.create();
      if (icon == null) {
        _log('TrayIcon.create() 返回 null，托盘不可用');
        return false;
      }
      _icon = icon;

      icon.setTooltip(AppConstants.appName);
      await _applyIcon(icon);

      final tray.Menu? menu = _buildMenu(actions);
      if (menu != null) {
        _menu = menu;
        icon.setContextMenu(menu);
      }
      icon.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
      icon.addListener(_handleTrayEvent);

      icon.setVisible(true);
      _log('托盘已就绪：菜单 ${_items.length} 项（显示/隐藏、播放暂停、上一首、下一首、退出）');
      return true;
    } catch (error, stack) {
      _log('托盘初始化失败（不影响播放）：$error');
      stderr.writeln('$stack');
      await dispose();
      return false;
    }
  }

  /// 把「正在播放」写进托盘提示，并同步菜单里的播放 / 暂停文案。
  void updatePlayback({String? title, required bool playing}) {
    final tray.TrayIcon? icon = _icon;
    if (icon == null) return;

    final String tooltip = (title == null || title.isEmpty)
        ? AppConstants.appName
        : '${AppConstants.appName} · $title';
    try {
      icon.setTooltip(tooltip);
      _playPauseItem?.label = playing ? '暂停' : '播放';
    } catch (error) {
      _log('更新托盘提示失败：$error');
    }
  }

  /// 显示 / 隐藏主窗口。实现统一放在 [DesktopWindow]，与全局快捷键共用一套。
  Future<void> toggleWindow() => DesktopWindow.toggleVisibility();

  /// 显示并聚焦主窗口。
  Future<void> showWindow() => DesktopWindow.showAndFocus();

  /// 销毁托盘（退出前调用）。
  Future<void> dispose() async {
    try {
      _icon?.setVisible(false);
    } catch (_) {
      // 忽略：图标可能已经不存在
    }

    for (final tray.MenuItem item in _items) {
      try {
        item.dispose();
      } catch (_) {
        // 忽略
      }
    }
    _items.clear();
    _playPauseItem = null;

    // 原生句柄各自释放；任何一步失败都不该影响退出流程。
    try {
      _menu?.dispose();
    } catch (_) {
      // 忽略
    }
    _menu = null;

    try {
      _image?.dispose();
    } catch (_) {
      // 忽略
    }
    _image = null;

    try {
      _icon?.dispose();
    } catch (_) {
      // 忽略
    }
    _icon = null;
  }

  // ── 内部 ──────────────────────────────────────────────────────

  /// 加载托盘图标。
  ///
  /// 原生侧要的是**文件路径**，所以把 Flutter 资源释放到临时目录再交给它。
  Future<void> _applyIcon(tray.TrayIcon icon) async {
    try {
      final Directory dir = await getTemporaryDirectory();
      final String path = '${dir.path}${Platform.pathSeparator}hoh_tray.ico';
      final File file = File(path);
      if (!file.existsSync()) {
        final ByteData data = await rootBundle.load('assets/icons/tray.ico');
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }

      final tray.Image? image = tray.Image.fromFile(path);
      if (image == null) {
        _log('图标文件无法解析（$path），使用系统默认图标');
        return;
      }
      _image = image;
      icon.icon = image;
    } catch (error) {
      _log('图标加载失败（用系统默认图标继续）：$error');
    }
  }

  tray.Menu? _buildMenu(TrayActions actions) {
    final tray.Menu? menu = tray.Menu.create();
    if (menu == null) {
      _log('Menu.create() 返回 null，跳过右键菜单');
      return null;
    }

    void add(String label, VoidCallback onTap) {
      final tray.MenuItem? item = tray.MenuItem.createWithLabelAndType(
        label,
        tray.MenuItemType.normal,
      );
      if (item == null) return;
      item.addListener((tray.MenuEvent event) {
        if (event is tray.MenuItemClickedEvent) onTap();
      });
      menu!.addItem(item);
      _items.add(item);
    }

    add('显示 / 隐藏窗口', () => unawaited(toggleWindow()));
    menu.addSeparator();

    final tray.MenuItem? playPause = tray.MenuItem.createWithLabelAndType(
      '播放 / 暂停',
      tray.MenuItemType.normal,
    );
    if (playPause != null) {
      playPause.addListener((tray.MenuEvent event) {
        if (event is tray.MenuItemClickedEvent) actions.onTogglePlay();
      });
      menu.addItem(playPause);
      _items.add(playPause);
      _playPauseItem = playPause;
    }
    add('上一首', actions.onPrevious);
    add('下一首', actions.onNext);

    menu.addSeparator();
    add('退出', actions.onQuit);

    return menu;
  }

  void _handleTrayEvent(tray.TrayIconEvent event) {
    switch (event) {
      // 左键单击：切换窗口显示
      case tray.TrayIconClickedEvent():
        unawaited(toggleWindow());
      // 双击：确保窗口出现并聚焦
      case tray.TrayIconDoubleClickedEvent():
        unawaited(showWindow());
      // 右键：菜单由原生侧弹出，这里不用处理
      case tray.TrayIconRightClickedEvent():
        break;
    }
  }
}

/// 优雅退出：**先撤掉托盘图标，再销毁窗口**。
///
/// ⚠️ 别用 `Stop-Process -Force` / 任务管理器「结束任务」来关这个应用：
/// 强杀时没人调 `Shell_NotifyIcon(NIM_DELETE)`，Windows 会把图标**留在托盘里**
/// （所谓"幽灵图标"，鼠标扫过托盘区域之前一直挂着）。
/// 0.0.21 用户就是看到任务栏一排重复图标 —— 那是截图脚本
/// `scripts/capture-window.ps1` 每次强杀攒出来的。
/// 现在脚本改用 `hoh_music.exe --exit-after=N` 让应用自己走这条路
/// （见 `debug_autoexit.dart`）。
Future<void> quitAppGracefully() async {
  _log('退出：先隐藏窗口，原生资源后台释放');
  try {
    await windowManager.setPreventClose(false);
  } catch (_) {
    // 忽略：可能本来就没设过
  }

  // hide 通常比 destroy 快得多，先让用户立刻看到 UI 消失；窗口销毁和
  // 托盘 NIM_DELETE 在后台继续，避免原生句柄释放卡住关闭反馈。
  try {
    await windowManager.hide();
  } catch (error) {
    _log('隐藏窗口失败：$error');
  }
  unawaited(_finishQuit());
}

Future<void> _finishQuit() async {
  try {
    await PlayerEngine.instance.dispose();
  } catch (error) {
    _log('音频引擎释放失败：$error');
  }
  try {
    await windowManager.destroy();
  } catch (error) {
    _log('窗口销毁失败：$error');
  }
  await TrayService.instance.dispose();
}

/// 把托盘接到应用上。
///
/// 挂在 `MaterialApp` 内层（需要访问 Riverpod 里的播放器控制器），
/// 同时接管「点关闭按钮 = 收进托盘」。
class TrayHost extends ConsumerStatefulWidget {
  const TrayHost({super.key, required this.child});

  /// 被包裹的子树。
  final Widget child;

  /// 当前平台是否启用托盘。
  static bool get isSupported => TrayService.isSupported;

  @override
  ConsumerState<TrayHost> createState() => _TrayHostState();
}

class _TrayHostState extends ConsumerState<TrayHost> with WindowListener {
  bool _ownsPreventClose = false;

  @override
  void initState() {
    super.initState();
    if (!TrayHost.isSupported) return;
    try {
      windowManager.addListener(this);
    } catch (error) {
      _log('窗口事件监听注册失败：$error');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_setup()));
  }

  Future<void> _setup() async {
    if (!mounted) return;
    final bool ok = await TrayService.instance.setup(
      actions: TrayActions(
        onTogglePlay: () =>
            ref.read(playerControllerProvider.notifier).togglePlayPause(),
        onNext: () => ref.read(playerControllerProvider.notifier).next(),
        onPrevious: () =>
            ref.read(playerControllerProvider.notifier).previous(),
        onQuit: () => unawaited(_quit()),
      ),
    );

    if (!ok) {
      // 没有托盘就**不能**拦截关闭，否则用户无法退出应用。
      _log('托盘不可用：关闭按钮仍然是直接退出');
      return;
    }

    try {
      await windowManager.setPreventClose(true);
      _ownsPreventClose = true;
      _log('已接管关闭按钮：点 ✕ 收进托盘，退出请走托盘菜单');
    } catch (error) {
      _log('preventClose 设置失败：$error');
    }

    // 首次同步一次托盘提示
    final PlayerUiState state = ref.read(playerControllerProvider);
    TrayService.instance.updatePlayback(
      title: state.currentTrack?.title,
      playing: state.playing,
    );
  }

  Future<void> _quit() async {
    _ownsPreventClose = false;
    await quitAppGracefully();
  }

  @override
  void onWindowClose() {
    unawaited(_hideToTray());
  }

  Future<void> _hideToTray() async {
    try {
      if (!await windowManager.isPreventClose()) return;
      await windowManager.hide();
    } catch (error) {
      _log('收进托盘失败：$error');
    }
  }

  @override
  void dispose() {
    if (TrayHost.isSupported) {
      try {
        windowManager.removeListener(this);
      } catch (_) {
        // 忽略
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 托盘提示跟随播放状态
    ref.listen(playerControllerProvider, (
      PlayerUiState? prev,
      PlayerUiState next,
    ) {
      TrayService.instance.updatePlayback(
        title: next.currentTrack?.title,
        playing: next.playing,
      );
    });

    return widget.child;
  }
}
