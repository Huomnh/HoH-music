# 原生 Flutter 歌词动画

## 当前实现

播放页提供六个 HoH 自有视觉模式，选择保存在 `lyrics.layout`。旧版本保存的模式名只在迁移层识别，不会出现在设置页：

| 选项 | 动画来源 | HoH 当前呈现 |
|---|---|---|
| 星屿 | HoH 原生 | 逐行扫光与邻句淡隐，画面稳定克制 |
| 微澜 | HoH 原生 | 字符重叠时窗扫光、依次缩放并带短辉光 |
| 浮光 | HoH 原生 | 轻量逐行聚焦与平滑切换 |
| 弦动 | HoH 原生 | 词级时间扫光，当前字按词时长抬升/缩放 |
| 留声 | HoH 原生 | 专辑封面、歌曲信息与低负载逐字歌词同屏 |
| 余晖 | HoH 原生 | 有 TTML 词时间时增强逐字表现，否则安全降级为行内进度 |

显示设置使用上游语义：歌词模糊、逐字辉光、当前字垂直/余弦抬升、平滑/弹性行切换；不再提供 HoH 自定义的“切句动画”和“动效强度”总开关。邻句会随当前行改变透明度和模糊，点击任一可见行均可 seek。绘制入口为 `lib/features/player/lyrics/project_lyric_renderers.dart`，排布和选择入口位于 `lyrics_scene.dart`、`lyrics_style.dart` 与 `appearance_settings.dart`。

## 数据与播放边界

```text
HoH 歌词来源/解析 → LyricsTimeline → LyricsVisualizerFrame
                                      └─ HoH lyrics renderers
```

- 播放、歌曲匹配、歌词来源、LRC/TTML 解析、翻译关联和 seek 全部由 HoH 原有服务完成；外部项目的音频后端、状态管理和网络来源没有移植。
- TTML 的行 `end` 和词 `begin/end` 都进入 HoH `LyricsTimeline`；普通 LRC 没有逐字时间戳，仍以本句到下一句的区间平滑估算，并非真实逐字同步。
- 原文和翻译使用相同的 HoH 播放时间进度。翻译自身没有词级时间戳时使用与原文相同的行内进度。
- 为控制开销，舞台只绘制当前句及前后各两句；绘制使用 `CustomPainter` 和 `TextPainter`，按播放时钟更新，不创建逐字 widget 树。media_kit 位置流只作校准锚点，播放期间由 Flutter `Ticker` 补齐本地帧，暂停时不做矩阵/进度刷新；普通滚动列表限制在约 30Hz，避免整张列表高频布局。
- 桌面歌词浮层仍使用 HoH 原有 Win32/GDI 窗口，不能直接调用 Flutter `CustomPainter`；本轮移除玻璃底、胶囊边框、高光和悬停轮询，改为透明双行文字 HUD，消费相同的 `LyricsTimeline`、显示模式和逐字进度。它是平台渲染适配，不宣称是上游项目的桌面端源码移植。

## 上游代码与许可

本实现的部分扫光、抬升和字符时窗算法参考/改编了以下歌词渲染思路，来源路径和上游快照记录在 [开源项目与协议清单](开源项目与协议清单.md)。它们是实现致谢与许可证边界，不是用户可见的模式名称：

- ZeroBit Player 的 `lib/components/lyric/word_render.dart`：字符重叠波形时间窗、非对称缩放曲线和当前字辉光。
- Pure Music 的 `lib/page/now_playing_page/component/lyrics_line_painter.dart` 与 `lyric_stagger_motion.dart`：逐字时间映射、柔和播放扫光、字形抬升/缩放、平滑与弹簧切句思路。

两个仓库均提供 GPL-3.0。HoH 当前使用 GPL-3.0-only，根目录许可证随本项目发布；源码及 README 保留上游项目和路径致谢。Pure Music README 还提出“仅限非商业使用”和注明来源的作者请求，README 同时将它描述为非法律条款；此处作为作者附加请求记录，不能与其 GPL 法律许可证混为一谈。分发前应保留本文件、README 和开源清单中的署名及许可说明。

## 验收与已知边界

- `flutter analyze --no-pub`、歌词 renderer/widget 测试和 Windows Debug 构建应在每次渲染改动后运行。
- 自动化测试只能验证时间映射、可构建性和点击入口；最终动效观感、不同字体换行及 GPU 使用仍需在实际播放中验收。
- 后续歌词动画继续在 HoH 自有六模式上迭代；新增样式继续复用 HoH 的歌词时间轴和 seek 接口。罗马音、多声部轨道、音频 reactive 等能力要等歌词数据模型提供对应输入后再接入。

播放页底部/侧栏/紧凑控制区的进度条不属于歌词 renderer：它使用同一套 HoH 播放位置和 seek，加入轻量主题渐变、短时平滑追帧和拖动播放头动画。ZeroBit Player 与 Pure Music 的进度条只作为交互观感参考，未引入其音频后端、播放器或状态管理。
