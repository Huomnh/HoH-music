/// 自定义音源相关**纯逻辑**单测（不联网、不起沙箱）。
///
/// 覆盖三块容易出错、又最适合单测的东西：
///   1. 登记表 / 在线曲目的 JSON 编解码（坏数据不能炸整个列表）；
///   2. 脚本头部元信息解析（展示名靠它，别被正文里的同名串骗了）；
///   3. 宿主搜索的响应解析（网易云 / iTunes 的真实字段形状）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hoh_music/core/audio/player_engine.dart' show Track;
import 'package:hoh_music/core/metadata/text_match.dart';
import 'package:hoh_music/core/source/host_search.dart';
import 'package:hoh_music/core/source/source_models.dart';
import 'package:hoh_music/features/library/library_views.dart' show primaryName;

/// 造一条"本地文件"曲目（只用到 title / artist，uri 随便给个本地路径）。
Track _localTrack(String title, String artist) => Track(
  id: r'D:\音乐\test.flac',
  uri: r'D:\音乐\test.flac',
  title: title,
  artist: artist,
  album: '',
);

void main() {
  group('MusicSource 登记表', () {
    test('JSON 往返不丢字段', () {
      const MusicSource source = MusicSource(
        id: 'abc123',
        name: '念心音源',
        origin: SourceOrigin.url,
        location: 'https://example.com/a.js',
        enabled: false,
        version: '1.0.2',
        author: '念心',
        platforms: <String>['wy', 'tx'],
        actions: <String>['musicUrl'],
        qualitys: <String>['320k'],
        error: '',
      );
      final MusicSource back = MusicSource.fromJson(
        jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
      );
      expect(back.id, 'abc123');
      expect(back.name, '念心音源');
      expect(back.origin, SourceOrigin.url);
      expect(back.enabled, isFalse);
      expect(back.version, '1.0.2');
      expect(back.platforms, <String>['wy', 'tx']);
      expect(back.platformLabels, <String>['芸音', '鹅音']);
    });

    test('坏数据不炸：空串 / 非 JSON / 混了坏记录都只丢弃坏的那条', () {
      expect(MusicSource.decodeRegistry(null), isEmpty);
      expect(MusicSource.decodeRegistry(''), isEmpty);
      expect(MusicSource.decodeRegistry('not json'), isEmpty);
      expect(MusicSource.decodeRegistry('{"a":1}'), isEmpty);
      final List<MusicSource> list = MusicSource.decodeRegistry(
        '[{"id":"x1","name":"A"},{"name":"没有 id 会被丢掉"},{"id":"x2"}]',
      );
      expect(list.length, 2);
      expect(list.first.enabled, isTrue, reason: '默认应该是启用');
      expect(list.last.name, '未命名音源');
    });

    test('脚本头部元信息：读 @name/@version/@author，且不看正文', () {
      const String code = '''
/**
 * @name 我的音源
 * @version 2.1.0
 * @author 张三
 */
lx.send('inited', {});
const text = "@name 正文里的假名字";
''';
      final ({String name, String version, String author}) meta =
          MusicSource.parseScriptHeader(code);
      expect(meta.name, '我的音源');
      expect(meta.version, '2.1.0');
      expect(meta.author, '张三');
    });

    test('没有头部注释时返回空（由调用方退回文件名）', () {
      final ({String name, String version, String author}) meta =
          MusicSource.parseScriptHeader("lx.send('inited', {});");
      expect(meta.name, isEmpty);
      expect(meta.version, isEmpty);
    });
  });

  group('OnlineTrack', () {
    const OnlineTrack track = OnlineTrack(
      platform: 'wy',
      songId: '186016',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      albumId: '185809',
      duration: Duration(minutes: 4, seconds: 29),
      quality: '320k',
    );

    test('id 用「平台:歌曲id」，与播放队列里的 Track.id 对得上', () {
      expect(track.id, 'wy:186016');
      expect(track.platformLabel, '芸音');
    });

    test('musicInfo 把各平台可能用到的字段名都给全', () {
      final Map<String, dynamic> info = track.toMusicInfo();
      expect(info['source'], 'wy');
      expect(info['songmid'], '186016');
      expect(info['songId'], '186016');
      expect(info['id'], '186016');
      expect(info['name'], '晴天');
      expect(info['singer'], '周杰伦');
      expect(info['albumName'], '叶惠美');
      expect(info['type'], '320k');
      // 音质可以按这次实际要解析的档位覆盖
      expect(track.toMusicInfo(qualityOverride: 'flac')['type'], 'flac');
    });

    test('musicInfo **不塞空字符串字段**（这是被踩过的坑）', () {
      // 音源脚本普遍写 `hash ?? songmid ?? id`，给个 hash:'' 会堵死后面的兜底，
      // 结果"字段明明给了却报缺少参数"（咪咕就是这么挂的）。
      final Map<String, dynamic> info = track.toMusicInfo();
      expect(info.containsKey('hash'), isFalse);
      expect(
        info.containsKey('albumMid') == false || info['albumMid'] != '',
        isTrue,
      );
      expect(
        info.values.where((Object? v) => v is String && v.isEmpty),
        isEmpty,
        reason: '不该有任何空字符串字段',
      );
    });

    test('平台特有字段（extra）会并进 musicInfo', () {
      const OnlineTrack kg = OnlineTrack(
        platform: 'kg',
        songId: 'HASH',
        title: '晴天',
        extra: <String, dynamic>{'320hash': 'H320', 'audio_id': '123'},
      );
      final Map<String, dynamic> info = kg.toMusicInfo();
      expect(info['320hash'], 'H320');
      expect(info['audio_id'], '123');
      expect(info['songmid'], 'HASH');
    });

    test('在线收藏的 JSON 往返', () {
      const OnlineTrack second = OnlineTrack(
        platform: 'wy',
        songId: '186017',
        title: 'Qing Tian',
      );
      final List<OnlineTrack> back = OnlineTrack.decodeList(
        OnlineTrack.encodeList(<OnlineTrack>[track, second]),
      );
      expect(back.length, 2);
      expect(back.first.duration, const Duration(minutes: 4, seconds: 29));
      expect(back.last.platform, 'wy');
      expect(OnlineTrack.decodeList('garbage'), isEmpty);
    });
  });

  group('宿主搜索响应解析', () {
    test('网易云搜索：歌名 / 多歌手 / 专辑封面 / 时长', () {
      final Map<String, dynamic> fixture = jsonDecode('''
      {"result":{"songCount":2,"songs":[
        {"id":186016,"name":"晴天","duration":269000,
         "artists":[{"id":6452,"name":"周杰伦"}],
         "album":{"id":185809,"name":"叶惠美","picUrl":"https://p1.music.126.net/x.jpg"}},
        {"id":1330348068,"name":"起风了","duration":325000,
         "artists":[{"name":"买辣椒也用券"},{"name":"周杰伦"}],
         "album":{"id":1,"name":"起风了"}}
      ]}}''') as Map<String, dynamic>;

      final List<OnlineTrack> tracks = HostSearch.parseNeteaseSearch(fixture);
      expect(tracks.length, 2);
      expect(tracks.first.id, 'wy:186016');
      expect(tracks.first.title, '晴天');
      expect(tracks.first.artist, '周杰伦');
      expect(tracks.first.album, '叶惠美');
      expect(tracks.first.albumId, '185809');
      expect(tracks.first.duration, const Duration(milliseconds: 269000));
      expect(tracks.first.coverUrl, 'https://p1.music.126.net/x.jpg');
      expect(tracks.last.artist, '买辣椒也用券 / 周杰伦');
      expect(tracks.last.coverUrl, isEmpty);
    });

    test('网易云搜索：没有 result / songs 时返回空表，不抛异常', () {
      expect(HostSearch.parseNeteaseSearch(<String, dynamic>{}), isEmpty);
      expect(
        HostSearch.parseNeteaseSearch(<String, dynamic>{
          'result': <String, dynamic>{},
        }),
        isEmpty,
      );
      expect(
        HostSearch.parseNeteaseSearch(<String, dynamic>{'result': 42}),
        isEmpty,
      );
    });

    test('英文网易云歌词：只保留原文，不拼中文翻译', () {
      final String? merged = HostSearch.parseNeteaseLyric(<String, dynamic>{
        'lrc': <String, dynamic>{
          'lyric': '[00:01.00]The little yellow flower\n',
        },
        'tlyric': <String, dynamic>{'lyric': '[00:01.00]小小的黄花\n'},
      });
      expect(merged, isNotNull);
      expect(merged, '[00:01.00]The little yellow flower\n\n[00:01.00]小小的黄花\n');
    });

    test('网易云歌词：空响应 → null；没翻译就只留原文', () {
      expect(HostSearch.parseNeteaseLyric(<String, dynamic>{}), isNull);
      expect(
        HostSearch.parseNeteaseLyric(<String, dynamic>{
          'lrc': <String, dynamic>{'lyric': '   '},
          'tlyric': <String, dynamic>{'lyric': ''},
        }),
        isNull,
      );
      final String? only = HostSearch.parseNeteaseLyric(<String, dynamic>{
        'lrc': <String, dynamic>{'lyric': '[00:01.00]只有原文'},
      });
      expect(only, '[00:01.00]只有原文');
    });

    test('Track.id 拆分：只有 `平台:id` 才算，别的都当未知', () {
      expect(HostSearch.splitTrackId('wy:186016'), ('wy', '186016'));
      // Windows 盘符不能被当成平台（这条是真踩过的 bug）
      expect(HostSearch.splitTrackId('D:\\音乐\\a.flac'), ('', ''));
      expect(HostSearch.splitTrackId('wy:'), ('', ''));
      expect(HostSearch.splitTrackId(':123'), ('', ''));
      expect(HostSearch.splitTrackId('qsvip:abc'), ('qsvip', 'abc'));
    });
  });

  group('模糊刮削（本地文件名千奇百怪）', () {
    test('文件名清洗：序号 / 码率噪声 / 括号后缀都去掉', () {
      expect(HostSearch.cleanQuery('01. 晴天 - 周杰伦'), '01. 晴天 - 周杰伦');
      expect(HostSearch.smartTitleOf(_localTrack('01. 晴天 320K', '周杰伦')), '晴天');
      expect(
        HostSearch.smartTitleOf(_localTrack('晴天_周杰伦_320K', '周杰伦')),
        '晴天 周杰伦',
      );
      // `歌手 - 歌名` 这种文件名，按 tag 里的歌手把真正歌名拆出来
      expect(HostSearch.smartTitleOf(_localTrack('周杰伦 - 晴天', '周杰伦')), '晴天');
      expect(HostSearch.smartTitleOf(_localTrack('晴天 - 周杰伦', '周杰伦')), '晴天');
    });

    test('普通歌词抓取仍然保留（0.0.52 只删了翻译那一层）', () {
      // 网易云的歌词解析（lrc + tlyric 拼在一起）没动
      final String? only = HostSearch.parseNeteaseLyric(<String, dynamic>{
        'lrc': <String, dynamic>{'lyric': '[00:01.00]只有原文'},
      });
      expect(only, '[00:01.00]只有原文');
    });
  });

  group('文件名里的「艺术家 / 标题」（顺序不固定）', () {
    test('标题在前、艺术家在后也能判对（用户实测的那首）', () {
      final (String artist, String title) = Track.splitFileName(
        'Last Thing You Need (from GTAVI The Album) - Morgan Wallen、Grand Theft Auto VI',
      );
      expect(artist, 'Morgan Wallen、Grand Theft Auto VI');
      expect(title, 'Last Thing You Need (from GTAVI The Album)');
    });

    test('常见的「艺术家 - 标题」保持原顺序', () {
      expect(Track.splitFileName('周杰伦 - 晴天'), ('周杰伦', '晴天'));
      expect(Track.splitFileName('Jay Chou - Qing Tian (Live)'), (
        'Jay Chou',
        'Qing Tian (Live)',
      ));
    });

    test('没有分隔符就返回空（交回调用方）', () {
      expect(Track.splitFileName('晴天'), ('', ''));
    });
  });

  group('模糊分类：只按第一个名字', () {
    test('多歌手 / 多作者分隔符都取第一个', () {
      expect(primaryName('周杰伦、袁咏琳'), '周杰伦');
      expect(primaryName('A / B'), 'A');
      expect(primaryName('A & B'), 'A');
      expect(primaryName('A feat. B'), 'A');
      expect(primaryName('A, B'), 'A');
      expect(primaryName('周杰伦'), '周杰伦');
      expect(primaryName(''), '');
    });
  });

  group('展示名兜底', () {
    test('未知平台 / 音质原样返回，不当成空', () {
      expect(platformLabel('wy'), '芸音');
      expect(platformLabel('unknown-platform'), 'unknown-platform');
      expect(qualityLabel('320k'), '高 320k');
      expect(qualityLabel('weird'), 'weird');
    });
  });

  group('多平台搜索解析', () {
    test('QQ音乐（new_json）：mid / 多歌手 / albumMid 拼封面', () {
      final Map<String, dynamic> fixture = jsonDecode('''
      {"code":0,"data":{"song":{"totalnum":1234,"list":[
        {"mid":"0039MnYb0qxYhV","name":"晴天","interval":269,
         "singer":[{"name":"周杰伦"}],"album":{"mid":"002fRO0N4FftzY","name":"叶惠美"}},
        {"mid":"004Z8Ihr0JIu5s","name":"稻香","interval":223,
         "singer":[{"name":"周杰伦"},{"name":"袁咏琳"}],"album":{"mid":"","name":"魔杰座"}}
      ]}}}''') as Map<String, dynamic>;

      final List<OnlineTrack> tracks = HostSearch.parseQQSearch(fixture);
      expect(tracks.length, 2);
      expect(tracks.first.platform, 'tx');
      expect(tracks.first.songId, '0039MnYb0qxYhV');
      expect(tracks.first.albumId, '002fRO0N4FftzY');
      expect(tracks.first.duration, const Duration(seconds: 269));
      expect(
        tracks.first.coverUrl,
        'https://y.gtimg.cn/music/photo_new/T002R300x300M000002fRO0N4FftzY.jpg',
      );
      expect(tracks.last.artist, '周杰伦 / 袁咏琳');
      expect(tracks.last.coverUrl, isEmpty, reason: '没有 albumMid 就不硬拼');
    });

    test('QQ音乐：空数据不抛异常', () {
      expect(HostSearch.parseQQSearch(<String, dynamic>{}), isEmpty);
      expect(
        HostSearch.parseQQSearch(<String, dynamic>{
          'data': <String, dynamic>{},
        }),
        isEmpty,
      );
    });

    test('QQ歌单：按顺序读取曲目信息并按 ID 去重', () {
      final List<OnlineTrack> tracks = HostSearch.parseQQPlaylist(
        jsonDecode('''
        {"songlist":[
          {"id":123,"mid":"001mid","name":"歌一","interval":211,
           "singer":[{"name":"歌手甲"}],"album":{"mid":"albummid","name":"专辑甲"},
           "file":{"media_mid":"media001"}},
          {"id":123,"mid":"001mid","name":"歌一","interval":211,
           "singer":[{"name":"歌手甲"}],"album":{"mid":"albummid","name":"专辑甲"}},
          {"id":456,"mid":"","name":"歌二","interval":180,
           "singer":[{"name":"歌手乙"}],"album":{"name":"专辑乙"}}
        ]}''') as Map<String, dynamic>,
      );
      expect(tracks.map((OnlineTrack track) => track.songId), <String>[
        '001mid',
        '456',
      ]);
      expect(tracks.first.title, '歌一');
      expect(tracks.first.artist, '歌手甲');
      expect(tracks.first.duration, const Duration(seconds: 211));
      expect(tracks.first.extra['media_mid'], 'media001');
      expect(tracks.last.album, '专辑乙');
    });

    test('QQ歌单分享：网页链接和电脑端短链都能提取真实 ID', () {
      expect(
        HostSearch.extractQqPlaylistId(
          'https://i2.y.qq.com/n3/other/pages/details/playlist.html?id=8042312767',
        ),
        '8042312767',
      );
      expect(
        HostSearch.extractQqPlaylistId(
          '<meta property="og:url" content="https://y.qq.com//n/ryqq_v2/playlist/3571076617">',
        ),
        '3571076617',
      );
      expect(
        HostSearch.extractQqPlaylistId(
          r'https://c6.y.qq.com/base/fcgi-bin/u?__=token\&next=https%3A%2F%2Fy.qq.com%2Fplaylist%2F9083461089',
        ),
        '9083461089',
      );
      expect(
        HostSearch.extractQqPlaylistId(
          r'{"og:url":"https:\/\/y.qq.com\/n\/ryqq_v2\/playlist\/3571076617"}',
        ),
        '3571076617',
      );
      expect(
        HostSearch.extractQqPlaylistId(
          'https://y.qq.com/n/ryqq_v2/playlist/3571076617?ADTAG=h5_share_playlist&redirecttag=mn.redirect.custom&mnst=0.98',
        ),
        '3571076617',
      );
    });

    test('酷狗（mobilecdn）：hash 当 songid，duration 是秒', () {
      final Map<String, dynamic> fixture = jsonDecode('''
      {"status":1,"data":{"total":999,"info":[
        {"hash":"cbcb2b1f6e6b1b0ecf5b6c8f1c9f0a1b","songname":"晴天",
         "singername":"周杰伦","album_id":"1234567","albumname":"叶惠美","duration":269}
      ]}}''') as Map<String, dynamic>;

      final List<OnlineTrack> tracks = HostSearch.parseKugouSearch(fixture);
      expect(tracks.length, 1);
      expect(tracks.first.platform, 'kg');
      expect(tracks.first.songId, 'cbcb2b1f6e6b1b0ecf5b6c8f1c9f0a1b');
      expect(tracks.first.title, '晴天');
      expect(tracks.first.albumId, '1234567');
      expect(tracks.first.duration, const Duration(seconds: 269));
    });

    test('酷我：单引号对象字面量也能解析（含撇号歌名不崩）', () {
      const String raw =
          "{'TOTAL':'2','abslist':["
          "{'SONGNAME':'晴天','ARTIST':'周杰伦','ALBUM':'叶惠美',"
          "'MUSICRID':'MUSIC_6289602','ALBUMID':'6289601','DURATION':'269'},"
          "{'SONGNAME':'Don't Stop','ARTIST':'群星','MUSICRID':'MUSIC_1'}]}";
      final Map<String, dynamic> body = HostSearch.looseObjectToMap(raw);
      final List<OnlineTrack> tracks = HostSearch.parseKuwoSearch(body);
      expect(tracks.length, 2, reason: '撇号歌名不能把解析整挂');
      expect(tracks.first.platform, 'kw');
      expect(tracks.first.songId, 'MUSIC_6289602');
      expect(tracks.first.artist, '周杰伦');
      expect(tracks.first.duration, const Duration(seconds: 269));
    });

    test('咪咕（v2）：copyrightId / singers / albums / 标签 / 歌词地址', () {
      final Map<String, dynamic> fixture = jsonDecode('''
      {"code":"000000","songResultData":{"totalCount":"198","result":[
        {"id":"3790007","copyrightId":"60054701923","name":"晴天",
         "singers":[{"id":"112","name":"周杰伦"}],
         "albums":[{"id":"8592","name":"叶惠美","type":"1"}],
         "tags":["流行","爱情","国语","伤感"],
         "lyricUrl":"https://d.musicapp.migu.cn/lyric/1.lrc"}
      ]}}''') as Map<String, dynamic>;

      final List<OnlineTrack> tracks = HostSearch.parseMiguSearch(fixture);
      expect(tracks.length, 1);
      expect(tracks.first.platform, 'mg');
      expect(tracks.first.songId, '60054701923');
      expect(tracks.first.artist, '周杰伦');
      expect(tracks.first.album, '叶惠美');
      expect(tracks.first.albumId, '8592');
      expect(tracks.first.tags, contains('流行'));
      expect(tracks.first.lyricUrl, endsWith('1.lrc'));
    });

    test('咪咕：老结构（musics）也能解析，空数据不抛异常', () {
      final Map<String, dynamic> fixture = jsonDecode(
        '''
      {"musics":[{"id":"6008310HJ4U","copyrightId":"6008310HJ4U",
        "songName":"晴天","singerName":"周杰伦","albumName":"叶惠美",
        "albumId":"6008310HJ4U","cover":"https://cdn.migu.cn/x.jpg"}]}''',
      ) as Map<String, dynamic>;
      final List<OnlineTrack> tracks = HostSearch.parseMiguSearch(fixture);
      expect(tracks.length, 1);
      expect(tracks.first.songId, '6008310HJ4U');
      expect(tracks.first.coverUrl, 'https://cdn.migu.cn/x.jpg');
      expect(HostSearch.parseMiguSearch(<String, dynamic>{}), isEmpty);
    });

    test('酷狗：`trans_param.union_cover` 里的 {size} 要换成实际尺寸', () {
      final Map<String, dynamic> fixture = jsonDecode('''
      {"status":1,"data":{"info":[
        {"hash":"b3a52a7a958bf0aed0ebfba2e9a818b7","songname":"晴天",
         "singername":"周杰伦","album_id":"966846","album_name":"叶惠美",
         "duration":269,
         "trans_param":{"union_cover":"http://imge.kugou.com/stdmusic/{size}/2023.jpg"}}
      ]}}''') as Map<String, dynamic>;
      final List<OnlineTrack> tracks = HostSearch.parseKugouSearch(fixture);
      expect(
        tracks.first.coverUrl,
        'http://imge.kugou.com/stdmusic/240/2023.jpg',
      );
      expect(tracks.first.album, '叶惠美');
    });
  });

  group('歌名相似度（本地曲目匹配用）', () {
    test('归一化：去掉括号内容与标点空格', () {
      expect(normalizeTrackText('半句再见 (Live)'), '半句再见');
      expect(normalizeTrackText('Qing  Tian!'), 'qingtian');
      expect(normalizeTrackText('【纯音乐】晴天'), '晴天');
    });

    test('歌名清洗：去 HTML 实体与括号后缀（跨平台兜底搜索用）', () {
      expect(HostSearch.cleanQuery('晴天&nbsp;(KTV版伴奏)'), '晴天');
      expect(HostSearch.cleanQuery('晴天 (Live)'), '晴天');
      expect(HostSearch.cleanQuery('  稻香  '), '稻香');
    });

    test('相似度：完全一样 1，包含 0.8，风马牛不相及很低', () {
      expect(similarityOf('晴天', '晴天'), 1);
      expect(similarityOf('晴天', '晴天 (Live)'), 1, reason: '括号内容会先被去掉');
      expect(similarityOf('起风了', '起风了 (原唱)'), 1);
      expect(similarityOf('晴天', '青花瓷') < 0.5, isTrue);
      expect(similarityOf('', '晴天'), 0);
    });
  });
}
