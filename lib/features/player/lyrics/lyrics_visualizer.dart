/// Visualizer boundary for the player lyrics surface.
library;

import 'package:flutter/widgets.dart';

import 'lyrics_parser.dart';
import 'lyrics_timeline.dart';

/// Immutable render input sent to a lyrics visualizer on every clock update.
class LyricsVisualizerFrame {
  const LyricsVisualizerFrame({
    required this.timeline,
    required this.position,
    required this.currentIndex,
    required this.progress,
  });

  final LyricsTimeline timeline;
  final Duration position;
  final int currentIndex;
  final double progress;

  LyricLine? get currentLine =>
      currentIndex < 0 || currentIndex >= timeline.lines.length
      ? null
      : timeline.lines[currentIndex];

  LyricLine? get nextLine => currentIndex + 1 >= timeline.lines.length
      ? null
      : timeline.lines[currentIndex + 1];
}

/// Renderer contract. A renderer owns presentation only; playback and source
/// selection stay in Riverpod/audio services.
abstract interface class LyricsVisualizer {
  Widget buildFrame(BuildContext context, LyricsVisualizerFrame frame);
}

/// Stable baseline renderer used while advanced native visualizers are loaded.
/// It intentionally contains no transition or animation policy.
class StillLyricsVisualizer implements LyricsVisualizer {
  const StillLyricsVisualizer({this.textStyle = const TextStyle(fontSize: 28)});

  final TextStyle textStyle;

  @override
  Widget buildFrame(BuildContext context, LyricsVisualizerFrame frame) {
    final LyricLine? current = frame.currentLine;
    final LyricLine? next = frame.nextLine;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (current != null)
            Text(current.text, textAlign: TextAlign.center, style: textStyle),
          if (current?.translation?.trim().isNotEmpty ?? false)
            Text(
              current!.translation!.trim(),
              textAlign: TextAlign.center,
              style: textStyle.copyWith(fontSize: textStyle.fontSize! * 0.42),
            ),
          if (next != null)
            Opacity(
              opacity: 0.32,
              child: Text(
                next.text,
                textAlign: TextAlign.center,
                style: textStyle,
              ),
            ),
        ],
      ),
    );
  }
}
