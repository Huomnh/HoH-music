/// desktop_window.dart
///
/// Windows runner 在创建主窗口时使用标准 WS_OVERLAPPEDWINDOW 样式，
/// 因此标题栏、最小化、最大化和关闭由 Windows 原生非客户区负责。
///
/// 1. 窗口背景——仅设置为透明，玻璃面板由 Flutter 自绘；不启用窗口级
///    DWM/Acrylic 材质，避免整窗透视模糊和启动阻塞。
/// setup 保留为后续平台窗口外壳的显式配置入口；Windows 默认启动路径不在
/// runApp 前调用它，以免窗口管理器初始化与 Flutter 首帧发生竞态。
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

  /// 显式配置桌面窗口的尺寸、背景和约束（当前 Windows runner 启动路径不调用）。
  ///
  /// 如果其他桌面平台外壳需要主动配置，可在 runApp 前调用；Windows 当前
  /// 由 runner 在创建时直接确定标准原生窗口样式，避免首帧期间动态改框。
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

      // 不调用 setAsFrameless：Windows 原生标题栏和系统按钮由 runner 保留。
      // Flutter 内容仍然可以使用透明背景与自己的玻璃面板。
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
      _winLog(
        'native frame / background / size ready before first frame',
      );
    } catch (error, stack) {
      // 窗口定制失败不能让应用自动退出；runner 仍会显示 Flutter 首帧，
      // 用户至少可以使用应用并看到未能应用的原生窗口样式。
      _winLog('setup error (non-fatal): $error');
      stderr.writeln('$stack');
    }
  }
}
