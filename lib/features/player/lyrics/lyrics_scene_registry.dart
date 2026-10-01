/// Lyrics scene registry.
///
/// 播放页只读取当前场景定义，
/// 场景实现自己消费统一的歌词/播放时钟，新增特效不再修改页面路由。
library;

import 'package:flutter/widgets.dart';

import 'lyrics_scene.dart';
import 'lyrics_style.dart';

typedef LyricsSceneBuilder = Widget Function({
  required VoidCallback onShowLyrics,
});

class LyricsSceneDefinition {
  const LyricsSceneDefinition({
    required this.mode,
    required this.label,
    required this.builder,
  });

  final LyricsLayoutMode mode;
  final String label;
  final LyricsSceneBuilder builder;
}

final List<LyricsSceneDefinition> lyricsSceneRegistry = LyricsLayoutMode.values
    .map(
      (LyricsLayoutMode mode) => LyricsSceneDefinition(
        mode: mode,
        label: mode.label,
        builder: ({required VoidCallback onShowLyrics}) =>
            LyricsScene(mode: mode, onShowLyrics: onShowLyrics),
      ),
    )
    .toList(growable: false);

LyricsSceneDefinition? lyricsSceneDefinitionFor(LyricsLayoutMode mode) {
  for (final LyricsSceneDefinition definition in lyricsSceneRegistry) {
    if (definition.mode == mode) return definition;
  }
  return null;
}
