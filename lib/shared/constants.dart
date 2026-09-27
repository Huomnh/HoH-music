/// constants.dart
///
/// 全局常量：应用名、包名、主题与音源脚本扩展名等（架构文档 1.3 项目命名）。
library;

/// 全项目共用常量。
///
/// ⚠️ 命名区分（改名前务必看这段）：
/// - **显示名** [appName] = `HoH music`——给用户看的标题栏、窗口标题、关于页；
/// - **标识符** `hoh_music`——pubspec 的 `name:`、Dart 导入路径
///   `package:hoh_music/...`、可执行文件名。**不要跟着显示名一起改**，
///   否则会破坏所有 import 与构建配置。
abstract final class AppConstants {
  /// 应用展示名称。仅用于界面与窗口标题。
  static const String appName = 'HoH music';

  /// 应用包名 / Bundle ID。
  static const String packageName = 'com.hohmusic.hohmusic';

  /// 当前版本号。与 `pubspec.yaml` 的 `version` 保持一致。
  ///
  /// 版本编号规则见 `docs/版本控制规范.md` 第三节：从 0.0.1 起算。
  static const String version = '0.1.0-beta.1';

  /// GitHub 仓库地址。仓库创建后填写，发布包和版本说明页共用此值。
  static const String repositoryUrl = 'https://github.com/Huomnh/HoH-music';

  /// 主题包扩展名（zip 打包：配置 + 预览图 + 资源）。
  static const String themeExtension = '.hohtheme';

  /// 音源脚本推荐扩展名（同时兼容普通 .js）。
  static const String sourceExtension = '.hohsource.js';

  /// 单首歌曲支持的音频格式（架构文档 3.1）。
  static const List<String> supportedAudioFormats = <String>[
    'mp3',
    'aac',
    'm4a',
    'flac',
    'wav',
    'ogg',
    'opus',
    'alac',
  ];

  /// 音源脚本单次执行超时（架构文档 3.2：单脚本超时 10 秒）。
  static const Duration sourceScriptTimeout = Duration(seconds: 10);
}
