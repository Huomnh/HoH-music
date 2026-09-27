/// widget_kit.dart
///
/// HoH music 原生玻璃效果组件库（架构文档 1.4 UI 设计方向）。
///
/// 对应架构文档目录树中的 `core/plugin/theme/widget_kit/`（声明式 UI 组件库）。
/// 这里是它的**共享实现**，放在 `shared/widgets/` 下，
/// 供后续主题引擎插件层与业务层共同复用。
///
/// 一次导入全部效果组件：
/// ```dart
/// import 'package:hoh_music/shared/widgets/widget_kit/widget_kit.dart';
/// ```
///
/// 全部基于 Flutter 原生绘制能力实现，**未使用任何第三方玻璃/模糊包**：
/// - 毛玻璃模糊 → BackdropFilter + ImageFilter.blur
/// - 霓虹渐变   → LinearGradient / RadialGradient + ShaderMask
/// - 边缘高光   → DecoratedBox 多层渐变叠加
/// - 圆角大卡片 → ClipRRect + BorderRadius
/// - 流光动效   → AnimationController + ShaderMask
/// - 旋转描边光 → SweepGradient + 30Hz 共享高光时钟
/// - 背景场景   → 程序化 CustomPainter（见 `background_scenes.dart`）
library;

export 'background_scenes.dart';
export 'blur_config_scope.dart';
export 'glass_blur.dart';
export 'glass_border.dart';
export 'glass_material.dart';
export 'glass_panel.dart';
export 'glass_surface.dart';
export 'neon_background.dart';
