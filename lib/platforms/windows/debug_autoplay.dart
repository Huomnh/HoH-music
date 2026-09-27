/// debug_autoplay.dart
///
/// 调试用的自动播放开关。
///
/// 用途：无头 / 自动化场景下验证播放管线是否真的能出声、进度是否在走。
/// 手动点「打开音乐」没法在脚本里做，所以留这个入口。
///
/// 触发方式（仅 Debug 构建生效）：
/// - 命令行参数：`hoh_music.exe "E:\music\a.mp3" "E:\music\b.flac"`
/// - 环境变量：`HOH_AUTOPLAY="E:\music\a.mp3"`
///
/// Release 构建下本组件直接返回 child，不做任何事。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart';
import '../../core/audio/player_providers.dart';

/// 从命令行参数 / 环境变量里解析待播放的路径。
///
/// 既接受音频文件，也接受**文件夹**（会递归扫描），
/// 与界面上「打开文件夹 / 选择文件」两条路径保持一致。
List<String> resolveDebugAutoPlayPaths(List<String> args) {
  if (kReleaseMode) return const <String>[];

  final List<String> candidates = <String>[
    ...args,
    if (Platform.environment['HOH_AUTOPLAY'] case final String env
        when env.isNotEmpty)
      env,
  ];

  return candidates
      .map((String p) => p.replaceAll('"', '').trim())
      .where((String p) => p.isNotEmpty)
      .where((String p) {
        final FileSystemEntityType type = FileSystemEntity.typeSync(p);
        if (type == FileSystemEntityType.directory) return true;
        if (type != FileSystemEntityType.file) return false;
        return isSupportedAudioFile(p);
      })
      .toList();
}

/// 启动后自动把 [paths] 加入队列并播放。
///
/// 放在 `MaterialApp` 内层使用——需要能访问 Provider 与 `BuildContext`。
class DebugAutoPlay extends ConsumerStatefulWidget {
  const DebugAutoPlay({super.key, required this.paths, required this.child});

  /// 待自动播放的文件或文件夹路径。
  final List<String> paths;

  /// 被包裹的子树。
  final Widget child;

  @override
  ConsumerState<DebugAutoPlay> createState() => _DebugAutoPlayState();
}

class _DebugAutoPlayState extends ConsumerState<DebugAutoPlay> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    if (widget.paths.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _done) return;
      _done = true;
      try {
        debugPrint('[DebugAutoPlay] 自动播放：${widget.paths.join(' | ')}');
        // 走的是与界面按钮完全相同的 loadPaths 通道，
        // 因此这条日志同时验证了目录递归扫描逻辑。
        await PlayerEngine.instance.loadPaths(widget.paths);
        debugPrint('[DebugAutoPlay] loadPaths 已返回');
      } catch (error) {
        debugPrint('[DebugAutoPlay] 自动播放失败：$error');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 监听一下状态，把关键指标打到控制台，方便脚本断言
    ref.listen(playerControllerProvider, (
      PlayerUiState? prev,
      PlayerUiState next,
    ) {
      if (prev?.currentIndex != next.currentIndex) {
        debugPrint(
          '[DebugAutoPlay] 切歌 → index=${next.currentIndex} '
          'track=${next.currentTrack?.title ?? '-'} playing=${next.playing}',
        );
      }
    });

    ref.listen(playbackPositionProvider, (
      AsyncValue<Duration>? prev,
      AsyncValue<Duration> next,
    ) {
      next.whenData((Duration pos) {
        // 只在整秒变化时打印，避免刷屏
        if (pos.inSeconds != prev?.value?.inSeconds) {
          debugPrint('[DebugAutoPlay] 播放位置 ${pos.inSeconds}s');
        }
      });
    });

    return widget.child;
  }
}
