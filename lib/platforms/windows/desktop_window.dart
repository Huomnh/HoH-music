/// desktop_window.dart
///
/// Windows runner 创建无标题栏顶层窗口，Flutter 自绘标题栏负责窗口操作。
///
/// 1. 窗口背景——仅设置为透明，玻璃面板由 Flutter 自绘；不启用窗口级
///    DWM/Acrylic 材质，避免整窗透视模糊和启动阻塞。
/// setup 在 runApp 前完成无边框和透明背景准备，runner 等 Flutter 首帧后显示窗口。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 窗口初始化阶段的诊断日志。
///
/// 刻意用 `stderr.writeln` 而不是 `debugPrint`：
/// `debugPrint` 带节流，在启动早期会丢行，排查窗口问题时极易误判
/// （之前就因此以为某一步挂了）。stderr 即时且不丢。
void _winLog(String message) {
  if (kReleaseMode) return;
  stderr.writeln('[DesktopWindow] $message');
}

/// 桌面窗口初始化。
abstract final class DesktopWindow {
  /// 是否支持窗口定制。
  ///
  /// 只在桌面平台启用；移动端 / Web 直接跳过，避免调用不存在的通道。
  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 显示 / 隐藏主窗口（托盘与全局快捷键共用）。
  static Future<void> toggleVisibility() async {
    if (!isSupported) return;
    try {
      if (await windowManager.isVisible()) {
        await windowManager.hide();
      } else {
        await showAndFocus();
      }
    } catch (error) {
      _winLog('toggleVisibility failed: $error');
    }
  }

  /// 显示并聚焦主窗口。
  static Future<void> showAndFocus() async {
    if (!isSupported) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (error) {
      _winLog('showAndFocus failed: $error');
    }
  }

  /// 显式配置桌面窗口的无边框、尺寸、背景和约束。
  static Future<void> setup({
    Size size = const Size(1280, 800),
    Size minimumSize = const Size(960, 640),
  }) async {
    if (!isSupported) {
      _winLog('not a desktop platform, skip');
      return;
    }
    _winLog('setup start');
    try {
      await windowManager.ensureInitialized();
      _winLog('windowManager initialized');

      // 必须在首帧前去掉系统非客户区，否则会出现原生框 + HoH 标题栏双层叠加。
      await windowManager.setAsFrameless();
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setSize(size);
      await windowManager.setMinimumSize(minimumSize);
      await windowManager.setResizable(true);
      await windowManager.center();
      _winLog('frameless / background / size ready before first frame');

      try {
        await windowManager.setHasShadow(true);
      } catch (error) {
        _winLog('shadow unavailable (non-fatal): $error');
      }
      _winLog('rounded Flutter frame will sync after the first frame');
    } catch (error, stack) {
      // 窗口定制失败不能让应用自动退出；runner 仍会显示 Flutter 首帧，
      // 用户至少可以使用应用并看到未能应用的原生窗口样式。
      _winLog('setup error (non-fatal): $error');
      stderr.writeln('$stack');
    }
  }
}
