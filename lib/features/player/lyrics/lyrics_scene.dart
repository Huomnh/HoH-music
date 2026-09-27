/// Lyrics scenes inspired by immersive lyric players, implemented natively in Flutter.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/player_providers.dart';
import '../../../shared/theme/app_accent.dart';
import 'lyrics_parser.dart';
import 'lyrics_camera_stage.dart';
import 'lyrics_style.dart';
import 'lyrics_view.dart' show currentLyricsProvider;
import 'lyrics_timeline.dart';
import 'lyrics_visualizer.dart';

class LyricsScene extends ConsumerWidget {
  const LyricsScene({
    super.key,
    required this.mode,
    required this.onShowLyrics,
  });

  final LyricsLayoutMode mode;
  final VoidCallback onShowLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LyricsStyle style =
        ref.watch(lyricsStyleProvider).value ?? const LyricsStyle();
    final Lyrics? lyrics = ref.watch(currentLyricsProvider).value;
    final Duration position =
        ref.watch(playbackPositionProvider).value ?? Duration.zero;
    final LyricsTimeline timeline = lyrics == null
        ? const LyricsTimeline(lines: <LyricLine>[])
        : LyricsTimeline.fromLyrics(lyrics, source: 'hoh-normalized');
    final int index = timeline.indexAt(position);
    final AppAccent accent = AppAccent.of(context);
    if (lyrics == null || lyrics.isEmpty || index < 0) {
      return _NoLyrics(accent: accent, onShowLyrics: onShowLyrics);
    }
    return _LyricsSceneStage(
      key: ValueKey<String>(mode.name),
      mode: mode,
      style: style,
      accent: accent,
      lyrics: lyrics,
      index: index,
      position: position,
      frame: LyricsVisualizerFrame(
        timeline: timeline,
        position: position,
        currentIndex: index,
        progress: timeline.progressAt(index, position),
      ),
      onSeek: (Duration value) =>
          ref.read(playerControllerProvider.notifier).seek(value),
    );
  }
}

class _LyricsSceneStage extends StatefulWidget {
  const _LyricsSceneStage({
    super.key,
    required this.mode,
    required this.style,
    required this.accent,
    required this.lyrics,
    required this.index,
    required this.position,
    required this.frame,
    required this.onSeek,
  });

  final LyricsLayoutMode mode;
  final LyricsStyle style;
  final AppAccent accent;
  final Lyrics lyrics;
  final int index;
  final Duration position;
  final LyricsVisualizerFrame frame;
  final ValueChanged<Duration> onSeek;

  @override
  State<_LyricsSceneStage> createState() => _LyricsSceneStageState();
}

class _LyricsSceneStageState extends State<_LyricsSceneStage> {
  @override
  Widget build(BuildContext context) {
    final LyricLine line = widget.frame.currentLine!;
    if (widget.mode == LyricsLayoutMode.flowline) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: LyricsCameraStage(
          frame: widget.frame,
          style: widget.style,
          accent: widget.accent,
          onSeek: widget.onSeek,
        ),
      );
    }
    final String previous = widget.frame.currentIndex > 0
        ? widget.frame.timeline.lines[widget.frame.currentIndex - 1].text
        : '';
    final String next =
        widget.frame.currentIndex + 1 < widget.frame.timeline.lines.length
        ? widget.frame.timeline.lines[widget.frame.currentIndex + 1].text
        : '';
    final double progress = widget.frame.progress;
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            RepaintBoundary(
              child: CustomPaint(
                painter: _SceneAtmospherePainter(
                  phase: 0,
                  primary: widget.accent.primary,
                  secondary: widget.accent.secondary,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.black.withValues(alpha: 0.04),
                    Colors.black.withValues(alpha: 0.22),
                  ],
                ),
              ),
            ),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double size = (constraints.maxWidth * 0.050).clamp(
                  30.0,
                  56.0,
                );
                return Center(
                  child: GestureDetector(
                    onTap: () => widget.onSeek(line.time),
                    child: _AnimatedSceneColumn(
                      previous: previous,
                      next: next,
                      line: line,
                      progress: progress,
                      position: widget.position,
                      size: size,
                      style: widget.style,
                      accent: widget.accent,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedSceneColumn extends StatelessWidget {
  const _AnimatedSceneColumn({
    required this.previous,
    required this.next,
    required this.line,
    required this.progress,
    required this.position,
    required this.size,
    required this.style,
    required this.accent,
  });

  final String previous;
  final String next;
  final LyricLine line;
  final double progress;
  final Duration position;
  final double size;
  final LyricsStyle style;
  final AppAccent accent;

  @override
  Widget build(BuildContext context) {
    final double gap = style.spacing == LyricLineSpacing.tight ? 15 : 20;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (previous.trim().isNotEmpty)
            _SceneSideLine(
              text: previous,
              size: size * 0.48,
              opacity: 0.21,
              style: style,
            ),
          SizedBox(height: gap),
          LyricsKaraokeText(
            text: line.text,
            words: line.words,
            progress: progress,
            position: position,
            size: size,
            color: accent.primary,
            style: style,
          ),
          if (style.showTranslation &&
              (line.translation?.trim().isNotEmpty ?? false)) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              line.translation!.trim(),
              textAlign: TextAlign.center,
              style: _sceneTextStyle(
                style,
                color: Colors.white.withValues(alpha: style.subtitleOpacity),
                size: size * 0.40,
                weight: FontWeight.w400,
              ),
            ),
          ],
          SizedBox(height: gap),
          if (next.trim().isNotEmpty)
            _SceneSideLine(
              text: next,
              size: size * 0.52,
              opacity: 0.29,
              style: style,
            ),
        ],
      ),
    );
  }
}

/// TTML 有词级时间时逐词推进；普通 LRC 使用连续行进度。
class LyricsKaraokeText extends StatelessWidget {
  const LyricsKaraokeText({
    super.key,
    required this.text,
    required this.words,
    required this.progress,
    required this.position,
    required this.size,
    required this.color,
    required this.style,
  });

  final String text;
  final List<LyricWord> words;
  final double progress;
  final Duration position;
  final double size;
  final Color color;
  final LyricsStyle style;

  @override
  Widget build(BuildContext context) {
    final double p = progress.clamp(0.0, 1.0);
    final double edge = (p + 0.006).clamp(0.0, 1.0);
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (Rect bounds) => LinearGradient(
        colors: <Color>[color, color, Colors.white, Colors.white],
        stops: <double>[0, p, edge, 1],
      ).createShader(bounds),
      child: Opacity(
        opacity: style.lyricsOpacity,
        child: _text(text, Colors.white),
      ),
    );
  }

  Widget _text(String value, Color textColor) => Text(
    value,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.center,
    style: _sceneTextStyle(
      style,
      color: textColor,
      size: size,
      weight: style.weight.value,
    ),
  );
}

class _NoLyrics extends StatelessWidget {
  const _NoLyrics({required this.accent, required this.onShowLyrics});
  final AppAccent accent;
  final VoidCallback onShowLyrics;

  @override
  Widget build(BuildContext context) => Center(
    child: OutlinedButton.icon(
      onPressed: onShowLyrics,
      icon: const Icon(Icons.lyrics_rounded, size: 17),
      label: const Text('暂无歌词'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: accent.primary.withValues(alpha: 0.5)),
      ),
    ),
  );
}

class _SceneSideLine extends StatelessWidget {
  const _SceneSideLine({
    required this.text,
    required this.size,
    required this.opacity,
    required this.style,
  });
  final String text;
  final double size;
  final double opacity;
  final LyricsStyle style;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.center,
    style: _sceneTextStyle(
      style,
      color: Colors.white.withValues(alpha: opacity),
      size: size,
      weight: FontWeight.w500,
    ),
  );
}

TextStyle _sceneTextStyle(
  LyricsStyle style, {
  required Color color,
  required double size,
  required FontWeight weight,
}) => TextStyle(
  color: color,
  fontSize: size,
  height: 1.15,
  fontFamily: style.fontFamily.family,
  fontWeight: weight,
  letterSpacing: style.letterSpacing,
);

class _SceneAtmospherePainter extends CustomPainter {
  const _SceneAtmospherePainter({
    required this.phase,
    required this.primary,
    required this.secondary,
  });
  final double phase;
  final Color primary;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final double angle = phase * math.pi * 2;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF10131F),
    );
    final List<(Offset, double, Color, double)> orbs =
        <(Offset, double, Color, double)>[
          (
            Offset(
              size.width * (0.22 + math.sin(angle * 0.7) * 0.10),
              size.height * 0.25,
            ),
            size.width * 0.54,
            primary,
            0.27,
          ),
          (
            Offset(
              size.width * (0.78 + math.cos(angle * 0.45) * 0.12),
              size.height * 0.72,
            ),
            size.width * 0.62,
            secondary,
            0.23,
          ),
        ];
    for (final (Offset center, double radius, Color color, double opacity)
        in orbs) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.06);
    final double shift = math.sin(angle * 0.4) * 18;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.1, size.height * 0.5),
        width: size.width * 0.8,
        height: size.height * 1.12 + shift,
      ),
      line,
    );
  }

  @override
  bool shouldRepaint(_SceneAtmospherePainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.primary != primary ||
      oldDelegate.secondary != secondary;
}
