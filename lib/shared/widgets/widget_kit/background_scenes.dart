/// 内置低开销背景场景。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 液态流光：三团低饱和渐变光缓慢漂移，约 8.3fps。
class LiquidBloomScene extends StatefulWidget {
  const LiquidBloomScene({
    super.key,
    this.animated = true,
    this.definition,
    this.themeColors,
  });

  final bool animated;
  final Map<String, Object?>? definition;
  final List<Color>? themeColors;

  @override
  State<LiquidBloomScene> createState() => _LiquidBloomSceneState();
}

class _LiquidBloomSceneState extends State<LiquidBloomScene>
    with WidgetsBindingObserver {
  static const Duration _tickInterval = Duration(milliseconds: 120);

  Timer? _timer;
  double _progress = 0;
  bool _appActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appActive =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant LiquidBloomScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncTimer();
  }

  void _syncTimer() {
    final bool shouldRun =
        widget.animated && _appActive && TickerMode.valuesOf(context).enabled;
    if (shouldRun) {
      _timer ??= Timer.periodic(_tickInterval, (_) {
        if (mounted) {
          setState(
            () => _progress =
                (_progress + _tickInterval.inMilliseconds / 1000 / 28) % 1,
          );
        }
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      // 主题色由 MaterialApp 的 AnimatedTheme 逐帧下发，绘制层只消费
      // 当前帧的三色，不额外创建高频动画控制器。
      painter: _LiquidBloomPainter(
        _progress,
        widget.definition,
        widget.themeColors,
      ),
      size: Size.infinite,
    ),
  );
}

class _LiquidBloomPainter extends CustomPainter {
  const _LiquidBloomPainter(this.progress, this.definition, this.themeColors);

  final double progress;
  final Map<String, Object?>? definition;
  final List<Color>? themeColors;

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
      'ink-fold' => const <Color>[
        Color(0xFF080E20),
        Color(0xFF101B32),
        Color(0xFF100E21),
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
    final List<Color> colors =
        themeColors ??
        ((definition?['colors'] is List)
            ? (definition!['colors'] as List)
                  .map((Object? value) => _color(value))
                  .whereType<Color>()
                  .toList()
            : const <Color>[]);
    Color colorAt(int index, Color fallback) =>
        colors.length > index ? colors[index] : fallback;

    if (renderer == 'ink-fold') {
      _paintInkFold(canvas, size, phase, colorAt);
      return;
    }

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

  /// 分层墨带以缓慢变形的等高线穿过画面；没有粒子、圆形光球或噪声滤镜。
  void _paintInkFold(
    Canvas canvas,
    Size size,
    double phase,
    Color Function(int index, Color fallback) colorAt,
  ) {
    final double w = size.width;
    final double h = size.height;
    final Rect bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF0A1125),
            Color(0xFF11182C),
            Color(0xFF100D1E),
            Color(0xFF080E1A),
          ],
          stops: <double>[0, .38, .72, 1],
        ).createShader(bounds),
    );

    final List<Color> inks = <Color>[
      colorAt(0, const Color(0xFF172341)),
      colorAt(1, const Color(0xFF286D78)),
      colorAt(2, const Color(0xFF8A4268)),
      const Color(0xFF314B83),
    ];

    for (int layer = 0; layer < 5; layer++) {
      final double direction = layer.isEven ? 1 : -1;
      final double baseY = h * (.22 + layer * .145);
      final double amplitude = h * (.075 + (layer % 3) * .018);
      final double offset = phase * direction + layer * 1.31;
      final double thickness = h * (.16 + (layer % 2) * .045);
      final Path ribbon = Path();
      const int segments = 48;
      double edgeY(double t, double extra) {
        final double wave =
            math.sin(t * math.pi * 2 + offset) * amplitude +
            math.sin(t * math.pi * 3 - offset * .63) * amplitude * .32 +
            math.sin(t * math.pi + offset * .42) * amplitude * .2;
        final double fold =
            math.exp(-math.pow((t - (.52 + math.sin(offset) * .19)) * 5, 2)) *
            h *
            .07;
        return baseY + wave + fold + extra;
      }

      ribbon.moveTo(-w * .04, edgeY(0, -thickness * .5));
      for (int step = 1; step <= segments; step++) {
        final double t = step / segments;
        ribbon.lineTo(w * (t * 1.08 - .04), edgeY(t, -thickness * .5));
      }
      for (int step = segments; step >= 0; step--) {
        final double t = step / segments;
        ribbon.lineTo(w * (t * 1.08 - .04), edgeY(t, thickness * .5));
      }
      ribbon.close();

      final Color ink = inks[layer % inks.length];
      canvas.drawPath(
        ribbon,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              ink.withValues(alpha: .015),
              ink.withValues(alpha: .18),
              ink.withValues(alpha: .27),
              ink.withValues(alpha: .035),
            ],
            stops: const <double>[0, .35, .68, 1],
          ).createShader(bounds),
      );

      // 褶皱边缘的一道细墨光强调空间层次，避免整片背景变成平面色带。
      final Path crease = Path();
      for (int step = 0; step <= segments; step++) {
        final double t = step / segments;
        final Offset point = Offset(
          w * (t * 1.08 - .04),
          edgeY(t, thickness * .5),
        );
        if (step == 0) {
          crease.moveTo(point.dx, point.dy);
        } else {
          crease.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(
        crease,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, h * .0015)
          ..shader = LinearGradient(
            colors: <Color>[
              Colors.transparent,
              ink.withValues(alpha: .22),
              Colors.white.withValues(alpha: .055),
              Colors.transparent,
            ],
          ).createShader(bounds),
      );
    }

    // 暗角让中间的歌词和控制文字保持清楚，同时保留两侧墨色的纵深。
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(.08, -.12),
          radius: 1.1,
          colors: <Color>[
            Colors.transparent,
            const Color(0xFF050812).withValues(alpha: .18),
            const Color(0xFF03050B).withValues(alpha: .46),
          ],
          stops: const <double>[.28, .72, 1],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(_LiquidBloomPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.definition != definition ||
      oldDelegate.themeColors != themeColors;

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
