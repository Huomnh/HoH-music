/// HoH's native Flutter lyric renderers.
///
/// Audio, lyric parsing and playback timing remain owned by HoH. The painter
/// keeps the useful sweep/lift primitives small and composable so each HoH
/// visual mode can share the same timeline without importing a second player.
///
/// Some character sweep/ripple math is adapted from GPL-3.0 projects:
/// - ZeroBit Player: lib/components/lyric/word_render.dart
/// - Pure Music: lib/page/now_playing_page/component/lyrics_line_painter.dart
/// See docs/开源项目与协议清单.md for upstream links and pinned revisions.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'lyrics_parser.dart';
import 'lyrics_style.dart';

@immutable
class LyricGlyphTiming {
  const LyricGlyphTiming({
    required this.progress,
    required this.groupProgress,
    required this.groupIndex,
    required this.indexInGroup,
    required this.groupLength,
    required this.durationSeconds,
  });

  /// Progress of this grapheme, used for the Pure Music lift/cursor.
  final double progress;

  /// Word-level progress; ZeroBit's overlapping character ripple uses this.
  final double groupProgress;
  final int groupIndex;
  final int indexInGroup;
  final int groupLength;
  final double durationSeconds;
}

/// Builds per-grapheme timings from authored word timestamps when available.
/// Plain LRC has no word timestamps, so it uses an explicitly visual
/// interpolation over the line interval.
List<LyricGlyphTiming> buildLyricGlyphTimings({
  required String text,
  required List<LyricWord> words,
  required Duration position,
  required double lineProgress,
  required Duration lineDuration,
}) {
  final List<String> glyphs = text.characters.toList(growable: false);
  if (glyphs.isEmpty) return const <LyricGlyphTiming>[];
  final List<int> offsets = <int>[];
  int utf16Offset = 0;
  for (final String glyph in glyphs) {
    offsets.add(utf16Offset);
    utf16Offset += glyph.length;
  }

  final List<LyricGlyphTiming> result = List<LyricGlyphTiming>.generate(
    glyphs.length,
    (int index) => LyricGlyphTiming(
      progress: (lineProgress * glyphs.length - index).clamp(0.0, 1.0),
      groupProgress: lineProgress,
      groupIndex: 0,
      indexInGroup: index,
      groupLength: glyphs.length,
      durationSeconds:
          lineDuration.inMicroseconds / Duration.microsecondsPerSecond,
    ),
    growable: false,
  );
  if (words.isEmpty) return result;

  int searchFrom = 0;
  int group = 1;
  for (final LyricWord word in words) {
    final String content = word.text;
    if (content.isEmpty || word.end <= word.start) continue;
    final int sourceStart = text.indexOf(content, searchFrom);
    if (sourceStart < 0) continue;
    final List<String> wordGlyphs = content.characters.toList(growable: false);
    if (wordGlyphs.isEmpty) continue;
    final int wordEnd = sourceStart + content.length;
    final int first = offsets.indexWhere((int value) => value >= sourceStart);
    if (first < 0) continue;
    int after = offsets.indexWhere((int value) => value >= wordEnd);
    if (after < 0) after = glyphs.length;
    final int count = math.min(wordGlyphs.length, after - first);
    if (count <= 0) continue;
    final int durationUs = word.end.inMicroseconds - word.start.inMicroseconds;
    final double wordProgress =
        ((position.inMicroseconds - word.start.inMicroseconds) / durationUs)
            .clamp(0.0, 1.0);
    for (int local = 0; local < count; local++) {
      final int index = first + local;
      final double start = local / count;
      final double end = (local + 1) / count;
      final double glyphProgress = ((wordProgress - start) / (end - start))
          .clamp(0.0, 1.0);
      result[index] = LyricGlyphTiming(
        progress: glyphProgress,
        groupProgress: wordProgress,
        groupIndex: group,
        indexInGroup: local,
        groupLength: count,
        durationSeconds: durationUs / Duration.microsecondsPerSecond,
      );
    }
    searchFrom = wordEnd;
    group++;
  }
  return result;
}

/// Shared painter surface. It preserves a stable line layout while painting
/// the time-synced sweep and current-character effect without rebuilding one
/// widget per character on every audio tick.
class ProjectLyricLine extends StatelessWidget {
  const ProjectLyricLine({
    super.key,
    required this.text,
    required this.words,
    required this.position,
    required this.progress,
    required this.lineDuration,
    required this.style,
    required this.mode,
    required this.accent,
    required this.active,
    required this.opacity,
  });

  final String text;
  final List<LyricWord> words;
  final Duration position;
  final double progress;
  final Duration lineDuration;
  final LyricsStyle style;
  final LyricsLayoutMode mode;
  final Color accent;
  final bool active;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    // Pure Music 的主行缩放接近 1.0；避免外层再叠加一个无法感知宽度的
    // AnimatedScale，长英文或中文歌词不会再撞出播放页边界。
    final double fontSize =
        (style.fontSize * (active ? style.activeScale : 1.0)).clamp(
          active ? 24.0 : 15.0,
          active ? 52.0 : 34.0,
        );
    final TextStyle textStyle = TextStyle(
      fontFamily: style.fontFamily.family,
      fontSize: fontSize,
      fontWeight: active ? style.weight.value : FontWeight.w500,
      letterSpacing: style.letterSpacing,
      height: 1.22,
    );
    final List<LyricGlyphTiming> timings = buildLyricGlyphTimings(
      text: text,
      words: active ? words : const <LyricWord>[],
      position: position,
      lineProgress: active ? progress : (progress >= 1 ? 1 : 0),
      lineDuration: lineDuration,
    );
    return RepaintBoundary(
      child: SizedBox(
        height: fontSize * 1.55,
        width: double.infinity,
        child: CustomPaint(
          painter: ProjectLyricLinePainter(
            text: text,
            textStyle: textStyle,
            align: style.align.textAlign,
            timings: timings,
            accent: accent,
            active: active,
            mode: mode,
            opacity: opacity * style.lyricsOpacity,
            enableGlow: style.enableGlow,
            liftStyle: style.liftStyle,
            displayMode: style.displayMode,
          ),
        ),
      ),
    );
  }
}

class ProjectLyricLinePainter extends CustomPainter {
  const ProjectLyricLinePainter({
    required this.text,
    required this.textStyle,
    required this.align,
    required this.timings,
    required this.accent,
    required this.active,
    required this.mode,
    required this.opacity,
    required this.enableGlow,
    required this.liftStyle,
    required this.displayMode,
  });

  final String text;
  final TextStyle textStyle;
  final TextAlign align;
  final List<LyricGlyphTiming> timings;
  final Color accent;
  final bool active;
  final LyricsLayoutMode mode;
  final double opacity;
  final bool enableGlow;
  final LyricLiftStyle liftStyle;
  final LyricDisplayMode displayMode;

  @override
  void paint(Canvas canvas, Size size) {
    if (text.isEmpty || size.isEmpty) return;
    final List<String> glyphs = text.characters.toList(growable: false);
    if (glyphs.isEmpty) return;

    TextPainter makePainter(TextStyle style) => TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
    );

    // Keep the song line on one visual row, shrinking only when necessary.
    double fontSize = textStyle.fontSize ?? 30;
    TextPainter measure = makePainter(textStyle);
    measure.layout(maxWidth: double.infinity);
    if (measure.width > size.width && measure.width > 0) {
      fontSize *= size.width / measure.width;
      measure.dispose();
      measure = makePainter(textStyle.copyWith(fontSize: fontSize));
      measure.layout(maxWidth: size.width);
    } else {
      measure.layout(maxWidth: size.width);
    }
    final double x = switch (align) {
      TextAlign.left || TextAlign.start || TextAlign.justify => 0,
      TextAlign.right || TextAlign.end => size.width - measure.width,
      _ => (size.width - measure.width) / 2,
    };
    final double y = (size.height - measure.height) / 2;
    final Color dim = Colors.white.withValues(
      alpha: (active ? .27 : .82) * opacity,
    );
    final TextStyle dimStyle = textStyle.copyWith(
      fontSize: fontSize,
      color: dim,
    );
    final TextPainter basePainter = makePainter(dimStyle);
    basePainter.layout(maxWidth: size.width);
    basePainter.paint(canvas, Offset(x, y));
    if (!active || timings.isEmpty) {
      basePainter.dispose();
      measure.dispose();
      return;
    }

    final List<Rect?> glyphRects = List<Rect?>.filled(glyphs.length, null);
    int utf16Offset = 0;
    for (int i = 0; i < glyphs.length; i++) {
      utf16Offset += glyphs[i].length;
      final List<TextBox> selection = measure.getBoxesForSelection(
        TextSelection(
          baseOffset: utf16Offset - glyphs[i].length,
          extentOffset: utf16Offset,
        ),
      );
      if (selection.isNotEmpty) {
        glyphRects[i] = selection.first.toRect().shift(Offset(x, y));
      }
    }
    if (glyphRects.every((Rect? rect) => rect == null)) {
      basePainter.dispose();
      measure.dispose();
      return;
    }

    double cursorX = x;
    bool foundCursor = false;
    for (int i = 0; i < glyphs.length && i < timings.length; i++) {
      final Rect? rect = glyphRects[i];
      if (rect == null) continue;
      final double p = timings[i].progress.clamp(0.0, 1.0);
      if (p >= 1) {
        cursorX = rect.right;
      } else {
        cursorX = rect.left + rect.width * p;
        foundCursor = true;
        break;
      }
    }
    if (!foundCursor &&
        timings.every((LyricGlyphTiming item) => item.progress >= 1)) {
      cursorX = x + measure.width;
    }

    if (cursorX > x + .5) {
      final double feather = (fontSize * .52).clamp(9.0, 28.0);
      final Rect shaderBounds = Rect.fromLTWH(
        x,
        y,
        measure.width,
        measure.height,
      );
      final double sweep = ((cursorX - x) / math.max(1, measure.width)).clamp(
        0.0,
        1.0,
      );
      final double fadeStart = (sweep - feather / math.max(1, measure.width))
          .clamp(0.0, 1.0);
      final double fadeEnd = (sweep + feather / math.max(1, measure.width))
          .clamp(fadeStart, 1.0);
      final Paint sweepPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[
            accent.withValues(alpha: opacity),
            Colors.white.withValues(alpha: opacity),
            Colors.white.withValues(alpha: opacity * .08),
          ],
          stops: <double>[fadeStart, sweep, fadeEnd],
        ).createShader(shaderBounds);
      final TextPainter playedPainter = makePainter(
        textStyle.copyWith(color: null, foreground: sweepPaint),
      );
      playedPainter.layout(maxWidth: size.width);
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(
          x,
          y - fontSize,
          cursorX + feather,
          y + measure.height + fontSize,
        ),
      );
      playedPainter.paint(canvas, Offset(x, y));
      canvas.restore();
      playedPainter.dispose();
    }

    final bool glyphRipple = mode.usesGlyphRipple;
    final bool wordEffects =
        active &&
        mode.usesWordTiming &&
        displayMode != LyricDisplayMode.lineByLine;
    final double baseline =
        y + measure.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    for (int i = 0; i < glyphs.length && i < timings.length; i++) {
      final Rect? rect = glyphRects[i];
      final String glyph = glyphs[i];
      if (rect == null || glyph.trim().isEmpty) continue;
      final LyricGlyphTiming timing = timings[i];
      double pulse;
      double maxScale;
      if (!wordEffects) continue;
      if (glyphRipple) {
        // 字符涟漪：后一个字略晚进入，并带一段柔和的缩放/辉光波纹。
        final double waveWidth = 1 / (.05 * (timing.groupLength - 1) + 1);
        final double start = timing.indexInGroup * .05 * waveWidth;
        final double local = ((timing.groupProgress - start) / waveWidth).clamp(
          0.0,
          1.0,
        );
        pulse = local < .4
            ? Curves.easeOut.transform(local / .4)
            : 1 - Curves.easeIn.transform((local - .4) / .6);
        final double longNote = ((timing.durationSeconds - .75) / 2.25).clamp(
          0.0,
          1.0,
        );
        maxScale = 1.10 + longNote * .12;
      } else {
        pulse = math.sin(timing.progress.clamp(0.0, 1.0) * math.pi);
        // 逐字效果按词时长决定是否放大，短促的字只做扫光，长音才产生
        // 抬升/辉光，避免每个字都突然弹一下。
        maxScale = timing.durationSeconds >= 0.75 ? 1.08 : 1.0;
      }
      if (pulse <= .02) continue;
      final double scale = 1 + (maxScale - 1) * pulse;
      final double liftAmount = 5.0 * pulse;
      final double lift = glyphRipple
          ? 0
          : liftStyle == LyricLiftStyle.cosine
          ? liftAmount * (0.5 + 0.5 * math.cos(math.pi * timing.progress))
          : liftAmount;
      final double glowAlpha = glyphRipple ? .68 * pulse : .42 * pulse;
      final TextPainter glyphPainter = TextPainter(
        text: TextSpan(
          text: glyph,
          style: textStyle.copyWith(
            fontSize: fontSize,
            color: Colors.white.withValues(alpha: opacity),
            shadows: enableGlow
                ? <Shadow>[
                    Shadow(
                      color: accent.withValues(alpha: glowAlpha * opacity),
                      blurRadius: glyphRipple ? 8 * pulse : 12 * pulse,
                    ),
                    if (glyphRipple)
                      Shadow(
                        color: accent.withValues(
                          alpha: glowAlpha * .48 * opacity,
                        ),
                        blurRadius: 17 * pulse,
                      ),
                  ]
                : const <Shadow>[],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final double cx = rect.center.dx;
      canvas.save();
      canvas.translate(cx, baseline - lift);
      canvas.scale(scale);
      glyphPainter.paint(
        canvas,
        Offset(
          -glyphPainter.width / 2,
          -glyphPainter.computeDistanceToActualBaseline(
            TextBaseline.alphabetic,
          ),
        ),
      );
      canvas.restore();
      glyphPainter.dispose();
    }

    basePainter.dispose();
    measure.dispose();
  }

  @override
  bool shouldRepaint(covariant ProjectLyricLinePainter oldDelegate) =>
      oldDelegate.text != text ||
      oldDelegate.textStyle != textStyle ||
      oldDelegate.align != align ||
      oldDelegate.timings != timings ||
      oldDelegate.accent != accent ||
      oldDelegate.active != active ||
      oldDelegate.mode != mode ||
      oldDelegate.opacity != opacity ||
      oldDelegate.enableGlow != enableGlow ||
      oldDelegate.liftStyle != liftStyle ||
      oldDelegate.displayMode != displayMode;
}
