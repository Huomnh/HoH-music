/// android_playback_service.dart
///
/// Android 播放保活桥接。真正的播放器仍由 Flutter/media_kit 持有，
/// 这里只在播放时启动一个轻量的媒体前台服务，避免应用切到后台后被
/// 系统过早回收；Windows 和其它平台不会调用这个通道。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart';
import '../../core/audio/player_providers.dart';
import '../../core/metadata/cover_art.dart';
import '../../features/library/playlists.dart';
import '../../features/player/lyrics/lyrics_parser.dart';
import '../../features/player/lyrics/lyrics_view.dart';

/// Flutter 与 Android 前台媒体服务之间的最小协议。
abstract final class AndroidPlaybackService {
  static const MethodChannel _channel = MethodChannel(
    'com.hohmusic/foreground_playback',
  );
  static bool _running = false;
  static DateTime _lastPositionSync = DateTime.fromMillisecondsSinceEpoch(0);

  /// 接收 Android 锁屏/通知栏发回来的媒体操作。
  static void installMediaActionHandler(
    Future<void> Function(String action, Duration? position) handler,
  ) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'mediaAction') return;
      final Map<Object?, Object?>? arguments = call.arguments is Map
          ? call.arguments as Map<Object?, Object?>
          : null;
      final String action = arguments?['action']?.toString() ?? '';
      final int? positionMs = (arguments?['positionMs'] as num?)?.toInt();
      await handler(
        action,
        positionMs == null ? null : Duration(milliseconds: positionMs),
      );
    });
  }

  /// 将当前播放状态同步给 Android 服务。
  static Future<void> sync(
    PlayerUiState state, {
    Duration? position,
    Uint8List? artwork,
    bool? favorite,
    String? lyric,
  }) async {
    if (!Platform.isAndroid) return;
    final Track? track = state.currentTrack;
    if (track == null) {
      if (!_running) return;
      _running = false;
      try {
        await _channel.invokeMethod<void>('stop');
      } on PlatformException catch (error) {
        debugPrint('[AndroidPlayback] 停止前台服务失败：$error');
      }
      return;
    }

    // 锁屏进度不需要跟 Flutter 页面一样高频刷新；降低 MethodChannel、
    // Android 通知和前台服务更新频率，避免后台耗电和频繁唤醒。
    if (position != null && artwork == null) {
      final DateTime now = DateTime.now();
      if (now.difference(_lastPositionSync) <
          const Duration(milliseconds: 500)) {
        return;
      }
      _lastPositionSync = now;
    }

    try {
      final Uint8List? compactArtwork = artwork == null
          ? null
          : await _prepareArtwork(artwork);
      await _channel.invokeMethod<void>('update', <String, Object?>{
        'title': track.title,
        'artist': track.artist,
        'album': track.album,
        'durationMs': state.duration.inMilliseconds,
        'positionMs': (position ?? Duration.zero).inMilliseconds,
        'playing': state.playing,
        if (compactArtwork != null) 'artwork': compactArtwork,
        if (favorite != null) 'favorite': favorite,
        if (lyric != null) 'lyric': lyric,
      });
      _running = true;
    } on PlatformException catch (error) {
      // 没有通知权限或系统限制服务启动时，不影响前台播放。
      debugPrint('[AndroidPlayback] 启动前台服务失败，继续普通播放：$error');
    }
  }

  /// 系统媒体会话把封面放进 Binder/MediaMetadata，避免直接传入超大的原图。
  static Future<Uint8List?> _prepareArtwork(Uint8List bytes) async {
    if (bytes.isEmpty) return Uint8List(0);
    if (bytes.lengthInBytes <= 700 * 1024) return bytes;
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 512,
        targetHeight: 512,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ByteData? data = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      codec.dispose();
      frame.image.dispose();
      return data?.buffer.asUint8List();
    } catch (error) {
      debugPrint('[AndroidPlayback] 封面压缩失败，使用原图：$error');
      return bytes;
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
  String _currentLyric(Duration? position) {
    final Lyrics? lyrics = ref.read(currentLyricsProvider).value;
    if (lyrics == null || lyrics.isEmpty) return '';
    final int index = lyrics.indexAt(position ?? Duration.zero);
    if (index < 0 || index >= lyrics.lines.length) return '';
    return lyrics.lines[index].text.trim();
  }

  bool _currentFavorite(PlayerUiState state) {
    final Track? track = state.currentTrack;
    return track != null && ref.read(isFavoriteProvider(track.id));
  }

  @override
  void initState() {
    super.initState();
    AndroidPlaybackService.installMediaActionHandler((
      String action,
      Duration? position,
    ) async {
      final PlayerController controller = ref.read(
        playerControllerProvider.notifier,
      );
      final PlayerUiState state = ref.read(playerControllerProvider);
      switch (action) {
        case 'play':
          if (!state.playing) await controller.togglePlayPause();
        case 'pause':
          if (state.playing) await controller.togglePlayPause();
        case 'next':
          await controller.next();
        case 'previous':
          await controller.previous();
        case 'seek':
          if (position != null) await controller.seek(position);
        case 'favorite':
          final Track? track = state.currentTrack;
          if (track != null) {
            await ref.read(playlistsProvider.notifier).toggleFavorite(track.id);
          }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        AndroidPlaybackService.sync(
          ref.read(playerControllerProvider),
          position: ref.read(playbackPositionProvider).value,
          artwork: ref.read(currentCoverProvider).value ?? Uint8List(0),
          favorite: _currentFavorite(ref.read(playerControllerProvider)),
          lyric: _currentLyric(ref.read(playbackPositionProvider).value),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PlayerUiState>(playerControllerProvider, (
      _,
      PlayerUiState next,
    ) {
      final Duration? position = ref.read(playbackPositionProvider).value;
      unawaited(
        AndroidPlaybackService.sync(
          next,
          favorite: _currentFavorite(next),
          lyric: _currentLyric(position),
        ),
      );
    });
    ref.listen<AsyncValue<Duration>>(playbackPositionProvider, (_, next) {
      final Duration? position = next.value;
      unawaited(
        AndroidPlaybackService.sync(
          ref.read(playerControllerProvider),
          position: position,
          lyric: _currentLyric(position),
        ),
      );
    });
    ref.listen<AsyncValue<Uint8List?>>(currentCoverProvider, (_, next) {
      unawaited(
        AndroidPlaybackService.sync(
          ref.read(playerControllerProvider),
          position: ref.read(playbackPositionProvider).value,
          artwork: next.value ?? Uint8List(0),
          favorite: _currentFavorite(ref.read(playerControllerProvider)),
          lyric: _currentLyric(ref.read(playbackPositionProvider).value),
        ),
      );
    });
    ref.listen<AsyncValue<Lyrics?>>(currentLyricsProvider, (_, next) {
      unawaited(
        AndroidPlaybackService.sync(
          ref.read(playerControllerProvider),
          position: ref.read(playbackPositionProvider).value,
          lyric: _currentLyric(ref.read(playbackPositionProvider).value),
        ),
      );
    });
    ref.listen<AsyncValue<List<Playlist>>>(playlistsProvider, (_, __) {
      final PlayerUiState state = ref.read(playerControllerProvider);
      unawaited(
        AndroidPlaybackService.sync(
          state,
          favorite: _currentFavorite(state),
          lyric: _currentLyric(ref.read(playbackPositionProvider).value),
        ),
      );
    });
    return widget.child;
  }
}
