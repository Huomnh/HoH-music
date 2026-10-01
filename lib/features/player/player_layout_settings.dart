/// 播放页控制区布局设置。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放页两种共享布局。
///
/// 这只是 Flutter UI 的排布选择，不绑定窗口、鼠标或 Windows API；移动端、
/// TV 和桌面端可以复用同一份状态与动画，平台差异留给外层窗口适配处理。
enum PlayerControlLayout {
  sidebar('侧栏控制', '控制区固定在左侧，适合宽屏播放'),
  bottom('底部控制', '控制区横向放在页面下方，歌词与内容更宽');

  const PlayerControlLayout(this.label, this.description);

  final String label;
  final String description;

  static PlayerControlLayout fromStoredName(String? name) => values.firstWhere(
    (PlayerControlLayout value) => value.name == name,
    orElse: () => PlayerControlLayout.bottom,
  );
}

final playerControlLayoutProvider =
    AsyncNotifierProvider<PlayerControlLayoutController, PlayerControlLayout>(
      PlayerControlLayoutController.new,
    );

/// 持久化播放页布局，并在设置改变后立即通知主界面。
class PlayerControlLayoutController extends AsyncNotifier<PlayerControlLayout> {
  static const String _key = 'appearance.playerControlLayout';

  @override
  Future<PlayerControlLayout> build() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return PlayerControlLayout.fromStoredName(prefs.getString(_key));
  }

  Future<void> setLayout(PlayerControlLayout layout) async {
    state = AsyncData<PlayerControlLayout>(layout);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, layout.name);
  }
}
