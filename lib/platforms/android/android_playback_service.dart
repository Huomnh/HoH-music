/// android_playback_service.dart
///
/// Android 播放保活桥接。真正的播放器仍由 Flutter/media_kit 持有，
/// 这里只在播放时启动一个轻量的媒体前台服务，避免应用切到后台后被
/// 系统过早回收；Windows 和其它平台不会调用这个通道。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart';
import '../../core/audio/player_providers.dart';

/// Flutter 与 Android 前台媒体服务之间的最小协议。
abstract final class AndroidPlaybackService {
  static const MethodChannel _channel = MethodChannel(
    'com.hohmusic/foreground_playback',
  );
  static bool _running = false;

  /// 将当前播放状态同步给 Android 服务。
  static Future<void> sync(PlayerUiState state) async {
    if (!Platform.isAndroid) return;
    final Track? track = state.currentTrack;
    if (track == null || !state.playing) {
      if (!_running) return;
      _running = false;
      try {
        await _channel.invokeMethod<void>('stop');
      } on PlatformException catch (error) {
        debugPrint('[AndroidPlayback] 停止前台服务失败：$error');
      }
      return;
    }

    try {
      await _channel.invokeMethod<void>('start', <String, Object?>{
        'title': track.title,
        'artist': track.artist,
      });
      _running = true;
    } on PlatformException catch (error) {
      // 没有通知权限或系统限制服务启动时，不影响前台播放。
      debugPrint('[AndroidPlayback] 启动前台服务失败，继续普通播放：$error');
    }
  }
}

/// 监听全局播放器状态，并把播放/暂停状态桥接到 Android 服务。
class AndroidPlaybackHost extends ConsumerStatefulWidget {
  /// 创建 Android 播放保活宿主。
  const AndroidPlaybackHost({required this.child, super.key});

  /// 应用页面。
  final Widget child;

  @override
  ConsumerState<AndroidPlaybackHost> createState() =>
      _AndroidPlaybackHostState();
}

class _AndroidPlaybackHostState extends ConsumerState<AndroidPlaybackHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        AndroidPlaybackService.sync(ref.read(playerControllerProvider)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PlayerUiState>(playerControllerProvider, (
      _,
      PlayerUiState next,
    ) {
      unawaited(AndroidPlaybackService.sync(next));
    });
    return widget.child;
  }
}
