/// android_karaoke_lyrics.dart
///
/// Android 专用轻量逐字歌词：只保留当前句、前一句和后一句，
/// 使用 TextSpan 着色而不是模糊/折射/逐字 shader，适合手机 GPU。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart';
import '../../core/audio/player_providers.dart';
import '../player/lyrics/lyrics_parser.dart';
import '../player/lyrics/lyrics_timeline.dart';
import '../player/lyrics/lyrics_view.dart';
import '../../shared/theme/app_accent.dart';

/// Android 播放页使用的低开销歌词组件。
class AndroidKaraokeLyrics extends ConsumerWidget {
  /// 创建轻量歌词。
  const AndroidKaraokeLyrics({super.key, this.compact = false});

  /// 紧凑模式用于首页当前播放卡片，只保留三句并降低字号/间距。
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Lyrics? lyrics = ref.watch(currentLyricsProvider).value;
    final Track? track = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState state) => state.currentTrack,
      ),
    );
    final AppAccent accent = AppAccent.of(context);
    if (lyrics == null || lyrics.isEmpty) {
      return Center(
        child: Text(
          track == null ? '选择一首歌开始播放' : '暂无歌词',
          style: TextStyle(
            color: accent.mutedForeground,
            fontSize: compact ? 11 : null,
          ),
        ),
      );
    }

    // 80ms 足够平滑，同时比逐帧重绘整套 ProjectLyricLine 低很多。
    final Duration position = ref.watch(
      playbackPositionProvider.select(
        (AsyncValue<Duration> value) => Duration(
          milliseconds:
              ((value.value ?? Duration.zero).inMilliseconds ~/ 80) * 80,
        ),
      ),
    );
    final int active = lyrics.indexAt(position);
    if (active < 0) {
      return Center(
        child: Text('歌词即将开始', style: TextStyle(color: accent.mutedForeground)),
      );
    }
    final LyricsTimeline timeline = LyricsTimeline.fromLyrics(
      lyrics,
      source: 'android-lightweight',
    );
    final List<int> indexes = <int>[
      if (active - 1 >= 0) active - 1,
      active,
      if (active + 1 < lyrics.lines.length) active + 1,
    ];

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (final int index in indexes)
          Padding(
            padding: EdgeInsets.symmetric(vertical: compact ? 1 : 7),
            child: _AndroidKaraokeLine(
              line: lyrics.lines[index],
              active: index == active,
              progress: timeline.progressAt(index, position),
              position: position,
              lineDuration: timeline.endAt(index) - lyrics.lines[index].time,
              color: accent.primary,
              compact: compact,
              onTap: () => ref
                  .read(playerControllerProvider.notifier)
                  .seek(lyrics.lines[index].time),
            ),
          ),
      ],
    );
  }
}

class _AndroidKaraokeLine extends StatelessWidget {
  const _AndroidKaraokeLine({
    required this.line,
    required this.active,
    required this.progress,
    required this.position,
    required this.lineDuration,
    required this.color,
    required this.compact,
    required this.onTap,
  });

  final LyricLine line;
  final bool active;
  final double progress;
  final Duration position;
  final Duration lineDuration;
  final Color color;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String text = line.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final double fraction = line.words.isNotEmpty
        ? progress.clamp(0.0, 1.0)
        : _plainFraction();
    final List<String> characters = text.characters.toList(growable: false);
    final int highlighted = (characters.length * fraction).round().clamp(
      0,
      characters.length,
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            for (int i = 0; i < characters.length; i++)
              TextSpan(
                text: characters[i],
                style: TextStyle(
                  color: !active
                      ? (AppAccent.of(context).mutedForeground
                            .withValues(alpha: .55))
                      : (i < highlighted
                            ? color
                            : AppAccent.of(context).foreground
                                  .withValues(alpha: .72)),
                ),
              ),
          ],
        ),
        textAlign: TextAlign.center,
        maxLines: compact ? 1 : 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: active ? (compact ? 14 : 22) : (compact ? 11 : 15),
          height: compact ? 1.15 : 1.3,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

  double _plainFraction() {
    if (lineDuration <= Duration.zero) return 0;
    return ((position - line.time).inMilliseconds / lineDuration.inMilliseconds)
        .clamp(0.0, 1.0);
  }
}
