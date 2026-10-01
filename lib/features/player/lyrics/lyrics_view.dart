/// lyrics_view.dart
///
/// 歌词相关的 provider 与渲染组件。
///
/// - [currentLyricsProvider]：当前曲目的歌词（内嵌优先，其次同目录 `.lrc`）；
/// - [LyricsPanel]：播放页右侧的**多行滚动歌词**（0.0.16 起歌词与封面是主内容，
///   当前行高亮并自动居中，点某一行可以跳到那个时间）。
///
/// 性能：歌词需要跟播放进度。这里用
/// `playbackPositionProvider.select(行号)` 只在**当前行号变化**时才重建，
/// 而不是每次进度推送都重建一次（进度一秒推好几次）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/player_engine.dart';
import '../../../core/audio/player_providers.dart';
import '../../../core/source/source_store.dart';
import '../../../shared/theme/app_accent.dart';
import '../../../shared/theme/app_colors.dart';
import 'lyrics_parser.dart';
import 'lyrics_style.dart';
import 'lyrics_timeline.dart';
import 'project_lyric_renderers.dart';

/// 当前曲目的歌词。没有曲目 / 找不到歌词时为 `null`。
///
/// 切歌时自动重新加载（`watch` 了当前曲目）。
final currentLyricsProvider = FutureProvider<Lyrics?>((ref) async {
  final Track? track = ref.watch(playerControllerProvider).currentTrack;
  if (track == null) return null;
  // 本地 / WebDAV / 在线曲目都可以走音源平台刮歌词（设置里可关）
  final bool useOnline = ref.watch(sourceScrapeProvider).value ?? false;
  return Lyrics.forTrack(track, useOnline: useOnline);
});

/// 当前唱到第几行（没有歌词 / 还没到第一行时为 `-1`）。
///
/// ⚠️ 用 `select` 只挑"行号"，所以**行号不变就不会通知** ——
/// 进度是高频的，桌面歌词浮层与小窗都靠这个避免每帧重绘。
final currentLyricIndexProvider = Provider<int>((ref) {
  final Lyrics? lyrics = ref.watch(currentLyricsProvider).value;
  if (lyrics == null || lyrics.isEmpty) return -1;
  return ref.watch(
    playbackPositionProvider.select(
      (AsyncValue<Duration> position) =>
          lyrics.indexAt(position.value ?? Duration.zero),
    ),
  );
});

/// 当前这一行的文本（空行 / 没歌词时为 `null`）。
///
/// 桌面歌词浮层（`platforms/windows/lyrics_overlay.dart`）用它。
final currentLyricLineProvider = Provider<String?>((ref) {
  final Lyrics? lyrics = ref.watch(currentLyricsProvider).value;
  if (lyrics == null || lyrics.isEmpty) return null;
  final int index = ref.watch(currentLyricIndexProvider);
  if (index < 0 || index >= lyrics.lines.length) return null;
  final String text = lyrics.lines[index].text.trim();
  return text.isEmpty ? null : text;
});

/// 当前行的翻译（没有翻译时为 `null`）。
///
/// 来源见 [LyricLine.translation]（同时间戳的第二行）。
final currentLyricTranslationProvider = Provider<String?>((ref) {
  final Lyrics? lyrics = ref.watch(currentLyricsProvider).value;
  if (lyrics == null || lyrics.isEmpty) return null;
  final int index = ref.watch(currentLyricIndexProvider);
  if (index < 0 || index >= lyrics.lines.length) return null;
  final String? text = lyrics.lines[index].translation?.trim();
  return (text == null || text.isEmpty) ? null : text;
});

/// 下一句歌词（最后一行之后为 `null`）。
///
/// 桌面歌词浮层的第二行用它（有翻译时第二行优先显示翻译）。
final nextLyricLineProvider = Provider<String?>((ref) {
  final Lyrics? lyrics = ref.watch(currentLyricsProvider).value;
  if (lyrics == null || lyrics.isEmpty) return null;
  final int index = ref.watch(currentLyricIndexProvider);
  final int next = index + 1;
  if (index < 0 || next >= lyrics.lines.length) return null;
  final String text = lyrics.lines[next].text.trim();
  return text.isEmpty ? null : text;
});

/// 多行滚动歌词面板。
///
/// 字号 / 行距 / 是否自动滚动都可以在「外观设置 → 歌词」里调
/// （见 [LyricsStyle]）。
class LyricsPanel extends ConsumerStatefulWidget {
  /// 创建面板。
  const LyricsPanel({super.key, this.centered = false});

  /// 普通歌词面板在宽屏辅助视图使用居中排版，避免跟随旧的靠右偏好挤在一侧。
  final bool centered;

  @override
  ConsumerState<LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends ConsumerState<LyricsPanel> {
  final ScrollController _controller = ScrollController();
  final Map<int, GlobalKey> _lineKeys = <int, GlobalKey>{};

  /// 上一次高亮的行号，用来判断"要不要滚动"。
  int _lastIndex = -2;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final LyricsStyle style =
        ref.watch(lyricsStyleProvider).value ?? const LyricsStyle();
    final Track? track = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.currentTrack),
    );
    final Lyrics? lyrics = ref.watch(currentLyricsProvider).value;

    if (lyrics == null || lyrics.isEmpty) {
      return _LyricsPlaceholder(
        title: track == null ? '暂无歌词' : '未找到歌词',
        hint: track == null ? '选择一首歌，这里会跟随滚动' : '把同名 .lrc 放在音频旁边，或写入内嵌歌词标签',
        fontSize: style.fontSize,
      );
    }

    final int index = ref.watch(
      playbackPositionProvider.select(
        (AsyncValue<Duration> position) =>
            lyrics.indexAt(position.value ?? Duration.zero),
      ),
    );
    // 滚动列表保留独立的 30Hz 更新上限：比旧版 10Hz 连续很多，
    // 又不会像主舞台的 60Hz 时钟一样让整张 ListView 反复布局。
    final int positionMs = ref.watch(
      playbackPositionProvider.select(
        (AsyncValue<Duration> value) =>
            ((value.value ?? Duration.zero).inMilliseconds ~/ 33) * 33,
      ),
    );
    final Duration position = Duration(milliseconds: positionMs);
    final LyricsTimeline timeline = LyricsTimeline.fromLyrics(
      lyrics,
      source: 'hoh-normalized',
    );

    _scheduleAutoScroll(index, style);

    return ScrollConfiguration(
      // 歌词面板不要滚动条（否则挡住文字），用手势滚动
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ListView.builder(
        controller: _controller,
        // 不设 itemExtent：歌词可按可用宽度自然换行，英文单词不会被省略。
        padding: const EdgeInsets.symmetric(vertical: 24),
        itemCount: lyrics.lines.length,
        itemBuilder: (BuildContext context, int i) {
          return _LyricLineTile(
            key: _lineKeys.putIfAbsent(i, GlobalKey.new),
            line: lyrics.lines[i],
            active: i == index,
            centered: widget.centered,
            style: style,
            accent: accent,
            position: position,
            wordProgress: timeline.progressAt(i, position),
            lineDuration: timeline.endAt(i) - lyrics.lines[i].time,
            onTap: () => ref
                .read(playerControllerProvider.notifier)
                .seek(lyrics.lines[i].time),
          );
        },
      ),
    );
  }

  /// 当前行变化时把那一行滚到中间（设置里可以关掉）。
  void _scheduleAutoScroll(int index, LyricsStyle style) {
    if (index == _lastIndex) return;
    _lastIndex = index;
    if (!style.autoScroll) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final BuildContext? lineContext = _lineKeys[index]?.currentContext;
      if (index >= 0 && lineContext != null) {
        Scrollable.ensureVisible(
          lineContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutQuart,
        );
      }
    });
  }
}

/// 一行歌词。
class _LyricLineTile extends StatefulWidget {
  const _LyricLineTile({
    super.key,
    required this.line,
    required this.active,
    required this.centered,
    required this.style,
    required this.accent,
    required this.wordProgress,
    required this.position,
    required this.lineDuration,
    required this.onTap,
  });

  final LyricLine line;
  final bool active;
  final bool centered;
  final LyricsStyle style;
  final AppAccent accent;
  final double wordProgress;
  final Duration position;
  final Duration lineDuration;
  final VoidCallback onTap;

  @override
  State<_LyricLineTile> createState() => _LyricLineTileState();
}

class _LyricLineTileState extends State<_LyricLineTile> {
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Align(
          alignment: widget.centered
              ? Alignment.center
              : widget.style.align.alignment,
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 140),
            style: const TextStyle(height: 1.25),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ProjectLyricLine(
                  text: widget.line.text,
                  words: widget.active
                      ? widget.line.words
                      : const <LyricWord>[],
                  position: widget.position,
                  progress: widget.wordProgress,
                  lineDuration: widget.lineDuration,
                  style: widget.centered
                      ? widget.style.copyWith(align: LyricAlign.center)
                      : widget.style,
                  mode: widget.style.layout,
                  accent: widget.accent.primary,
                  active: widget.active,
                  opacity: widget.active ? 1 : .62,
                ),
                if (widget.line.translation?.trim().isNotEmpty ?? false)
                  ProjectLyricLine(
                    text: widget.line.translation!.trim(),
                    words: const <LyricWord>[],
                    position: widget.position,
                    progress: widget.wordProgress,
                    lineDuration: widget.lineDuration,
                    style:
                        (widget.centered
                                ? widget.style.copyWith(
                                    align: LyricAlign.center,
                                  )
                                : widget.style)
                            .copyWith(
                              fontSize: (widget.style.fontSize * .72).clamp(
                                12.0,
                                20.0,
                              ),
                              weight: LyricWeight.regular,
                              lyricsOpacity: widget.style.subtitleOpacity,
                            ),
                    mode: widget.style.layout,
                    accent: widget.accent.primary,
                    active: widget.active,
                    opacity: widget.active ? 1 : .58,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 没有歌词时的占位。
class _LyricsPlaceholder extends StatelessWidget {
  const _LyricsPlaceholder({
    required this.title,
    required this.hint,
    required this.fontSize,
  });

  final String title;
  final String hint;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.lyrics_outlined,
            size: 34,
            color: Colors.white.withValues(alpha: 0.22),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              color: const Color(0xD9FFFFFF),
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11.5,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
