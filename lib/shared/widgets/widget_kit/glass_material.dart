/// glass_material.dart
///
/// 玻璃的材质层：色调、边缘高光。
///
/// 这几层都绘制在模糊层**之上**，用来把「一片模糊」变成有厚度、有质感的
/// 液态玻璃。全部由 Flutter 原生的渐变与 Widget 叠加实现。
///
/// 0.0.8 起移除了原来的「噪点纹理层」（`GlassNoise`）：它的画面收益很小，
/// 却要逐像素画几千个点，与本次「降 GPU 占用」的目标相反。
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// 玻璃色调层。
///
/// 用极低不透明度的白色叠加在模糊之上，模拟玻璃的漫反射；
/// 同时叠加一道纵向渐变，让玻璃上亮下暗、产生厚度感。
class GlassTint extends StatelessWidget {
  const GlassTint({super.key, this.tint, this.gradient, this.opacity = 1.0});

  /// 纯色色调。与 [gradient] 二选一，同时给则叠加。
  final Color? tint;

  /// 渐变色调。默认使用 [AppColors.glassSurfaceGradient]。
  final Gradient? gradient;

  /// 整体不透明度系数。
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final Gradient grad = gradient ?? AppColors.glassSurfaceGradient;
    return IgnorePointer(
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint ?? AppColors.glassFill,
            gradient: grad,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// 玻璃边缘高光层——液态玻璃「折射感」的来源。
///
/// 模拟单侧光源打在玻璃边缘：左上边缘亮、右下边缘暗，同时在顶部内缘
/// 画一道明亮细边，形成厚度折角。纯渐变实现，无需着色器。
class GlassHighlight extends StatelessWidget {
  const GlassHighlight({
    super.key,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.strength = 1.0,
    this.enabled = true,
    this.showTopEdge = true,
  });

  /// 圆角半径，必须与玻璃容器一致，否则高光会错位。
  final BorderRadius borderRadius;

  /// 高光强度系数，0~1。
  final double strength;

  /// 是否启用。
  final bool enabled;

  /// 是否绘制顶部内缘亮线。
  final bool showTopEdge;

  @override
  Widget build(BuildContext context) {
    if (!enabled || strength <= 0) return const SizedBox.shrink();

    final double s = strength.clamp(0.0, 1.0);

    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          // 左上到右下的斜向高光渐变
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Colors.white.withValues(alpha: 0.16 * s),
              Colors.white.withValues(alpha: 0.03 * s),
              Colors.transparent,
              Colors.white.withValues(alpha: 0.06 * s),
            ],
            stops: const <double>[0.0, 0.3, 0.62, 1.0],
          ),
          // 内缘 1px 亮边：叠加在渐变之上形成"折角"
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.14 * s),
            width: 1,
          ),
        ),
        child: showTopEdge
            ? Align(
                alignment: Alignment.topCenter,
                child: FractionallySizedBox(
                  widthFactor: 0.72,
                  child: Container(
                    height: 1,
                    margin: const EdgeInsets.only(top: 1),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(1),
                      gradient: LinearGradient(
                        colors: <Color>[
                          Colors.white.withValues(alpha: 0.0),
                          Colors.white.withValues(alpha: 0.55 * s),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}
