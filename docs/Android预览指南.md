# Android 端预览指南

## 当前状态

Android runner 已加入仓库，移动端 UI 版本从 `0.0.1` 起算。当前实现包含：

- 底部导航：首页、发现、我的、设置；
- 首页当前歌曲卡片和快捷入口；
- 首页无歌曲时可直接进入发现，快捷入口可进入“我的”曲库；
- 发现页在线搜索；
- 首页快捷搜索、歌单导入、自建/导入歌单直达；
- 我的页面新建/导入歌单、纵向大卡片歌单列表和独立所有歌曲入口；
- 设置页的外观、播放、音源管理和版本说明子页面；
- 底部迷你播放器、全屏播放页、轻量逐字歌词、进度拖动、上一首/下一首、播放暂停、播放列表和加入喜欢。
- 首页当前播放卡片和迷你播放器可直接进入全屏歌词页；顶部右侧使用播放列表按钮，迷你播放器封面使用旋转黑胶。
- 全屏播放页的加入喜欢位于上一首左侧、播放列表位于下一首右侧；播放列表标题栏可切换顺序播放、列表循环、单曲循环和随机播放，不再提供歌词视觉模式入口。
- 本地、在线和导入歌单都会完整解析后一次性建立播放队列，Android 与 Windows 使用相同的下一首/上一首和播放顺序语义，不再逐首临时接管队列。
- 普通自建/导入歌单支持左滑显示垃圾桶，确认后删除歌单记录；“我喜欢的音乐”和“所有歌曲”不可删除，歌曲文件不会被删除。
- 音源管理页的音乐库下方新增 WebDAV 连接列表、添加网盘和全部同步入口；脚本导入操作区在窄屏下自动换行。

当前已成功构建 Debug APK：`build/app/outputs/flutter-apk/app-debug.apk`。本轮补充完整歌单队列、播放列表实时顺序按钮、轻量逐字歌词、播放页队列/喜欢操作和黑白极简背景；Android 玻璃面板使用跨厂商兼容的 BackdropFilter 低强度模糊、实体染色和圆角边框，避免折射错层，并加入播放时的 Android 前台媒体服务保活。已在 `emulator-5554` 安装启动验证，触控、播放、通知权限和不同厂商后台行为仍建议由用户在其他模拟器/真机验收。

歌单链接导入和新建歌单弹窗由各自的 Stateful dialog 管理输入 controller，避免弹窗退出动画尚未结束就释放 controller 导致 Flutter debug 红屏；网易云公开链接（包括带 `playlist?id=` 的链接）仍只读取歌单元数据，实际播放地址由音源重新解析。

播放引擎、音源脚本、曲库、歌单、歌词解析、主题和持久化状态继续复用共享 Dart 层。Windows 的窗口、托盘、桌面歌词、全局快捷键和 SMTC 不会在 Android 挂载。

## 构建环境

需要安装：

- Flutter 3.47.5 stable；
- Android SDK、Android SDK Platform、Build Tools 和 Android Emulator 或实体设备；
- JDK 17；
- Android Studio（推荐，用于 SDK 与模拟器管理）。

检查环境：

```powershell
flutter doctor
flutter devices
```

## Debug 构建

在仓库根目录执行：

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --reporter compact
flutter build apk --debug
```

APK 默认输出到：

```text
build/app/outputs/flutter-apk/app-debug.apk
```

连接实体设备或启动模拟器后，也可以直接运行：

```powershell
flutter run -d <设备 ID>
```

## 版本规则

Android 的 Gradle runner 当前固定为：

- `versionName = 0.0.1`；
- `versionCode = 1`。

Windows 仍使用独立的 `0.1.0` 正式版发布流程。后续 Android 发布时只递增 Android runner 的版本号与版本代码，并在本文件、README 和交接文档同步记录。

## 当前限制

- 当前已完成移动端 UI 壳层、APK 工程接入和基础前台播放保活，尚未完成 Android 实机长时间播放验收；
- Android 逐字歌词采用当前句及相邻句、80ms 量化位置的轻量渲染；歌词源没有逐词时间戳时按行时间区间估算，暂不宣称与桌面视觉模式完全一致；
- Android `GlassPanel` 使用 Flutter/Skia `BackdropFilter` 的低强度模糊加实体染色，不调用任何厂商私有液态玻璃 API，也不使用容易把下方滚动内容折射进来的位移采样；不同 Android 系统会得到一致的兼容效果。
- 已加入 `HoHPlaybackService` 媒体前台服务和播放/暂停生命周期桥接；音频焦点、耳机按键、锁屏媒体控制、通知权限和不同厂商后台限制仍需 Android 专项适配；
- Android 文件访问权限、下载目录选择和音源脚本导入需要在真实设备上逐项验收；
- 本机若没有 Android SDK，`flutter build apk` 会在构建前直接失败，这是环境限制，不代表 Dart/Flutter 静态分析失败。
- 如果项目目录与 Pub 缓存位于不同磁盘，`android/gradle.properties` 已关闭 Kotlin 增量编译，并将旧版 `flutter_js` 的 JVM 目标差异降为 warning，以保证 APK 可以稳定构建；首次构建会自动下载 NDK、CMake 和 `media_kit` 播放库，耗时可能较长。
