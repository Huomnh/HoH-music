/// online_selftest.dart
///
/// 「自定义音源」整条链路的**一站式真机自检**（Debug 专用）：
///
/// ```
/// 导入脚本 → 装进沙箱 → 宿主搜索（网易云）→ 音源解析播放地址 → 歌词 → 封面
/// ```
/// 触发（`HOH_ONLINE_SELFTEST=1` 用已有音源；也可以直接给一个脚本目录）：
/// ```powershell
/// $env:HOH_ONLINE_SELFTEST='1'
/// $env:HOH_SOURCE_DIR='D:\my-sources'        # 可选：先把这批脚本导入
/// $env:HOH_ONLINE_KEYWORD='晴天 周杰伦'       # 可选：默认「晴天」
/// & .\build\windows\x64\runner\Debug\hoh_music.exe
/// ```
/// 结论写 `build/online-selftest.log`（同时打 stderr / stdout）。
///
/// 为什么要这么个东西：这条链路上"失败"的方式太多了（沙箱缺 API、音源不支持该平台、
/// 上游接口挂了、非官方接口被限流…），一步一手点根本查不清。一次跑完，
/// **每一步的结论都落盘**，出问题直接看是哪一步断的。
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/player_engine.dart' show Track;
import 'host_search.dart';
import 'lx_sandbox.dart';
import 'source_host.dart';
import 'source_models.dart';
import 'source_store.dart';

File? _logFile;

void _log(String line) {
  final File? file = _logFile;
  if (file != null) {
    try {
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志失败不影响自检
    }
  }
  stderr.writeln(line);
  stdout.writeln(line);
}

/// 是否要跑（只在 Debug 生效，Release 恒为 false）。
bool onlineSelfTestRequested() {
  if (kReleaseLike) return false;
  final String? env = Platform.environment['HOH_ONLINE_SELFTEST'];
  return env != null && env.isNotEmpty && env != '0' && env != 'false';
}

/// Release 判断（用 assert 探测，不依赖 kReleaseMode 的编译期常量）。
bool get kReleaseLike {
  var release = true;
  assert(() {
    release = false;
    return true;
  }());
  return release;
}

/// 跑一遍整链路自检。
Future<void> runOnlineSelfTest() async {
  final String env = Platform.environment['HOH_ONLINE_SELFTEST'] ?? '';
  final String keyword = Platform.environment['HOH_ONLINE_KEYWORD'] ?? '晴天';
  final String sourceDir = Platform.environment['HOH_SOURCE_DIR'] ?? '';

  _logFile = File('build/online-selftest.log');
  try {
    _logFile!.writeAsStringSync('', flush: true);
  } catch (_) {
    _logFile = null;
  }

  _log('==================== 自定义音源链路自检 ====================');
  _log('[自检] 关键词=$keyword  脚本目录=${sourceDir.isEmpty ? '(用已有音源)' : sourceDir}');
  if (env == '1' && sourceDir.isEmpty) {
    _log('[自检] HOH_ONLINE_SELFTEST=1：不导入脚本，直接用登记表里已启用的音源');
  }

  final ProviderContainer container = ProviderContainer();
  try {
    // ① 需要的话先把脚引导进来（给了 HOH_SOURCE_DIR 就导入，
    //    否则直接用登记表里已有的音源）
    if (sourceDir.isNotEmpty) {
      final ImportReport report = await container
          .read(sourceRegistryProvider.notifier)
          .importPaths(<String>[sourceDir]);
      _log('[自检] 导入：${report.summary}');
      if (report.failed.isNotEmpty) {
        _log('[自检] 导入失败：${report.failed.join('；')}');
      }
    }

    final List<MusicSource> registry = await container.read(
      sourceRegistryProvider.future,
    );
    _log(
      '[自检] 登记表里 ${registry.length} 个脚本'
      '（启用 ${registry.where((MusicSource s) => s.enabled).length} 个）',
    );

    // ② 装沙箱
    final SourceHostState host = await container.read(
      sourceHostProvider.future,
    );
    _log('[自检] 沙箱加载完成：可用 ${host.ready.length} 个 / 共 ${host.runtimes.length} 个');
    for (final SourceRuntime runtime in host.runtimes) {
      if (runtime.ok) {
        _log(
          '  ✅ ${runtime.meta.name}：'
          '${runtime.report.sources.map((LxSourceInfo s) => s.key).join(',')}',
        );
      } else {
        _log('  ❌ ${runtime.meta.name}：${runtime.report.summary}');
      }
    }
    _log('[自检] 可用平台：${host.platforms}');
    for (final String platform in host.platforms) {
      _log('  · ${host.describePlatform(platform)}');
    }

    // ③ 各平台搜索（逐平台报告：能不能搜到、第几首、能不能解析地址）
    _log('');
    _log('---- 各平台搜索（关键词：$keyword）----');
    final List<OnlineTrack> resolvedSamples = <OnlineTrack>[];
    for (final String platform in kSearchablePlatforms) {
      final Stopwatch sw = Stopwatch()..start();
      final PlatformSearchResult result = await HostSearch.instance
          .searchPlatform(platform, keyword, limit: 5);
      final String label = platformLabel(platform);
      if (result.tracks.isEmpty) {
        _log(
          '  ❌ $label：搜不到'
          '${result.error.isEmpty ? '（平台没结果）' : '（${result.error}）'}'
          '  ${sw.elapsedMilliseconds}ms',
        );
        continue;
      }
      final OnlineTrack first = result.tracks.first;
      _log(
        '  ✅ $label：${result.tracks.length} 首'
        '${result.total > 0 ? ' / 共 ${result.total} 首' : ''}'
        '  首条=${first.title} - ${first.artist}（${first.id}）'
        '  ${sw.elapsedMilliseconds}ms',
      );

      // 歌词（0.0.52：翻译那一层已删除，这里只报有没有拿到普通歌词）
      final String? lyric = await HostSearch.instance.lyricFor(first);
      _log(
        '      歌词：${(lyric?.length ?? 0) > 0 ? '✅ ${lyric!.length} 字' : '⚠️ 拿不到'}',
      );

      // 封面
      final String? cover = await HostSearch.instance.coverUrlFor(first);
      _log('      封面：${cover == null ? '⚠️ 拿不到' : '✅ $cover'}');

      // 播放地址（只有启用了对应音源才可能成功）
      if (host.platforms.contains(platform)) {
        _log(
          '      送给音源的 musicInfo 字段：'
          '${first.toMusicInfo().keys.join(',')}',
        );
        final SourceResolveResult r = await container
            .read(sourceHostProvider.notifier)
            .resolveMusicUrl(first);
        _log('      播放地址：${r.ok ? '✅ ${r.provider}' : '❌ ${r.error}'}');
        if (r.ok) {
          _log('        ${r.url}');
          resolvedSamples.add(first);
        }
      } else {
        _log('      播放地址：—（没有启用支持「$label」的音源）');
      }
    }

    // ④ 本地 / WebDAV 曲目：用「歌名 + 歌手」匹配平台，拿封面与歌词
    _log('');
    _log('---- 本地曲目刮削（音源平台匹配）----');
    final String matchTitle = Platform.environment['HOH_MATCH_TITLE'] ?? '晴天';
    final String matchArtist =
        Platform.environment['HOH_MATCH_ARTIST'] ?? '周杰伦';
    final Track sample = Track(
      id: r'D:\示例\sample.flac', // 本地路径（不是 `平台:id`，要走匹配）
      uri: r'D:\示例\sample.flac',
      title: matchTitle,
      artist: matchArtist,
      album: '',
    );
    _log('[自检] 样本：$matchTitle - $matchArtist（模拟本地文件）');
    final OnlineTrack? matched = await HostSearch.instance.matchTrack(sample);
    if (matched == null) {
      _log('  ⚠️ 没匹配到（相似度不到门槛）—— 本地曲目就不会挂错封面/歌词');
    } else {
      _log(
        '  ✅ 匹配到：${matched.platform} ${matched.title} - ${matched.artist}'
        '（${matched.id}）',
      );
      if (matched.tags.isNotEmpty) {
        _log('  平台标签：${matched.tags.take(8).join('、')}');
      }
      final String? cover = await HostSearch.instance.coverUrlForTrack(sample);
      _log('  封面：${cover == null ? '⚠️ 拿不到' : '✅ $cover'}');
      final String? lyric = await HostSearch.instance.lyricForTrack(sample);
      _log(
        '  歌词：${(lyric?.length ?? 0) > 0 ? '✅ ${lyric!.length} 字' : '⚠️ 拿不到'}',
      );
    }

    // ⑤ 分页（第二页确实是新的一批）
    _log('');
    _log('---- 分页 ----');
    final PlatformSearchResult page1 = await HostSearch.instance.searchPlatform(
      'wy',
      keyword,
      page: 1,
      limit: 5,
    );
    final PlatformSearchResult page2 = await HostSearch.instance.searchPlatform(
      'wy',
      keyword,
      page: 2,
      limit: 5,
    );
    final Set<String> ids1 = page1.tracks.map((OnlineTrack t) => t.id).toSet();
    final int overlap = page2.tracks
        .where((OnlineTrack t) => ids1.contains(t.id))
        .length;
    _log(
      '  第 1 页 ${page1.tracks.length} 首 / 第 2 页 ${page2.tracks.length} 首，'
      '重复 $overlap 首  ${overlap == 0 && page2.tracks.isNotEmpty ? '✅' : '⚠️'}',
    );
    _log('  还有更多：${page2.hasMore}');

    if (resolvedSamples.isEmpty) {
      _log('');
      _log('[自检] ⚠️ 没有任何平台解析出播放地址（可能都没启用对应音源）');
    }

    _log('[自检] 日志：build/online-selftest.log');
    _log('==================== 自检结束 ====================');
  } catch (error, stack) {
    _log('[自检] ❌ 异常：$error');
    _log('$stack');
  } finally {
    container.dispose();
    HostSearch.instance.dispose();
  }
}
