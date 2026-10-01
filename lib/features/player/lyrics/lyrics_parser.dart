/// lyrics_parser.dart
///
/// LRC 歌词解析（架构文档 3.6 歌词系统）。
///
/// 支持的内容：
/// - 时间标签 `[mm:ss.xx]` / `[mm:ss:xx]` / `[mm:ss]`；
/// - 一行多个时间标签（`[00:12.00][01:20.00]同样的词`）；
/// - 元数据标签 `[ti:]` `[ar:]` `[al:]` `[by:]` `[offset:+/-毫秒]`；
/// - **编码兜底**：UTF-8 优先，失败时按系统 ANSI（中文系统 = GBK）解码，
///   见 `platforms/windows/ansi_text.dart`。
/// - TTML 逐词歌词：支持 AMLL TTML DB 的 `<p>/<span>` 时间轴，并保留翻译。
///
/// 歌词来源优先级：
/// 1. 音频文件内嵌歌词（ID3 USLT / Vorbis LYRICS / MP4 lyrics，由
///    `audio_metadata_reader` 读出来，存在 [Track.lyrics]）；
/// 2. 同目录同名的 `.lrc` 文件（大小写都试）。
///
/// KRC / QRC / YRC 仍由音源层按需转换；TTML 是当前播放页优先支持的
/// 逐词数据格式，避免把第三方渲染器绑定进 HoH 的跨端 UI。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/audio/player_engine.dart';
import '../../../core/source/host_search.dart';
import '../../../platforms/windows/ansi_text.dart';
import 'amll_ttml_source.dart';

/// 一行歌词。
@immutable
class LyricLine {
  /// 创建一行歌词。
  const LyricLine(
    this.time,
    this.text, {
    this.end,
    this.translation,
    this.words = const <LyricWord>[],
  });

  /// 该行出现的时刻。
  final Duration time;

  /// 歌词源明确提供的结束时间（TTML 等逐词格式）。LRC 没有该字段，
  /// 时间轴会按下一行或最后一个词回退计算。
  final Duration? end;

  /// 歌词文本。
  final String text;

  /// 翻译（0.0.26）。
  ///
  /// 来源：**同一时间戳的第二行** —— 中文歌词文件里最常见的双语写法：
  /// ```
  /// [00:12.00]I've been waiting for you
  /// [00:12.00]我一直在等你
  /// ```
  /// 解析时会把这种重复时间戳合并成一行（正文 + 译文）。
  final String? translation;

  /// 逐词时间轴。普通 LRC 为空，TTML 歌词可用它实现连续高亮。
  final List<LyricWord> words;

  /// 带翻译的一行（用于浮层显示）。
  LyricLine withTranslation(String? value) =>
      LyricLine(time, text, end: end, translation: value, words: words);

  @override
  String toString() =>
      '[${time.inMilliseconds}] $text${translation == null ? '' : ' / $translation'}';
}

/// TTML 中一个可逐词高亮的片段。
@immutable
class LyricWord {
  const LyricWord({required this.text, required this.start, required this.end});

  final String text;
  final Duration start;
  final Duration end;
}

/// 一份歌词。
@immutable
class Lyrics {
  /// 创建歌词。
  const Lyrics({
    required this.lines,
    this.title,
    this.artist,
    this.album,
    this.offset = Duration.zero,
  });

  /// 按时间升序排列的行。
  final List<LyricLine> lines;

  /// `[ti:]` 标题。
  final String? title;

  /// `[ar:]` 艺术家。
  final String? artist;

  /// `[al:]` 专辑。
  final String? album;

  /// `[offset:]` 整体偏移（正数表示歌词提前）。
  final Duration offset;

  /// 是否没有可用歌词。
  bool get isEmpty => lines.isEmpty;

  /// 返回 [position] 对应的行下标；还没到第一行时返回 -1。
  ///
  /// 用二分查找：歌词可能几百行，而这个方法每次进度更新都会被调用。
  int indexAt(Duration position) {
    if (lines.isEmpty) return -1;

    final int target = position.inMilliseconds + offset.inMilliseconds;
    if (target < lines.first.time.inMilliseconds) return -1;

    int low = 0;
    int high = lines.length - 1;
    while (low < high) {
      final int mid = (low + high + 1) ~/ 2;
      if (lines[mid].time.inMilliseconds <= target) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// 解析一段 LRC 文本。
  static Lyrics parse(String content) {
    final List<LyricLine> lines = <LyricLine>[];
    String? title;
    String? artist;
    String? album;
    int offsetMs = 0;

    final RegExp tagPattern = RegExp(r'\[([^\]]*)\]');
    // [mm:ss.xx] / [mm:ss:xx] / [mm:ss] / [m:ss]
    final RegExp timePattern = RegExp(
      r'^(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?$',
    );

    for (final String rawLine in const LineSplitter().convert(content)) {
      final String line = rawLine.trim();
      if (line.isEmpty) continue;

      final List<RegExpMatch> tags = tagPattern
          .allMatches(line)
          .toList(growable: false);
      if (tags.isEmpty) continue;

      // 标签之后剩下的就是歌词文本
      final String text = line.substring(tags.last.end).trim();

      final List<Duration> stamps = <Duration>[];
      for (final RegExpMatch tag in tags) {
        final String body = tag.group(1)?.trim() ?? '';
        final RegExpMatch? m = timePattern.firstMatch(body);
        if (m != null) {
          final int minutes = int.parse(m.group(1)!);
          final int seconds = int.parse(m.group(2)!);
          final String? frac = m.group(3);
          int millis = 0;
          if (frac != null) {
            // 一位是百分秒、两位是厘秒、三位是毫秒
            millis = frac.length == 1
                ? int.parse(frac) * 100
                : (frac.length == 2 ? int.parse(frac) * 10 : int.parse(frac));
          }
          stamps.add(
            Duration(minutes: minutes, seconds: seconds, milliseconds: millis),
          );
          continue;
        }

        // 元数据标签
        final int colon = body.indexOf(':');
        if (colon <= 0) continue;
        final String key = body.substring(0, colon).toLowerCase();
        final String value = body.substring(colon + 1).trim();
        switch (key) {
          case 'ti':
            title = value.isEmpty ? null : value;
          case 'ar':
            artist = value.isEmpty ? null : value;
          case 'al':
            album = value.isEmpty ? null : value;
          case 'offset':
            offsetMs = int.tryParse(value) ?? 0;
        }
      }

      if (stamps.isEmpty || text.isEmpty) continue;
      for (final Duration stamp in stamps) {
        // 同一时间戳的第二行 = 这行的翻译（0.0.26）。
        // 约束：时间相同、文本不同、还没配过翻译 —— 三条都满足才合并，
        // 免得把正常的重复歌词吃掉。
        final int sameTime = lines.indexWhere(
          (LyricLine l) =>
              l.time == stamp && l.text != text && l.translation == null,
        );
        if (sameTime >= 0) {
          lines[sameTime] = lines[sameTime].withTranslation(text);
          continue;
        }
        lines.add(LyricLine(stamp, text));
      }
    }

    lines.sort((LyricLine a, LyricLine b) => a.time.compareTo(b.time));

    return Lyrics(
      lines: lines,
      title: title,
      artist: artist,
      album: album,
      offset: Duration(milliseconds: offsetMs),
    );
  }

  /// 按内容自动识别 LRC / TTML。
  static Lyrics parseAuto(String content) {
    final String trimmed = content.trimLeft();
    if (RegExp(r'<tt(?:\s|>)', caseSensitive: false).hasMatch(trimmed)) {
      return parseTtml(content);
    }
    return parse(content);
  }

  /// 解析 AMLL TTML DB 的逐词歌词。
  ///
  /// 采用轻量 XML 片段解析，避免给桌面、移动端和 TV 增加 XML 运行时
  /// 依赖。AMLL 文件的核心结构是 `<p begin/end><span begin/end>`，
  /// 其它元数据不影响播放，按纯文本安全降级。
  static Lyrics parseTtml(String content) {
    final List<LyricLine> lines = <LyricLine>[];
    final RegExp paragraph = RegExp(
      r'<p\b([^>]*)>([\s\S]*?)</p>',
      caseSensitive: false,
    );
    final RegExp attr = RegExp(r'([\w:.-]+)\s*=\s*"([^"]*)"');
    final RegExp span = RegExp(
      r'<span\b([^>]*)>([\s\S]*?)</span>',
      caseSensitive: false,
    );

    for (final RegExpMatch pMatch in paragraph.allMatches(content)) {
      final Map<String, String> pAttrs = <String, String>{
        for (final RegExpMatch m in attr.allMatches(pMatch.group(1) ?? ''))
          m.group(1)!.toLowerCase(): m.group(2)!,
      };
      final Duration? start = _parseTtmlTime(pAttrs['begin']);
      if (start == null) continue;
      final String body = pMatch.group(2) ?? '';
      String? translation;
      final List<LyricWord> words = <LyricWord>[];
      final StringBuffer text = StringBuffer();
      int cursor = 0;

      for (final RegExpMatch sMatch in span.allMatches(body)) {
        text.write(_stripMarkup(body.substring(cursor, sMatch.start)));
        final Map<String, String> attrs = <String, String>{
          for (final RegExpMatch m in attr.allMatches(sMatch.group(1) ?? ''))
            m.group(1)!.toLowerCase(): m.group(2)!,
        };
        final String value = _stripMarkup(sMatch.group(2) ?? '');
        final String role = attrs['ttm:role'] ?? attrs['role'] ?? '';
        if (role == 'x-translation' || role == 'translation') {
          translation = value.trim();
        } else {
          text.write(value);
          final Duration? wordStart = _parseTtmlTime(attrs['begin']);
          final Duration? wordEnd = _parseTtmlTime(attrs['end']);
          if (wordStart != null && wordEnd != null && value.trim().isNotEmpty) {
            words.add(LyricWord(text: value, start: wordStart, end: wordEnd));
          }
        }
        cursor = sMatch.end;
      }
      text.write(_stripMarkup(body.substring(cursor)));
      final String value = text
          .toString()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (value.isEmpty) continue;
      final Duration? end = _parseTtmlTime(pAttrs['end']);
      lines.add(
        LyricLine(
          start,
          value,
          end: end,
          translation: translation,
          words: words,
        ),
      );
    }
    lines.sort((LyricLine a, LyricLine b) => a.time.compareTo(b.time));
    return Lyrics(lines: lines);
  }

  static Duration? _parseTtmlTime(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final String value = raw.trim();
    final RegExpMatch? clock = RegExp(
      r'^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?$',
    ).firstMatch(value);
    if (clock != null) {
      final int hours = int.tryParse(clock.group(1) ?? '0') ?? 0;
      final int minutes = int.tryParse(clock.group(2)!) ?? 0;
      final int seconds = int.tryParse(clock.group(3)!) ?? 0;
      final String fraction = clock.group(4) ?? '';
      final int millis = fraction.isEmpty
          ? 0
          : int.parse(fraction.padRight(3, '0').substring(0, 3));
      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: millis,
      );
    }
    final RegExpMatch? offset = RegExp(r'^(\d+(?:\.\d+)?)(ms|s)$')
        .firstMatch(value);
    if (offset == null) return null;
    final double number = double.tryParse(offset.group(1)!) ?? 0;
    return Duration(
      milliseconds: (number * (offset.group(2) == 's' ? 1000 : 1)).round(),
    );
  }

  static String _stripMarkup(String value) => value
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

  /// 取一首曲目的歌词：先内嵌，再同目录的 `.lrc`，最后（可选）**问音源平台**。
  ///
  /// 取不到就返回 `null`（界面显示"未找到歌词"，不是错误）。
  ///
  /// [useOnline] = 用音源平台刮（`sourceScrapeProvider`）：
  /// - **远端曲目**（在线音源 / WebDAV）：id 里就有平台和歌曲号，直接按平台取；
  /// - **本地曲目**：用「歌名 + 歌手」在平台上匹配一首最像的，再取它的歌词
  ///   （带翻译）—— 这样"本地歌也能有滚动歌词"。
  static Future<Lyrics?> forTrack(Track track, {bool useOnline = false}) async {
    // ① 内嵌歌词
    final String? embedded = track.lyrics;
    if (embedded != null && embedded.trim().isNotEmpty) {
      final Lyrics lyrics = parseAuto(embedded);
      if (!lyrics.isEmpty) return lyrics;
    }

    // ② 远端曲目没有同目录文件，直接问宿主搜索层
    if (track.isRemote) {
      if (!useOnline) return null;
      final String? amll = await AmllTtmlSource.fetchForTrack(track);
      if (amll != null) {
        final Lyrics lyrics = parseAuto(amll);
        if (!lyrics.isEmpty) return lyrics;
      }
      final String? online = await _onlineLyric(track);
      if (online != null && online.trim().isNotEmpty) {
        final Lyrics lyrics = parseAuto(online);
        if (!lyrics.isEmpty) return lyrics;
      }
      return null;
    }

    // ③ 同名 .lrc
    final File? localLyric = siblingLyricFile(track.id);
    if (localLyric != null) {
      try {
        final String text = decodeLyricBytes(await localLyric.readAsBytes());
        final Lyrics lyrics = parseAuto(text);
        if (!lyrics.isEmpty) return lyrics;
      } catch (error) {
        debugPrint('[Lyrics] 读取歌词失败（${localLyric.path}）：$error');
      }
    }

    // ④ 本地曲目：音源平台刮一份（离线时静默失败，不影响播放）
    if (useOnline) {
      final String? amll = await AmllTtmlSource.fetchForTrack(track);
      if (amll != null) {
        final Lyrics lyrics = parseAuto(amll);
        if (!lyrics.isEmpty) return lyrics;
      }
      final String? online = await _onlineLyric(track);
      if (online != null && online.trim().isNotEmpty) {
        final Lyrics lyrics = parseAuto(online);
        if (!lyrics.isEmpty) return lyrics;
      }
    }
    return null;
  }

  /// 问音源平台要歌词（失败/没匹配上都返回 null）。
  static Future<String?> _onlineLyric(Track track) async {
    try {
      return await HostSearch.instance.lyricForTrack(track);
    } catch (error) {
      debugPrint('[Lyrics] 音源平台取歌词失败：$error');
      return null;
    }
  }

  /// 找音频文件旁边同名的 `.lrc`（扩展名大小写都试）。
  static File? siblingLyricFile(String audioPath) {
    final String base = p.withoutExtension(audioPath);
    for (final String ext in <String>[
      '.ttml',
      '.TTML',
      '.lrc',
      '.LRC',
      '.Lrc',
    ]) {
      final File file = File('$base$ext');
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// 兼容旧调用方。
  static File? siblingLrc(String audioPath) => siblingLyricFile(audioPath);

  /// 字节 → 文本：UTF-8 优先，失败时按系统 ANSI（中文 = GBK）兜底。
  ///
  /// 顺序很重要：把 GBK 文本当 UTF-8 读会抛异常（能走到兜底），
  /// 而把 UTF-8 当 GBK 读**必然乱码**，所以必须先试 UTF-8。
  @visibleForTesting
  static String decodeLyricBytes(List<int> bytes) {
    // 去掉 UTF-8 BOM
    final List<int> body =
        (bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF)
        ? bytes.sublist(3)
        : bytes;

    try {
      return utf8.decode(body);
    } catch (_) {
      // 不是 UTF-8：交给 Windows 的 ANSI 代码页
    }

    final String? ansi = decodeSystemAnsi(body);
    if (ansi != null) return ansi;

    // 最后的兜底：Latin-1 不会抛异常，至少不崩
    return latin1.decode(body, allowInvalid: true);
  }
}
