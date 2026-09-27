/// source_store.dart
///
/// 音源脚本的**登记表**与**在线曲目收藏**（都落 `shared_preferences`）。
///
/// 设计取舍：
/// - 脚本**正文落盘**在 `<应用支持目录>/sources/<id>.js`，prefs 只存登记信息 ——
///   一个音源脚本可能有 150KB，塞进 prefs 会把设置文件撑爆，而且用户挪走原文件
///   之后我们还得能用（所以导入时就复制一份）。
/// - id = `来源|位置|名字` 的 sha1 前 12 位：同一个文件重复导入不会产生重复项。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lx_sandbox.dart';
import 'source_models.dart';

const String _registryKey = 'sources.registry';
const String _onlineKey = 'library.online';

/// 一次导入的结果。
class ImportReport {
  /// 创建结果。
  const ImportReport({
    this.added = const <String>[],
    this.skipped = const <String>[],
    this.failed = const <String>[],
  });

  /// 新增成功的脚本名。
  final List<String> added;

  /// 已存在（同一个来源重复导入）而跳过的。
  final List<String> skipped;

  /// 失败的原因（`文件名：原因`）。
  final List<String> failed;

  /// 一眼可读的摘要。
  String get summary {
    final List<String> parts = <String>[];
    if (added.isNotEmpty) parts.add('新增 ${added.length} 个');
    if (skipped.isNotEmpty) parts.add('已存在跳过 ${skipped.length} 个');
    if (failed.isNotEmpty) parts.add('失败 ${failed.length} 个');
    return parts.isEmpty ? '什么都没导入' : parts.join('，');
  }
}

/// 脚本落盘目录：`<应用支持目录>/sources`。
Future<Directory> sourcesDirectory() async {
  final Directory base = await getApplicationSupportDirectory();
  final Directory dir = Directory(
    '${base.path}${Platform.pathSeparator}sources',
  );
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// 由「来源 + 位置 + 名字」算出稳定 id（前 12 位 sha1）。
String sourceIdFor({
  required String origin,
  required String location,
  required String name,
}) => sha1
    .convert(utf8.encode('$origin|$location|$name'))
    .toString()
    .substring(0, 12);

/// 已导入音源脚本的登记表。
final sourceRegistryProvider =
    AsyncNotifierProvider<SourceRegistryController, List<MusicSource>>(
      SourceRegistryController.new,
    );

/// 登记表控制器。
class SourceRegistryController extends AsyncNotifier<List<MusicSource>> {
  @override
  Future<List<MusicSource>> build() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<MusicSource> list = MusicSource.decodeRegistry(
      prefs.getString(_registryKey),
    );
    final List<MusicSource> next = List<MusicSource>.of(list);
    bool changed = false;

    // 清理 0.1.0 beta 之前从 Flutter assets 自动登记的旧内置音源。
    // 新版本的默认来源只允许来自程序目录下的 music音源 文件夹。
    final List<MusicSource> legacyBuiltin = next
        .where(
          (MusicSource source) =>
              source.origin == SourceOrigin.builtin ||
              source.location.replaceAll('\\', '/').contains('assets/sources'),
        )
        .toList(growable: false);
    if (legacyBuiltin.isNotEmpty) {
      next.removeWhere(
        (MusicSource source) =>
            source.origin == SourceOrigin.builtin ||
            source.location.replaceAll('\\', '/').contains('assets/sources'),
      );
      changed = true;
      for (final MusicSource source in legacyBuiltin) {
        final File file = await scriptFile(source.id);
        if (file.existsSync()) await file.delete();
      }
    }

    // 安装器把 music音源 与 hoh_music.exe 放在同一目录；开发运行时则
    // 回退到当前工作区的 music音源，保证 Debug/Release 逻辑一致。
    final List<File> bundledFiles = await _bundledSourceFiles();
    if (bundledFiles.isNotEmpty) {
      final List<File> files = bundledFiles;
      bool hasEnabled = next.any((MusicSource source) => source.enabled);
      for (final File file in files) {
        try {
          final String code = LxSandbox.decodeScriptBytes(
            file.readAsBytesSync(),
          );
          if (code.trim().isEmpty) continue;
          final ({String name, String version, String author}) meta =
              MusicSource.parseScriptHeader(code);
          final String fallback = file.uri.pathSegments.last.replaceAll(
            '.js',
            '',
          );
          final String name = meta.name.isNotEmpty ? meta.name : fallback;
          final String stableLocation = 'music音源/${file.uri.pathSegments.last}';
          final String id = sourceIdFor(
            origin: SourceOrigin.bundled.name,
            location: stableLocation,
            name: name,
          );
          final int existingIndex = next.indexWhere(
            (MusicSource source) => source.id == id,
          );
          final MusicSource source = MusicSource(
            id: id,
            name: name,
            origin: SourceOrigin.bundled,
            location: stableLocation,
            enabled: existingIndex >= 0
                ? next[existingIndex].enabled
                : !hasEnabled,
            version: meta.version,
            author: meta.author,
          );
          await _writeScript(id, code);
          if (existingIndex >= 0) {
            next[existingIndex] = source;
          } else {
            next.add(source);
            hasEnabled = true;
          }
          changed = true;
        } catch (_) {
          // 一个默认脚本损坏时跳过它，不阻塞程序和其他来源启动。
        }
      }
    }

    // HoH music 只保留一个“当前音源”。旧版本允许多个脚本同时启用，
    // 会造成启动时重复初始化、播放时多个接口互相抢地址；升级时保留
    // 列表中第一个已启用项作为当前音源，其余自动改为停用。
    bool selected = false;
    for (int i = 0; i < next.length; i++) {
      final MusicSource source = next[i];
      if (!source.enabled) continue;
      if (!selected) {
        selected = true;
        continue;
      }
      next[i] = source.copyWith(enabled: false);
      changed = true;
    }
    if (changed) {
      await prefs.setString(_registryKey, MusicSource.encodeRegistry(next));
    }
    return next;
  }

  /// 查找并合并所有可能的内置音源目录。
  ///
  /// 不能在第一个“存在但为空”的目录处返回：安装器可能先创建了空的
  /// `music音源`，而开发运行时真正的脚本仍在当前工程目录中。
  Future<List<File>> _bundledSourceFiles() async {
    final List<Directory> candidates = <Directory>[
      Directory(
        '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}music音源',
      ),
      Directory('${Directory.current.path}${Platform.pathSeparator}music音源'),
    ];
    final Set<String> seen = <String>{};
    final List<File> result = <File>[];
    for (final Directory candidate in candidates) {
      if (!candidate.existsSync()) continue;
      for (final File file
          in candidate
              .listSync(recursive: true)
              .whereType<File>()
              .where((File file) => file.path.toLowerCase().endsWith('.js'))) {
        final String key = file.absolute.path.toLowerCase();
        if (seen.add(key)) result.add(file);
      }
    }
    return result;
  }

  List<MusicSource> get _current => state.value ?? const <MusicSource>[];

  Future<void> _commit(List<MusicSource> list) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_registryKey, MusicSource.encodeRegistry(list));
    state = AsyncData<List<MusicSource>>(list);
  }

  /// 脚本文件路径（不管存不存在）。
  Future<File> scriptFile(String id) async {
    final Directory dir = await sourcesDirectory();
    return File('${dir.path}${Platform.pathSeparator}$id.js');
  }

  /// 读脚本正文（供沙箱加载）。
  Future<String?> readCode(String id) async {
    final File file = await scriptFile(id);
    if (!file.existsSync()) return null;
    try {
      return LxSandbox.decodeScriptBytes(file.readAsBytesSync());
    } catch (error) {
      return null;
    }
  }

  /// 导入本地文件 / 目录（目录会递归找 `.js`）。
  Future<ImportReport> importPaths(List<String> paths) async {
    final List<String> added = <String>[];
    final List<String> skipped = <String>[];
    final List<String> failed = <String>[];

    final List<File> files = <File>[];
    for (final String path in paths) {
      final FileSystemEntityType type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        files.addAll(
          Directory(path)
              .listSync(recursive: true)
              .whereType<File>()
              .where((File f) => f.path.toLowerCase().endsWith('.js')),
        );
      } else if (type == FileSystemEntityType.file) {
        files.add(File(path));
      } else {
        failed.add('$path：路径不存在');
      }
    }

    final List<MusicSource> list = List<MusicSource>.of(_current);
    for (final File file in files) {
      try {
        final List<int> bytes = file.readAsBytesSync();
        final String code = LxSandbox.decodeScriptBytes(bytes);
        if (code.trim().isEmpty) {
          failed.add('${_baseName(file.path)}：文件是空的');
          continue;
        }
        final String fileName = _baseName(file.path);
        final ({String name, String version, String author}) meta =
            MusicSource.parseScriptHeader(code);
        final String name = meta.name.isNotEmpty
            ? meta.name
            : fileName.replaceAll('.js', '');
        final String id = sourceIdFor(
          origin: SourceOrigin.file.name,
          location: file.path,
          name: name,
        );
        if (list.any((MusicSource s) => s.id == id)) {
          skipped.add(name);
          continue;
        }
        await _writeScript(id, code);
        list.add(
          MusicSource(
            id: id,
            name: name,
            origin: SourceOrigin.file,
            location: file.path,
            enabled: !list.any((MusicSource s) => s.enabled),
            version: meta.version,
            author: meta.author,
          ),
        );
        added.add(name);
      } catch (error) {
        failed.add('${_baseName(file.path)}：$error');
      }
    }

    if (added.isNotEmpty) await _commit(list);
    return ImportReport(added: added, skipped: skipped, failed: failed);
  }

  /// 从 URL 导入一个脚本。
  Future<ImportReport> importUrl(String url) async {
    final String trimmed = url.trim();
    if (trimmed.isEmpty) {
      return const ImportReport(failed: <String>['URL 是空的']);
    }
    final Dio dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        headers: <String, String>{
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) HoH-music',
        },
      ),
    );
    try {
      final Response<List<int>> res = await dio.get<List<int>>(
        trimmed,
        options: Options(responseType: ResponseType.bytes),
      );
      final List<int> bytes = res.data ?? <int>[];
      final String code = LxSandbox.decodeScriptBytes(bytes);
      if (code.trim().isEmpty) {
        return const ImportReport(failed: <String>['下载到的内容是空的']);
      }
      final ({String name, String version, String author}) meta =
          MusicSource.parseScriptHeader(code);
      final String name = meta.name.isNotEmpty
          ? meta.name
          : Uri.parse(trimmed).pathSegments.last.replaceAll('.js', '');
      final String id = sourceIdFor(
        origin: SourceOrigin.url.name,
        location: trimmed,
        name: name,
      );
      if (_current.any((MusicSource s) => s.id == id)) {
        return ImportReport(skipped: <String>[name]);
      }
      await _writeScript(id, code);
      await _commit(<MusicSource>[
        ..._current,
        MusicSource(
          id: id,
          name: name,
          origin: SourceOrigin.url,
          location: trimmed,
          enabled: !_current.any((MusicSource s) => s.enabled),
          version: meta.version,
          author: meta.author,
        ),
      ]);
      return ImportReport(added: <String>[name]);
    } catch (error) {
      return ImportReport(failed: <String>['$trimmed：$error']);
    } finally {
      dio.close(force: true);
    }
  }

  /// 启用 / 停用（停用的脚本不会被加载进沙箱）。
  Future<void> setEnabled(String id, bool enabled) async {
    // 启用即切换当前音源；同一时间只允许一个脚本处于启用状态。
    await _commit(<MusicSource>[
      for (final MusicSource s in _current)
        s.copyWith(enabled: enabled && s.id == id),
    ]);
  }

  /// 删除（同时删掉落盘的脚本副本）。
  Future<void> remove(String id) async {
    await _commit(
      _current.where((MusicSource s) => s.id != id).toList(growable: false),
    );
    try {
      final File file = await scriptFile(id);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 文件删不掉不影响登记表（下次导入会覆盖）
    }
  }

  /// 把沙箱加载结果写回登记表（平台 / 动作 / 失败原因），界面据此展示。
  Future<void> applyReports(Map<String, LxScriptReport> reports) async {
    if (reports.isEmpty) return;
    bool changed = false;
    final List<MusicSource> next = <MusicSource>[];
    for (final MusicSource s in _current) {
      final LxScriptReport? report = reports[s.id];
      if (report == null) {
        next.add(s);
        continue;
      }
      final List<String> platforms = report.sources
          .map((LxSourceInfo i) => i.key)
          .where((String k) => k.isNotEmpty)
          .toSet()
          .toList();
      final List<String> actions = report.sources
          .expand((LxSourceInfo i) => i.actions)
          .toSet()
          .toList();
      final List<String> qualitys = report.sources
          .expand((LxSourceInfo i) => i.qualitys)
          .map(commonQualityOf)
          .whereType<String>()
          .toSet()
          .toList();
      final String error = report.ok ? '' : report.summary;
      if (_sameList(platforms, s.platforms) &&
          _sameList(actions, s.actions) &&
          _sameList(qualitys, s.qualitys) &&
          error == s.error) {
        next.add(s);
        continue;
      }
      changed = true;
      next.add(
        s.copyWith(
          platforms: platforms,
          actions: actions,
          qualitys: qualitys,
          error: error,
        ),
      );
    }
    if (changed) await _commit(next);
  }

  Future<void> _writeScript(String id, String code) async {
    final File file = await scriptFile(id);
    file.writeAsStringSync(code, flush: true);
  }

  static String _baseName(String path) =>
      path.split(Platform.pathSeparator).last;

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ════════════════════════════════════════════════════════════════
//  刮削开关（本地 / WebDAV 曲目要不要用音源平台刮封面与歌词）
// ════════════════════════════════════════════════════════════════

const String _scrapeKey = 'sources.scrapeLocal';

/// 是否用音源平台给**本地 / WebDAV** 曲目刮封面与歌词（默认**开**）。
///
/// 打开后：本地曲目没有内嵌封面 / 歌词时，会用「歌名 + 歌手」在平台上
/// 搜一首最像的（相似度门槛见 `HostSearch.matchTrack`），再取它的封面和歌词。
/// 关掉就只读取内嵌封面；歌词仍按本地文件与音源设置处理。
final sourceScrapeProvider =
    AsyncNotifierProvider<SourceScrapeController, bool>(
      SourceScrapeController.new,
    );

/// 刮削开关控制器。
class SourceScrapeController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_scrapeKey) ?? true;
  }

  /// 设置开关。
  Future<void> setEnabled(bool enabled) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_scrapeKey, enabled);
    state = AsyncData<bool>(enabled);
  }
}

// ════════════════════════════════════════════════════════════════
//  在线曲目收藏（点过 / 收藏过的在线曲目，用来离线记住"歌是谁"）
// ════════════════════════════════════════════════════════════════

/// 在线曲目信息表（`平台:歌曲id` → 曲目信息）。
///
/// 为什么需要它：在线曲目**只有 id 和播放地址**，播放地址会过期，
/// 但"这首是什么歌"要能长久记住 —— 这样「我的喜欢」里点了在线收藏，
/// 还能重新解析一次地址再播。
final onlineLibraryProvider =
    AsyncNotifierProvider<OnlineLibraryController, List<OnlineTrack>>(
      OnlineLibraryController.new,
    );

/// 在线曲目信息表控制器。
class OnlineLibraryController extends AsyncNotifier<List<OnlineTrack>> {
  @override
  Future<List<OnlineTrack>> build() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return OnlineTrack.decodeList(prefs.getString(_onlineKey));
  }

  List<OnlineTrack> get _current => state.value ?? const <OnlineTrack>[];

  Future<void> _commit(List<OnlineTrack> list) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_onlineKey, OnlineTrack.encodeList(list));
    state = AsyncData<List<OnlineTrack>>(list);
  }

  /// 记住一批曲目（同 id 覆盖旧信息）。
  Future<void> remember(Iterable<OnlineTrack> tracks) async {
    if (tracks.isEmpty) return;
    final Map<String, OnlineTrack> merged = <String, OnlineTrack>{
      for (final OnlineTrack t in _current) t.id: t,
    };
    for (final OnlineTrack t in tracks) {
      merged[t.id] = t;
    }
    await _commit(merged.values.toList(growable: false));
  }

  /// 忘掉一首。
  Future<void> forget(String id) async {
    await _commit(
      _current.where((OnlineTrack t) => t.id != id).toList(growable: false),
    );
  }

  /// 清空。
  Future<void> clear() async => _commit(const <OnlineTrack>[]);
}
