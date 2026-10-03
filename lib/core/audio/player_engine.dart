/// player_engine.dart
///
/// 音频播放引擎——MediaKit（底层 libmpv）的封装。
///
/// 按架构文档 3.1「Audio Pipeline 抽象层」的要求：
/// **播放器实例全局唯一**，切歌只换媒体源、不重建播放器，
/// 避免系统 MediaSession 被回收、也避免重复初始化解码后端。
///
/// 职责边界：只负责「播放」这件事，不含任何 UI。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
// media_kit 也导出一个 Track（媒体轨道），与本文件的 Track（曲目）同名，隐藏之
import 'package:media_kit/media_kit.dart' hide Track;

import 'playback_prefs.dart';
import '../source/source_models.dart' as source_models;

/// 一首可播放的曲目。
class Track {
  /// 创建曲目。
  Track({
    required this.id,
    required this.uri,
    required this.title,
    required this.artist,
    required this.album,
    this.duration,
    this.isRemote = false,
    this.lyrics,
    this.sampleRate,
    this.bitrate,
    this.fileSize,
    this.formatOverride,
    this.source,
    this.genre,
    this.quality,
  });

  /// 稳定标识。本地曲目用文件路径，远程曲目用 `音源id:曲目id`。
  final String id;

  /// 播放地址。本地为文件 URI，远程为 HTTP(S) URL。
  final String uri;

  /// 标题。
  final String title;

  /// 艺术家。
  final String artist;

  /// 专辑。
  final String album;

  /// 时长。解析元数据失败时为 null，播放中会由播放器补上。
  Duration? duration;

  /// 是否来自网络（音源插件 / WebDAV）。
  final bool isRemote;

  /// **内嵌歌词**（ID3 USLT / Vorbis LYRICS / MP4 lyrics）。
  ///
  /// 没有内嵌时由 `Lyrics.forTrack()` 去找同目录的 `.lrc`。
  final String? lyrics;

  /// 采样率（Hz）。
  final int? sampleRate;

  /// 比特率（kbps）。
  final int? bitrate;

  /// 文件大小（字节）。
  final int? fileSize;

  /// 在线直链常见为 `.php` 接口，使用 HEAD / Content-Type 得到的实际格式。
  final String? formatOverride;

  /// 来源平台或本地来源。
  final String? source;

  /// 标签中的流派。
  final String? genre;

  /// 下载或解析时选择的音质档位。
  final String? quality;

  /// 保留播放与技术信息，只替换补全后的标签。
  Track copyWith({String? title, String? artist, String? album}) => Track(
    id: id,
    uri: uri,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    duration: duration,
    isRemote: isRemote,
    lyrics: lyrics,
    sampleRate: sampleRate,
    bitrate: bitrate,
    fileSize: fileSize,
    formatOverride: formatOverride,
    source: source,
    genre: genre,
    quality: quality,
  );

  /// 音频格式（由扩展名推得，如 `FLAC` / `MP3`）。
  ///
  /// 远端曲目看 **uri**（`wy:186016` 这种 id 里没有扩展名，但播放地址有，
  /// 而且带 `?bitrate$320` 之类的查询串，要先切掉）；
  /// 实在认不出来就返回 `在线`，别显示"未知格式"吓人。
  String get format {
    if (formatOverride != null && formatOverride!.isNotEmpty) {
      return formatOverride!.toUpperCase();
    }
    // 远程 URL 的 .mp3/.php 只是接口路径，不能当成真实音频容器。
    // 真实格式要等源返回明确元数据或下载后读取文件签名。
    if (isRemote) return '在线（格式未验证）';
    String source = isRemote ? uri : id;
    final int query = source.indexOf('?');
    if (query >= 0) source = source.substring(0, query);
    final int dot = source.lastIndexOf('.');
    if (dot < 0 || dot == source.length - 1) return isRemote ? '在线' : '未知格式';
    final String ext = source.substring(dot + 1).toUpperCase();
    if (ext.length > 4 || !RegExp(r'^[A-Z0-9]+$').hasMatch(ext)) {
      return isRemote ? '在线' : '未知格式';
    }
    return ext;
  }

  /// 本地文件的比特率归一到 **kbps**。
  ///
  /// ⚠️ 上游 `audio_metadata_reader` 各格式的量纲**不一致**（读源码 + 实测）：
  ///
  /// | 格式 | 实际量纲 | 例子 |
  /// |---|---|---|
  /// | MP3 | kbps | `320` |
  /// | FLAC | bit/s | `705600` = 16 × 44100 |
  /// | WAV / AIFF | **byte/s** | `88200` = 44100 × 2 字节（riff_metadata 的注释写的是 bit/s，但算出来的是 byte/s） |
  ///
  /// 这里不根据文件大小和时长估算比特率，只使用音频解析器从文件
  /// 容器/音频帧读取的 bitrate。不同容器的库字段单位不同，因此只做
  /// 单位统一，不把请求音质或文件大小推算值当成实际码率。
  int? get bitrateKbps {
    final int? raw = bitrate;
    if (raw == null || raw <= 0) return null;

    // audio_metadata_reader 的格式实现定义：
    // MP3 为 kbps；FLAC/Vorbis/Opus 为 bit/s；RIFF/WAV 与 AIFF 为 byte/s。
    // 必须按容器判断，不能用数值阈值判断：双声道 44.1kHz WAV 的
    // byte rate 是 176400，若先按 bit/s 处理会错误显示成 176 kbps。
    switch (format.toLowerCase()) {
      case 'wav' || 'aiff' || 'aif':
        return (raw * 8 / 1000).round();
      case 'flac' || 'ogg' || 'oga' || 'opus':
        return (raw / 1000).round();
      case 'mp3' || 'm4a' || 'mp4' || 'aac':
        return raw;
    }

    // 对无法确定容器的本地文件保留旧格式的兼容处理；这仍然只处理
    // 解析器给出的 bitrate，不进行文件大小/时长估算。
    if (raw >= 100000) return (raw / 1000).round();
    if (raw >= 10000) return (raw * 8 / 1000).round();
    return raw;
  }

  /// 音质一行摘要，例如 `FLAC · 44.1 kHz · 706 kbps · 32.4 MB`。
  ///
  /// 每一项拿不到就跳过，不会出现 `null`。
  String get qualityLabel {
    // 在线曲目没有本地媒体文件；在线阶段只展示请求/解析得到的音质
    // 档位，不展示音源可能附带的 bitrate。下载完成重新作为本地文件
    // 载入后，才进入下面的本地文件技术信息展示。
    if (isRemote) {
      return quality == null || quality!.isEmpty
          ? '在线音频'
          : source_models.qualityLabel(quality!);
    }

    final List<String> parts = <String>[format];

    final int? rate = sampleRate;
    if (rate != null && rate > 0) {
      final double khz = rate / 1000.0;
      parts.add(
        '${khz == khz.roundToDouble() ? khz.toStringAsFixed(0) : khz.toStringAsFixed(1)} kHz',
      );
    }

    final int? kbps = bitrateKbps;
    if (kbps != null) {
      parts.add('$kbps kbps');
    }

    final int? size = fileSize;
    if (size != null && size > 0) {
      parts.add('${(size / 1024 / 1024).toStringAsFixed(1)} MB');
    }

    return parts.join(' · ');
  }

  /// 从本地文件构建曲目。
  ///
  /// 先读音频标签；标签缺失时按架构文档 3.7 的降级策略，
  /// 从文件名里猜「艺术家 / 标题」（**顺序不固定**，靠启发式判）。
  ///
  /// 为什么不能固定按「艺术家 - 标题」拆：实测用户的文件是
  /// `Last Thing You Need (from GTAVI The Album) - Morgan Wallen、Grand Theft Auto VI.flac`
  /// —— 标题在前、艺术家在后，硬拆就显示反了。
  ///
  /// 判据（打分）：
  ///   - 多人名分隔符（`、` `,` `&` `feat.` `ft.`）→ 更像艺术家；
  ///   - 带括号（`(from …)` / `(Live)` / `(Remix)` / `(feat. …)`）→ 更像标题；
  ///   - 没有括号 → 略偏艺术家（常见单人名）。
  /// 打平时保持「艺术家 - 标题」的老约定（多数中文库是这个顺序）。
  @visibleForTesting
  static (String artist, String title) splitFileName(String baseName) {
    final RegExpMatch? m = RegExp(r'^(.+?)\s*[-–—]\s*(.+)$')
        .firstMatch(baseName);
    if (m == null) return ('', '');
    final String left = m.group(1)!.trim();
    final String right = m.group(2)!.trim();
    if (left.isEmpty || right.isEmpty) return ('', '');

    double artistScore(String part) {
      double score = 0;
      if (RegExp(r'[、,，&]').hasMatch(part)) score += 3;
      if (RegExp(
        r'\b(feat|ft|with)\.?\s',
        caseSensitive: false,
      ).hasMatch(part)) {
        score += 2;
      }
      if (!part.contains('(') && !part.contains('（')) score += 1;
      if (part.length <= 24) score += 0.5;
      return score;
    }

    double titleScore(String part) {
      double score = 0;
      if (RegExp(r'[\(（].+[\)）]').hasMatch(part)) score += 3;
      if (RegExp(
        r'(from|live|remix|version|edition|album|ost|伴奏|纯音乐)',
        caseSensitive: false,
      ).hasMatch(part)) {
        score += 2;
      }
      return score;
    }

    final double leftAsArtist = artistScore(left) + titleScore(right);
    final double rightAsArtist = artistScore(right) + titleScore(left);
    if (rightAsArtist > leftAsArtist) {
      return (right, left); // 标题 - 艺术家
    }
    return (left, right); // 艺术家 - 标题（默认约定）
  }

  ///
  /// ⚠️ 默认**不读封面图**（`withCover`）：扫描一个上万首的目录时，
  /// 每首都把封面读进内存会很难看。封面只在需要时按需读，见
  /// [readEmbeddedCover]。
  static Future<Track> fromFile(File file) async {
    String title = file.uri.pathSegments.last;
    String artist = '未知艺术家';
    String album = '未知专辑';
    Duration? duration;
    String? lyrics;
    int? sampleRate;
    int? bitrate;
    int? fileSize;
    String? genre;

    // 去扩展名
    final String baseName = title.replaceAll(RegExp(r'\.[^.]+$'), '');
    title = baseName;

    try {
      fileSize = file.lengthSync();
    } catch (_) {
      // 文件读不到就算了，展示时跳过这一项
    }

    try {
      // 注意：readMetadata 返回非空类型，解析失败会抛异常
      final AudioMetadata meta = readMetadata(file, getImage: false);
      if (meta.title != null && meta.title!.trim().isNotEmpty) {
        title = meta.title!.trim();
      }
      if (meta.artist != null && meta.artist!.trim().isNotEmpty) {
        artist = meta.artist!.trim();
      }
      if (meta.album != null && meta.album!.trim().isNotEmpty) {
        album = meta.album!.trim();
      }
      duration = meta.duration;
      sampleRate = meta.sampleRate;
      bitrate = meta.bitrate;
      if (meta.genres.isNotEmpty) genre = meta.genres.first;
      final String? embedded = meta.lyrics;
      if (embedded != null && embedded.trim().isNotEmpty) {
        lyrics = embedded;
      }
    } catch (_) {
      // 标签解析失败不是致命问题，继续用文件名降级
    }

    // 文件名降级：文件名里常有「A - B」，但**谁在前谁在后各家不一样**
    // （用户实测：`Last Thing You Need (from GTAVI The Album) - Morgan Wallen、Grand Theft Auto VI.flac`
    //   是「标题 - 艺术家」，而别处常见「艺术家 - 标题」）。
    // 所以先按 `splitFileName` 的启发式判一下，别硬按一种约定拆。
    if (artist == '未知艺术家') {
      final (String guessedArtist, String guessedTitle) = splitFileName(
        baseName,
      );
      if (guessedArtist.isNotEmpty && guessedTitle.isNotEmpty) {
        artist = guessedArtist;
        title = guessedTitle;
      }
    }

    return Track(
      id: file.path,
      uri: file.uri.toString(),
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      lyrics: lyrics,
      sampleRate: sampleRate,
      bitrate: bitrate,
      fileSize: fileSize,
      source: '本地文件',
      genre: genre,
    );
  }

  /// 按需读取**内嵌封面**（front cover 优先，取不到就退而取第一张）。
  ///
  /// 只对"当前正在播放的这一首"调用，不要放进扫描循环里。
  static Uint8List? readEmbeddedCover(String path) {
    final File file = File(path);
    if (!file.existsSync()) return null;

    try {
      final AudioMetadata meta = readMetadata(file, getImage: true);
      final List<Picture> pictures = meta.pictures;
      if (pictures.isEmpty) return null;

      // 优先正封面
      for (final Picture picture in pictures) {
        if (picture.pictureType == PictureType.coverFront &&
            picture.bytes.isNotEmpty) {
          return picture.bytes;
        }
      }
      final Picture first = pictures.first;
      return first.bytes.isEmpty ? null : first.bytes;
    } catch (error) {
      debugPrint('[Track] 读取内嵌封面失败（$path）：$error');
      return null;
    }
  }
}

/// 支持的音频扩展名（架构文档 3.1：MP3 / AAC / FLAC / WAV / OGG / Opus / ALAC）。
const Set<String> kSupportedAudioExtensions = <String>{
  'mp3',
  'aac',
  'm4a',
  'flac',
  'wav',
  'ogg',
  'opus',
  'alac',
};

/// 判断一个路径是否是受支持的音频文件（按扩展名）。
bool isSupportedAudioFile(String path) {
  final int dot = path.lastIndexOf('.');
  if (dot < 0) return false;
  return kSupportedAudioExtensions.contains(
    path.substring(dot + 1).toLowerCase(),
  );
}

/// 递归扫描文件夹，收集受支持的音频文件。
///
/// - 自动跳过隐藏目录与常见的非音乐目录；
/// - 单个子目录无权限时跳过，不影响其余结果；
/// - 结果按路径排序，保证每次顺序一致。
List<File> scanAudioFiles(String directoryPath) {
  final Directory dir = Directory(directoryPath);
  if (!dir.existsSync()) return const <File>[];

  final List<File> result = <File>[];
  try {
    for (final FileSystemEntity entity in dir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final String path = entity.path;
      // 跳过隐藏目录里的文件（.git、$RECYCLE.BIN 之类）
      if (path.contains('${Platform.pathSeparator}.')) continue;
      if (isSupportedAudioFile(path)) result.add(entity);
    }
  } on FileSystemException catch (error) {
    debugPrint('[PlayerEngine] 扫描目录部分失败（已跳过）：${error.message}');
  }

  result.sort((File a, File b) => a.path.compareTo(b.path));
  return result;
}

/// 异步递归扫描目录，避免大曲库扫描时长时间阻塞 UI isolate。
///
/// 与 [scanAudioFiles] 使用相同的过滤规则；新增的异步入口供实际载入流程
/// 使用，保留同步入口给轻量统计与兼容旧调用方。
Future<List<File>> scanAudioFilesAsync(String directoryPath) async {
  final Directory dir = Directory(directoryPath);
  if (!await dir.exists()) return const <File>[];

  final List<File> result = <File>[];
  try {
    await for (final FileSystemEntity entity in dir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final String path = entity.path;
      if (path.contains('${Platform.pathSeparator}.')) continue;
      if (isSupportedAudioFile(path)) result.add(entity);
    }
  } on FileSystemException catch (error) {
    debugPrint('[PlayerEngine] 异步扫描目录部分失败（已跳过）：${error.message}');
  }

  result.sort((File a, File b) => a.path.compareTo(b.path));
  return result;
}

/// 播放引擎。
class PlayerEngine {
  PlayerEngine._();

  static PlayerEngine? _instance;

  /// 全局唯一实例——对应架构文档 3.1 的「播放器实例全局唯一」。
  static PlayerEngine get instance => _instance ??= PlayerEngine._();

  /// 初始化解码后端。必须在 `runApp` 之前调用一次。
  static void ensureInitialized() {
    MediaKit.ensureInitialized();
  }

  Player? _player;
  bool _disposed = false;

  /// 播放列表发生替换（选新文件夹 / 新队列）时触发。
  final StreamController<List<Track>> _queueController =
      StreamController<List<Track>>.broadcast();

  /// 当前曲目信息补全（异步读到标签）时触发。
  final StreamController<Track> _trackInfoController =
      StreamController<Track>.broadcast();

  List<Track> _queue = <Track>[];

  /// 随机播放状态（自管顺序，见 [setShuffleMode]）。
  bool _shuffle = false;
  List<int> _shuffleOrder = <int>[];
  int _shufflePos = 0;
  final Random _random = Random();

  /// 惰性创建播放器。首次播放时才真正初始化，加快冷启动。
  Player get player => _player ??= Player();

  /// 当前队列快照。
  List<Track> get queue => List<Track>.unmodifiable(_queue);

  /// 队列变化流。
  Stream<List<Track>> get queueStream => _queueController.stream;

  /// 曲目信息补全流。
  Stream<Track> get trackInfoStream => _trackInfoController.stream;

  // ── 底层播放器的状态流 ──────────────────────────────────────────
  //
  // 说明：media_kit 的 `player.stream` 是 **PlayerStream**——一组按字段拆分的流，
  // 并没有一个合并的 `Stream<PlayerState>`。这里把需要的几条暴露出去，
  // 让上层各自订阅：进度这类高频流单独用，避免整页重建。

  /// 播放 / 暂停状态流。
  Stream<bool> get playingStream => player.stream.playing;

  /// 缓冲状态流。
  Stream<bool> get bufferingStream => player.stream.buffering;

  /// 播放位置流（高频，UI 里单独隔离消费）。
  Stream<Duration> get positionStream => player.stream.position;

  /// 当前媒体时长流。
  Stream<Duration> get durationStream => player.stream.duration;

  /// 播放列表（含当前索引）变化流。
  Stream<Playlist> get playlistStream => player.stream.playlist;

  /// 音量变化流。
  Stream<double> get volumeStream => player.stream.volume;

  /// 当前输出通道变化流。
  Stream<AudioDevice> get audioDeviceStream => player.stream.audioDevice;

  /// 系统当前可用的输出通道列表。
  Stream<List<AudioDevice>> get audioDevicesStream =>
      player.stream.audioDevices;

  /// 播放出错流。
  Stream<String> get errorStream => player.stream.error;

  /// 同步读取当前播放状态快照。
  PlayerState get state => player.state;

  /// 用一批本地文件替换当前队列。
  ///
  /// [startIndex] 指定从哪一首开始播。
  Future<void> loadFiles(
    List<File> files, {
    int startIndex = 0,
    bool autoPlay = true,
  }) async {
    if (files.isEmpty) return;

    // 先用文件名快速建出曲目，保证 UI 立刻有内容可显示
    final List<Track> tracks = files
        .map(
          (File f) => Track(
            id: f.path,
            uri: f.uri.toString(),
            title: f.uri.pathSegments.last.replaceAll(RegExp(r'\.[^.]+$'), ''),
            artist: '读取中…',
            album: '未知专辑',
          ),
        )
        .toList();

    _queue = tracks;
    _queueController.add(queue);
    _rebuildShuffleOrder();

    // 用整个队列一次性打开播放器：Player.open 接受 Playlist，
    // 这样切歌由底层接管，不需要重建播放器实例。
    final int index = startIndex.clamp(0, tracks.length - 1);
    try {
      await player.open(
        // Playlist 的 medias 是位置参数（不是命名参数）
        Playlist(tracks.map((Track t) => Media(t.uri)).toList(), index: index),
        play: autoPlay,
      );
      // 随机模式下：让它成为随机顺序里的"当前"（免得下一首又随机回它自己）
      _syncShufflePos(index);
      debugPrint(
        '[PlayerEngine] player.open 完成：index=$index，'
        'playing=${player.state.playing}，duration=${player.state.duration}',
      );
    } catch (error, stack) {
      // 打开失败必须让上层知道，否则界面停在那里毫无反应，很难排查
      debugPrint('[PlayerEngine] player.open 失败：$error');
      debugPrint('$stack');
      rethrow;
    }

    // 后台逐个补全标签，读到一条就推一条，不阻塞播放
    unawaited(_enrichMetadata(files));
  }

  /// 本地曲库首播：一次性打开完整队列并定位到点中的曲目。
  ///
  /// 旧实现为了首帧速度只打开第一首，再在后台逐个 `add`。在 Android
  /// 上用户很容易在追加完成前点击下一首，底层播放列表因此只有一首，
  /// 也会让歌单看起来没有队列。一次性提交完整 Playlist 能保证 UI 队列、
  /// media_kit 队列和下一首行为始终一致；元数据读取仍由调用方在后台完成。
  Future<void> loadLocalTracksFast(
    List<Track> tracks, {
    int startIndex = 0,
    bool autoPlay = true,
  }) async {
    if (tracks.isEmpty) return;
    final int index = startIndex.clamp(0, tracks.length - 1);
    _queue = List<Track>.of(tracks);
    _queueController.add(queue);
    _rebuildShuffleOrder();
    await player.open(
      Playlist(
        tracks.map((Track track) => Media(track.uri)).toList(growable: false),
        index: index,
      ),
      play: autoPlay,
    );
    _syncShufflePos(index);
  }

  /// 用一批**远端**曲目替换队列并开始播放（WebDAV 等）。
  ///
  /// ⚠️ 用户的明确要求：**不下载到本地**，每次播放都直接从网盘流式取
  /// （`Track.uri` 就是带鉴权的 WebDAV 地址，libmpv 自己会发 HTTP + Range 请求）。
  /// 所以这里：
  /// - **不做**本地文件扫描，也**不做**后台标签补全（`_enrichMetadata` 只吃本地文件）；
  /// - 曲名 / 艺术家由调用方（WebDAV 页面）从**文件名与目录名**推导出来；
  /// - 时长等由 mpv 边播边报（`player.state.duration`）。
  Future<void> loadRemoteTracks(
    List<Track> tracks, {
    int startIndex = 0,
    bool autoPlay = true,
    Map<String, String>? httpHeaders,
  }) async {
    if (tracks.isEmpty) return;

    _queue = tracks;
    _queueController.add(queue);
    _rebuildShuffleOrder();

    final int index = startIndex.clamp(0, tracks.length - 1);
    // ⚠️ 鉴权走**显式 HTTP 头**，不要只靠 URL 里的 `user:pass@`：
    //    mpv 对 https + userinfo 不保证认，表现就是"一直转圈然后跳下一首"。
    //    media_kit 的 Media 支持 httpHeaders（会转成 mpv 的 --http-header-fields）。
    final Map<String, String>? headers =
        (httpHeaders == null || httpHeaders.isEmpty) ? null : httpHeaders;
    await player.open(
      Playlist(
        tracks.map((Track t) => Media(t.uri, httpHeaders: headers)).toList(),
        index: index,
      ),
      play: autoPlay,
    );
    // 随机模式下：选集/换队列时，让"这一首"成为随机顺序的当前点
    _syncShufflePos(index);
    debugPrint(
      '[PlayerEngine] 远端队列已打开：${tracks.length} 首，index=$index，'
      'playing=${player.state.playing}（流式，未落盘，'
      '带了 ${headers?.length ?? 0} 个请求头）',
    );
  }

  /// **追加**一批曲目到当前队列（不打断正在播的那首）。
  ///
  /// 用于「添加到播放队列」以及"从搜索 / WebDAV 这类来源点播放"——
  /// 用户的明确要求：**这些来源是补充到队列，而不是把队列顶掉**。
  Future<int> enqueueTracks(
    List<Track> tracks, {
    Map<String, String>? httpHeaders,
    int? autoPlayIndex,
  }) async {
    if (tracks.isEmpty) return 0;
    final Map<String, String>? headers =
        (httpHeaders == null || httpHeaders.isEmpty) ? null : httpHeaders;
    final bool wasEmpty = _queue.isEmpty;
    final int firstIndex = _queue.length;
    _queue = <Track>[..._queue, ...tracks];
    _queueController.add(queue);
    for (final Track t in tracks) {
      await player.add(Media(t.uri, httpHeaders: headers));
    }
    if (_shuffle) _rebuildShuffleOrder(keep: firstIndex);
    // 什么时候开播：
    //   - `autoPlayIndex` 给了 → **点播**语义：追加完直接跳到那一首播（0.0.41 起
    //     搜索页 / WebDAV 页点某一首就走这里，"点啥放啥"）；
    //   - 队列本来是空的 → 追加的这批直接开始播（否则点「添加到播放队列」像没反应）；
    //   - 其余（纯"添加到播放队列"按钮）→ 只入队，不打断当前播放。
    final int? target = autoPlayIndex ?? (wasEmpty ? 0 : null);
    if (target != null && target >= 0 && target < tracks.length) {
      await player.jump(firstIndex + target);
      await player.play();
      _syncShufflePos(firstIndex + target);
    }
    debugPrint(
      '[PlayerEngine] 追加 ${tracks.length} 首到队列'
      '（现在共 ${_queue.length} 首，带了 ${headers?.length ?? 0} 个请求头，'
      '自动播放=${target ?? '否'}）',
    );
    return tracks.length;
  }

  /// 从一批路径加载：目录会被递归扫描，音频文件直接收下。
  /// 返回真正被加入的音频文件。调用方据此判断"选完到底有没有反应"。
  Future<List<File>> loadPaths(
    List<String> paths, {
    bool autoPlay = true,
  }) async {
    final List<File> files = <File>[];
    int directoryCount = 0;

    for (final String raw in paths) {
      final FileSystemEntityType type = FileSystemEntity.typeSync(raw);
      debugPrint('[PlayerEngine] 路径 [$raw] 类型=$type');

      switch (type) {
        case FileSystemEntityType.directory:
          final List<File> found = await scanAudioFilesAsync(raw);
          debugPrint('[PlayerEngine] 目录扫描到 ${found.length} 个音频文件');
          files.addAll(found);
          directoryCount++;
        case FileSystemEntityType.file:
          if (isSupportedAudioFile(raw)) {
            files.add(File(raw));
          } else {
            debugPrint('[PlayerEngine] 跳过不支持的扩展名：$raw');
          }
        default:
          debugPrint('[PlayerEngine] 跳过（路径不存在）：$raw');
      }
    }

    // 允许用户同时加入父目录和子目录时只保留一份曲目。
    final Map<String, File> unique = <String, File>{
      for (final File file in files) file.absolute.path.toLowerCase(): file,
    };
    final List<File> deduplicated = unique.values.toList()
      ..sort((File a, File b) => a.path.compareTo(b.path));

    debugPrint(
      '[PlayerEngine] loadPaths 汇总：$directoryCount 个目录，'
      '共 ${deduplicated.length} 个音频文件（去重前 ${files.length} 个）',
    );

    if (deduplicated.isEmpty) return const <File>[];
    await loadFiles(deduplicated, autoPlay: autoPlay);
    return deduplicated;
  }

  /// 追加到当前队列。
  Future<void> appendFiles(List<File> files) async {
    if (files.isEmpty) return;
    final List<Track> tracks = await Future.wait(files.map(Track.fromFile));
    _queue = <Track>[..._queue, ...tracks];
    _queueController.add(queue);
    for (final Track t in tracks) {
      await player.add(Media(t.uri));
    }
    unawaited(_enrichMetadata(files));
  }

  /// 按索引播放队列中的某一首。
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await player.jump(index);
    await player.play();
    // 随机模式下：手动点的这首优先级最高 → 把随机指针挪到它
    _syncShufflePos(index);
  }

  /// 从播放队列移除一首，不删除源文件；移除当前曲目时平滑切到相邻曲目。
  Future<void> removeQueueAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final int current = player.state.playlist.index;
    if (_queue.length == 1) {
      await player.stop();
      await player.remove(index);
    } else if (index == current) {
      // 先跳到相邻曲目，再删掉原当前项，避免播放器停在已移除媒体上。
      await player.jump(index < _queue.length - 1 ? index + 1 : index - 1);
      await player.remove(index);
    } else {
      await player.remove(index);
    }
    _queue = List<Track>.of(_queue)..removeAt(index);
    final int nextCurrent = player.state.playlist.index;
    _rebuildShuffleOrder(keep: nextCurrent);
    _queueController.add(queue);
  }

  /// 播放 / 暂停切换。
  Future<void> togglePlayPause() async {
    if (_queue.isEmpty && player.state.playlist.medias.isEmpty) return;
    if (player.state.playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  /// 下一首。
  ///
  /// 随机模式下走**我们自己的随机顺序**（见 [setShuffleMode]）——
  /// media_kit 的 `next()` 在随机模式下不保证随机（用户实测反馈：
  /// 「直接下一首按钮不是随机播放的」）。
  Future<void> next() async {
    if (_shuffle && _shuffleOrder.isNotEmpty) {
      _shufflePos = (_shufflePos + 1) % _shuffleOrder.length;
      await player.jump(_shuffleOrder[_shufflePos]);
      await player.play();
      return;
    }
    await player.next();
  }

  /// 上一首（随机模式下按我们自己的顺序倒着走）。
  Future<void> previous() async {
    if (_shuffle && _shuffleOrder.isNotEmpty) {
      _shufflePos =
          (_shufflePos - 1 + _shuffleOrder.length) % _shuffleOrder.length;
      await player.jump(_shuffleOrder[_shufflePos]);
      await player.play();
      return;
    }
    await player.previous();
  }

  /// 跳转到指定播放位置。
  Future<void> seek(Duration position) => player.seek(position);

  /// 设置音量（0~100）。
  Future<void> setVolume(double volume) =>
      player.setVolume(volume.clamp(0, 100));

  /// 切换音频输出通道。
  ///
  /// `AudioDevice.auto()` 交给系统选择默认设备；其它设备由 media_kit
  /// 根据当前平台返回的名称路由到扬声器、耳机或虚拟音频设备。
  Future<void> setAudioDevice(AudioDevice device) =>
      player.setAudioDevice(device);

  /// 随机播放开关（**自管顺序**，不再用 media_kit 的 shuffle）。
  ///
  /// 为什么不用 media_kit 的 `setShuffle`：它会把**内部播放列表重排**，
  /// 于是 `jump(i)` 里的 `i` 不再对应我们 `_queue` 的下标 ——
  /// 表现就是"随机模式下点哪首歌，播出来的都不是我点的那首"。
  /// 现在：
  ///   - 播放器里的列表顺序**永远等于 `_queue`**（下标一致，点歌必中）；
  ///   - 随机顺序单独记在 `_shuffleOrder` 里，只影响 `next()` / `previous()`；
  ///   - 手动点歌时把随机指针挪到那首（"我选的优先级更高"）。
  Future<void> setShuffleMode(bool shuffle) async {
    // 先把语义记下来：引擎还没初始化（测试 / 冷启动）时也不影响 UI 状态
    _shuffle = shuffle;
    try {
      await player.setShuffle(false);
      _rebuildShuffleOrder(keep: player.state.playlist.index);
    } catch (error) {
      // ⚠️ 必须是 try/catch：这个方法是 async 的，同步 throw 会变成"未处理的
      //    异步异常"—— 调用方那个 try/catch 抓不到（0.0.41 测试里踩到过）。
      debugPrint('[PlayerEngine] 随机模式设置失败（引擎未就绪？）：$error');
    }
  }

  /// 重建随机顺序（换队列 / 开随机时调用）。
  void _rebuildShuffleOrder({int keep = -1}) {
    _shuffleOrder = List<int>.generate(_queue.length, (int i) => i)
      ..shuffle(_random);
    if (keep >= 0 && keep < _queue.length) {
      _shuffleOrder.remove(keep);
      _shuffleOrder.insert(0, keep);
    }
    _shufflePos = 0;
  }

  /// 手动选中的那首在随机顺序里的位置（保持前后一致）。
  void _syncShufflePos(int index) {
    if (!_shuffle) return;
    final int pos = _shuffleOrder.indexOf(index);
    if (pos >= 0) {
      _shufflePos = pos;
    } else {
      _rebuildShuffleOrder(keep: index);
    }
  }

  /// 循环模式。
  ///
  /// [PlaybackMode] 是 UI 侧的语义，这里映射到 media_kit 的 [PlaylistMode]。
  /// 随机播放对应 `loop`（随机 + 列表循环），具体见枚举注释。
  Future<void> setReplayMode(PlaybackMode mode) {
    final PlaylistMode native = switch (mode) {
      PlaybackMode.sequential => PlaylistMode.none,
      PlaybackMode.repeatAll => PlaylistMode.loop,
      PlaybackMode.repeatOne => PlaylistMode.single,
      PlaybackMode.shuffle => PlaylistMode.loop,
    };
    return player.setPlaylistMode(native);
  }

  /// 当前是否正在播放。
  bool get isPlaying => player.state.playing;

  /// 当前曲目是否播完（一次性事件流）。
  Stream<bool> get completedStream => player.stream.completed;

  /// 后台补全标签：逐个读元数据并替换队列里的占位信息。
  Future<void> _enrichMetadata(List<File> files) async {
    for (final File file in files) {
      if (_disposed) return;
      try {
        final Track enriched = await Track.fromFile(file);
        final Track completed = enriched;
        final int idx = _queue.indexWhere((Track t) => t.id == completed.id);
        if (idx >= 0) {
          _queue = List<Track>.from(_queue)..[idx] = completed;
          _trackInfoController.add(completed);
        }
      } catch (_) {
        // 单首解析失败不影响其它曲目
      }
    }
    if (!_disposed) _queueController.add(queue);
  }

  /// 释放资源。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final Player? player = _player;
    // 先暂停再释放，避免退出窗口已经隐藏后音频仍继续播放一小段时间。
    // 不读取 lazy getter，避免从未播放过的应用在退出时反而创建播放器。
    if (player != null) {
      try {
        await player.pause().timeout(const Duration(milliseconds: 300));
      } catch (_) {
        // dispose 仍会继续尝试释放原生播放器。
      }
    }
    await _queueController.close();
    await _trackInfoController.close();
    await player?.dispose();
    _player = null;
  }
}
