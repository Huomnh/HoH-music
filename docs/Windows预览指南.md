# Windows 开发与构建指南

本指南描述当前 Windows runner 的开发流程。首次构建前应安装 Flutter SDK、Visual Studio 的 C++ 桌面开发工作负载，并满足 `smtc_windows` 所需 Rust/Cargo 工具链。版本/环境变更应以本机 `flutter doctor -v` 为准，不要依赖下方旧机器快照。

## 常用命令

```powershell
cd E:\HoH-music
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter run -d windows
flutter build windows --release
powershell -ExecutionPolicy Bypass -File scripts\package-windows.ps1
```

应用依赖锁文件 `pubspec.lock`，更新依赖后检查锁文件差异，并在锁定依赖上重跑 analyze/test/build。

## Windows 安装包

`packaging/hoh_music.iss` 定义 Inno Setup 安装向导：用户可编辑安装路径，安装整个 Flutter Release 目录（含 DLL、MediaKit/libmpv、QuickJS 和 Flutter assets），创建开始菜单快捷方式，并可选创建桌面快捷方式。安装包内含项目 `LICENSE`、第三方许可证清单、Flutter 资源内的 `NOTICES.Z`，以及独立的 `music音源` 脚本文件夹。用户音乐库和歌曲文件不打包；音源脚本不自动注册/启用，用户安装后可在音源管理中手动导入。程序图标、托盘图标和安装器图标统一来自 `assets/icons/hoh_logo.png` 生成的圆角 ICO。安装器需要管理员确认，用于 Program Files 安装和缺失时安装 VC++ 运行库。

运行 `scripts/package-windows.ps1`（需安装 Inno Setup 6）会重新构建 Release、剔除生成 bundle 中的 `assets/audio` 与 `assets/sources`，再将项目根目录的 `music音源/*.js` 作为普通文件放入安装目录的同名文件夹；随后下载并验证 Microsoft 官方 x64 VC++ Redistributable 签名、编译安装器，并在 `build/packaging/smoke-install` 做自定义路径的静默安装/卸载冒烟测试。成功后安装器和 SHA-256 信息位于 `dist/windows/`（哈希打印到终端）。此冒烟测试不等于干净电脑的首次启动、音频设备、音源网络及全部功能验收。

## MediaKit 本机构建资源

本环境的原生 MediaKit 资产下载可能无法直连 GitHub Release。若构建因 MPV/ANGLE 包下载或校验失败，可运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\prepare-media-kit.ps1
flutter pub get
flutter build windows --debug
```

脚本会将所需归档放入本地 `build/` 并校验；不要把构建缓存或用户临时目录纳入发布包。只有在已确认清理范围时才运行 `flutter clean`，因为它会删除本机构建缓存并触发重新下载/编译。

## Beta 验收步骤

1. `flutter analyze` 无错误。
2. `flutter test` 全量通过，不能将历史断言失败当作预期通过。
3. `flutter build windows --release` 成功，检查产物依赖和安装/启动。
4. 在干净 Windows 用户配置下测试首次启动、重复启动只唤回一个窗口、点击 HoH 自绘关闭按钮时是否出现“取消 / 保留后台 / 退出程序”选择、托盘退出、设置保存、导入音乐、播放/暂停/切歌、进度条拖动、歌词（含长句、翻译、放大字号时不应出现 BOTTOM OVERFLOWED）、下载及退出后进程是否消失。runner 创建 `WS_POPUP + WS_THICKFRAME` 顶层窗口，`window_manager` 在首帧前完成无边框配置，Flutter 标题栏负责窗口按钮；`WindowFrameSync`/`DragToResizeArea` 负责圆角和边缘缩放。紧凑播放器入口位于标题栏或侧栏“紧凑播放器”，外框为 340×284；保留后台应隐藏主窗口和任务栏入口，但保留托盘隐藏图标与播放。初始窗口为 1280×800；lib/app.dart 同时隔离 Flutter 语义树，以规避 Flutter 3.47.5 accessibility bridge 的 AXTree 崩溃。
5. 核验版本显示 `0.1.0-beta.1`、安装包文件名/架构、许可证和第三方依赖清单。
6. 正式公开分发前，用可信代码签名证书签署安装器并验证签名；当前生成的 beta 安装器未签名。

## 常见排错方向

- **Flutter/Visual Studio 未识别**：检查 `flutter doctor -v`，确认 VS C++ workload 和 Windows SDK 已安装。
- **Rust 插件失败**：确认 `rustc --version` 和 `cargo --version` 可运行，重新打开终端后再构建；错误仍存在时记录完整 CMake/MSBuild 输出。
- **媒体归档校验失败**：重新运行项目的准备脚本，核对其校验输出；不要从未知来源复制 DLL 到发布目录。
- **源码分析成功但测试失败**：分析与测试覆盖范围不同；修复/迁移失败断言后才能将 beta 标记为可发布。
- **Debug 启动后闪退**：确认使用本轮构建的 `build\windows\x64\runner\Debug\hoh_music.exe`，不要把旧 exe 与新 DLL 混用；本轮已用普通启动 15 秒和 `--exit-after=12` 回归，退出码应为 `0`。若升级 Flutter 后重新出现 `flutter_windows.dll` 的 AXTree 崩溃，先检查 `lib/app.dart` 的 Windows `ExcludeSemantics` 是否被删除，再记录 Flutter 版本与 Windows Application Error。

构建产物位于 `build\windows\`，属于本地生成文件，不是仓库源文件。当前其他平台没有完整工程，见 [多平台构建可行性评估](多平台构建可行性.md)。
