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
      'anime-candy' => const <Color>[
        Color(0xFFBDA7D1),
        Color(0xFFA6CAD8),
        Color(0xFFD6C995),
        Color(0xFFB2A8D3),
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

    if (renderer == 'anime-candy') {
      _paintAnimeCandy(canvas, size, phase, colors);
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

  void _paintAnimeCandy(
    Canvas canvas,
    Size size,
    double phase,
    List<Color> colors,
  ) {
    final double w = size.width;
    final double h = size.height;
    Color colorAt(int index, Color fallback) =>
        colors.length > index ? colors[index] : fallback;

    // Slightly muted dusk-pastel base, keeping white UI labels legible.
    final Paint shade = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0x24291D3B),
          Color(0x0F322545),
          Color(0x38322448),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, shade);

    final Paint rainbow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const List<Color> rainbowColors = <Color>[
      Color(0xFFFF9BBE),
      Color(0xFFFFC875),
      Color(0xFFFFF09A),
      Color(0xFF9DE8C7),
      Color(0xFF8DDCFF),
      Color(0xFFC4A7FF),
    ];
    for (int index = 0; index < rainbowColors.length; index++) {
      rainbow
        ..color = rainbowColors[index].withValues(alpha: .29)
        ..strokeWidth = 13;
      canvas.drawArc(
        Rect.fromLTWH(
          w * .52 - index * 10,
          h * .04 + index * 7,
          w * .72,
          h * .62,
        ),
        math.pi * 1.08,
        math.pi * .78,
        false,
        rainbow,
      );
    }

    void cloud(double x, double y, double scale, Color color) {
      final Paint paint = Paint()..color = color.withValues(alpha: .45);
      final Offset base = Offset(w * x, h * y);
      canvas.drawOval(
        Rect.fromCenter(
          center: base + Offset(0, 10 * scale),
          width: 150 * scale,
          height: 42 * scale,
        ),
        paint,
      );
      canvas.drawCircle(base + Offset(-42 * scale, 0), 28 * scale, paint);
      canvas.drawCircle(base + Offset(0, -15 * scale), 38 * scale, paint);
      canvas.drawCircle(base + Offset(38 * scale, 1), 25 * scale, paint);
    }

    cloud(
      .18 + math.sin(phase) * .05,
      .22 + math.cos(phase) * .045,
      .72,
      Colors.white,
    );
    cloud(
      .82 + math.cos(phase * .8) * .055,
      .72 + math.sin(phase) * .045,
      .52,
      colorAt(0, Colors.white),
    );

    void star(double x, double y, double scale, Color color) {
      final Paint paint = Paint()..color = color.withValues(alpha: .70);
      final Path path = Path();
      for (int point = 0; point < 10; point++) {
        final double radius = point.isEven ? 22 * scale : 8 * scale;
        final double angle = -math.pi / 2 + point * math.pi / 5;
        final Offset p = Offset(
          w * x + math.cos(angle) * radius,
          h * y + math.sin(angle) * radius,
        );
        point == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, paint);
    }

    star(
      .13,
      .67 + math.sin(phase * 1.4) * .06,
      .7,
      colorAt(2, const Color(0xFFFFC857)),
    );
    star(
      .88,
      .18 + math.cos(phase * 1.1) * .05,
      .52,
      colorAt(1, const Color(0xFFFF9BC8)),
    );
    star(
      .68,
      .88 + math.sin(phase) * .045,
      .35,
      colorAt(3, const Color(0xFF9FDFFF)),
    );

    // 可识别的小猫头像：耳朵、脸、眼睛和腮红。
    final Offset cat = Offset(
      w * (.52 + math.sin(phase * .7) * .035),
      h * (.70 + math.sin(phase * 1.4) * .045),
    );
    final double r = math.min(w, h) * .105;
    final Paint catPaint = Paint()
      ..color = const Color(0xFFFFB9D2).withValues(alpha: .94);
    final Path ears = Path()
      ..moveTo(cat.dx - r * .8, cat.dy - r * .45)
      ..lineTo(cat.dx - r * .72, cat.dy - r * 1.35)
      ..lineTo(cat.dx - r * .12, cat.dy - r * .8)
      ..lineTo(cat.dx + r * .18, cat.dy - r * .8)
      ..lineTo(cat.dx + r * .78, cat.dy - r * 1.35)
      ..lineTo(cat.dx + r * .86, cat.dy - r * .4)
      ..close();
    canvas.drawPath(ears, catPaint);
    canvas.drawCircle(cat, r, catPaint);
    final Paint face = Paint()
      ..color = const Color(0xFF604A78).withValues(alpha: .9);
    canvas.drawOval(
      Rect.fromCenter(
        center: cat + Offset(-r * .34, -.05 * r),
        width: r * .18,
        height: r * .34,
      ),
      face,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: cat + Offset(r * .34, -.05 * r),
        width: r * .18,
        height: r * .34,
      ),
      face,
    );
    canvas.drawCircle(cat + Offset(0, r * .2), r * .09, face);
    final Paint cheek = Paint()
      ..color = const Color(0xFFFF7FAE).withValues(alpha: .55);
    canvas.drawOval(
      Rect.fromCenter(
        center: cat + Offset(-r * .62, r * .28),
        width: r * .3,
        height: r * .12,
      ),
      cheek,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: cat + Offset(r * .62, r * .28),
        width: r * .3,
        height: r * .12,
      ),
      cheek,
    );

    // Floating wrapped candies: rotate gently while moving on separate paths.
    void candy(double x, double y, double angle, Color color) {
      canvas.save();
      final Offset center = Offset(w * x, h * y);
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      final Paint candyPaint = Paint()..color = color.withValues(alpha: .78);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: w * .065,
            height: h * .035,
          ),
          Radius.circular(h * .018),
        ),
        candyPaint,
      );
      final Path wrapper = Path()
        ..moveTo(-w * .033, 0)
        ..lineTo(-w * .048, -h * .02)
        ..lineTo(-w * .048, h * .02)
        ..close()
        ..moveTo(w * .033, 0)
        ..lineTo(w * .048, -h * .02)
        ..lineTo(w * .048, h * .02)
        ..close();
      canvas.drawPath(wrapper, candyPaint);
      canvas.restore();
    }

    candy(
      .28 + math.sin(phase * .9) * .035,
      .48 + math.cos(phase * 1.2) * .09,
      phase * .12,
      const Color(0xFFFF9FBF),
    );
    candy(
      .82 + math.cos(phase * .8) * .04,
      .42 + math.sin(phase * 1.1) * .08,
      -phase * .1,
      const Color(0xFF8EDDE3),
    );

    // A few bubbles drift upward and gently pulse, adding visible motion without particles.
    for (int index = 0; index < 5; index++) {
      final double seed = index * 1.71;
      final double x = .12 + (index * .19) + math.sin(phase + seed) * .025;
      final double y = (.18 + index * .16 + phase * .025 + seed * .01) % .9;
      final double radius =
          5 + (index % 3) * 3 + math.sin(phase * 1.5 + seed).abs() * 2;
      final Paint bubble = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFFF8FF).withValues(alpha: .62);
      canvas.drawCircle(Offset(w * x, h * y), radius, bubble);
      canvas.drawCircle(
        Offset(w * x - radius * .28, h * y - radius * .32),
        math.max(1.5, radius * .17),
        Paint()..color = Colors.white.withValues(alpha: .72),
      );
    }
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
