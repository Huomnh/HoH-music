/// global_hotkey_service.dart
///
/// 全局快捷键（架构文档 3.9 系统集成）。
///
/// 用 `hotkey_manager` 注册**系统级**热键（应用在后台也能触发）：
///
/// | 快捷键 | 动作 |
/// |---|---|
/// | `Ctrl + Alt + Space` | 播放 / 暂停 |
/// | `Ctrl + Alt + ←` | 上一首 |
/// | `Ctrl + Alt + →` | 下一首 |
/// | `Ctrl + Alt + ↑` | 音量 +5% |
/// | `Ctrl + Alt + ↓` | 音量 −5% |
/// | `Ctrl + Alt + H` | 显示 / 隐藏窗口 |
///
/// 设置页只做**开关 + 展示**，不做自定义录制：录制交互（`HotkeyRecorder`）
/// 当前按键绑定在播放设置页中只读展示；平台按键注册仍与 UI 解耦。
///
/// ⚠️ 热键是**系统级独占**的：被别的软件占用时注册会失败。
/// 这里逐个注册、失败只记日志，不影响其它键，也不会让应用起不来。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/audio/player_providers.dart';
import 'desktop_window.dart';

/// 诊断日志走 stderr：`debugPrint` 带节流，启动早期会丢行。
void _log(String message) => stderr.writeln('[Hotkey] $message');

/// 快捷键触发的动作。
enum HotkeyAction {
  /// 播放 / 暂停。
  togglePlay,

  /// 下一首。
  next,

  /// 上一首。
  previous,

  /// 音量加。
  volumeUp,

  /// 音量减。
  volumeDown,

  /// 显示 / 隐藏窗口。
  toggleWindow,
}

/// 一条快捷键定义（纯数据，设置页直接渲染它）。
@immutable
class HotkeySpec {
  /// 创建定义。
  const HotkeySpec({
    required this.action,
    required this.label,
    required this.keysLabel,
    required this.key,
    this.modifiers = const <HotKeyModifier>[
      HotKeyModifier.control,
      HotKeyModifier.alt,
    ],
  });

  /// 触发的动作。
  final HotkeyAction action;

  /// 动作说明（「播放 / 暂停」）。
  final String label;

  /// 展示用的按键文本（`Ctrl + Alt + Space`）。
  final String keysLabel;

  /// 物理键。
  final PhysicalKeyboardKey key;

  /// 修饰键。
  final List<HotKeyModifier> modifiers;
}

/// 全部快捷键（顺序即设置页展示顺序）。
const List<HotkeySpec> kHotkeySpecs = <HotkeySpec>[
  HotkeySpec(
    action: HotkeyAction.togglePlay,
    label: '播放 / 暂停',
    keysLabel: 'Ctrl + Alt + Space',
    key: PhysicalKeyboardKey.space,
  ),
  HotkeySpec(
    action: HotkeyAction.previous,
    label: '上一首',
    keysLabel: 'Ctrl + Alt + ←',
    key: PhysicalKeyboardKey.arrowLeft,
  ),
  HotkeySpec(
    action: HotkeyAction.next,
    label: '下一首',
    keysLabel: 'Ctrl + Alt + →',
    key: PhysicalKeyboardKey.arrowRight,
  ),
  HotkeySpec(
    action: HotkeyAction.volumeUp,
    label: '音量 +',
    keysLabel: 'Ctrl + Alt + ↑',
    key: PhysicalKeyboardKey.arrowUp,
  ),
  HotkeySpec(
    action: HotkeyAction.volumeDown,
    label: '音量 −',
    keysLabel: 'Ctrl + Alt + ↓',
    key: PhysicalKeyboardKey.arrowDown,
  ),
  HotkeySpec(
    action: HotkeyAction.toggleWindow,
    label: '显示 / 隐藏窗口',
    keysLabel: 'Ctrl + Alt + H',
    key: PhysicalKeyboardKey.keyH,
  ),
];

/// 快捷键要回调到 UI / 播放层的动作。
class HotkeyCallbacks {
  /// 创建回调集合。
  const HotkeyCallbacks({
    required this.onTogglePlay,
    required this.onNext,
    required this.onPrevious,
    required this.onVolumeUp,
    required this.onVolumeDown,
  });

  /// 播放 / 暂停。
  final VoidCallback onTogglePlay;

  /// 下一首。
  final VoidCallback onNext;

  /// 上一首。
  final VoidCallback onPrevious;

  /// 音量加。
  final VoidCallback onVolumeUp;

  /// 音量减。
  final VoidCallback onVolumeDown;
}

/// 全局快捷键服务。
class GlobalHotkeyService {
  GlobalHotkeyService._();

  /// 单例。
  static final GlobalHotkeyService instance = GlobalHotkeyService._();

  /// 是否支持全局快捷键（桌面三端）。
  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 注册成功的动作（设置页用来显示"已生效 / 被占用"）。
  final Set<HotkeyAction> _registered = <HotkeyAction>{};

  /// 注册失败的动作（多半是被别的软件占用了）。
  final Set<HotkeyAction> _failed = <HotkeyAction>{};

  /// 已注册的动作。
  Set<HotkeyAction> get registeredActions => Set<HotkeyAction>.of(_registered);

  /// 注册失败的动作。
  Set<HotkeyAction> get failedActions => Set<HotkeyAction>.of(_failed);

  /// 是否已经注册过。
  bool get isActive => _registered.isNotEmpty;

  /// 注册全部快捷键，返回成功注册的数量。
  Future<int> register(HotkeyCallbacks callbacks) async {
    if (!isSupported) {
      _log('当前平台不支持，跳过');
      return 0;
    }
    // 组件测试里没有原生实现，直接跳过，避免刷无关异常
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      _log('测试环境，跳过');
      return 0;
    }

    await unregister();
    _failed.clear();

    for (final HotkeySpec spec in kHotkeySpecs) {
      try {
        await HotKeyManager.instance.register(
          HotKey(
            key: spec.key,
            modifiers: spec.modifiers,
            scope: HotKeyScope.system,
          ),
          keyDownHandler: (HotKey _) => _dispatch(spec.action, callbacks),
        );
        _registered.add(spec.action);
      } catch (error) {
        // 被占用是最常见的情况（例如输入法、录屏软件），不是致命错误
        _failed.add(spec.action);
        _log('注册失败（可能被占用）：${spec.keysLabel} → $error');
      }
    }

    _log(
      '全局快捷键已注册 ${_registered.length}/${kHotkeySpecs.length}'
      '${_failed.isEmpty ? "" : "，失败：${_failed.map((HotkeyAction a) => _labelOf(a)).join("、")}"}',
    );
    return _registered.length;
  }

  /// 注销全部快捷键。
  Future<void> unregister() async {
    if (_registered.isEmpty) return;
    try {
      await HotKeyManager.instance.unregisterAll();
    } catch (error) {
      _log('注销失败（忽略）：$error');
    }
    _registered.clear();
  }

  void _dispatch(HotkeyAction action, HotkeyCallbacks callbacks) {
    switch (action) {
      case HotkeyAction.togglePlay:
        callbacks.onTogglePlay();
      case HotkeyAction.next:
        callbacks.onNext();
      case HotkeyAction.previous:
        callbacks.onPrevious();
      case HotkeyAction.volumeUp:
        callbacks.onVolumeUp();
      case HotkeyAction.volumeDown:
        callbacks.onVolumeDown();
      case HotkeyAction.toggleWindow:
        // 窗口动作不需要播放层参与（也不会走到这里）
        unawaited(DesktopWindow.toggleVisibility());
    }
  }

  String _labelOf(HotkeyAction action) =>
      kHotkeySpecs.firstWhere((HotkeySpec s) => s.action == action).label;
}

/// 全局快捷键是否启用（默认开）。
final hotkeysEnabledProvider =
    AsyncNotifierProvider<HotkeysEnabledController, bool>(
      HotkeysEnabledController.new,
    );

/// 快捷键开关控制器。
class HotkeysEnabledController extends AsyncNotifier<bool> {
  static const String _key = 'hotkeys.enabled';

  @override
  Future<bool> build() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? true;
    } catch (error) {
      debugPrint('[Hotkey] 读取开关失败（用默认开）：$error');
      return true;
    }
  }

  /// 开关。
  Future<void> setEnabled(bool value) async {
    state = AsyncData<bool>(value);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (error) {
      debugPrint('[Hotkey] 保存开关失败：$error');
    }
  }
}

/// 把全局快捷键接到应用上（挂在 `MaterialApp` 内层，需要 Riverpod）。
class HotkeyHost extends ConsumerStatefulWidget {
  /// 创建宿主。
  const HotkeyHost({super.key, required this.child});

  /// 被包裹的子树。
  final Widget child;

  /// 当前平台是否启用全局快捷键。
  static bool get supported => GlobalHotkeyService.isSupported;

  @override
  ConsumerState<HotkeyHost> createState() => _HotkeyHostState();
}

class _HotkeyHostState extends ConsumerState<HotkeyHost> {
  /// 上一次实际生效的开关值，避免每帧重复注册。
  bool? _applied;

  @override
  Widget build(BuildContext context) {
    final bool enabled = ref.watch(hotkeysEnabledProvider).value ?? true;

    if (_applied != enabled) {
      _applied = enabled;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_apply(enabled));
      });
    }

    return widget.child;
  }

  Future<void> _apply(bool enabled) async {
    if (!GlobalHotkeyService.isSupported) return;

    if (!enabled) {
      await GlobalHotkeyService.instance.unregister();
      _log('全局快捷键已关闭');
      return;
    }

    await GlobalHotkeyService.instance.register(
      HotkeyCallbacks(
        onTogglePlay: () =>
            ref.read(playerControllerProvider.notifier).togglePlayPause(),
        onNext: () => ref.read(playerControllerProvider.notifier).next(),
        onPrevious: () =>
            ref.read(playerControllerProvider.notifier).previous(),
        onVolumeUp: () =>
            ref.read(playerControllerProvider.notifier).stepVolume(0.05),
        onVolumeDown: () =>
            ref.read(playerControllerProvider.notifier).stepVolume(-0.05),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(GlobalHotkeyService.instance.unregister());
    super.dispose();
  }
}
