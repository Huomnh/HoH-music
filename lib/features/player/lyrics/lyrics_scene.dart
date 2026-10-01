/// Player-page lyric animation modes adapted for HoH's native Flutter UI.
///
/// The two renderers use HoH's normalized timeline and never own audio,
/// matching, lyric parsing, translation lookup, or seeking.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/player_engine.dart' show Track;
import '../../../core/audio/player_providers.dart';
import '../../../shared/theme/app_accent.dart';
import 'lyrics_parser.dart';
import 'lyrics_style.dart';
import 'lyrics_view.dart' show currentLyricsProvider;
import 'lyrics_timeline.dart';
import 'lyrics_visualizer.dart';
import 'project_lyric_renderers.dart';
import '../cover_stage.dart';

class LyricsScene extends ConsumerStatefulWidget {
  const LyricsScene({
    super.key,
    required this.mode,
    required this.onShowLyrics,
  });

  final LyricsLayoutMode mode;
  final VoidCallback onShowLyrics;

  @override
  ConsumerState<LyricsScene> createState() => _LyricsSceneState();
}

/// 用本地时钟补齐 media_kit 位置流的离散更新。
///
/// media_kit 的位置流是同步锚点，不保证每帧发出；如果直接拿它驱动
/// CustomPaint，歌词逐字高亮会被锁在 10~20Hz。这里只在收到真实播放位置时
/// 重新校准，播放期间用 Flutter Ticker 在本地推进，暂停/拖动时立即回到锚点。
class _LyricsSceneState extends ConsumerState<LyricsScene>
    with SingleTickerProviderStateMixin {
  late final Ticker _clock;
  late final ProviderSubscription<AsyncValue<Duration>> _positionSubscription;
  late final ProviderSubscription<bool> _playingSubscription;

  Duration _position = Duration.zero;
  Duration _anchorPosition = Duration.zero;
  DateTime _anchorAt = DateTime.now();
  bool _playing = false;
  bool _hasLyrics = false;

  @override
  void initState() {
    super.initState();
    _position = ref.read(playbackPositionProvider).value ?? Duration.zero;
    _anchorPosition = _position;
    _playing = ref.read(playerControllerProvider).playing;
    _positionSubscription = ref.listenManual<AsyncValue<Duration>>(
      playbackPositionProvider,
      (_, next) => _syncPosition(next.value),
    );
    _playingSubscription = ref.listenManual<bool>(
      playerControllerProvider.select((PlayerUiState state) => state.playing),
      (_, next) => _syncPlaying(next),
    );
    _clock = createTicker((_) {
      if (!_playing || !_hasLyrics || !mounted) return;
      final Duration next =
          _anchorPosition + DateTime.now().difference(_anchorAt);
      if (next == _position) return;
      setState(() => _position = next);
    })..start();
  }

  void _syncPosition(Duration? value) {
    if (!mounted || value == null) return;
    _anchorPosition = value;
    _anchorAt = DateTime.now();
    if (_position != value) setState(() => _position = value);
  }

  void _syncPlaying(bool value) {
    if (_playing == value) return;
    _playing = value;
    _anchorPosition = _position;
    _anchorAt = DateTime.now();
  }

  @override
  void dispose() {
    _clock.dispose();
    _positionSubscription.close();
    _playingSubscription.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final WidgetRef ref = this.ref;
    final LyricsStyle style =
        ref.watch(lyricsStyleProvider).value ?? const LyricsStyle();
    final Lyrics? lyrics = ref.watch(currentLyricsProvider).value;
    final Duration position = _position;
    _hasLyrics = lyrics != null && lyrics.lines.isNotEmpty;
    final LyricsTimeline timeline = lyrics == null
        ? const LyricsTimeline(lines: <LyricLine>[])
        : LyricsTimeline.fromLyrics(lyrics, source: 'hoh-normalized');
    final int index = timeline.indexAt(position);
    final AppAccent accent = AppAccent.of(context);
    if (widget.mode.showsAlbumInfo) {
      return AlbumInfoLyricsStage(
        key: ValueKey<String>(widget.mode.name),
        style: style,
        accent: accent,
        frame: LyricsVisualizerFrame(
          timeline: timeline,
          position: position,
          currentIndex: index,
          progress: index >= 0 ? timeline.progressAt(index, position) : 0,
        ),
        onSeek: (Duration value) =>
            ref.read(playerControllerProvider.notifier).seek(value),
        onShowLyrics: widget.onShowLyrics,
      );
    }
    if (lyrics == null || lyrics.isEmpty || index < 0) {
      return _NoLyrics(accent: accent, onShowLyrics: widget.onShowLyrics);
    }
    return LyricsVisualizerStage(
      key: ValueKey<String>(widget.mode.name),
      mode: widget.mode,
      style: style,
      accent: accent,
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

/// HoH 自有的“留声”播放页：专辑信息与逐字歌词同屏，但不堆叠重特效。
///
/// 左侧信息列固定封面和曲目信息，右侧复用同一套时间轴/逐字 painter。
/// 这样切换到该模式时不会另起播放器、歌词解析器或第二套进度时钟。
class AlbumInfoLyricsStage extends ConsumerWidget {
  const AlbumInfoLyricsStage({
    super.key,
    required this.style,
    required this.accent,
    required this.frame,
    required this.onSeek,
    required this.onShowLyrics,
  });

  final LyricsStyle style;
  final AppAccent accent;
  final LyricsVisualizerFrame frame;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onShowLyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track? track = ref.watch(
      playerControllerProvider.select(
        (PlayerUiState state) => state.currentTrack,
      ),
    );
    final TextTheme textTheme = Theme.of(context).textTheme;
    final LyricsStyle quietStyle = style.copyWith(
      // “留声”是信息优先的轻量模式：仍然逐字扫光，但不放大每一个字，
      // 不使用模糊/辉光，避免专辑信息列和歌词互相争夺视觉焦点。
      fontSize: style.fontSize.clamp(16.0, 26.0),
      activeScale: 1.12,
      align: LyricAlign.left,
      enableBlur: false,
      enableGlow: false,
    );

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              accent.primary.withValues(alpha: .08),
              Colors.transparent,
            ],
          ),
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double infoWidth = math.min(310, constraints.maxWidth * .32);
            final double coverSize = math.min(
              infoWidth,
              math.min(280, math.max(156, constraints.maxHeight * .42)),
            );
            final bool hasLyrics =
                frame.timeline.lines.isNotEmpty && frame.currentIndex >= 0;
            return Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  SizedBox(
                    width: infoWidth,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Center(child: CoverStage(size: coverSize)),
                        const SizedBox(height: 22),
                        Text(
                          track?.title ?? '未播放歌曲',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          track?.artist ?? '选择一首歌曲开始播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleMedium?.copyWith(
                            color: textTheme.bodyMedium?.color?.withValues(
                              alpha: .78,
                            ),
                          ),
                        ),
                        if (track?.album.trim().isNotEmpty ??
                            false) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            track!.album,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium?.copyWith(
                              color: textTheme.bodyMedium?.color?.withValues(
                                alpha: .56,
                              ),
                            ),
                          ),
                        ],
                        if (track != null) ...<Widget>[
                          const SizedBox(height: 14),
                          Text(
                            track.qualityLabel,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelMedium?.copyWith(
                              color: accent.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 36),
                  Expanded(
                    child: hasLyrics
                        ? LyricsVisualizerStage(
                            mode: LyricsLayoutMode.albumVoice,
                            style: quietStyle,
                            accent: accent,
                            frame: frame,
                            onSeek: onSeek,
                          )
                        : _NoLyrics(accent: accent, onShowLyrics: onShowLyrics),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class LyricsVisualizerStage extends StatelessWidget {
  const LyricsVisualizerStage({
    super.key,
    required this.mode,
    required this.style,
    required this.accent,
    required this.frame,
    required this.onSeek,
  });

  final LyricsLayoutMode mode;
  final LyricsStyle style;
  final AppAccent accent;
  final LyricsVisualizerFrame frame;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(.28, -.18),
            radius: 1.05,
            colors: <Color>[
              accent.primary.withValues(alpha: .075),
              Colors.transparent,
            ],
          ),
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Size size = Size(constraints.maxWidth, constraints.maxHeight);
            final int current = frame.currentIndex;
            if (current < 0 || current >= frame.timeline.lines.length) {
              return const SizedBox.expand();
            }
            // 上游行渲染使用约 600~700ms 的隐式过渡。固定五格但不再给
            // 当前行叠加 AnimatedScale，避免长句布局超出 slot 后触发黄黑
            // 溢出警告；字体本身已经在 painter 内按可用宽度缩放。
            final double slotExtent = (size.height / 5.4).clamp(66.0, 126.0);
            final Duration transitionDuration = mode.usesGlyphRipple
                ? const Duration(milliseconds: 600)
                : const Duration(milliseconds: 700);
            final Curve transitionCurve =
                style.staggerStyle == LyricStaggerStyle.spring
                ? Curves.easeOutBack
                : Curves.easeOutCubic;
            final List<Widget> lines = <Widget>[];
            for (int distance = -2; distance <= 2; distance++) {
              final int index = current + distance;
              if (index < 0 || index >= frame.timeline.lines.length) {
                continue;
              }
              final double centerY = size.height / 2 + distance * slotExtent;
              final double top = centerY - slotExtent / 2;
              final Widget line = _LyricsLineSlot(
                key: ValueKey<String>('slot-$index'),
                line: frame.timeline.lines[index],
                index: index,
                distance: distance,
                position: frame.position,
                progress: distance == 0
                    ? frame.progress
                    : distance < 0
                    ? 1
                    : 0,
                lineDuration:
                    frame.timeline.endAt(index) -
                    frame.timeline.lines[index].time,
                style: style,
                mode: mode,
                accent: accent.primary,
                transitionDuration: transitionDuration,
                transitionCurve: transitionCurve,
                onSeek: onSeek,
              );
              lines.add(
                style.staggerStyle == LyricStaggerStyle.spring
                    ? _SpringPositioned(
                        key: ValueKey<int>(index),
                        top: top,
                        height: slotExtent,
                        child: line,
                      )
                    : AnimatedPositioned(
                        key: ValueKey<int>(index),
                        duration: transitionDuration,
                        curve: transitionCurve,
                        left: 0,
                        right: 0,
                        top: top,
                        height: slotExtent,
                        child: line,
                      ),
              );
            }
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: lines,
            );
          },
        ),
      ),
    ),
  );
}

/// 弹性行切换：使用 `SpringSimulation(mass: 1,
/// stiffness: 100, damping: 17)` 对齐，不用 easeOutBack 冒充弹簧。
class _SpringPositioned extends StatefulWidget {
  const _SpringPositioned({
    super.key,
    required this.top,
    required this.height,
    required this.child,
  });

  final double top;
  final double height;
  final Widget child;

  @override
  State<_SpringPositioned> createState() => _SpringPositionedState();
}

class _SpringPositionedState extends State<_SpringPositioned>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: 1,
  );
  double _from = 0;
  double _to = 0;

  @override
  void initState() {
    super.initState();
    _from = widget.top;
    _to = widget.top;
  }

  @override
  void didUpdateWidget(covariant _SpringPositioned oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.top - widget.top).abs() < .01) return;
    _from = oldWidget.top;
    _to = widget.top;
    _controller
      ..stop()
      ..value = 0
      ..animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 100, damping: 17),
          0,
          1,
          0,
        ),
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (BuildContext context, Widget? child) => Positioned(
      left: 0,
      right: 0,
      top: ui.lerpDouble(_from, _to, _controller.value) ?? _to,
      height: widget.height,
      child: child!,
    ),
    child: widget.child,
  );
}

class _LyricsLineSlot extends StatelessWidget {
  const _LyricsLineSlot({
    super.key,
    required this.line,
    required this.index,
    required this.distance,
    required this.position,
    required this.progress,
    required this.lineDuration,
    required this.style,
    required this.mode,
    required this.accent,
    required this.transitionDuration,
    required this.transitionCurve,
    required this.onSeek,
  });

  final LyricLine line;
  final int index;
  final int distance;
  final Duration position;
  final double progress;
  final Duration lineDuration;
  final LyricsStyle style;
  final LyricsLayoutMode mode;
  final Color accent;
  final Duration transitionDuration;
  final Curve transitionCurve;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final bool active = distance == 0;
    final int depth = distance.abs();
    final double targetOpacity = active ? 1 : (depth == 1 ? .46 : .20);
    final Widget lyricBlock = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onSeek(line.time),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 38, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            ProjectLyricLine(
              text: line.text,
              words: line.words,
              position: position,
              progress: progress,
              lineDuration: lineDuration,
              style: style,
              mode: mode,
              accent: accent,
              active: active,
              opacity: 1,
            ),
            if (active &&
                style.showTranslation &&
                (line.translation?.trim().isNotEmpty ?? false)) ...<Widget>[
              const SizedBox(height: 4),
              ProjectLyricLine(
                text: line.translation!.trim(),
                words: const <LyricWord>[],
                position: position,
                progress: progress,
                lineDuration: lineDuration,
                style: style.copyWith(
                  fontSize: (style.fontSize * .48).clamp(12.0, 20.0),
                  weight: LyricWeight.regular,
                  letterSpacing: style.letterSpacing * .45,
                  lyricsOpacity: style.subtitleOpacity,
                ),
                mode: mode,
                accent: accent,
                active: true,
                opacity: 1,
              ),
            ],
          ],
        ),
      ),
    );

    // 当前行可能同时包含主歌词和翻译，而槽位高度会随窗口尺寸变化。
    // 先给内容一个有限宽度，再用 scaleDown 约束到槽位内，避免字号、
    // 逐字动画或翻译把 Column 撑出 RenderFlex overflow。
    final Widget fittedLyricBlock = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: SizedBox(width: constraints.maxWidth, child: lyricBlock),
        );
      },
    );

    Widget result = AnimatedOpacity(
      duration: transitionDuration,
      curve: transitionCurve,
      opacity: targetOpacity,
      child: AnimatedSwitcher(
        duration: transitionDuration,
        switchInCurve: transitionCurve,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (Widget child, Animation<double> animation) {
          final Offset begin = mode.usesGlyphRipple
              ? const Offset(0, .18)
              : const Offset(0, .08);
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: begin,
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: KeyedSubtree(key: ValueKey<int>(index), child: fittedLyricBlock),
      ),
    );
    if (style.enableBlur && depth > 0) {
      result = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: (depth * .6).clamp(0.0, 2.5),
          sigmaY: (depth * .6).clamp(0.0, 2.5),
        ),
        child: result,
      );
    }
    return result;
  }
}

class _NoLyrics extends StatelessWidget {
  const _NoLyrics({required this.accent, required this.onShowLyrics});

  final AppAccent accent;
  final VoidCallback onShowLyrics;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.lyrics_outlined, size: 42, color: accent.primary),
        const SizedBox(height: 12),
        Text(
          '暂无歌词',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: .68),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: onShowLyrics, child: const Text('查找歌词')),
      ],
    ),
  );
}
