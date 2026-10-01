/// smtc_service.dart
///
/// Windows **SMTC**（System Media Transport Controls）—— 系统媒体控制中心。
///
/// 接上之后能拿到这些系统级能力（对应架构文档 3.9）：
/// - 按音量键 / 媒体键弹出的那个「正在播放」浮层显示曲名 / 艺术家 / 专辑，
///   以及进度条（`PlaybackTimeline`）；
/// - 浮层上的播放 / 暂停 / 上一首 / 下一首**按钮反过来控制本应用**；
/// - 蓝牙耳机、键盘多媒体键、Xbox 手柄的媒体键都走这条链路。
///
/// 实现基于 `smtc_windows`（Rust 插件，flutter_rust_bridge + cargokit）。
/// ⚠️ **它要求本机装好 rustup**，否则 `flutter build windows` 会在
/// `smtc_windows_cargokit.vcxproj` 报 MSB8066（0.0.24 之前就是因此停用的）。
///
/// ⚠️ SMTC 只在真的把曲目推上去之后才会出现在系统里；`dispose()` 会清掉。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smtc_windows/smtc_windows.dart';

import '../../core/audio/player_providers.dart';

/// 诊断日志走 stderr：`debugPrint` 带节流，启动早期会丢行。
void _log(String message) => stderr.writeln('[SMTC] $message');

/// 系统浮层按钮 → 应用动作。
class SmtcActions {
  const SmtcActions({
    required this.onPlay,
    required this.onPause,
    required this.onNext,
    required this.onPrevious,
  });

  /// 播放（系统要求开始播放）。
  final VoidCallback onPlay;

  /// 暂停。
  final VoidCallback onPause;

  /// 下一首。
  final VoidCallback onNext;

  /// 上一首。
  final VoidCallback onPrevious;
}

/// 系统媒体控制中心。
class SmtcService {
  SmtcService._();

  /// 单例：整个进程只应有一个 SMTC 会话。
  static final SmtcService instance = SmtcService._();

  /// 当前平台是否支持。
  static bool get isSupported => !kIsWeb && Platform.isWindows;

  SMTCWindows? _smtc;
  StreamSubscription<PressedButton>? _buttons;

  /// 上次推送过的内容，用来避免重复调用原生（每次都是一次跨 FFI 调用）。
  String? _pushedTitle;
  String? _pushedArtist;
  String? _pushedAlbum;
  bool? _pushedPlaying;
  int _pushedPositionSecond = -1;
  int _pushedDurationSecond = -1;

  /// 是否已经接上系统。
  bool get isReady => _smtc != null;

  /// 接入系统媒体控制。失败**不影响播放**，只打日志并返回 false。
  Future<bool> setup({required SmtcActions actions}) async {
    if (!isSupported) {
      _log('当前平台不支持，跳过');
      return false;
    }
    if (_smtc != null) return true;

    // 组件测试里既没有原生库也不该起 Rust 运行时
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      _log('测试环境，跳过');
      return false;
    }
    try {
      await SMTCWindows.initialize();
      final SMTCWindows smtc = SMTCWindows(
        config: const SMTCConfig(
          playEnabled: true,
          pauseEnabled: true,
          // 本项目没有"停止"语义（停止=清空队列），别给系统这个按钮
          stopEnabled: false,
          nextEnabled: true,
          prevEnabled: true,
          // 快进 / 快退在系统浮层上是 ±30s，本应用暂不支持，先关掉
          fastForwardEnabled: false,
          rewindEnabled: false,
        ),
        metadata: const MusicMetadata(title: 'HoH music'),
        timeline: const PlaybackTimeline(
          startTimeMs: 0,
          endTimeMs: 0,
          positionMs: 0,
        ),
        status: PlaybackStatus.stopped,
      );
      _smtc = smtc;

      _buttons = smtc.buttonPressStream.listen(
        (PressedButton button) => _handleButton(button, actions),
        onError: (Object error) => _log('按钮事件流出错：$error'),
      );

      _log('已接入系统媒体控制（播放/暂停/上一首/下一首）');
      return true;
    } catch (error, stack) {
      _log('初始化失败（不影响播放）：$error');
      stderr.writeln('$stack');
      _smtc = null;
      return false;
    }
  }

  void _handleButton(PressedButton button, SmtcActions actions) {
    switch (button) {
      case PressedButton.play:
        actions.onPlay();
      case PressedButton.pause:
        actions.onPause();
      case PressedButton.next:
        actions.onNext();
      case PressedButton.previous:
        actions.onPrevious();
      case PressedButton.stop:
      case PressedButton.fastForward:
      case PressedButton.rewind:
      case PressedButton.record:
      case PressedButton.channelUp:
      case PressedButton.channelDown:
        // 没在 config 里开启的按钮不该来；真来了就忽略，别乱动播放状态
        break;
    }
  }

  /// 把「正在播放」推给系统。
  ///
  /// ⚠️ 会被高频调用（进度每秒变一次），所以这里**逐项比对**，
  /// 只有真的变了才走 FFI，避免每秒一堆原生调用。
  Future<void> updateNowPlaying({
    required String? title,
    required String? artist,
    required String? album,
    required bool playing,
    required bool hasTrack,
    required Duration position,
    required Duration duration,
  }) async {
    final SMTCWindows? smtc = _smtc;
    if (smtc == null) return;

    try {
      // ① 元数据：换歌才推
      final String nowTitle = title ?? '';
      final String nowArtist = artist ?? '';
      final String nowAlbum = album ?? '';
      if (nowTitle != _pushedTitle ||
          nowArtist != _pushedArtist ||
          nowAlbum != _pushedAlbum) {
        _pushedTitle = nowTitle;
        _pushedArtist = nowArtist;
        _pushedAlbum = nowAlbum;
        await smtc.updateMetadata(
          MusicMetadata(
            title: nowTitle.isEmpty ? 'HoH music' : nowTitle,
            artist: nowArtist.isEmpty ? null : nowArtist,
            album: nowAlbum.isEmpty ? null : nowAlbum,
            albumArtist: nowArtist.isEmpty ? null : nowArtist,
          ),
        );
      }

      // ② 播放状态：只有变的时候推（否则系统浮层会闪）
      if (_pushedPlaying != playing) {
        _pushedPlaying = playing;
        await smtc.setPlaybackStatus(
          playing ? PlaybackStatus.playing : PlaybackStatus.paused,
        );
      }

      // ③ 进度：整秒变化才推
      final int positionSecond = position.inSeconds;
      final int durationSecond = duration.inSeconds;
      if (positionSecond != _pushedPositionSecond ||
          durationSecond != _pushedDurationSecond) {
        _pushedPositionSecond = positionSecond;
        _pushedDurationSecond = durationSecond;
        await smtc.updateTimeline(
          PlaybackTimeline(
            startTimeMs: 0,
            endTimeMs: duration.inMilliseconds,
            positionMs: position.inMilliseconds,
            minSeekTimeMs: 0,
            maxSeekTimeMs: hasTrack ? duration.inMilliseconds : 0,
          ),
        );
      }
    } catch (error) {
      _log('推送播放状态失败：$error');
    }
  }

  /// 清空并断开（退出前调用）。
  Future<void> dispose() async {
    await _buttons?.cancel();
    _buttons = null;
    final SMTCWindows? smtc = _smtc;
    _smtc = null;
    if (smtc == null) return;
    try {
      await smtc.clearMetadata();
      await smtc.disableSmtc();
      await smtc.dispose();
      _log('已断开系统媒体控制');
    } catch (error) {
      _log('断开失败（忽略）：$error');
    }
  }
}

/// 把 SMTC 接到应用上。
///
/// 挂在 `MaterialApp` 内层（需要访问 Riverpod 里的播放器控制器），
/// 与 `TrayHost` / `HotkeyHost` 同一套写法。
class SmtcHost extends ConsumerStatefulWidget {
  const SmtcHost({super.key, required this.child});

  /// 被包裹的子树。
  final Widget child;

  /// 当前平台是否支持。
  static bool get isSupported => SmtcService.isSupported;

  @override
  ConsumerState<SmtcHost> createState() => _SmtcHostState();
}

class _SmtcHostState extends ConsumerState<SmtcHost> {
  @override
  void initState() {
    super.initState();
    if (!SmtcHost.isSupported) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_setup()));
  }

  Future<void> _setup() async {
    if (!mounted) return;
    final bool ok = await SmtcService.instance.setup(
      actions: SmtcActions(
        // 系统让播就播、让停就停（不要无脑 toggle，否则状态会反）
        onPlay: _play,
        onPause: _pause,
        onNext: () => ref.read(playerControllerProvider.notifier).next(),
        onPrevious: () =>
            ref.read(playerControllerProvider.notifier).previous(),
      ),
    );
    if (!ok) {
      _log('没有 SMTC：音量键浮层不会显示本应用');
      return;
    }
    _sync();
  }

  void _play() {
    if (!ref.read(playerControllerProvider).playing) {
      unawaited(ref.read(playerControllerProvider.notifier).togglePlayPause());
    }
  }

  void _pause() {
    if (ref.read(playerControllerProvider).playing) {
      unawaited(ref.read(playerControllerProvider.notifier).togglePlayPause());
    }
  }

  /// 把当前播放状态推给系统。
  void _sync() {
    final PlayerUiState state = ref.read(playerControllerProvider);
    final Duration position =
        ref.read(playbackPositionProvider).value ?? Duration.zero;
    final Duration total = state.duration > Duration.zero
        ? state.duration
        : (state.currentTrack?.duration ?? Duration.zero);
    unawaited(
      SmtcService.instance.updateNowPlaying(
        title: state.currentTrack?.title,
        artist: state.currentTrack?.artist,
        album: state.currentTrack?.album,
        playing: state.playing,
        hasTrack: state.currentTrack != null,
        position: position,
        duration: total,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(SmtcService.instance.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 换歌 / 播放状态 / 进度，任何一种变化都同步给系统（内部按项去重）
    ref.listen(playerControllerProvider, (
      PlayerUiState? prev,
      PlayerUiState next,
    ) {
      _sync();
    });
    ref.listen(playbackPositionProvider, (
      AsyncValue<Duration>? prev,
      AsyncValue<Duration> next,
    ) {
      _sync();
    });
    return widget.child;
  }
}
