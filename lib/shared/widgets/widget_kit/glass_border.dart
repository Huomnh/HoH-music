/// glass_border.dart
///
/// 霓虹渐变描边、霓虹光晕与流光扫光动效（架构文档 1.4「霓虹渐变」「流光动效」）。
///
/// 实现手段：
/// - 渐变描边：外层铺渐变、内层用同色圆角内缩——Flutter 的 Border 只支持单色，
///   做渐变边框必须用这种双层技巧；
/// - 霓虹光晕：多层 [BoxShadow] 模糊 + [AnimationController] 驱动的呼吸脉冲；
/// - 流光扫光：[ShaderMask] 配合平移动画的 [LinearGradient]。
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// 渐变描边容器。
class GlassBorder extends StatelessWidget {
  const GlassBorder({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.gradient,
    this.width = 1.0,
    this.innerColor,
    this.glowColor,
    this.glowStrength = 0.0,
  });

  /// 子内容。
  final Widget child;

  /// 圆角半径。
  final BorderRadius borderRadius;

  /// 描边渐变。默认使用 [AppColors.glassBorderGradient]。
  final Gradient? gradient;

  /// 描边宽度。
  final double width;

  /// 内层填充色。默认透明，以免遮挡已画好的模糊层。
  final Color? innerColor;

  /// 光晕颜色。null 表示不发光。
  final Color? glowColor;

  /// 光晕强度，0 表示关闭。
  final double glowStrength;

  @override
  Widget build(BuildContext context) {
    final Gradient grad = gradient ?? AppColors.glassBorderGradient;

    Widget result = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: grad,
        boxShadow: (glowColor != null && glowStrength > 0)
            ? AppColors.neonGlow(glowColor!, strength: glowStrength)
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.all(width),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: _deflate(borderRadius, width),
            color: innerColor ?? Colors.transparent,
          ),
          child: child,
        ),
      ),
    );

    result = ClipRRect(borderRadius: borderRadius, child: result);
    return result;
  }

  /// 内层圆角按描边宽度收缩，否则边角会出现月牙状空隙。
  static BorderRadius _deflate(BorderRadius radius, double amount) {
    final BorderRadius resolved = radius.resolve(TextDirection.ltr);
    return BorderRadius.only(
      topLeft: _clampRadius(resolved.topLeft, amount),
      topRight: _clampRadius(resolved.topRight, amount),
      bottomLeft: _clampRadius(resolved.bottomLeft, amount),
      bottomRight: _clampRadius(resolved.bottomRight, amount),
    );
  }

  /// 收缩后半径不能为负，否则 DecoratedBox 断言失败。
  static Radius _clampRadius(Radius radius, double amount) {
    final double x = radius.x - amount;
    final double y = radius.y - amount;
    return Radius.elliptical(x < 0 ? 0 : x, y < 0 ? 0 : y);
  }
}

/// 霓虹呼吸光晕。
///
/// [enabled] 为 false 时**完全不启动动画**，只渲染一个静态光晕，
/// 对应省电档位「关闭动效」的要求。
class NeonPulse extends StatefulWidget {
  const NeonPulse({
    super.key,
    required this.child,
    this.color = AppColors.neonCyan,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.enabled = true,
    this.strength = 1.0,
    this.duration = const Duration(milliseconds: 2600),
    this.minFactor = 0.4,
  });

  /// 子内容。
  final Widget child;

  /// 光晕颜色。
  final Color color;

  /// 圆角半径。
  final BorderRadius borderRadius;

  /// 是否播放动画。
  final bool enabled;

  /// 光晕强度系数。
  final double strength;

  /// 一次完整呼吸的时长。
  final Duration duration;

  /// 最弱时的强度比例。
  final double minFactor;

  @override
  State<NeonPulse> createState() => _NeonPulseState();
}

class _NeonPulseState extends State<NeonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 0.0,
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(NeonPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.enabled && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.enabled && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return _wrap(1.0);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double t =
            widget.minFactor + (1.0 - widget.minFactor) * _controller.value;
        return _wrap(t);
      },
      child: widget.child,
    );
  }

  Widget _wrap(double factor) {
    if (widget.strength <= 0) return widget.child;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius,
        boxShadow: AppColors.neonGlow(
          widget.color,
          strength: widget.strength * factor,
        ),
      ),
      child: widget.child,
    );
  }
}

/// 流光扫光层。
///
/// 用 [ShaderMask] 把渐变当不透明蒙版，所以**只对已有内容生效**——
/// 适合文字、图标、描边，不适合当背景。
class ShimmerSweep extends StatefulWidget {
  const ShimmerSweep({
    super.key,
    required this.child,
    this.baseColor,
    this.highlightColor,
    this.enabled = true,
    this.duration = const Duration(milliseconds: 2800),
    this.bandWidth = 0.3,
  });

  /// 被扫光的内容。
  final Widget child;

  /// 基础色。
  final Color? baseColor;

  /// 高光带颜色。
  final Color? highlightColor;

  /// 是否播放。
  final bool enabled;

  /// 扫过一次的时长。
  final Duration duration;

  /// 高光带宽度（相对容器宽度的比例，0~1）。
  final double bandWidth;

  @override
  State<ShimmerSweep> createState() => _ShimmerSweepState();
}

class _ShimmerSweepState extends State<ShimmerSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _controller.repeat();
  }

  @override
  void didUpdateWidget(ShimmerSweep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.enabled && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.enabled && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 关闭动效时冻结在中间位置，仍然看得出是渐变文字
    if (!widget.enabled) return _buildMask(0.5);

    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) =>
          _buildMask(_controller.value),
      child: widget.child,
    );
  }

  Widget _buildMask(double t) {
    final double half = (widget.bandWidth / 2).clamp(0.01, 0.5);
    // 高光带从左侧外部移动到右侧外部
    final double center = -half + t * (1.0 + half * 2);
    final double left = center - half;
    final double right = center + half;

    // LinearGradient 要求 stops 单调不减且落在 [0,1]，
    // 先夹取再逐项保证非递减，否则会触发断言。
    final double s1 = left.clamp(0.0, 1.0);
    final double s2 = right.clamp(s1, 1.0);

    final Color base = widget.baseColor ?? AppColors.neonViolet;
    final Color highlight = widget.highlightColor ?? Colors.white;

    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (Rect bounds) {
        return LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[base, highlight, base],
          stops: <double>[s1, ((s1 + s2) / 2).clamp(s1, s2), s2],
        ).createShader(bounds);
      },
      child: widget.child,
    );
  }
}

/// 渐变文字——霓虹字体基础。
///
/// [shimmer] 为 true 时叠加持续扫光（流光动效）。
class GradientText extends StatelessWidget {
  const GradientText(
    this.text, {
    super.key,
    this.style,
    this.gradient,
    this.shimmer = false,
    this.shimmerEnabled = true,
  });

  /// 文字内容。
  final String text;

  /// 文字样式。
  final TextStyle? style;

  /// 渐变。默认 [AppColors.primaryGradient]。
  final Gradient? gradient;

  /// 是否叠加扫光。
  final bool shimmer;

  /// 扫光是否播放（受性能档位控制）。
  final bool shimmerEnabled;

  @override
  Widget build(BuildContext context) {
    final TextStyle effective =
        (style ??
                Theme.of(context).textTheme.displaySmall ??
                const TextStyle(fontSize: 32, fontWeight: FontWeight.w700))
            .copyWith(color: Colors.white);

    Widget result = ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (Rect bounds) =>
          (gradient ?? AppColors.primaryGradient).createShader(bounds),
      child: Text(text, style: effective),
    );

    if (shimmer) {
      result = ShimmerSweep(enabled: shimmerEnabled, child: result);
    }

    return result;
  }
}

/// 霓虹描边胶囊标签，用于标注效果名称。
class NeonChip extends StatelessWidget {
  const NeonChip({
    super.key,
    required this.label,
    this.color = AppColors.neonCyan,
    this.icon,
  });

  /// 文本。
  final String label;

  /// 主色。
  final Color color;

  /// 前置图标。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: LinearGradient(
          colors: <Color>[
            color.withValues(alpha: 0.22),
            color.withValues(alpha: 0.06),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        boxShadow: AppColors.neonGlow(color, strength: 0.35, radius: 14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
