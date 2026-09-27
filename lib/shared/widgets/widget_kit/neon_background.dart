/// neon_background.dart
///
/// 深色调霓虹背景（架构文档 1.4「深色调」「霓虹渐变」）。
///
/// 玻璃效果必须叠在**有内容的背景**上才看得出来——纯色背景下模糊与不模糊
/// 视觉上没有区别。本组件用原生 [CustomPainter] 绘制四层背景：
/// 1. 纵向明暗渐变 —— 建立深色基调；
/// 2. 霓虹网格 —— 迈阿密风格的透视网格感；
/// 3. 径向光斑 —— 分别用青、品红、紫三种霓虹色；
/// 4. 扫描线 —— 极淡的 CRT 质感。
///
/// 0.0.8 起移除了原来的「浮动粒子」层（连同上层的「背景粒子」设置项）：
/// 它与径向光斑的观感重叠，却要多画几十个每帧变化的圆。
///
/// 不依赖任何图片资源，全部实时绘制。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/performance_tier.dart';
import 'blur_config_scope.dart';

/// 深色霓虹背景。
class NeonBackground extends StatefulWidget {
  const NeonBackground({
    super.key,
    required this.child,
    this.animated = true,
    this.gridEnabled = true,
    this.showScanlines = true,
  });

  /// 叠在背景之上的内容。
  final Widget child;

  /// 是否播放光斑呼吸动画。
  final bool animated;

  /// 是否绘制网格。
  final bool gridEnabled;

  /// 是否绘制扫描线（CRT 质感）。
  final bool showScanlines;

  @override
  State<NeonBackground> createState() => _NeonBackgroundState();
}

class _NeonBackgroundState extends State<NeonBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animated) _controller.repeat();
  }

  @override
  void didUpdateWidget(NeonBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animated && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.animated && _controller.isAnimating) {
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
    final BlurConfig config = BlurConfigScope.of(context);
    final bool animate = widget.animated && config.animationsEnabled;

    final painter = _NeonBackgroundPainter(
      gridEnabled: widget.gridEnabled,
      showScanlines: widget.showScanlines,
    );

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: ColoredBox(
            color: AppColors.abyss,
            child: animate
                ? AnimatedBuilder(
                    animation: _controller,
                    builder: (BuildContext context, Widget? child) {
                      return CustomPaint(
                        painter: painter..time = _controller.value,
                        size: Size.infinite,
                      );
                    },
                  )
                : CustomPaint(
                    painter: painter..time = 0.0,
                    size: Size.infinite,
                  ),
          ),
        ),
        // 内容
        widget.child,
      ],
    );
  }
}

class _NeonBackgroundPainter extends CustomPainter {
  _NeonBackgroundPainter({
    required this.gridEnabled,
    required this.showScanlines,
  });

  final bool gridEnabled;
  final bool showScanlines;

  /// 归一化时间 0~1，用于驱动光斑呼吸。
  double time = 0.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect rect = Offset.zero & size;

    _paintBaseGradient(canvas, rect);
    if (gridEnabled) _paintGrid(canvas, rect);
    _paintGlowSpots(canvas, rect);
    if (showScanlines) _paintScanlines(canvas, rect);
  }

  /// 1. 纵向明暗渐变，建立深紫黑的基调。
  void _paintBaseGradient(Canvas canvas, Rect rect) {
    final Paint paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0xFF0A0620),
          Color(0xFF05030F),
          Color(0xFF0D0620),
        ],
        stops: <double>[0.0, 0.55, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  /// 2. 霓虹网格——细线 + 缓慢明暗流动，营造迈阿密氛围。
  void _paintGrid(Canvas canvas, Rect rect) {
    const double cell = 64;
    final double pulse = 0.5 + 0.5 * math.sin(time * math.pi * 2);

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = AppColors.neonViolet.withValues(alpha: 0.045 + 0.03 * pulse);

    for (double x = 0; x <= rect.width; x += cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, rect.height), paint);
    }
    for (double y = 0; y <= rect.height; y += cell) {
      canvas.drawLine(Offset(0, y), Offset(rect.width, y), paint);
    }
  }

  /// 3. 三处径向霓虹光斑，缓慢呼吸位移。
  void _paintGlowSpots(Canvas canvas, Rect rect) {
    final double t = time * math.pi * 2;

    void spot({
      required double dx,
      required double dy,
      required Color color,
      required double radius,
      required double phase,
    }) {
      final Offset center = Offset(
        rect.width * (dx + 0.03 * math.sin(t + phase)),
        rect.height * (dy + 0.03 * math.cos(t * 0.8 + phase)),
      );
      final double breath = 0.85 + 0.15 * math.sin(t * 1.3 + phase);

      final Paint paint = Paint()
        ..shader =
            RadialGradient(
              colors: <Color>[
                color.withValues(alpha: 0.30 * breath),
                color.withValues(alpha: 0.07 * breath),
                Colors.transparent,
              ],
              stops: const <double>[0.0, 0.45, 1.0],
            ).createShader(
              Rect.fromCircle(center: center, radius: radius * breath),
            );
      canvas.drawCircle(center, radius * breath, paint);
    }

    final double shortest = math.min(rect.width, rect.height);
    spot(
      dx: 0.18,
      dy: 0.16,
      color: AppColors.neonCyan,
      radius: shortest * 0.55,
      phase: 0.0,
    );
    spot(
      dx: 0.85,
      dy: 0.30,
      color: AppColors.neonMagenta,
      radius: shortest * 0.5,
      phase: 1.7,
    );
    spot(
      dx: 0.55,
      dy: 0.88,
      color: AppColors.neonViolet,
      radius: shortest * 0.6,
      phase: 3.4,
    );
  }

  /// 4. 极淡的横向扫描线，增加 CRT / 街机质感。
  void _paintScanlines(Canvas canvas, Rect rect) {
    final Paint paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.055)
      ..strokeWidth = 1;
    for (double y = 0; y < rect.height; y += 3) {
      canvas.drawLine(Offset(0, y), Offset(rect.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_NeonBackgroundPainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.gridEnabled != gridEnabled ||
        oldDelegate.showScanlines != showScanlines;
  }
}
