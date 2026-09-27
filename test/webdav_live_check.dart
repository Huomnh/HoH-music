// 联调脚本（live check）：用项目里的 WebDavClient 连**真实**服务器，
// 验证"连接测试 / 列目录 / 中文路径 / 播放地址"在真实响应上确实能跑。
//
// ⚠️ **凭据不写进仓库**：地址 / 账号 / 密码一律从环境变量读，
//    没设就**跳过**这个用例（所以普通 `flutter test` 永远是绿的）：
//
//   $env:HOH_DAV_URL  = 'https://webdav.123pan.cn/webdav'
//   $env:HOH_DAV_USER = '你的账号'
//   $env:HOH_DAV_PASS = '你的应用密码'
//   flutter test test/webdav_live_check.dart
//
// 为什么放在 test/ 下、且必须用 `flutter test`：
// 纯 `dart run` 跑不了（客户端 import 了 `package:flutter/foundation.dart`，
// 会拉进 dart:ui），Flutter 测试宿主可以。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hoh_music/core/remote/webdav_client.dart';

void main() {
  final String url = Platform.environment['HOH_DAV_URL'] ?? '';
  final String user = Platform.environment['HOH_DAV_USER'] ?? '';
  final String pass = Platform.environment['HOH_DAV_PASS'] ?? '';
  final bool configured = url.isNotEmpty && user.isNotEmpty;

  test('WebDAV 联调：连接测试 + 一级/二级列目录 + 播放地址', () async {
    final WebDavClient client = WebDavClient(
      WebDavConfig(baseUrl: url, username: user, password: pass),
    );

    final ({bool ok, String message}) test = await client.testConnection();
    stdout.writeln('[连接测试] ok=${test.ok}  ${test.message}');
    expect(test.ok, isTrue, reason: test.message);

    final List<WebDavEntry> root = await client.list('');
    stdout.writeln('[根目录] ${root.length} 项');
    for (final WebDavEntry e in root.take(10)) {
      stdout.writeln(
        '   ${e.isDirectory ? '[目录]' : '[文件]'} ${e.name}'
        '  路径=${e.path}  大小=${e.size}  时间=${e.modified}',
      );
    }
    // 条目路径不该带服务器前缀（123 云盘是 /webdav）
    final String basePath = Uri.parse(url).path;
    for (final WebDavEntry e in root) {
      expect(
        e.path.startsWith(basePath),
        isFalse,
        reason: '条目路径不该带服务器前缀：${e.path}',
      );
    }

    // 钻进第一个目录，验证"二级路径 + 中文 + 尾斜杠"也对
    final WebDavEntry firstDir = root.firstWhere(
      (WebDavEntry e) => e.isDirectory,
      orElse: () => const WebDavEntry(name: '', path: '', isDirectory: false),
    );
    if (firstDir.name.isNotEmpty) {
      final List<WebDavEntry> sub = await client.list(firstDir.path);
      stdout.writeln('[${firstDir.name}] ${sub.length} 项');
      for (final WebDavEntry e in sub.take(8)) {
        stdout.writeln('   ${e.isDirectory ? '[目录]' : '[文件]'} ${e.name}');
      }
    }
    // ⚠️ 打印播放地址时**只打路径**，别把账号密码打到日志里
    final String samplePath = root.isEmpty ? '/' : root.first.path;
    stdout.writeln('[播放地址路径] ${Uri.parse(client.streamUrl(samplePath)).path}');

    // ② 找一个音频文件，验证"**流式播放**"这条路真的通：
    //    Range 请求能不能拿到 206（能 range 才能拖动进度条），
    //    以及返回的 content-type。**不下载整个文件**，只要前 64KB。
    final List<WebDavEntry>? audioDir = await _findAudioDir(client, root);
    if (audioDir == null) {
      stdout.writeln('[流式探测] 没找到音频文件，跳过（目录里可能都是视频）');
      return;
    }
    final WebDavEntry audio = audioDir.first;
    final String audioUrl = client.streamUrl(audio.path);
    final HttpClient http = HttpClient();
    try {
      final HttpClientRequest req = await http.getUrl(Uri.parse(audioUrl));
      req.headers.set('Range', 'bytes=0-65535');
      final HttpClientResponse res = await req.close();
      final int bytes = await res.fold<int>(
        0,
        (int a, List<int> b) => a + b.length,
      );
      stdout.writeln('[流式探测] ${audio.name}');
      stdout.writeln(
        '   HTTP ${res.statusCode}（206 = 支持 Range，可拖动进度）'
        '  content-type=${res.headers.contentType}  收到 $bytes 字节',
      );
      expect(res.statusCode, anyOf(200, 206), reason: '拿不到音频数据就没法流式播放');
    } finally {
      http.close(force: true);
    }
  }, skip: configured ? false : '未设置 HOH_DAV_URL / HOH_DAV_USER（凭据不入库）');
}

/// 在（最多两层）目录里找第一个含音频文件的目录。
Future<List<WebDavEntry>?> _findAudioDir(
  WebDavClient client,
  List<WebDavEntry> root,
) async {
  final List<WebDavEntry> audioHere = root
      .where((WebDavEntry e) => !e.isDirectory && e.looksLikeAudio)
      .toList();
  if (audioHere.isNotEmpty) return audioHere;

  final List<WebDavEntry> dirs = root
      .where((WebDavEntry e) => e.isDirectory)
      .toList();
  if (dirs.isEmpty) return null;

  // 音乐目录优先，其次按名字试前两个
  final List<WebDavEntry> ordered = <WebDavEntry>[
    ...dirs.where((WebDavEntry e) => e.name.contains('音乐')),
    ...dirs.where((WebDavEntry e) => !e.name.contains('音乐')).take(2),
  ];
  for (final WebDavEntry dir in ordered) {
    try {
      final List<WebDavEntry> sub = await client.list(dir.path);
      final List<WebDavEntry> audio = sub
          .where((WebDavEntry e) => !e.isDirectory && e.looksLikeAudio)
          .toList();
      if (audio.isNotEmpty) return audio;
      for (final WebDavEntry nested
          in sub.where((WebDavEntry e) => e.isDirectory).take(2)) {
        final List<WebDavEntry> deep = await client.list(nested.path);
        final List<WebDavEntry> deepAudio = deep
            .where((WebDavEntry e) => !e.isDirectory && e.looksLikeAudio)
            .toList();
        if (deepAudio.isNotEmpty) return deepAudio;
      }
    } catch (_) {
      // 单个目录读失败不影响整体探测
    }
  }
  return null;
}
