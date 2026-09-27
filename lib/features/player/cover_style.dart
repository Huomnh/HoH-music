/// cover_style.dart
///
/// 封面舞台（黑胶 + 方形专辑封面）的样式设置。
///
/// 参考《播放页「黑胶复古」主题封面动效组件》方案 A：
/// 旋转层（黑胶圆盘 + 圆心专辑封面）与固定层（方形封面）分离。
/// 这里只放**用户可调**的两项：黑胶往哪边伸、是否开启旋转。
/// 其余视觉参数是常量（见 `cover_stage.dart`），后续接主题引擎时
/// 再抽成 `VinylThemeConfig` 从 JSON 读。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 封面舞台样式。
///
/// 0.0.20：黑胶从封面区搬走，不再有"伸出方向"这种设置，
/// 只剩"要不要转"。枚举 `VinylSide` 已随之删除。
/// 0.0.21：黑胶落到侧边栏顶部的控制台里（转速 6 秒/圈）。
@immutable
class CoverStageStyle {
  /// 创建样式。
  const CoverStageStyle({this.spin = true});

  /// 是否开启黑胶旋转（关掉后整块静止，省 GPU）。
  final bool spin;

  CoverStageStyle copyWith({bool? spin}) =>
      CoverStageStyle(spin: spin ?? this.spin);

  @override
  bool operator ==(Object other) =>
      other is CoverStageStyle && other.spin == spin;

  @override
  int get hashCode => spin.hashCode;
}

/// 封面舞台样式（持久化）。
final coverStageStyleProvider =
    AsyncNotifierProvider<CoverStageStyleController, CoverStageStyle>(
      CoverStageStyleController.new,
    );

/// 封面舞台样式控制器。
class CoverStageStyleController extends AsyncNotifier<CoverStageStyle> {
  static const String _spinKey = 'cover.spin';

  @override
  Future<CoverStageStyle> build() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return CoverStageStyle(spin: prefs.getBool(_spinKey) ?? true);
    } catch (error) {
      debugPrint('[Cover] 读取封面样式失败（用默认）：$error');
      return const CoverStageStyle();
    }
  }

  /// 开关黑胶旋转。
  Future<void> setSpin(bool spin) async {
    state = AsyncData<CoverStageStyle>(
      (state.value ?? const CoverStageStyle()).copyWith(spin: spin),
    );
    await _write((SharedPreferences p) => p.setBool(_spinKey, spin));
  }

  Future<void> _write(
    Future<void> Function(SharedPreferences prefs) action,
  ) async {
    try {
      await action(await SharedPreferences.getInstance());
    } catch (error) {
      debugPrint('[Cover] 保存封面样式失败：$error');
    }
  }
}
