/// desktop_window.dart
///
/// Windows 桌面窗口配置。
///
/// 解决两个问题：
/// 1. **「两个框」**——Windows 原生边框 + 界面里自绘的标题栏叠在一起。
///    用 `windowManager.setAsFrameless()` 去掉原生边框，
///    界面里那条标题栏就成为唯一的框。
/// 2. **「整体透明」**——用 `flutter_acrylic` 的 [WindowEffect.transparent]
///    让窗口背景真正透过桌面，玻璃面板的模糊才有素材可采样。
/// 3. **圆角外框**——Windows 10 没有 DWM 圆角，用 `SetWindowRgn` 区域裁剪，
///    见 [WindowFrame]。
///
/// ⚠️ 透明效果依赖 Windows 的 DWM 合成，**仅在无边框窗口上生效**，
/// 因此 `setAsFrameless()` 必须先于 `setEffect()`。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:window_manager/window_manager.dart';

import 'window_frame.dart';

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

  /// 应用启动时调用，完成无边框 + 透明 + 圆角设置。
  ///
  /// 必须在 `runApp` **之前**执行，否则用户会先看到一闪而过的系统边框窗口。
  static Future<void> setup({
    Size size = const Size(1280, 800),
    Size minimumSize = const Size(960, 640),
  }) async {
    if (!isSupported) {
      _winLog('not a desktop platform, skip');
      return;
    }
    _winLog('setup start');

    await windowManager.ensureInitialized();
    _winLog('windowManager initialized');

    const WindowOptions options = WindowOptions(
      size: null, // 用下面的 setSize 统一处理，避免和 waitUntilReadyToShow 冲突
      minimumSize: null,
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      title: 'HoH music',
    );

    // 先隐藏，等设置完再显示，避免启动瞬间闪现原生边框
    await windowManager.waitUntilReadyToShow(options, () async {
      _winLog('readyToShow callback entered');
      try {
        // ① 去掉原生标题栏与边框——必须在设置透明效果之前
        await windowManager.setAsFrameless();
        _winLog('frameless ok');

        // ② 窗口背景色。
        //
        // ⚠️ 踩坑记录：**不能用 `Colors.transparent`**。
        // 无边框窗口一旦设成全透明，DWM（Windows 10 上尤其明显）会把整个
        // 窗口当作"半透明背景材质"处理，结果是**整窗透视模糊** ——
        // 界面中部会出现一条横带、直接看到桌面和身后的浏览器内容。
        //
        // 正确做法：窗口背景给一个**不透明的深色底**，
        // 具体哪块玻璃透、透多少，完全由 Flutter 侧自绘的 `BackdropFilter`
        // 决定（它模糊的是窗口内的自绘背景场景）。这样既没有整窗透视，
        // 玻璃质感也完全可控。
        // 玻璃面板与窗口圆角共同负责底色；原生底色透明，避免四角露出黑块。
        await windowManager.setBackgroundColor(Colors.transparent);
        _winLog('transparent background set');

        // ③ DWM 效果：**保持 disabled**。
        //
        // 试过 transparent 与 acrylic 两种：
        // - `transparent`：Windows 10 上会让整窗透视模糊（见上面第 ② 步的说明）；
        // - `acrylic`：同样作用于整窗，中部出现半透明横带，能看到背后程序。
        //
        // 本项目的玻璃效果是**自绘**的（BackdropFilter 采样窗口内自绘的海滩场景），
        // 不需要 DWM 的窗口级材质。所以这里显式关掉，避免它破坏观感。
        //
        // 也顺带解决了另一个问题：实测 `setEffect` 在本机**永不返回**，
        // 之前 `await` 它会卡住后面的 show 与圆角设置。
        // 现在干脆不调用它了 —— 少一次可能挂起的跨平台调用。
        _winLog('DWM effect skipped (glass is self-drawn)');

        await windowManager.setSize(size);
        await windowManager.setMinimumSize(minimumSize);
        await windowManager.setResizable(true);
        await windowManager.center();
        _winLog('size ok');

        // 尺寸和无边框状态就绪后立即显示；阴影与圆角属于视觉增强，不能阻塞
        // 首次 UI 出现，否则启动时会长时间像“没有反应”。
        await windowManager.show();
        await windowManager.focus();
        _winLog('shown ok');

        // 无边框窗口默认没有系统投影，显式打开
        try {
          await windowManager.setHasShadow(true);
          _winLog('shadow ok');
        } catch (error) {
          _winLog('shadow FAILED (non-fatal): $error');
        }

        _winLog('applying rounded corners');

        // ④ 圆角外框。必须在 show 之后——SetWindowRgn 需要真实窗口尺寸。
        await WindowFrame.applyRoundedCorners();
        _winLog('rounded corners step done');
      } catch (error, stack) {
        // 窗口定制失败不能让应用起不来，界面仍可用
        _winLog('setup error: $error');
        stderr.writeln('$stack');
        try {
          await windowManager.show();
        } catch (_) {
          // 忽略
        }
      }
      _winLog('readyToShow callback finished');
    });

    _winLog('setup done');
  }
}
