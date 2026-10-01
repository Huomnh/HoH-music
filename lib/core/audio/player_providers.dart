/// player_providers.dart
///
/// 播放状态到 UI 的桥接层（Riverpod）。
///
/// 设计要点（对应架构文档 2.2）：
/// **音频状态独立 Provider 隔离**——播放器每秒推送多次进度更新，
/// 如果让整个页面都监听它，界面会被高频重建。
/// 这里只把「进度」单独做成一个细粒度 provider，
/// 进度条订阅它，其余组件不受影响。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart'
    show FilePicker, FileType, PlatformFile;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// media_kit 也导出一个 Track（媒体轨道），与本文件的 Track（曲目）同名，隐藏之
import 'package:media_kit/media_kit.dart' hide Track;

import 'playback_prefs.dart';
import 'player_engine.dart';

export 'playback_prefs.dart' show PlaybackMode;

/// 播放引擎单例。
final playerEngineProvider = Provider<PlayerEngine>((ref) {
  return PlayerEngine.instance;
});

/// 播放器整体状态。
///
/// 音量刻意用 **0~1** 表示（UI 单位）。media_kit 用的是 0~100，
/// 转换只在 [PlayerController] 边界发生，界面代码不需要知道底层量纲。
@immutable
class PlayerUiState {
  /// 创建状态快照。
  const PlayerUiState({
    this.queue = const <Track>[],
    this.currentIndex = -1,
    this.playing = false,
    this.buffering = false,
    this.duration = Duration.zero,
    this.volume = 0.8,
    this.completed = false,
    this.mode = PlaybackMode.repeatAll,
  });

  /// 当前队列。
  final List<Track> queue;

  /// 正在播放的索引。
  final int currentIndex;

  /// 是否正在播放。
  final bool playing;

  /// 是否正在缓冲。
  final bool buffering;

  /// 当前曲目时长。
  final Duration duration;

  /// 音量，0~1。
  final double volume;

  /// 当前曲目是否播完。
  final bool completed;

  /// 播放模式（顺序 / 列表循环 / 单曲循环 / 随机）。
  final PlaybackMode mode;

  /// 当前曲目。队列为空时为 null。
  Track? get currentTrack {
    if (currentIndex < 0 || currentIndex >= queue.length) return null;
    return queue[currentIndex];
  }

  /// 队列是否为空。
  bool get isEmpty => queue.isEmpty;

  /// 复制并覆盖部分字段。
  PlayerUiState copyWith({
    List<Track>? queue,
    int? currentIndex,
    bool? playing,
    bool? buffering,
    Duration? duration,
    double? volume,
    bool? completed,
    PlaybackMode? mode,
  }) {
    return PlayerUiState(
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      playing: playing ?? this.playing,
      buffering: buffering ?? this.buffering,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      completed: completed ?? this.completed,
      mode: mode ?? this.mode,
    );
  }
}

/// 播放状态的控制器。
///
/// 订阅底层引擎的事件流，把 MediaKit 的状态翻译成 [PlayerUiState]。
class PlayerController extends Notifier<PlayerUiState> {
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  PlayerEngine get _engine => ref.read(playerEngineProvider);

  @override
  PlayerUiState build() {
    // media_kit 的状态是「一组按字段拆分的流」，这里逐条订阅并各自映射到
    // PlayerUiState 的对应字段。高频的 position 不在这里，见
    // playbackPositionProvider——避免每秒多次重建整个页面。
    //
    // ⚠️ 这些流需要 media_kit 的解码后端已初始化。组件测试环境里没有原生库，
    // 此时订阅会抛异常；界面应退化为「可显示、不可播放」而不是直接崩掉。
    try {
      _subs.addAll(<StreamSubscription<Object?>>[
        _engine.playingStream.listen(
          (bool v) => state = state.copyWith(playing: v),
        ),
        _engine.bufferingStream.listen(
          (bool v) => state = state.copyWith(buffering: v),
        ),
        _engine.durationStream.listen(
          (Duration v) => state = state.copyWith(duration: v),
        ),
        _engine.playlistStream.listen((Playlist p) {
          final bool trackChanged = p.index != state.currentIndex;
          state = state.copyWith(currentIndex: p.index, completed: false);

          // 换歌了 → 把"等下一首生效"的播放模式落下去。
          // 这时用户本来就会看到曲目信息变化，不算"点按钮把歌换掉了"。
          final PlaybackMode? pending = _pendingMode;
          if (trackChanged && pending != null) {
            _pendingMode = null;
            _applyModeToEngine(pending);
            _logger('播放模式「${pending.label}」已生效');
          }
        }),
        _engine.completedStream.listen((bool done) {
          state = state.copyWith(completed: done);
        }),
        _engine.volumeStream.listen(
          // media_kit 的音量是 0~100，UI 统一用 0~1
          (double v) =>
              state = state.copyWith(volume: (v / 100).clamp(0.0, 1.0)),
        ),
      ]);
      _logger('播放状态流已订阅');
    } catch (error) {
      // 只在调试期提示，不向用户抛错
      debugPrint('[PlayerController] 无法订阅播放状态流（引擎未就绪）：$error');
    }

    // 队列被替换。队列由引擎自己维护，不依赖 media_kit 后端。
    _subs.add(
      _engine.queueStream.listen(
        (List<Track> q) => state = state.copyWith(queue: q),
      ),
    );

    // 单条曲目信息在后台补全
    _subs.add(
      _engine.trackInfoStream.listen((Track track) {
        final List<Track> next = List<Track>.from(state.queue);
        final int idx = next.indexWhere((Track t) => t.id == track.id);
        if (idx >= 0) {
          next[idx] = track;
          state = state.copyWith(queue: next);
        }
      }),
    );

    ref.onDispose(() {
      for (final StreamSubscription<Object?> s in _subs) {
        s.cancel();
      }
      _subs.clear();
    });

    // 恢复上次的音量 / 随机 / 循环（读盘异步，回来后写进 state 与引擎）
    unawaited(_restorePrefs());

    // 初始快照只取队列——读取 _engine.state 会强制创建 Player 实例，
    // 在引擎未初始化时会抛异常。
    return PlayerUiState(queue: _engine.queue);
  }

  Future<void> _restorePrefs() async {
    final PlaybackPrefs prefs = await PlaybackPrefs.load();
    if (!ref.mounted) return;

    // 启动时没有"正在播放的歌"，模式直接生效
    setPlaybackMode(prefs.mode, persist: false);

    // 音量：先写进 UI 状态，再推给引擎（引擎未就绪就只留状态）
    state = state.copyWith(volume: prefs.volume);
    try {
      // 引擎的音量是 media_kit 量纲（0~100），别直接传 0~1
      await _engine.setVolume(prefs.volume * 100);
    } catch (error) {
      _logger('恢复音量失败（引擎未就绪）：$error');
    }
    _logger(
      '已恢复播放偏好：音量 ${(prefs.volume * 100).round()}% / ${prefs.mode.label}',
    );
  }

  /// 待生效的播放模式。
  ///
  /// ⚠️ **点模式按钮不立刻改引擎**（0.0.16 的行为）：
  /// `setShuffle` 会重排播放列表、把"正在播放的那首"换掉，
  /// 用户点了按钮却发现歌变了。所以这里只记下意图，
  /// 等**下一首真正开始**（或本来就没在播）时才应用。
  PlaybackMode? _pendingMode;

  /// 设置播放模式。
  ///
  /// [persist] 为 false 时只改状态（启动恢复用）。
  void setPlaybackMode(PlaybackMode mode, {bool persist = true}) {
    final bool changed = state.mode != mode;
    state = state.copyWith(mode: mode);
    if (persist && changed) unawaited(PlaybackPrefs.saveMode(mode));

    if (state.currentTrack == null) {
      // 没在播 → 立即生效
      _applyModeToEngine(mode);
      _pendingMode = null;
      return;
    }

    if (changed) {
      _pendingMode = mode;
      _logger('播放模式已切换为「${mode.label}」，将在下一首生效');
    }
  }

  /// 模式按钮：四挡循环。
  void cyclePlaybackMode() {
    final PlaybackMode next = switch (state.mode) {
      PlaybackMode.sequential => PlaybackMode.repeatAll,
      PlaybackMode.repeatAll => PlaybackMode.repeatOne,
      PlaybackMode.repeatOne => PlaybackMode.shuffle,
      PlaybackMode.shuffle => PlaybackMode.sequential,
    };
    setPlaybackMode(next);
  }

  /// 把模式落到 media_kit。
  void _applyModeToEngine(PlaybackMode mode) {
    try {
      switch (mode) {
        case PlaybackMode.sequential:
          unawaited(_engine.setShuffleMode(false));
          unawaited(_engine.setReplayMode(PlaybackMode.sequential));
        case PlaybackMode.repeatAll:
          unawaited(_engine.setShuffleMode(false));
          unawaited(_engine.setReplayMode(PlaybackMode.repeatAll));
        case PlaybackMode.repeatOne:
          unawaited(_engine.setShuffleMode(false));
          unawaited(_engine.setReplayMode(PlaybackMode.repeatOne));
        case PlaybackMode.shuffle:
          // 用**引擎自管的随机顺序**（0.0.41）：不用 media_kit 的 setShuffle，
          // 它会把内部播放列表重排，导致"随机模式下点歌点不对"。
          unawaited(_engine.setShuffleMode(true));
          // 随机 + 列表循环：最符合"随机播放"的直觉
          unawaited(_engine.setReplayMode(PlaybackMode.repeatAll));
      }
    } catch (error) {
      _logger('应用播放模式失败：$error');
    }
  }

  /// 当前音量上加减（全局快捷键用）。
  void stepVolume(double delta) {
    final double next = (state.volume + delta).clamp(0.0, 1.0);
    setVolume(next);
  }

  void _logger(String message) => debugPrint('[PlayerController] $message');

  /// 选择本地音乐**文件**加入队列并播放，返回加入的曲目数量。
  ///
  /// 用户取消或没选到有效文件时返回 0。
  ///
  /// ⚠️ file_picker 13 的 API 注意点（0.0.14 更正）：
  /// - 没有 `allowMultiple` 参数 —— Windows 实现里已经写死多选，直接调 `pickFiles()` 即可；
  /// - **不要用 `pickFileAndDirectoryPaths()`**：它在 Windows 上返回 `Uri.path`
  ///   （百分号编码 + 多余前导斜杠），中文/空格文件名会变成 `%E5%8D%8A...`。
  ///   `pickFiles()` 的 `PlatformFile.path` 走 `Uri.toFilePath()`，才是真路径；
  /// - 取消时返回空列表，而不是早期版本的可空 `FilePickerResult`。
  Future<int> pickFilesAndPlay() async {
    final List<PlatformFile> picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: kSupportedAudioExtensions.toList(),
      dialogTitle: '选择要播放的音乐文件（可多选）',
    );
    final List<String> paths = picked
        .map((PlatformFile file) => file.path)
        .whereType<String>()
        .toList();
    debugPrint('[PlayerController] 文件选择框返回 ${paths.length} 个路径');
    return _loadPaths(paths);
  }

  /// 选择一个**文件夹**，递归扫描其中的音频文件并播放。
  ///
  /// 对应「播放本地文件夹音乐」的用法：选一个音乐目录，
  /// 子目录里的歌也会一并收进来。
  Future<int> pickFolderAndPlay() async {
    final String? folder = await FilePicker.getDirectoryPath(
      dialogTitle: '选择音乐文件夹（会递归扫描子目录）',
    );
    debugPrint('[PlayerController] 文件夹选择框返回：$folder');
    if (folder == null || folder.isEmpty) return 0;
    return _loadPaths(<String>[folder]);
  }

  /// 载入一个文件夹（递归扫描）并开始播放。
  ///
  /// 与 [pickFolderAndPlay] 分开，是为了让"选文件夹"这件事能由调用方先做
  /// （界面需要拿到路径才能写进音乐库）。
  Future<int> playFolder(String folder) => _loadPaths(<String>[folder]);

  /// 载入多个路径并开始播放。
  ///
  /// 路径可以是**文件夹**（递归扫描）或**音频文件**（直接进队列）——
  /// 音乐库里两种记录混在一起，启动恢复与「载入音乐库」都走这里。
  Future<int> playPaths(List<String> paths) => _loadPaths(paths);

  /// 只把路径**载入队列**，不开始播放（「启动后自动载入」用）。
  ///
  /// 引擎侧本来就有 `autoPlay` 开关（`player.open(..., play: false)`），
  /// 所以这里不会出现"先响一声再暂停"。
  Future<int> loadPathsOnly(List<String> paths) =>
      _loadPaths(paths, autoPlay: false);

  /// 从路径加载并返回成功加入的数量。失败会打日志并向上抛出。
  Future<int> _loadPaths(List<String> paths, {bool autoPlay = true}) async {
    if (paths.isEmpty) return 0;
    final List<File> loaded = await _engine.loadPaths(
      paths,
      autoPlay: autoPlay,
    );
    debugPrint(
      '[PlayerController] 实际加入队列：${loaded.length} 首'
      '${autoPlay ? "" : "（不自动播放）"}',
    );
    return loaded.length;
  }

  /// 播放队列中指定位置。
  Future<void> playAt(int index) => _engine.playAt(index);

  /// 从播放队列移除曲目，不删除本地文件。
  Future<void> removeQueueAt(int index) => _engine.removeQueueAt(index);

  /// 大曲库首播的低延迟入口。
  Future<void> playLocalTracksFast(
    List<Track> tracks, {
    int startIndex = 0,
    bool autoPlay = true,
  }) => _engine.loadLocalTracksFast(
    tracks,
    startIndex: startIndex,
    autoPlay: autoPlay,
  );

  /// 播放一批**远端**曲目（WebDAV 流式播放）。
  ///
  /// ⚠️ 用户明确要求：**不下载到本地**，每次播放都从网盘直接取。
  /// 曲名 / 艺术家由调用方从文件名与目录名推导（远端没有本地标签可读）。
  Future<int> playRemoteTracks(
    List<Track> tracks, {
    Map<String, String>? httpHeaders,
    int startIndex = 0,
  }) async {
    if (tracks.isEmpty) return 0;
    await _engine.loadRemoteTracks(
      tracks,
      startIndex: startIndex,
      httpHeaders: httpHeaders,
    );
    return tracks.length;
  }

  /// **追加**一批曲目到队列（不打断当前播放）。
  ///
  /// 「添加到播放队列」按钮、以及"从搜索 / WebDAV 来源点播放"都走这里 ——
  /// 用户的要求是这些来源**补充**队列，而不是替换。
  /// [autoPlayIndex] 给了就是"点播"语义：追加完跳到那一首直接播。
  Future<int> enqueueTracks(
    List<Track> tracks, {
    Map<String, String>? httpHeaders,
    int? autoPlayIndex,
  }) => _engine.enqueueTracks(
    tracks,
    httpHeaders: httpHeaders,
    autoPlayIndex: autoPlayIndex,
  );

  /// 播放队列里的某个曲目**对象**（曲库页面拿的是 `Track`，不是下标）。  ///
  /// 队列里找不到就什么也不做 —— 等接上"全库扫描"再把"从库里找出来塞进队列"补上。
  Future<void> playTrackObject(Track track) async {
    final int index = state.queue.indexWhere((Track t) => t.id == track.id);
    if (index < 0) return;
    await playAt(index);
  }

  /// 播放 / 暂停。
  Future<void> togglePlayPause() => _engine.togglePlayPause();

  /// 下一首。
  Future<void> next() => _engine.next();

  /// 上一首。
  Future<void> previous() => _engine.previous();

  /// 跳转播放位置。
  Future<void> seek(Duration position) => _engine.seek(position);

  /// 调整音量。入参为 0~1，内部换算成 media_kit 的 0~100。
  ///
  /// 顺便持久化：拖滑杆会连续产生很多次调用，所以做 600ms 防抖，
  /// 松手之后才写一次盘。
  Future<void> setVolume(double volume) async {
    final double clamped = volume.clamp(0.0, 1.0);
    state = state.copyWith(volume: clamped);

    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(PlaybackPrefs.saveVolume(clamped)),
    );

    await _engine.setVolume(clamped * 100);
  }

  Timer? _volumeSaveTimer;
}

/// 播放状态 provider。
final playerControllerProvider =
    NotifierProvider<PlayerController, PlayerUiState>(PlayerController.new);

/// 播放位置（高频更新，单独隔离）。
///
/// 只有进度条与时间文字监听它，避免每秒多次重建整个页面。
final playbackPositionProvider = StreamProvider<Duration>((ref) {
  final PlayerEngine engine = ref.watch(playerEngineProvider);
  return engine.positionStream.distinct();
});
