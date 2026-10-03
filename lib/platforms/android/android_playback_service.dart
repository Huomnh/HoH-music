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
  static String? _activeTrackId;
  static int _trackRevision = 0;

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
    String? artworkTrackId,
  }) async {
    if (!Platform.isAndroid) return;
    final Track? track = state.currentTrack;
    if (track == null) {
      if (!_running) return;
      _running = false;
      _activeTrackId = null;
      _trackRevision++;
      try {
        await _channel.invokeMethod<void>('stop');
      } on PlatformException catch (error) {
        debugPrint('[AndroidPlayback] 停止前台服务失败：$error');
      }
      return;
    }

    if (_activeTrackId != track.id) {
      _activeTrackId = track.id;
      _trackRevision++;
    }
    final int requestRevision = _trackRevision;

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
      // 封面压缩是异步的。歌曲切换后，旧请求可能晚于新歌曲返回；
      // 丢弃这类结果，避免系统锁屏卡片被旧封面覆盖。
      if (artwork != null &&
          (_activeTrackId != track.id ||
              requestRevision != _trackRevision ||
              (artworkTrackId != null && artworkTrackId != track.id))) {
        return;
      }
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
  int _artworkRequestId = 0;

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

  /// 以当前歌曲为快照加载封面，并在结果返回后再次确认歌曲没有变化。
  ///
  /// `currentCoverProvider` 本身会受到网络请求延迟影响，所以不能把监听
  /// 回调里拿到的字节直接认为仍属于当前歌曲。切歌时先发空封面清除原生
  /// MediaSession 的旧图，加载完成后再发新图。
  Future<void> _refreshArtworkForCurrentTrack() async {
    final PlayerUiState initial = ref.read(playerControllerProvider);
    final Track? track = initial.currentTrack;
    if (track == null) return;
    final String trackId = track.id;
    final int requestId = ++_artworkRequestId;
    final Duration? position = ref.read(playbackPositionProvider).value;

    await AndroidPlaybackService.sync(
      initial,
      position: position,
      artwork: Uint8List(0),
      artworkTrackId: trackId,
      favorite: _currentFavorite(initial),
      lyric: _currentLyric(position),
    );

    Uint8List? bytes;
    try {
      bytes = await ref.read(currentCoverProvider.future);
    } catch (error) {
      debugPrint('[AndroidPlayback] 获取封面失败，保留空封面：$error');
    }
    if (!mounted ||
        requestId != _artworkRequestId ||
        ref.read(playerControllerProvider).currentTrack?.id != trackId) {
      return;
    }
    final PlayerUiState state = ref.read(playerControllerProvider);
    final Duration? currentPosition = ref.read(playbackPositionProvider).value;
    await AndroidPlaybackService.sync(
      state,
      position: currentPosition,
      artwork: bytes ?? Uint8List(0),
      artworkTrackId: trackId,
      favorite: _currentFavorite(state),
      lyric: _currentLyric(currentPosition),
    );
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
      unawaited(_refreshArtworkForCurrentTrack());
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<PlayerUiState>(playerControllerProvider, (
      PlayerUiState? previous,
      PlayerUiState next,
    ) {
      final bool trackChanged =
          previous?.currentTrack?.id != next.currentTrack?.id;
      if (trackChanged && next.currentTrack != null) {
        unawaited(_refreshArtworkForCurrentTrack());
      }
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
    ref.listen<AsyncValue<Uint8List?>>(currentCoverProvider, (_, __) {
      // 只重新按当前歌曲读取 provider.future，不直接使用监听回调的字节，
      // 这样旧歌曲的迟到结果不会污染新歌曲的系统封面。
      unawaited(_refreshArtworkForCurrentTrack());
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
