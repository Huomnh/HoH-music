/// 内置低开销背景场景。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 液态流光：三团低饱和渐变光缓慢漂移，约 12.5fps。
class LiquidBloomScene extends StatefulWidget {
  const LiquidBloomScene({super.key, this.animated = true, this.definition});

  final bool animated;
  final Map<String, Object?>? definition;

  @override
  State<LiquidBloomScene> createState() => _LiquidBloomSceneState();
}

class _LiquidBloomSceneState extends State<LiquidBloomScene> {
  Timer? _timer;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    if (widget.animated) _start();
  }

  @override
  void didUpdateWidget(covariant LiquidBloomScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animated) {
      _start();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _start() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (mounted) setState(() => _progress = (_progress + 0.08 / 28) % 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _LiquidBloomPainter(_progress, widget.definition),
      size: Size.infinite,
    ),
  );
}

class _LiquidBloomPainter extends CustomPainter {
  const _LiquidBloomPainter(this.progress, this.definition);

  final double progress;
  final Map<String, Object?>? definition;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect rect = Offset.zero & size;
    final double w = size.width;
    final double h = size.height;
    final String renderer =
        definition?['renderer']?.toString() ?? 'liquid-bloom';
    final List<Color> baseColors = switch (renderer) {
      'sunset-ember' => const <Color>[
        Color(0xFF321A25),
        Color(0xFF51302B),
        Color(0xFF211525),
      ],
      _ => const <Color>[
        Color(0xFF11152C),
        Color(0xFF182B42),
        Color(0xFF101A32),
        Color(0xFF090B19),
      ],
    };
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: baseColors,
        ).createShader(rect),
    );

    void bloom(double x, double y, double radius, Color color) {
      final Offset center = Offset(w * x, h * y);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              color.withValues(alpha: 0.42),
              color.withValues(alpha: 0.14),
              Colors.transparent,
            ],
            stops: const <double>[0, 0.42, 1],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    final double speed = ((definition?['speed'] as num?)?.toDouble() ?? 1.0)
        .clamp(0.1, 4.0)
        .toDouble();
    final double phase = progress * math.pi * 2 * speed;
    final List<Color> colors = (definition?['colors'] is List)
        ? (definition!['colors'] as List)
              .map((Object? value) => _color(value))
              .whereType<Color>()
              .toList()
        : const <Color>[];
    Color colorAt(int index, Color fallback) =>
        colors.length > index ? colors[index] : fallback;

    final double bloomAlpha = renderer == 'sunset-ember' ? 0.34 : 0.42;
    bloom(
      0.22 + math.sin(phase) * 0.06,
      0.22 + math.cos(phase) * 0.05,
      h * 0.64,
      colorAt(0, const Color(0xFF5D7CFF)).withValues(alpha: bloomAlpha),
    );
    bloom(
      0.78 + math.cos(phase) * 0.05,
      0.36 + math.sin(phase) * 0.08,
      h * 0.58,
      colorAt(1, const Color(0xFFFF78C8)).withValues(alpha: bloomAlpha),
    );
    bloom(
      0.54 + math.sin(phase * 2) * 0.04,
      0.86 + math.cos(phase * 2) * 0.04,
      h * 0.48,
      colorAt(2, const Color(0xFF47E5C2)).withValues(alpha: bloomAlpha),
    );
  }

  @override
  bool shouldRepaint(_LiquidBloomPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.definition != definition;

  static Color? _color(Object? value) {
    final String text = '$value';
    final int? argb = value is num
        ? value.toInt()
        : int.tryParse(text) ??
              int.tryParse(
                text.toLowerCase().replaceFirst('0x', ''),
                radix: 16,
              );
    return argb == null ? null : Color(argb);
  }
}
