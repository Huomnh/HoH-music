# HoH music

默认音源脚本来自程序目录的 `music音源` 文件夹；启动时自动扫描并登记其中可用脚本，不再从旧的 `assets/sources` 读取。用户仍可手动导入其他脚本。

HoH music 是基于 Flutter/Dart 的音乐播放器。当前可运行和验收的发布目标为 **Windows 桌面**；代码采用共享 Flutter UI 与业务逻辑，其他平台尚未达到可构建/发布状态。

本项目采用 **GNU GPL 第 3 版（GPL-3.0-only）**，完整条款见根目录 [LICENSE](LICENSE)。这表示项目采用 GPLv3 本版，不自动包含未来版本；第三方依赖和素材仍分别遵循其各自许可证。

> 当前开发版本：`0.1.0-beta.1+1`。这是 beta 候选版本号，不代表已通过发布验收。请先查看下方验证状态和 [项目交接](docs/项目进度交接.md)。

项目仓库：[github.com/Huomnh/HoH-music](https://github.com/Huomnh/HoH-music)；欢迎提交 Issue 反馈 Bug 或功能建议。

## 开源项目致谢

感谢以下开源项目及其维护者提供的工具、数据和设计启发。HoH music 使用的运行时依赖与参考范围见[开源项目与协议清单](docs/开源项目与协议清单.md)；除明确标注的依赖/数据接入外，下列产品仅作为功能或交互参考，不代表复制或嵌入了它们的代码。

- [Flutter](https://github.com/flutter/flutter)、[Riverpod](https://github.com/rrousselGit/riverpod)、[MediaKit](https://github.com/media-kit/media-kit)：应用 UI、状态管理与音频播放基础。
- [LX Music Desktop](https://github.com/lyswhut/lx-music-desktop)：自定义音源协议与音源接入逻辑参考；感谢其公开的音源接口文档和社区生态。
- [AMLL TTML DB](https://github.com/amll-dev/amll-ttml-db)：逐词歌词数据接入；感谢项目维护者提供开放的 TTML 歌词资源与接入说明。
- [Any Listen](https://github.com/any-listen/any-listen)、[Namida](https://github.com/namidaco/namida)、[Particle Music](https://github.com/AfalpHy/ParticleMusic)、[Coriander Player](https://github.com/Ferry-200/coriander_player)：音乐库、下载、跨平台架构及桌面播放器交互参考，感谢作者分享实现经验。
- [sonic-topography](https://github.com/yin-yizhen/sonic-topography)、[AMLL TTML Tool](https://github.com/amll-dev/amll-ttml-tool)：歌词时间轴、可视化与 TTML 格式研究参考，感谢相关项目的探索和文档。

HoH music 不隶属于上述项目。第三方依赖、数据和媒体资源按各自适用的许可证及服务条款使用；完整清单和合规说明请查阅[开源项目与协议清单](docs/开源项目与协议清单.md)。

## 界面预览

以下图片来自当前项目的页面预览，后续 UI 更新会同步维护 `docs/preview/`：

| 播放页 | 所有歌曲 |
|---|---|
| ![播放页](docs/preview/player-page.png) | ![所有歌曲](docs/preview/0.0.56-library-top.png) |

| 在线搜索 | 音源管理 |
|---|---|
| ![在线搜索](docs/preview/0.0.39-online-search.png) | ![音源管理](docs/preview/0.0.55-sources.png) |

| WebDAV | 外观设置 |
|---|---|
| ![WebDAV](docs/preview/0.0.54-webdav.png) | ![外观设置](docs/preview/appearance-settings.png) |

| 播放设置 | 下载/音质设置 |
|---|---|
| ![播放设置](docs/preview/playback-settings.png) | ![音质设置](docs/preview/0.0.58-quality.png) |

## 当前功能

- 本地音乐库：导入文件/文件夹、元数据读取、增量扫描、排序与收藏；所有歌曲只展示本地与已配置 WebDAV 曲库，不混入在线播放历史。
- 播放：MediaKit/libmpv、播放队列、播放模式、进度与音量控制；可单独从曲库列表或当前队列移除歌曲，不会删除磁盘文件。
- 歌词：LRC/增强歌词、翻译同步、歌词时间轴与 Flutter 播放页视觉器；当前提供摄影机词幕和滚动列表。
- 字体：内置耀圆体作为 UI 与播放页歌词默认字体；外观设置支持分别导入 TTF 替换 UI 字体和歌词字体，字体文件保存在用户应用数据目录。
- 在线音源：单个活动音源、LX 自定义音源脚本兼容、搜索/在线播放/音质档位选择；安装包将脚本放在独立 `music音源` 文件夹，启动时自动扫描登记并启用第一个可用脚本。
- 下载管理：后台任务、进度/速度、暂停/继续/删除、断点续传、文件定位与音频标签写入。
- WebDAV：连接配置、远端音乐浏览与播放入口。
- 外观：内置液态流光和自定义图片、玻璃参数、字体、主题包导入/导出。
- Windows 集成：无边框可缩放窗口、紧凑播放器、桌面歌词、系统托盘、快捷键和系统媒体控制。

功能细节以当前代码和专题文档为准；不表示在线音源一定能提供所有音质/技术元数据。在线曲目不显示推算码率，本地码率以媒体解析器读到的文件信息为准。

## Beta 验证状态

- `flutter analyze`：通过（2026-09-27）。
- `flutter test --reporter compact`：80 项通过（2026-09-27）。
- `flutter build windows --release`：通过，产物为 `build/windows/x64/runner/Release/hoh_music.exe`。
- Windows 安装器：本地生成于 `dist/windows/HoH-music-Setup-0.1.0-beta.1-Windows-x64.exe`；安装目录可自定义，并默认创建桌面快捷方式。安装包不提交源码仓库，公开下载请使用 [GitHub Releases](https://github.com/Huomnh/HoH-music/releases)。
- 安装器当前未签名；正式公开分发建议使用可信代码签名证书，避免 Windows 发布者未知提示。
- 安装需要管理员确认（VC++ 运行库可能需要系统级安装），安装目录可在向导中修改。
- 干净机器安装/启动、实际播放和下载验收：尚未完成。
- Android、iOS、macOS、Linux、TV：当前没有完整平台工程和发布验收，不属于此 beta 支持范围。

在干净环境和实际播放/下载验收完成前，不应对外发布 beta 安装包或宣称跨平台支持。

## 开发环境

- Flutter 3.47.5 stable / Dart 3.13.4（本机已验证组合）
- Windows 桌面构建需 Visual Studio C++ 桌面开发工具链；系统媒体控制依赖 `smtc_windows` 插件及其 Rust 构建工具链。
- 项目通过 `pubspec.lock` 固定传递依赖。不要删除或忽略锁文件。

```powershell
cd E:\HoH-music
flutter pub get
flutter analyze
flutter test
flutter run -d windows
flutter build windows --release
powershell -ExecutionPolicy Bypass -File scripts\package-windows.ps1
```

安装包不含用户音乐库或歌曲文件。音源脚本单独放在安装目录 `music音源` 文件夹，须由用户手动导入，应用不会当作内置数据加载。打包器会从 Flutter bundle 中剔除 `assets/audio` 与 `assets/sources`。安装包需联网获取并校验 Microsoft 官方 x64 Visual C++ Redistributable；打包脚本用 Inno Setup 编译可选目录安装器，默认创建桌面快捷方式，并默认做静默安装/卸载冒烟检查。输出位于 `dist\windows\`；使用 `-SkipInstallerSmokeTest` 可跳过本机安装器冒烟测试。

### 发布到 GitHub Releases

1. 打包完成后打开仓库的 [Releases](https://github.com/Huomnh/HoH-music/releases)，选择 **Draft a new release**。
2. 标签填写 `v0.1.0-beta.1`，目标分支选择 `main`，上传 `dist/windows/HoH-music-Setup-0.1.0-beta.1-Windows-x64.exe`。
3. 发布前可用 `Get-FileHash .\dist\windows\HoH-music-Setup-0.1.0-beta.1-Windows-x64.exe -Algorithm SHA256` 生成校验值，并粘贴到 Release 说明。
4. 点击 **Publish release** 后，用户即可从 Releases 页面下载；源码仓库仍不提交 `dist/` 安装包。

如果本机无法下载 MediaKit 构建资产，可先执行 `scripts/prepare-media-kit.ps1`，详见 [Windows 预览与构建指南](docs/Windows预览指南.md)。

## 架构与维护入口

- [当前架构](音乐播放器架构文档.md)：模块边界、数据流与平台边界。
- [项目进度交接](docs/项目进度交接.md)：当前状态、验证结果、限制和后续工作。
- [变更记录](docs/变更记录.md)：按版本记录实现和文档变化。
- [多平台可行性](docs/多平台构建可行性.md)：已验证能力与平台差距。
- [歌词视觉器规划](docs/歌词原生FlutterVisualizer规划.md)：共享时间轴与原生 Flutter renderer 方向。
- [开源项目与协议清单](docs/开源项目与协议清单.md)：运行时依赖、参考资料与协议核对入口。
- [文档维护规范](docs/文档维护规范.md)及根目录 [AGENTS.md](AGENTS.md)：所有代码工作必须同步交接与文档。

## 远期内容

移动端/TV 工程适配、跨端数据同步、Home Assistant 集成尚未实现。跨端同步方案目前仅为待确认设计，不应按已交付功能使用。
> 曲库操作：所有歌曲、收藏和歌单中的删除按钮只移除当前列表记录；本地文件不会被删除，所有歌曲支持撤销。
