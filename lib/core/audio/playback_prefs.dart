/// playback_prefs.dart
///
/// 播放器偏好的持久化：音量 / 随机 / 循环模式 / 输出通道。
///
/// 都是"用户调过一次就该记住"的东西，用 `shared_preferences`。
/// 读写全部包在 try/catch 里：测试环境或平台不支持时按默认值走，不影响播放。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放模式（**一个按钮循环切换**，0.0.16 起把随机与循环合并成它）。
///
/// 四种模式互斥，映射到 media_kit 的组合：
///
/// | 模式 | shuffle | PlaylistMode |
/// |---|---|---|
/// | 顺序播放 | 关 | none |
/// | 列表循环 | 关 | loop |
/// | 单曲循环 | 关 | single |
/// | 随机播放 | 开 | loop（随机 + 列表循环，最符合直觉） |
enum PlaybackMode {
  /// 顺序播放，播完队列停止。
  sequential('顺序播放', '播完队列停止'),

  /// 列表循环。
  repeatAll('列表循环', '播完从头再来'),

  /// 单曲循环。
  repeatOne('单曲循环', '一直重复这一首'),

  /// 随机播放。
  shuffle('随机播放', '随机挑下一首');

  const PlaybackMode(this.label, this.description);

  /// 界面显示名。
  final String label;

  /// 一句话说明。
  final String description;
}

/// 播放器偏好。
@immutable
class PlaybackPrefs {
  /// 创建偏好。
  const PlaybackPrefs({
    this.volume = 0.8,
    this.mode = PlaybackMode.repeatAll,
    this.audioDeviceName = 'auto',
  });

  /// 音量（0~1）。
  final double volume;

  /// 播放模式。
  final PlaybackMode mode;

  /// 输出通道名称；`auto` 表示交给系统选择默认输出设备。
  final String audioDeviceName;

  /// 从磁盘读取；失败返回默认值。
  ///
  /// 兼容 0.0.15 的旧键（`playback.shuffle` + `playback.replay`）：
  /// 随机开 → 随机播放；否则按 replay 映射。读到就顺手写成新键。
  static Future<PlaybackPrefs> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      PlaybackMode mode;
      final String? modeName = prefs.getString('playback.mode');
      if (modeName != null) {
        mode = PlaybackMode.values.firstWhere(
          (PlaybackMode m) => m.name == modeName,
          orElse: () => PlaybackMode.repeatAll,
        );
      } else if (prefs.getBool('playback.shuffle') ?? false) {
        mode = PlaybackMode.shuffle;
      } else {
        mode = switch (prefs.getString('playback.replay')) {
          'all' => PlaybackMode.repeatAll,
          'one' => PlaybackMode.repeatOne,
          _ => PlaybackMode.repeatAll,
        };
      }

      return PlaybackPrefs(
        volume: (prefs.getDouble('playback.volume') ?? 0.8).clamp(0.0, 1.0),
        mode: mode,
        audioDeviceName: prefs.getString('playback.audioDevice') ?? 'auto',
      );
    } catch (error) {
      debugPrint('[PlaybackPrefs] 读取失败（用默认值）：$error');
      return const PlaybackPrefs();
    }
  }

  /// 保存音量。
  static Future<void> saveVolume(double volume) =>
      _write((SharedPreferences p) => p.setDouble('playback.volume', volume));

  /// 保存播放模式。
  static Future<void> saveMode(PlaybackMode mode) =>
      _write((SharedPreferences p) => p.setString('playback.mode', mode.name));

  /// 保存输出通道名称。
  static Future<void> saveAudioDeviceName(String name) => _write(
    (SharedPreferences p) => p.setString('playback.audioDevice', name),
  );

  static Future<void> _write(
    Future<void> Function(SharedPreferences prefs) action,
  ) async {
    try {
      await action(await SharedPreferences.getInstance());
    } catch (error) {
      debugPrint('[PlaybackPrefs] 保存失败：$error');
    }
  }
}
