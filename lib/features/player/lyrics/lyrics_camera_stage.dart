/// Native Flutter 2.5D lyric stage.
///
/// The stage treats each lyric line as a node in a small virtual world. The
/// camera follows the current timeline position and projects only nearby
/// nodes, which keeps the effect reusable on Windows, mobile and web.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/theme/app_accent.dart';
import 'lyrics_parser.dart';
import 'lyrics_style.dart';
import 'lyrics_visualizer.dart';

class LyricsCameraStage extends StatelessWidget {
  const LyricsCameraStage({
    super.key,
    required this.frame,
    required this.style,
    required this.accent,
    required this.onSeek,
  });

  final LyricsVisualizerFrame frame;
  final LyricsStyle style;
  final AppAccent accent;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: _LyricsCameraViewport(
        frame: frame,
        style: style,
        accent: accent,
        onSeek: onSeek,
      ),
    );
  }
}

class _LyricsCameraViewport extends StatefulWidget {
  const _LyricsCameraViewport({
    required this.frame,
    required this.style,
    required this.accent,
    required this.onSeek,
  });

  final LyricsVisualizerFrame frame;
  final LyricsStyle style;
  final AppAccent accent;
  final ValueChanged<Duration> onSeek;

  @override
  State<_LyricsCameraViewport> createState() => _LyricsCameraViewportState();
}

class _LyricsCameraViewportState extends State<_LyricsCameraViewport>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cameraMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  double _cameraPosition = 0;
  double _motionStart = 0;
  double _motionTarget = 0;
  int _lastIndex = -1;

  @override
  void initState() {
    super.initState();
    _lastIndex = widget.frame.currentIndex;
    _cameraPosition = _focusPosition(widget.frame);
  }

  @override
  void didUpdateWidget(covariant _LyricsCameraViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    final double target = _focusPosition(widget.frame);
    if (widget.frame.currentIndex != _lastIndex) {
      _lastIndex = widget.frame.currentIndex;
      _motionStart = _cameraPosition;
      _motionTarget = target;
      _cameraMotion
        ..value = 0
        ..forward();
    } else {
      // Follow the clock without restarting a full line transition.
      _cameraPosition = target;
    }
  }

  double _focusPosition(LyricsVisualizerFrame frame) =>
      frame.currentIndex + frame.progress.clamp(0.0, 1.0) * 0.28;

  @override
  void dispose() {
    _cameraMotion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _cameraMotion,
      builder: (BuildContext context, Widget? child) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth;
          final double height = constraints.maxHeight;
          final double rowExtent = (height * 0.22).clamp(76.0, 142.0);
          final double camera = _cameraMotion.isAnimating
              ? Curves.easeOutCubic.transform(_cameraMotion.value) *
                        (_motionTarget - _motionStart) +
                    _motionStart
              : _cameraPosition;
          if (!_cameraMotion.isAnimating) {
            _cameraPosition = _focusPosition(widget.frame);
          }
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              CustomPaint(
                painter: _CameraAtmospherePainter(
                  primary: widget.accent.primary,
                  secondary: widget.accent.secondary,
                ),
              ),
              for (final int index in _visibleIndexes())
                _buildNode(
                  index: index,
                  camera: camera,
                  rowExtent: rowExtent,
                  width: width,
                  height: height,
                ),
            ],
          );
        },
      ),
    );
  }

  Iterable<int> _visibleIndexes() sync* {
    final int current = widget.frame.currentIndex;
    final int start = math.max(0, current - 4);
    final int end = math.min(
      widget.frame.timeline.lines.length - 1,
      current + 4,
    );
    for (int index = start; index <= end; index++) {
      yield index;
    }
  }

  Widget _buildNode({
    required int index,
    required double camera,
    required double rowExtent,
    required double width,
    required double height,
  }) {
    final LyricLine line = widget.frame.timeline.lines[index];
    final double relative = index - camera;
    final double distance = relative.abs();
    final double depth = (distance / 4).clamp(0.0, 1.0);
    final bool active = index == widget.frame.currentIndex;
    final double scale = active ? 1.0 : (1.0 - depth * 0.27).clamp(0.68, 0.98);
    final double opacity = active
        ? 1.0
        : (1.0 - depth * 0.66).clamp(0.12, 0.62);
    final double x = math.sin(index * 0.82) * width * 0.035 * depth;
    final double y = relative * rowExtent;
    final double rotation = math.sin(index * 0.82) * 0.035 * depth;
    final double blur = depth * 0.65;
    final double size =
        (width * 0.045).clamp(24.0, 48.0) * (active ? 1.0 : 0.78);

    final Widget content = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => widget.onSeek(line.time),
      child: _CameraLyricLine(
        line: line,
        active: active,
        progress: active ? widget.frame.progress : 0,
        position: widget.frame.position,
        size: size,
        style: widget.style,
        accent: widget.accent,
        opacity: opacity,
        blur: blur,
      ),
    );

    return Align(
      alignment: Alignment.center,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..translateByDouble(x, y, -depth * 80, 1.0)
          ..rotateY(rotation)
          ..scaleByDouble(scale, scale, scale, 1.0),
        child: SizedBox(
          width: width * 0.82,
          height: math.max(rowExtent, height * 0.14),
          child: Center(child: content),
        ),
      ),
    );
  }
}

class _CameraLyricLine extends StatelessWidget {
  const _CameraLyricLine({
    required this.line,
    required this.active,
    required this.progress,
    required this.position,
    required this.size,
    required this.style,
    required this.accent,
    required this.opacity,
    required this.blur,
  });

  final LyricLine line;
  final bool active;
  final double progress;
  final Duration position;
  final double size;
  final LyricsStyle style;
  final AppAccent accent;
  final double opacity;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final TextStyle base = TextStyle(
      fontFamily: style.fontFamily.family,
      fontSize: size,
      height: 1.12,
      fontWeight: active ? style.weight.value : FontWeight.w500,
      letterSpacing: style.letterSpacing,
    );
    final Widget text = active
        ? _CameraKaraokeText(
            line: line,
            progress: progress,
            position: position,
            style: base,
            color: accent.primary,
          )
        : Text(
            line.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: base.copyWith(color: Colors.white),
          );
    return Opacity(
      opacity: opacity * style.lyricsOpacity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          text,
          if (style.showTranslation &&
              (line.translation?.trim().isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                line.translation!.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: base.copyWith(
                  fontSize: size * 0.38,
                  fontWeight: FontWeight.w400,
                  color: Colors.white.withValues(
                    alpha: style.subtitleOpacity * 0.82,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CameraKaraokeText extends StatelessWidget {
  const _CameraKaraokeText({
    required this.line,
    required this.progress,
    required this.position,
    required this.style,
    required this.color,
  });

  final LyricLine line;
  final double progress;
  final Duration position;
  final TextStyle style;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final double p = progress.clamp(0.0, 1.0);
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (Rect bounds) => LinearGradient(
        colors: <Color>[color, color, Colors.white, Colors.white],
        stops: <double>[0, p, (p + 0.008).clamp(0.0, 1.0), 1],
      ).createShader(bounds),
      child: Text(
        line.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: style.copyWith(color: Colors.white),
      ),
    );
  }
}

class _CameraAtmospherePainter extends CustomPainter {
  const _CameraAtmospherePainter({
    required this.primary,
    required this.secondary,
  });
  final Color primary;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF0C101B),
    );
    for (final (Offset center, double radius, Color color) item
        in <(Offset, double, Color)>[
          (
            Offset(size.width * .18, size.height * .22),
            size.width * .58,
            primary,
          ),
          (
            Offset(size.width * .84, size.height * .78),
            size.width * .66,
            secondary,
          ),
        ]) {
      canvas.drawCircle(
        item.$1,
        item.$2,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              item.$3.withValues(alpha: .20),
              item.$3.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: item.$1, radius: item.$2)),
      );
    }
    final Paint guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: .045);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * .5, size.height * .5),
        width: size.width * .98,
        height: size.height * 1.6,
      ),
      guide,
    );
  }

  @override
  bool shouldRepaint(_CameraAtmospherePainter oldDelegate) =>
      oldDelegate.primary != primary || oldDelegate.secondary != secondary;
}
