# Android 端预览指南

## 当前状态

Android runner 已加入仓库，移动端 UI 版本从 `0.0.1` 起算。当前实现包含：

- 底部导航：首页、发现、我的、设置；
- 首页当前歌曲卡片和快捷入口；
- 首页无歌曲时可直接进入发现，快捷入口可进入“我的”曲库；
- 发现页在线搜索；
- 我的页面歌单快捷入口和所有歌曲，点击歌单卡片可进入对应歌单并返回曲库；
- 设置页的外观、播放、音源管理和版本说明子页面；
- 底部迷你播放器、全屏播放页、歌词面板、进度拖动、上一首/下一首和播放暂停。

当前已成功构建 Debug APK：`build/app/outputs/flutter-apk/app-debug.apk`。本轮已修复窄屏音源管理滚动、在线搜索筛选行裁切、移动端歌单快捷入口，并加入播放时的 Android 前台媒体服务保活；触控、播放、通知权限和不同厂商后台行为仍建议由用户在其他模拟器/真机验收。

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
- 已加入 `HoHPlaybackService` 媒体前台服务和播放/暂停生命周期桥接；音频焦点、耳机按键、锁屏媒体控制、通知权限和不同厂商后台限制仍需 Android 专项适配；
- Android 文件访问权限、下载目录选择和音源脚本导入需要在真实设备上逐项验收；
- 本机若没有 Android SDK，`flutter build apk` 会在构建前直接失败，这是环境限制，不代表 Dart/Flutter 静态分析失败。
- 如果项目目录与 Pub 缓存位于不同磁盘，`android/gradle.properties` 已关闭 Kotlin 增量编译，并将旧版 `flutter_js` 的 JVM 目标差异降为 warning，以保证 APK 可以稳定构建；首次构建会自动下载 NDK、CMake 和 `media_kit` 播放库，耗时可能较长。
