/// glass_surface.dart
///
/// 玻璃表面组合组件——把模糊、色调、高光、描边、光晕叠成一块完整玻璃。
///
/// 全部基于 Flutter 原生绘制能力（BackdropFilter / ImageFilter / gradient /
/// CustomPainter / ShaderMask），**未引入任何第三方玻璃或模糊效果包**。
///
/// 0.0.8 起去掉了「磨砂噪点」层：逐像素画点在那点观感收益上不划算，
/// 与 `GlassPanel` 的实际用法保持一致。
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/performance_tier.dart';
import 'blur_config_scope.dart';
import 'glass_blur.dart';
import 'glass_border.dart';
import 'glass_material.dart';

/// 玻璃表面。
///
/// 绘制层次（由下到上）：
/// 1. 背景模糊 —— [BackdropFilter]，把身后已绘制的像素糊掉；
/// 2. 色调 —— 低透明度白 + 纵向渐变，产生厚度；
/// 3. 边缘高光 —— 左上亮、右下暗的折射感；
/// 4. 渐变描边 —— 1px 亮边勾出玻璃轮廓；
/// 5. 外发光 —— 可选的霓虹光晕。
///
/// 各参数默认取当前 [BlurConfigScope] 的档位参数，也可以逐个显式覆盖。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.blurSigma,
    this.tint,
    this.tintGradient,
    this.highlight = true,
    this.border = true,
    this.borderGradient,
    this.borderWidth = 1.0,
    this.glowColor,
    this.glowStrength,
    this.padding = const EdgeInsets.all(20),
    this.margin,
    this.width,
    this.height,
    this.clipContent = true,
    this.useConfig = true,
    this.borderGradientEnabled = true,
    this.interactive = false,
  });

  /// 玻璃承载的内容。
  final Widget child;

  /// 圆角半径。[clipContent] 为 true 时同时用于裁剪。
  final BorderRadius borderRadius;

  /// 模糊强度。null 时取 [BlurConfigScope] 的值。
  final double? blurSigma;

  /// 底色。null 时使用 [AppColors.glassFill]。
  final Color? tint;

  /// 覆盖默认的纵向渐变色调。
  final Gradient? tintGradient;

  /// 是否绘制边缘高光（还要看档位是否允许）。
  final bool highlight;

  /// 是否绘制渐变描边。
  final bool border;

  /// 描边渐变。
  final Gradient? borderGradient;

  /// 描边宽度。
  final double borderWidth;

  /// 外发光颜色。null 表示不发光。
  final Color? glowColor;

  /// 外发光强度。null 时取档位的 [BlurConfig.neonStrength]。
  final double? glowStrength;

  /// 内边距。
  final EdgeInsetsGeometry padding;

  /// 外边距。
  final EdgeInsetsGeometry? margin;

  /// 固定宽度。
  final double? width;

  /// 固定高度。
  final double? height;

  /// 是否把内容裁剪进圆角。需要内容溢出玻璃边界时传 false。
  final bool clipContent;

  /// 是否读取 [BlurConfigScope] 的档位参数。false 表示完全按显式参数渲染。
  final bool useConfig;

  /// 是否启用默认描边渐变（false 时用单色淡描边）。
  final bool borderGradientEnabled;

  /// 交互模式。
  ///
  /// 为 true 时会在内容**下方**垫一层色调，而不再在内容上方叠加噪点与高光。
  /// 原因：Flutter 的命中测试是「后绘制者先命中」，盖在内容之上的覆盖层
  /// 会挡住子组件（如按钮）的点击与悬停反馈。需要放可点控件时传 true。
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final BlurConfig config = useConfig
        ? BlurConfigScope.of(context)
        : BlurConfig.forTier(PerformanceTier.high);

    final double sigma = blurSigma ?? config.blurSigma;
    final bool highlightOn = highlight && config.highlightEnabled;
    final double glow = glowStrength ?? config.neonStrength;

    // 内容用内边距包住，使留白落在玻璃内部（而不是玻璃外部）
    Widget content = Padding(padding: padding, child: child);

    // 需要内容溢出时不做圆角裁剪
    if (clipContent) {
      content = ClipRRect(borderRadius: borderRadius, child: content);
    }

    // ── 1. 模糊打底 ─────────────────────────────────────────────
    // 注意：BackdropFilter 必须放在被裁剪的子树里，
    // 否则模糊会溢出到圆角之外。
    Widget surface = GlassBackdrop(
      borderRadius: borderRadius,
      blurSigma: sigma,
      fallbackColor: AppColors.midnight.withValues(alpha: 0.72),
      child: Stack(
        children: <Widget>[
          // ── 色调垫底 ──────────────────────────────────────────
          // 交互模式下把色调放在内容下方，视觉上依然有玻璃底色，
          // 但不会遮挡子组件的指针事件。
          if (interactive)
            Positioned.fill(
              child: GlassTint(tint: tint, gradient: tintGradient),
            ),

          content,

          // ── 2. 色调 ────────────────────────────────────────────
          if (!interactive)
            Positioned.fill(
              child: GlassTint(tint: tint, gradient: tintGradient),
            ),

          // ── 3. 边缘高光 ────────────────────────────────────────
          if (!interactive && highlightOn)
            Positioned.fill(
              child: GlassHighlight(
                borderRadius: borderRadius,
                enabled: highlightOn,
              ),
            ),
        ],
      ),
    );

    // ── 4. 渐变描边 ─────────────────────────────────────────────
    if (border) {
      final Gradient grad =
          borderGradient ??
          (borderGradientEnabled
              ? AppColors.glassBorderGradient
              : LinearGradient(
                  colors: <Color>[AppColors.glassBorder, AppColors.glassBorder],
                ));

      surface = GlassBorder(
        borderRadius: borderRadius,
        gradient: grad,
        width: borderWidth,
        // 光晕挂在这一层，避免被内层 ClipRRect 裁掉
        glowColor: glowColor,
        glowStrength: glowColor != null ? glow : 0.0,
        child: surface,
      );
    } else if (glowColor != null && glow > 0) {
      // 没有描边时用一层纯光晕包裹
      surface = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: AppColors.neonGlow(glowColor!, strength: glow),
        ),
        child: surface,
      );
    }

    return Container(
      width: width,
      height: height,
      margin: margin,
      child: surface,
    );
  }
}
