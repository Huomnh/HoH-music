/// Normalized lyric timeline shared by every renderer.
library;

import 'lyrics_parser.dart';

/// A renderer-independent lyric timeline.
///
/// Input adapters may produce LRC, TTML or another source format, but the
/// player surface only consumes this normalized model. A renderer must never
/// inspect the original source format or invent word timing that is absent.
class LyricsTimeline {
  const LyricsTimeline({required this.lines, this.source, this.confidence = 0});

  factory LyricsTimeline.fromLyrics(
    Lyrics lyrics, {
    String? source,
    double confidence = 0,
  }) => LyricsTimeline(
    lines: List<LyricLine>.unmodifiable(lyrics.lines),
    source: source,
    confidence: confidence.clamp(0, 1),
  );

  final List<LyricLine> lines;
  final String? source;
  final double confidence;

  bool get isEmpty => lines.isEmpty;

  int indexAt(Duration position) {
    if (lines.isEmpty) return -1;
    int low = 0;
    int high = lines.length - 1;
    while (low <= high) {
      final int middle = (low + high) ~/ 2;
      if (lines[middle].time <= position) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return high.clamp(0, lines.length - 1);
  }

  Duration endAt(int index) {
    if (index < 0 || index >= lines.length) return Duration.zero;
    final LyricLine line = lines[index];
    final Duration? authoredEnd = line.end;
    if (authoredEnd != null && authoredEnd > line.time) return authoredEnd;
    if (index + 1 < lines.length && lines[index + 1].time > line.time) {
      return lines[index + 1].time;
    }
    if (line.words.isNotEmpty) {
      final Duration wordEnd = line.words
          .map((LyricWord word) => word.end)
          .reduce((Duration a, Duration b) => a > b ? a : b);
      if (wordEnd > line.time) return wordEnd;
    }
    return line.time + const Duration(seconds: 5);
  }

  double progressAt(int index, Duration position) {
    if (index < 0 || index >= lines.length) return 0;
    final Duration start = lines[index].time;
    final Duration end = endAt(index);
    final int span = end.inMicroseconds - start.inMicroseconds;
    if (span <= 0) return 1;
    return ((position.inMicroseconds - start.inMicroseconds) / span).clamp(
      0,
      1,
    );
  }
}
