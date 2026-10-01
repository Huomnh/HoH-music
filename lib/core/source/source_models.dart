/// source_models.dart
///
/// 自定义音源相关的**纯数据模型**（不碰网络、不碰 Flutter，方便单测）。
///
/// 两条主线：
/// - [MusicSource]：导入到本机的一个音源**脚本**（LX 格式 `.js`）的登记信息；
/// - [OnlineTrack]：宿主搜索到的**在线曲目**（网易云等）—— 也是喂给音源脚本的
///   `musicInfo` 的来源。
library;

import 'dart:convert';

import 'platform_aliases.dart';

/// 平台标识 → HoH music 界面显示名。
///
/// 这些 key 是 LX 生态的通用写法（音源脚本的 `sources` 里就用它们）。
const Map<String, String> kPlatformLabels = <String, String>{
  'wy': '芸音',
  'tx': '鹅音',
  'kw': '沃音',
  'kg': '苟音',
  'mg': '菇音',
  'qs': '汽水',
  'qsvip': '汽水VIP',
  'local': '本地',
};

/// 平台标识 → 展示名（未知的平台原样返回）。
String platformLabel(String key) =>
    kPlatformLabels[key] ?? platformDisplayAlias(key);

/// 音质标识 → 展示名。
const Map<String, String> kQualityLabels = <String, String>{
  '128k': '标准 128k',
  '192k': '较高 192k',
  '320k': '高 320k',
  'flac': '无损 FLAC',
  'flac24bit': 'Hi-Res 24bit',
  'flac24bit48': 'Hi-Res 24bit · 48kHz',
  'flac24bit96': 'Hi-Res 24bit · 96kHz',
  'flac24bit192': 'Hi-Res 24bit · 192kHz',
  'hires': 'Hi-Res',
  'master': '母带',
};

/// HoH music 对用户展示的主流音质档位。
///
/// 音源脚本内部可以声明更多平台专用名称，但不能把这些内部名称直接
/// 暴露给用户；它们必须映射到下面四个可理解、可选择的档位。
const List<String> kCommonQualities = <String>[
  '128k',
  '320k',
  'flac',
  'flac24bit',
  // 只有音源明确声明这些精确档位时才展示，不能把普通 flac24bit 冒充成它们。
  'flac24bit48',
  'flac24bit96',
  'flac24bit192',
];

/// 音质标识 → 展示名（未知的原样返回）。
String qualityLabel(String key) => kQualityLabels[key] ?? key;

/// 将音源脚本内部的兼容名称归一为 HoH music 的标准档位。
String? commonQualityOf(String key) {
  if (kCommonQualities.contains(key)) return key;
  if (const <String>{'hires', 'master'}.contains(key)) return 'flac24bit';
  return null;
}

/// 可选音质（界面下拉用；按从低到高）。
const List<String> kSelectableQualities = kCommonQualities;

// ════════════════════════════════════════════════════════════════
//  导入的音源脚本
// ════════════════════════════════════════════════════════════════

/// 脚本来源类型。
enum SourceOrigin {
  /// 本地文件 / 文件夹导入。
  file,

  /// 从 URL 下载导入。
  url,

  /// 随安装包放在程序目录 `music音源/` 的默认音源。
  bundled,

  /// 历史版本的 Flutter asset 内置音源，仅用于迁移清理，不再创建。
  @Deprecated('历史兼容值；新的内置音源统一使用 bundled')
  builtin,
}

/// 一个已导入的音源脚本。
///
/// 脚本**正文不入 prefs**，落在 `<应用支持目录>/sources/<id>.js`；
/// 这里只记登记信息（见 `source_store.dart`）。
class MusicSource {
  /// 创建登记信息。
  const MusicSource({
    required this.id,
    required this.name,
    required this.origin,
    required this.location,
    this.enabled = true,
    this.version = '',
    this.author = '',
    this.platforms = const <String>[],
    this.actions = const <String>[],
    this.qualitys = const <String>[],
    this.error = '',
  });

  /// 稳定标识（来源 + 名字的短哈希）。
  final String id;

  /// 展示名（脚本 `@name` 或文件名）。
  final String name;

  /// 来源类型。
  final SourceOrigin origin;

  /// 原路径 / 原 URL（只用于展示，脚本正文已另存）。
  final String location;

  /// 是否启用（只有启用的脚本会被加载进沙箱）。
  final bool enabled;

  /// 脚本元信息（`lx.currentScriptInfo` / `@version`）。
  final String version;

  /// 脚本作者（`@author`）。
  final String author;

  /// 上次加载成功时脚本声明的平台（如 `wy` / `tx`）。
  final List<String> platforms;

  /// 上次加载成功时脚本支持的动作（`musicUrl` / `lyric` / `pic`）。
  final List<String> actions;

  /// 上次加载成功时脚本支持的音质。
  final List<String> qualitys;

  /// 上次加载失败的原因（空字符串 = 没失败）。
  final String error;

  /// 平台展示名列表。
  List<String> get platformLabels =>
      platforms.map(platformLabel).toList(growable: false);

  /// 复制并改字段。
  MusicSource copyWith({
    String? name,
    bool? enabled,
    String? version,
    String? author,
    List<String>? platforms,
    List<String>? actions,
    List<String>? qualitys,
    String? error,
  }) => MusicSource(
    id: id,
    name: name ?? this.name,
    origin: origin,
    location: location,
    enabled: enabled ?? this.enabled,
    version: version ?? this.version,
    author: author ?? this.author,
    platforms: platforms ?? this.platforms,
    actions: actions ?? this.actions,
    qualitys: qualitys ?? this.qualitys,
    error: error ?? this.error,
  );

  /// 序列化（存 prefs）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'origin': origin.name,
    'location': location,
    'enabled': enabled,
    'version': version,
    'author': author,
    'platforms': platforms,
    'actions': actions,
    'qualitys': qualitys,
    'error': error,
  };

  /// 反序列化（容错：字段缺了就取默认值，别让一条坏记录毁掉整个列表）。
  factory MusicSource.fromJson(Map<String, dynamic> json) => MusicSource(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '未命名音源',
    origin: switch (json['origin']?.toString()) {
      'url' => SourceOrigin.url,
      'bundled' => SourceOrigin.bundled,
      'builtin' => SourceOrigin.builtin,
      _ => SourceOrigin.file,
    },
    location: json['location']?.toString() ?? '',
    enabled: json['enabled'] != false,
    version: json['version']?.toString() ?? '',
    author: json['author']?.toString() ?? '',
    platforms: _stringList(json['platforms']),
    actions: _stringList(json['actions']),
    qualitys: _stringList(json['qualitys']),
    error: json['error']?.toString() ?? '',
  );

  /// 从脚本头部的注释里读元信息。
  ///
  /// LX 的脚本模板在开头写 `@name` / `@version` / `@author`，
  /// 用户导入时我们就用它当展示名（比文件名好看得多）。
  /// 只在**前 2000 个字符**里找，避免匹配到脚本正文里的同类字符串。
  static ({String name, String version, String author}) parseScriptHeader(
    String code,
  ) {
    final String head = code.length > 2000 ? code.substring(0, 2000) : code;
    String pick(String key) {
      final RegExpMatch? match = RegExp('@$key\\s+([^\\r\\n*]+)')
          .firstMatch(head);
      return match == null ? '' : match.group(1)!.trim();
    }

    return (
      name: pick('name'),
      version: pick('version'),
      author: pick('author'),
    );
  }

  /// 解析登记表 JSON（`sources.registry`）。
  static List<MusicSource> decodeRegistry(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <MusicSource>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <MusicSource>[];
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map(
            (Map<Object?, Object?> m) => MusicSource.fromJson(
              m.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
            ),
          )
          .where((MusicSource s) => s.id.isNotEmpty)
          .toList();
    } on FormatException {
      return const <MusicSource>[];
    }
  }

  /// 编码登记表。
  static String encodeRegistry(List<MusicSource> list) =>
      jsonEncode(list.map((MusicSource s) => s.toJson()).toList());
}

List<String> _stringList(Object? value) {
  if (value is List) {
    return value
        .map((Object? e) => e.toString())
        .where((String e) => e.isNotEmpty)
        .toList();
  }
  return const <String>[];
}

// ════════════════════════════════════════════════════════════════
//  在线曲目
// ════════════════════════════════════════════════════════════════

/// 宿主搜索到的一首在线曲目。
///
/// `platform + songId` 就是它在对应平台上的身份，也是喂给音源脚本
/// `musicUrl` 的关键参数；[id] 用 `平台:歌曲id`，与 [Track.id] 一致，
/// 这样「我的喜欢 / 加入歌单」里存的 id 能直接对上。
class OnlineTrack {
  /// 创建在线曲目。
  const OnlineTrack({
    required this.platform,
    required this.songId,
    required this.title,
    this.artist = '',
    this.album = '',
    this.albumId = '',
    this.duration = Duration.zero,
    this.coverUrl = '',
    this.lyricUrl = '',
    this.tags = const <String>[],
    this.extra = const <String, dynamic>{},
    this.quality = '320k',
  });

  /// 平台标识（`wy` / `tx` / …）。
  final String platform;

  /// 平台内的歌曲 id。
  final String songId;

  /// 标题。
  final String title;

  /// 歌手（多个用 ` / ` 连接）。
  final String artist;

  /// 专辑名。
  final String album;

  /// 专辑 id。
  final String albumId;

  /// 时长（拿不到就是 0）。
  final Duration duration;

  /// 封面地址（可能为空，界面会去刮）。
  final String coverUrl;

  /// 平台直接给的歌词地址（目前只有咪咕的结果带）。
  final String lyricUrl;

  /// 平台返回的原始标签，供匹配和调试展示。
  final List<String> tags;

  /// **平台特有的附加字段**，会原样并进 `musicInfo`（同名时覆盖基础字段）。
  ///
  /// 为什么需要：同一个平台的不同音源脚本要的字段不一样。实测酷狗要
  /// `320hash` / `sqhash` / `audio_id`，咪咕要数字 `id` / `contentId` ——
  /// 基础字段覆盖不了，就靠这个通道把搜索响应里的原始字段带过去。
  final Map<String, dynamic> extra;

  /// 解析播放地址时用的音质。
  final String quality;

  /// 稳定标识：`平台:歌曲id`。
  String get id => '$platform:$songId';

  /// 平台展示名。
  String get platformLabel => platformLabelOf(platform);

  /// 复制并改字段。
  OnlineTrack copyWith({
    String? title,
    String? artist,
    String? album,
    String? albumId,
    Duration? duration,
    String? coverUrl,
    String? lyricUrl,
    List<String>? tags,
    Map<String, dynamic>? extra,
    String? quality,
  }) => OnlineTrack(
    platform: platform,
    songId: songId,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    albumId: albumId ?? this.albumId,
    duration: duration ?? this.duration,
    coverUrl: coverUrl ?? this.coverUrl,
    lyricUrl: lyricUrl ?? this.lyricUrl,
    tags: tags ?? this.tags,
    extra: extra ?? this.extra,
    quality: quality ?? this.quality,
  );

  /// 序列化（存 prefs：在线收藏）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'platform': platform,
    'songId': songId,
    'title': title,
    'artist': artist,
    'album': album,
    'albumId': albumId,
    'durationMs': duration.inMilliseconds,
    'coverUrl': coverUrl,
    'lyricUrl': lyricUrl,
    'tags': tags,
    'extra': extra,
    'quality': quality,
  };

  /// 反序列化。
  factory OnlineTrack.fromJson(Map<String, dynamic> json) => OnlineTrack(
    platform: json['platform']?.toString() ?? '',
    songId: json['songId']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    artist: json['artist']?.toString() ?? '',
    album: json['album']?.toString() ?? '',
    albumId: json['albumId']?.toString() ?? '',
    duration: Duration(
      milliseconds: int.tryParse(json['durationMs']?.toString() ?? '') ?? 0,
    ),
    coverUrl: json['coverUrl']?.toString() ?? '',
    lyricUrl: json['lyricUrl']?.toString() ?? '',
    tags: _stringList(json['tags']),
    extra: json['extra'] is Map
        ? (json['extra'] as Map<Object?, Object?>).map(
            (Object? k, Object? v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          )
        : const <String, dynamic>{},
    quality: json['quality']?.toString() ?? '320k',
  );

  /// 解析在线收藏列表。
  static List<OnlineTrack> decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <OnlineTrack>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <OnlineTrack>[];
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map(
            (Map<Object?, Object?> m) => OnlineTrack.fromJson(
              m.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
            ),
          )
          .where((OnlineTrack t) => t.songId.isNotEmpty)
          .toList();
    } on FormatException {
      return const <OnlineTrack>[];
    }
  }

  /// 编码在线收藏列表。
  static String encodeList(List<OnlineTrack> list) =>
      jsonEncode(list.map((OnlineTrack t) => t.toJson()).toList());

  /// 交给音源脚本的 `musicInfo`。
  ///
  /// ⚠️ 各平台的字段名不一样（LX 传的就是各平台的原始字段），
  /// 所以这里**尽量给全**：`songmid` / `songId` / `id` / `hash` 都塞上，
  /// 脚本取哪个都能取到。
  ///
  /// ⚠️⚠️ **空字符串字段会整个省略**（0.0.39 踩到的坑）：音源脚本普遍写
  /// `musicInfo.hash ?? musicInfo.songmid ?? musicInfo.id` —— `??` 只在
  /// `null/undefined` 时回退，给个 `hash: ''` 反而把后面的兜底全堵死，
  /// 结果就是"字段明明给了却报缺少参数"（咪咕实测就是被这个坑掉的）。
  Map<String, dynamic> toMusicInfo({String? qualityOverride}) {
    final Map<String, dynamic> info = <String, dynamic>{
      'source': platform,
      'platform': platform,
      'songmid': songId,
      'songId': songId,
      'id': songId,
      'musicId': songId,
      'name': title,
      'title': title,
      'singer': artist,
      'artist': artist,
      'albumName': album,
      'album': album,
      'albumId': albumId,
      'albumMid': albumId,
      'interval': duration.inSeconds,
      'duration': duration.inSeconds,
      'type': qualityOverride ?? quality,
      // 平台特有字段放最后：同名时按平台的来（酷狗要 320hash/audio_id，
      // 咪咕要数字 id/contentId，这些不给就会被脚本判"缺少参数"）
      ...extra,
    };
    info.removeWhere(
      (String key, Object? value) =>
          value == null || (value is String && value.isEmpty),
    );
    return info;
  }

  @override
  String toString() => '$platform:$songId $title - $artist';
}

/// [OnlineTrack.platformLabel] 的实现体（顶层函数，避免与字段同名冲突）。
String platformLabelOf(String key) => platformLabel(key);
