/// app.dart
///
/// 应用根组件。
///
/// 当前桌面应用根组件。业务状态由 Riverpod 管理；Windows 专属窗口和系统
/// 集成由 `platforms/windows` 适配层挂载，其余 UI 与播放状态留在 Flutter。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/library/library_store.dart';
import 'features/player/player_page.dart';
import 'platforms/windows/debug_autoplay.dart';
import 'platforms/windows/debug_glass.dart';
import 'platforms/windows/global_hotkey_service.dart';
import 'platforms/windows/lyrics_overlay.dart';
import 'platforms/windows/smtc_service.dart';
import 'platforms/windows/tray_service.dart';
import 'shared/constants.dart';
import 'shared/theme/app_accent.dart';
import 'shared/theme/app_colors.dart';
import 'shared/theme/custom_fonts.dart';
import 'shared/theme/performance_tier.dart';
import 'shared/widgets/widget_kit/blur_config_scope.dart';

/// 应用根组件。
class HoHMusicApp extends ConsumerWidget {
  /// 创建应用根组件。
  ///
  /// [debugAutoPlayPaths] 仅用于调试：非空时启动后自动播放这些路径
  /// （文件或文件夹，见 `platforms/windows/debug_autoplay.dart`）。
  /// Release 构建下会被忽略。
  const HoHMusicApp({super.key, this.debugAutoPlayPaths = const <String>[]});

  /// 调试用：启动后自动播放的文件 / 文件夹路径。
  final List<String> debugAutoPlayPaths;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BlurConfig config = ref.watch(blurConfigProvider);
    final CustomFontSettings fonts =
        ref.watch(customFontsProvider).value ?? const CustomFontSettings();
    // 强调色跟随背景（自定义图片会从图里取色）
    final AppAccent accent = ref.watch(accentProvider);
    Widget home = const PlayerPage();

    // 启动恢复：按「启动行为」决定是否载入扫描记录并播放
    home = LibraryBootstrap(child: home);

    // 调试入口：仅在确实有路径时包一层
    if (debugAutoPlayPaths.isNotEmpty) {
      home = DebugAutoPlay(paths: debugAutoPlayPaths, child: home);
    }

    // 调试入口：环境变量要求统计帧耗时 / 强制开启高光流动时才包一层
    if (DebugGlass.wanted) {
      home = DebugGlass(child: home);
    }

    // 系统托盘：窗口 ✕ 收进托盘、右键菜单控制播放（仅 Windows）
    if (TrayHost.isSupported) {
      home = TrayHost(child: home);
    }

    // 全局快捷键：后台也能控制播放 / 窗口
    if (HotkeyHost.supported) {
      home = HotkeyHost(child: home);
    }

    // 系统媒体控制中心（SMTC）：音量键浮层显示曲目、媒体键反过来控制播放
    if (SmtcHost.isSupported) {
      home = SmtcHost(child: home);
    }

    // 桌面歌词浮层：置顶、鼠标穿透的独立小窗（0.0.25）
    if (LyricsOverlayHost.isSupported) {
      home = LyricsOverlayHost(child: home);
    }

    final Widget app = MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: _buildDarkTheme(accent, fonts.uiFamily ?? 'KirakaraMaru'),
      // 把渲染参数与强调色下发到整棵子树：
      // 玻璃面板据此决定模糊 / 高光 / 动效，控件据此决定强调色
      home: AccentScope(
        accent: accent,
        child: BlurConfigScope(config: config, child: home),
      ),
    );
    return !kIsWeb && Platform.isWindows ? ExcludeSemantics(child: app) : app;
  }

  /// 深色主题。底色取自 [AppColors]，强调色跟随背景（见 [AppAccent]）。
  ThemeData _buildDarkTheme(AppAccent accent, String? uiFontFamily) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: accent.primary,
          brightness: Brightness.dark,
        ).copyWith(
          surface: AppColors.midnight,
          primary: accent.primary,
          secondary: accent.secondary,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: uiFontFamily,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.abyss,
      dividerColor: AppColors.divider,
      splashFactory: NoSplash.splashFactory,
    );
  }
}
