import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/audio/player_engine.dart';
import 'core/source/lx_selftest.dart';
import 'core/source/online_selftest.dart';
import 'platforms/windows/debug_autoexit.dart';
import 'platforms/windows/debug_autoplay.dart';
import 'platforms/windows/desktop_window.dart';

/// HoH music 应用入口。
///
/// 启动流程：
///   1. 绑定 Flutter 引擎
///   2. 初始化 MediaKit 解码后端（libmpv）
///   3. 解析命令行参数（调试自动播放 / 调试自动退出）
///   4. 配置桌面窗口：无边框 + 透明
///   5. 启动界面
///
/// Windows 系统集成在应用根组件中按能力启用；音乐库索引、用户设置和主题
/// 分别由对应 feature/provider 负责初始化与持久化。
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // ⓪ 自定义音源自检（仅 Debug + 显式开启）：纯命令行跑一遍 LX 格式脚本，
  //    结论写 stderr，跑完直接退出 —— 不建窗口、不初始化音频。
  //    见 core/source/lx_selftest.dart 顶部的环境变量说明。
  final String? sourceSelfTestDir = resolveSourceSelfTestDir(args);
  if (sourceSelfTestDir != null) {
    await runSourceSelfTest(sourceSelfTestDir);
    exit(0);
  }

  // ⓪′ 整条链路自检（导入 → 沙箱 → 搜索 → 解析地址 → 歌词 → 封面），
  //    同样跑完就退出。见 core/source/online_selftest.dart。
  if (onlineSelfTestRequested()) {
    await runOnlineSelfTest();
    exit(0);
  }

  // ① 音频引擎：必须在 runApp 之前，且只调用一次
  PlayerEngine.ensureInitialized();

  // ② 调试自动播放：命令行传入的音频文件或文件夹会在启动后自动播放。
  //    方便脚本 / 无头环境验证播放管线，Release 下恒为空。
  final List<String> autoPlayPaths = resolveDebugAutoPlayPaths(args);

  // ③ 桌面窗口：去掉原生边框、开启透明、加圆角。
  //    放在 runApp 之前，避免先闪出一个带系统边框的窗口。
  // 窗口初始化与 Flutter 首帧并行，避免启动时一直等待原生窗口配置完成。
  unawaited(DesktopWindow.setup());

  // ④ 调试自动退出（`--exit-after=秒`）：截图脚本用它收尾，
  //    走的是托盘清理那条路，不会在任务栏留下幽灵图标。
  scheduleDebugAutoExit(args);

  runApp(ProviderScope(child: HoHMusicApp(debugAutoPlayPaths: autoPlayPaths)));
}
