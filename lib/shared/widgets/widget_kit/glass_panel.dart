/// The production glass surface used throughout HoH music.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_plus/liquid_glass_plus.dart';

import '../../theme/app_accent.dart';
import 'blur_config_scope.dart';
import 'liquid_glass_settings.dart';

/// Shared low-frequency edge highlight clock.
/// The material itself is rendered by `liquid_glass_plus`; this overlay only
/// preserves HoH's requested moving border highlight and never handles input.
abstract final class GlassSweepClock {
  static const Duration period = Duration(seconds: 14);
  // 16-17fps remains visually smooth for a slow 14s perimeter sweep while
  // cutting redraw work compared with the former 30fps timer.
  static const Duration tickInterval = Duration(milliseconds: 60);
  static final double stepPerTick =
      tickInterval.inMicroseconds / period.inMicroseconds;
  static final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  static Timer? _timer;
  static int _users = 0;
  static bool _appActive = true;

  static bool get isRunning => _timer != null;
  static int get userCount => _users;

  static GlassSweepAnimation acquire(double phase) {
    _users++;
    if (_users == 1) {
      _appActive =
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused;
      WidgetsBinding.instance.addObserver(_lifecycleObserver);
    }
    _syncTimer();
    return GlassSweepAnimation(_progress, phase);
  }

  static void release() {
    if (_users > 0) _users--;
    if (_users == 0) {
      _timer?.cancel();
      _timer = null;
      WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    }
  }

  static void _onLifecycleChanged(AppLifecycleState state) {
    _appActive =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncTimer();
  }

  static void _syncTimer() {
    if (_users > 0 && _appActive) {
      _timer ??= Timer.periodic(tickInterval, (_) {
        var next = _progress.value + stepPerTick;
        if (next >= 1) next -= 1;
        _progress.value = next;
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  static final WidgetsBindingObserver _lifecycleObserver =
      _GlassSweepLifecycleObserver();
}

class _GlassSweepLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    GlassSweepClock._onLifecycleChanged(state);
  }
}

class GlassSweepAnimation extends ChangeNotifier
    implements ValueListenable<double> {
  GlassSweepAnimation(this._clock, this.phase) {
    _clock.addListener(notifyListeners);
  }

  final ValueListenable<double> _clock;
  final double phase;

  @override
  double get value {
    final value = _clock.value + phase;
    return value >= 1 ? value - 1 : value;
  }

  @override
  void dispose() {
    _clock.removeListener(notifyListeners);
    super.dispose();
  }
}

/// A plugin-first glass panel. The legacy constructor fields remain source
/// compatible for existing pages; all effective material parameters come from
/// `BlurConfig` and `buildHohLiquidGlassSettings`.
class GlassPanel extends StatefulWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.blurSigma = 18,
    this.glowOpacity = 1,
    this.sweep = true,
    this.initialSweepPhase = 0,
    this.showSweepAt = true,
    this.padding = EdgeInsets.zero,
    this.blurEnabled = true,
    this.tintOpacity = 1,
    this.glowColor,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blurSigma;
  final double glowOpacity;
  final bool sweep;
  final double initialSweepPhase;
  final bool showSweepAt;
  final EdgeInsetsGeometry padding;
  final bool blurEnabled;
  final double tintOpacity;
  final Color? glowColor;

  @override
  State<GlassPanel> createState() => _GlassPanelState();
}

class _GlassPanelState extends State<GlassPanel> {
  GlassSweepAnimation? _sweep;

  bool get _wantsSweep =>
      defaultTargetPlatform != TargetPlatform.android &&
      !AppAccent.of(context).isMonochrome &&
      widget.sweep &&
      widget.showSweepAt &&
      widget.glowOpacity > 0;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSweep();
  }

  @override
  void didUpdateWidget(GlassPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSweep();
  }

  void _syncSweep() {
    if (_wantsSweep && _sweep == null) {
      _sweep = GlassSweepClock.acquire(widget.initialSweepPhase);
    } else if (!_wantsSweep && _sweep != null) {
      _sweep!.dispose();
      _sweep = null;
      GlassSweepClock.release();
    }
  }

  @override
  void dispose() {
    if (_sweep != null) {
      _sweep!.dispose();
      GlassSweepClock.release();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final config = BlurConfigScope.of(context);
    final settings = buildHohLiquidGlassSettings(
      config,
      enabled: widget.blurEnabled,
    );
    final Widget panelContent = ClipRRect(
      borderRadius: widget.borderRadius,
      child: RepaintBoundary(
        key: const ValueKey<String>('glass-panel-content'),
        child: Padding(padding: widget.padding, child: widget.child),
      ),
    );
    // Android returns to the stable low-cost material: a small backdrop blur
    // plus an opaque tint. It never samples refracted/displaced content, so
    // scrolling text cannot bleed into the panel and several panels do not
    // create the heavier liquid-glass shader path at once.
    final bool isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final bool flatMonochrome = accent.isMonochrome;
    final Widget material = flatMonochrome
        ? _flatMonochromeSurface(panelContent, accent)
        : isAndroid
        ? ClipRRect(
            borderRadius: widget.borderRadius,
            child: widget.blurEnabled
                ? BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: _androidTintedSurface(panelContent),
                  )
                : _androidTintedSurface(panelContent),
          )
        : widget.blurEnabled
        ? LiquidGlass.withOwnLayer(
            settings: settings,
            shape: LiquidRoundedSuperellipse(
              borderRadius: widget.borderRadius.topLeft.x,
            ),
            child: panelContent,
          )
        : _androidTintedSurface(panelContent);
    final sweep = _sweep;
    if (sweep == null || flatMonochrome) return material;
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        material,
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _SweepBorderPainter(
                  animation: sweep,
                  borderRadius: widget.borderRadius,
                  opacity: widget.glowOpacity,
                  color: widget.glowColor ?? AccentScope.of(context).primary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _flatMonochromeSurface(Widget child, AppAccent accent) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.panelSurface,
        borderRadius: widget.borderRadius,
        border: Border.all(
          color: accent.foreground.withValues(alpha: .24),
          width: 1,
        ),
      ),
      child: child,
    );
  }

  Widget _androidTintedSurface(Widget child) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xD9141A2C),
        borderRadius: widget.borderRadius,
        border: Border.all(color: Colors.white.withValues(alpha: .18)),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xCC29344E), Color(0xD9141A2C)],
        ),
      ),
      child: child,
    );
  }
}

class _SweepBorderPainter extends CustomPainter {
  _SweepBorderPainter({
    required this.animation,
    required this.borderRadius,
    required this.opacity,
    required this.color,
  }) : super(repaint: animation);

  final ValueListenable<double> animation;
  final BorderRadius borderRadius;
  final double opacity;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || opacity <= 0) return;
    final peak = Color.lerp(color, Colors.white, .35)!;
    final gradient = SweepGradient(
      colors: <Color>[
        Colors.transparent,
        Colors.transparent,
        color.withValues(alpha: .35 * opacity),
        peak.withValues(alpha: .9 * opacity),
        peak.withValues(alpha: opacity),
        color.withValues(alpha: .35 * opacity),
        Colors.transparent,
      ],
      stops: const <double>[0, .29, .322, .333, .344, .375, 1],
      transform: GradientRotation(animation.value * 2 * math.pi),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..shader = gradient.createShader(Offset.zero & size);
    final rect = borderRadius
        .resolve(TextDirection.ltr)
        .toRRect(Offset.zero & size)
        .inflate(-.7);
    canvas.drawRRect(rect, paint);
  }

  @override
  bool shouldRepaint(_SweepBorderPainter oldDelegate) =>
      oldDelegate.opacity != opacity ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.color != color ||
      oldDelegate.animation != animation;
}
