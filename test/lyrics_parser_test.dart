import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hoh_music/features/player/lyrics/lyrics_parser.dart';

/// LRC 解析的单元测试（不依赖 Flutter，也不需要原生库）。
void main() {
  group('Lyrics.parse', () {
    test('解析基本时间标签与文本', () {
      final Lyrics lyrics = Lyrics.parse(
        '[00:12.34]第一行\n[00:15.00]第二行\n[01:05.50]第三行',
      );

      expect(lyrics.lines, hasLength(3));
      expect(lyrics.lines[0].text, '第一行');
      expect(
        lyrics.lines[0].time,
        const Duration(seconds: 12, milliseconds: 340),
      );
      expect(
        lyrics.lines[2].time,
        const Duration(minutes: 1, seconds: 5, milliseconds: 500),
      );
    });

    test('一行多个时间标签会展开成多条', () {
      final Lyrics lyrics = Lyrics.parse('[00:10.00][01:20.00]重复的副歌');
      expect(lyrics.lines, hasLength(2));
      expect(lyrics.lines[0].text, '重复的副歌');
      expect(lyrics.lines[1].time, const Duration(minutes: 1, seconds: 20));
    });

    test('读取元数据标签与 offset', () {
      final Lyrics lyrics = Lyrics.parse(
        '[ti:半句再见]\n[ar:孙燕姿]\n[al:跳舞的梵谷]\n[offset:-200]\n[00:01.00]词',
      );
      expect(lyrics.title, '半句再见');
      expect(lyrics.artist, '孙燕姿');
      expect(lyrics.album, '跳舞的梵谷');
      expect(lyrics.offset, const Duration(milliseconds: -200));
    });

    test('忽略没有时间标签的行与空行', () {
      final Lyrics lyrics = Lyrics.parse('作词：某人\n\n[00:01.00]正文\n[ar:歌手]');
      expect(lyrics.lines, hasLength(1));
      expect(lyrics.lines.single.text, '正文');
    });

    test('毫秒位数按 1/2/3 位分别解读', () {
      expect(
        Lyrics.parse('[00:01.5]a').lines.single.time,
        const Duration(seconds: 1, milliseconds: 500),
      );
      expect(
        Lyrics.parse('[00:01.25]a').lines.single.time,
        const Duration(seconds: 1, milliseconds: 250),
      );
      expect(
        Lyrics.parse('[00:01.125]a').lines.single.time,
        const Duration(seconds: 1, milliseconds: 125),
      );
    });
  });

  group('Lyrics.indexAt', () {
    final Lyrics lyrics = Lyrics.parse('[00:00.00]A\n[00:10.00]B\n[00:20.00]C');

    test('按位置返回当前行', () {
      expect(lyrics.indexAt(const Duration(seconds: 0)), 0);
      expect(lyrics.indexAt(const Duration(seconds: 9)), 0);
      expect(lyrics.indexAt(const Duration(seconds: 10)), 1);
      expect(lyrics.indexAt(const Duration(seconds: 19)), 1);
      expect(lyrics.indexAt(const Duration(minutes: 5)), 2);
    });

    test('offset 生效（正数表示歌词提前）', () {
      final Lyrics shifted = Lyrics.parse('[offset:1000]\n[00:10.00]B');
      // offset +1000ms → 播放到 9 秒时就已经进入这一行
      expect(shifted.indexAt(const Duration(seconds: 9)), 0);
      expect(shifted.indexAt(const Duration(seconds: 8)), -1);
    });

    test('还没到第一行时返回 -1', () {
      final Lyrics late = Lyrics.parse('[00:30.00]A');
      expect(late.indexAt(const Duration(seconds: 10)), -1);
    });

    test('空歌词返回 -1', () {
      expect(const Lyrics(lines: <LyricLine>[]).indexAt(Duration.zero), -1);
    });
  });

  test('TTML 逐词歌词保留翻译和词级时间轴', () {
    const String ttml = '''
<tt xmlns:ttm="http://www.w3.org/ns/ttml#"><body><div>
<p begin="00:01.000" end="00:03.000">
  <span begin="00:01.000" end="00:01.500">Hello</span>
  <span begin="00:01.500" end="00:02.000"> world</span>
  <span ttm:role="x-translation">你好 世界</span>
</p>
</div></body></tt>
''';
    final Lyrics lyrics = Lyrics.parseAuto(ttml);
    expect(lyrics.lines, hasLength(1));
    expect(lyrics.lines.single.text, 'Hello world');
    expect(lyrics.lines.single.translation, '你好 世界');
    expect(lyrics.lines.single.words, hasLength(2));
    expect(lyrics.lines.single.words.first.start, const Duration(seconds: 1));
  });

  group('Lyrics.decodeLyricBytes', () {
    test('UTF-8（含 BOM）正常解码', () {
      const String text = '[00:01.00]半句再见 - 孙燕姿';
      expect(Lyrics.decodeLyricBytes(utf8.encode(text)), text);
      expect(
        Lyrics.decodeLyricBytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(text)]),
        text,
      );
    });

    test('GBK 歌词按系统 ANSI 解码，不乱码', () {
      // 中文 Windows 上大量 .lrc 是 GBK：这里直接给出「半句再见」的 GBK 字节
      final List<int> gbk = <int>[
        0x5B,
        0x30,
        0x30,
        0x3A,
        0x30,
        0x31,
        0x2E,
        0x30,
        0x30,
        0x5D, // [00:01.00]
        0xB0, 0xEB, 0xBE, 0xE4, 0xD4, 0xD9, 0xBC, 0xFB, // 半句再见
      ];
      final String decoded = Lyrics.decodeLyricBytes(gbk);

      if (Platform.isWindows) {
        // 只有 Windows 才有 ANSI 兜底；中文系统上应当解出「半句再见」
        expect(decoded, contains('半句再见'));
      } else {
        // 其它平台退化为 Latin-1，至少不抛异常
        expect(decoded, isNotEmpty);
      }
    });
  });

  test('同时间戳的第二行会合并成翻译（0.0.26）', () {
    final Lyrics lyrics = Lyrics.parse(
      '[00:01.00]I have been waiting for you\n'
      '[00:01.00]我一直在等你\n'
      '[00:05.00]第二句\n',
    );
    expect(lyrics.lines, hasLength(2), reason: '翻译不该多出一行');
    expect(lyrics.lines.first.text, 'I have been waiting for you');
    expect(lyrics.lines.first.translation, '我一直在等你');
    expect(lyrics.lines[1].translation, isNull);

    // 同一句重复出现（时间相同、文本也相同）时不能被当成翻译吃掉
    final Lyrics dup = Lyrics.parse('[00:02.00]同一句\n[00:02.00]同一句\n');
    expect(dup.lines, hasLength(2));
    expect(dup.lines.first.translation, isNull);
  });

  test('同目录同名的 .lrc 能被找到（大小写都能命中）', () {
    final Directory dir = Directory.systemTemp.createTempSync('hoh_lrc_test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final File audio = File('${dir.path}\\track.flac')..writeAsStringSync('x');
    final File lrc = File('${dir.path}\\track.lrc')
      ..writeAsStringSync('[00:01.00]line');

    final File? found = Lyrics.siblingLrc(audio.path);
    expect(found, isNotNull);
    expect(found!.existsSync(), isTrue);
    expect(found.path.toLowerCase(), lrc.path.toLowerCase());

    // 换成大写扩展名：Windows 的文件系统不区分大小写，
    // 所以这里只断言"仍然找得到且文件存在"，不比对具体大小写
    lrc.deleteSync();
    File('${dir.path}\\track.LRC').writeAsStringSync('[00:01.00]line');
    final File? upper = Lyrics.siblingLrc(audio.path);
    expect(upper?.existsSync(), isTrue);

    // 没有歌词文件时返回 null
    upper?.deleteSync();
    expect(Lyrics.siblingLrc(audio.path), isNull);
  });
}
