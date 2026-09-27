/// debug_autoexit.dart
///
/// 调试用的「到点优雅自退」开关。
///
/// 用途：`scripts/capture-window.ps1` 拍完预览图要关掉应用。
/// **必须让应用自己退出**，不能用 `Stop-Process -Force` 强杀 ——
/// 强杀时没有机会调 `Shell_NotifyIcon(NIM_DELETE)`，Windows 会把托盘图标
/// 留在任务栏（"幽灵图标"）。0.0.21 用户看到任务栏一排重复图标，
/// 就是前面几次截图强杀攒出来的。
///
/// 触发方式（仅 Debug 构建生效）：
/// - 命令行参数：`hoh_music.exe --exit-after=22`
/// - 环境变量：`HOH_EXIT_AFTER=22`
///
/// 到点后走的是与托盘菜单「退出」完全相同的 [quitAppGracefully]。
/// Release 构建下本文件不生效（不会自动退出）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'tray_service.dart';

/// 参数前缀。
const String _kFlag = '--exit-after=';

/// 从命令行 / 环境变量里解析「多少秒后自动退出」。
///
/// 返回 `null` 表示不开这个功能（Release 构建恒为 `null`）。
int? resolveDebugAutoExitSeconds(List<String> args) {
  if (kReleaseMode) return null;

  final List<String> candidates = <String>[
    ...args,
    if (Platform.environment['HOH_EXIT_AFTER'] case final String env
        when env.isNotEmpty)
      '$_kFlag$env',
  ];

  for (final String raw in candidates) {
    final String arg = raw.replaceAll('"', '').trim();
    if (!arg.startsWith(_kFlag)) continue;
    final int? seconds = int.tryParse(arg.substring(_kFlag.length));
    if (seconds != null && seconds > 0) return seconds;
  }
  return null;
}

/// 安排一次自动退出。参数里没有 `--exit-after` 时什么都不做。
///
/// 必须在 `DesktopWindow.setup()` 之后调用（要等窗口管理器就绪）。
void scheduleDebugAutoExit(List<String> args) {
  final int? seconds = resolveDebugAutoExitSeconds(args);
  if (seconds == null) return;

  // stderr 而不是 debugPrint：debugPrint 带节流，启动早期的行会丢
  stderr.writeln('[DebugAutoExit] $seconds 秒后优雅退出（走托盘清理，不留幽灵图标）');
  Timer(Duration(seconds: seconds), () {
    stderr.writeln('[DebugAutoExit] 到点，开始优雅退出');
    unawaited(quitAppGracefully());
  });
}
