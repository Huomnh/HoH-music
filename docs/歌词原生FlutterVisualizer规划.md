# 原生 Flutter 歌词视觉器

## 当前实现（不是规划项）

歌词功能使用 Flutter/Dart 自身渲染。统一输入定义在 `lyrics_visualizer.dart`：`LyricsVisualizerFrame` 持有归一化时间轴、播放位置、当前行和行内进度；renderer 只呈现画面，不控制播放器。

播放页当前有两种可切换布局（`LyricsLayoutMode`）：

1. **摄影机词幕**：`lyrics_camera_stage.dart` 将当前句及邻近歌词映射到有限深度的 2.5D 视口，随时间轴推进焦点；不是独立 3D 引擎。
2. **滚动列表**：`lyrics_view.dart` 以普通 Flutter 文本/滚动控件展示歌词。

歌词解析和时间轴位于 `lyrics_parser.dart`、`lyrics_timeline.dart`；翻译跟随相同的歌词行和播放位置。逐词高亮只有在歌词源提供逐词时间戳时才有可靠依据，不应按字符数或文件时长伪造精度。

## 数据和渲染分层

```text
Audio position provider
        ↓
Lyrics parser → LyricsTimeline → LyricsVisualizerFrame
                                   ├─ Camera lyrics stage
                                   └─ Scrolling list
```

封面/主题颜色可影响视觉配色，但歌词布局不得另行维护播放时钟。播放器状态更新应尽量局部重建；长列表/高成本 Painter 使用 `RepaintBoundary`，动效需能跟随应用动画偏好降级。

## 后续优化方向

- 先补逐词时间戳、双语同步、切句/暂停/拖动 seek 等 widget 和 timeline 测试，再调动效参数。
- 对播放时钟高频刷新进行 profile，确保只重绘歌词区域；低端设备和动画关闭时提供静态/低帧率策略。
- 新增视觉模式前先提供可运行 prototype 和可测 renderer，不要先堆空设置项或只写展示名称。
- Windows 通过后，再在移动端/TV 工程存在时验证字体、宽高比、遥控器与帧率。

## 未实现范围

音频频谱驱动粒子、更多独立视觉模式、字幕编辑器、移动锁屏歌词和 TV 专用舞台目前都未实现；本规划不把它们描述为现有功能。跨平台支持状态以 [多平台构建可行性评估](多平台构建可行性.md) 为准。
