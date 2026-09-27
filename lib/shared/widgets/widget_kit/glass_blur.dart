/// glass_blur.dart
///
/// 毛玻璃模糊层（架构文档 1.4「毛玻璃模糊」）。
///
/// 全部使用 Flutter 原生能力实现，未引入任何第三方玻璃效果包：
/// - [BackdropFilter] + [ImageFilter.blur]：模糊背后已绘制的像素
/// - [ClipRRect]：把模糊裁剪进圆角范围
/// - [RepaintBoundary]：隔离重绘，避免玻璃层反复触发整页重绘
///
/// ⚠️ 原理要点：BackdropFilter 模糊的是**绘制顺序上位于它之前**的像素。
/// 因此玻璃组件必须叠在背景之上，且背景要足够丰富（渐变、光斑）才看得出效果。
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// 毛玻璃模糊层。
///
/// 只负责「模糊 + 圆角剪裁 + 降级兜底」，不含色调、噪点与描边，
/// 那三层由 `glass_material.dart` 提供。
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({
    super.key,
    required this.child,
    required this.borderRadius,
    required this.blurSigma,
    this.enabled = true,
    this.fallbackColor,
  });

  /// 玻璃容器承载的内容（绘制在模糊层**之上**）。
  final Widget child;

  /// 圆角半径。
  final BorderRadius borderRadius;

  /// 模糊强度（ImageFilter.blur 的 sigma）。0 表示不模糊。
  final double blurSigma;

  /// 是否启用模糊。性能降级档位传 false。
  final bool enabled;

  /// 降级时的兜底填充色。
  ///
  /// 关闭模糊后如果没有底色，内容会直接浮在背景上、失去"玻璃"观感，
  /// 所以用一层半透明深色代替模糊。
  final Color? fallbackColor;

  @override
  Widget build(BuildContext context) {
    final bool doBlur = enabled && blurSigma > 0;

    Widget content = child;

    if (doBlur) {
      // 让模糊层自身独立成层，避免每次动画都重算整棵子树的光栅化。
      content = RepaintBoundary(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: blurSigma,
            sigmaY: blurSigma,
            tileMode: TileMode.clamp,
          ),
          child: content,
        ),
      );
    } else if (fallbackColor != null) {
      content = ColoredBox(color: fallbackColor!, child: content);
    }

    return ClipRRect(borderRadius: borderRadius, child: content);
  }
}

/// 一个可复用的「模糊圆角卡片」容器。
///
/// 相比 [GlassBackdrop] 多了一层 [Container]，用于承载边框与内边距，
/// 适合直接当作卡片使用。
class FrostedPanel extends StatelessWidget {
  const FrostedPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.blurSigma = 24,
    this.enabled = true,
    this.padding = const EdgeInsets.all(16),
    this.fallbackColor = const Color(0xCC0B0820),
    this.decoration,
  });

  /// 卡片内容。
  final Widget child;

  /// 圆角半径。
  final BorderRadius borderRadius;

  /// 模糊强度。
  final double blurSigma;

  /// 是否启用模糊。
  final bool enabled;

  /// 内边距。
  final EdgeInsetsGeometry padding;

  /// 降级兜底色。
  final Color fallbackColor;

  /// 额外的装饰（例如描边、阴影）。
  final BoxDecoration? decoration;

  @override
  Widget build(BuildContext context) {
    return GlassBackdrop(
      borderRadius: borderRadius,
      blurSigma: blurSigma,
      enabled: enabled,
      fallbackColor: fallbackColor,
      child: Container(padding: padding, decoration: decoration, child: child),
    );
  }
}
