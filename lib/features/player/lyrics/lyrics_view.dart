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

  /// 滚动列表布局在宽屏播放页使用居中排版，避免跟随旧的靠右偏好挤在一侧。
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
    // 逐字高亮不需要每个音频 tick 重绘；100ms 一拍足够平滑，也避免整张
    // ListView 和可见歌词阴影在高频进度流下反复光栅化。
    final int positionMs = ref.watch(
      playbackPositionProvider.select(
        (AsyncValue<Duration> value) =>
            ((value.value ?? Duration.zero).inMilliseconds ~/ 100) * 100,
      ),
    );
    final Duration position = Duration(milliseconds: positionMs);

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
            text: lyrics.lines[i].text,
            translation: lyrics.lines[i].translation,
            active: i == index,
            centered: widget.centered,
            style: style,
            accent: accent,
            wordProgress: _lineProgress(lyrics, index, position),
            onTap: () => ref
                .read(playerControllerProvider.notifier)
                .seek(lyrics.lines[i].time),
          );
        },
      ),
    );
  }

  double _lineProgress(Lyrics lyrics, int index, Duration position) {
    if (index < 0 || index >= lyrics.lines.length) return 0;
    final Duration start = lyrics.lines[index].time;
    final Duration end = index + 1 < lyrics.lines.length
        ? lyrics.lines[index + 1].time
        : start + const Duration(seconds: 5);
    final int span = end.inMilliseconds - start.inMilliseconds;
    if (span <= 0) return 1;
    return ((position.inMilliseconds - start.inMilliseconds) / span).clamp(
      0.0,
      1.0,
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
    required this.text,
    required this.translation,
    required this.active,
    required this.centered,
    required this.style,
    required this.accent,
    required this.wordProgress,
    required this.onTap,
  });

  final String text;
  final String? translation;
  final bool active;
  final bool centered;
  final LyricsStyle style;
  final AppAccent accent;
  final double wordProgress;
  final VoidCallback onTap;

  @override
  State<_LyricLineTile> createState() => _LyricLineTileState();
}

class _LyricLineTileState extends State<_LyricLineTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Align(
          alignment: widget.centered
              ? Alignment.center
              : widget.style.align.alignment,
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 140),
            style: TextStyle(
              fontSize: widget.active
                  ? widget.style.activeFontSize
                  : widget.style.fontSize,
              fontFamily: widget.style.fontFamily.family,
              letterSpacing: widget.style.letterSpacing,
              fontWeight: widget.active
                  ? widget.style.weight.value
                  : FontWeight.w400,
              height: 1.25,
              color: widget.active
                  ? Colors.white
                  : (_hovered
                        ? Colors.white.withValues(alpha: 0.92)
                        : Colors.white.withValues(alpha: 0.62)),
              shadows: widget.active
                  ? <Shadow>[
                      Shadow(
                        color: widget.accent.primary.withValues(alpha: 0.55),
                        blurRadius: 16,
                      ),
                      const Shadow(color: Color(0xB3000000), blurRadius: 8),
                    ]
                  : const <Shadow>[
                      // 非当前行也给一层暗影：歌词常叠在亮背景上，
                      // 没有它 60% 白的字会糊掉（用户反馈"看着难受"）
                      Shadow(color: Color(0x99000000), blurRadius: 6),
                    ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                widget.active
                    ? _karaokeText(
                        widget.text,
                        widget.wordProgress,
                        widget.centered
                            ? TextAlign.center
                            : widget.style.align.textAlign,
                        widget.accent.primary,
                      )
                    : Text(
                        widget.text,
                        textAlign: widget.centered
                            ? TextAlign.center
                            : widget.style.align.textAlign,
                      ),
                if (widget.translation != null &&
                    widget.translation!.isNotEmpty)
                  Text(
                    widget.translation!,
                    textAlign: widget.centered
                        ? TextAlign.center
                        : widget.style.align.textAlign,
                    style: TextStyle(
                      fontSize:
                          (widget.active
                              ? widget.style.activeFontSize
                              : widget.style.fontSize) *
                          0.72,
                      color: Colors.white.withValues(alpha: 0.56),
                      fontFamily: widget.style.fontFamily.family,
                      letterSpacing: widget.style.letterSpacing * 0.7,
                      fontWeight: FontWeight.w400,
                      height: 1.25,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _karaokeText(
  String text,
  double progress,
  TextAlign align,
  Color accent,
) {
  // 按文本的水平进度连续扫亮，而不是按字符取整；这样中文、英文和混合歌词
  // 都像播放器进度条一样平滑，光标不会出现“一个字一个字跳”的感觉。
  final double p = progress.clamp(0.0, 1.0);
  final double edge = (p + 0.003).clamp(0.0, 1.0);
  return ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (Rect bounds) => LinearGradient(
      colors: <Color>[accent, accent, Colors.white, Colors.white],
      stops: <double>[0, p, edge, 1],
    ).createShader(bounds),
    child: Text(
      text,
      textAlign: align,
      softWrap: true,
      overflow: TextOverflow.visible,
      style: const TextStyle(color: Colors.white),
    ),
  );
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
