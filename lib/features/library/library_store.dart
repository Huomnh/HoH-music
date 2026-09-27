/// library_store.dart
///
/// 本地音乐库的**扫描记录**与**启动行为**。
///
/// 做两件事：
/// 1. 记住音乐库里的东西 —— **文件夹**（递归扫描）与**单曲**（单独挑出来的文件），
///    记路径 / 加入时间 / 上次扫到的曲目数；下次启动仍然在，设置页里可查看与移除；
/// 2. 记住"启动后自动播放 / 不播放"，启动时按它决定要不要恢复音乐库。
///
/// 文件夹 / 单曲登记仍存储用 `shared_preferences`（JSON 字符串）；曲目标签
/// 与增量索引由 `LocalScanner` 的 Drift 数据库负责。
///
/// ⚠️ 这里不存曲目标签：登记表只负责记录用户选择的根目录和单曲路径，
/// 避免把“用户配置”和“扫描结果”混在一起；扫描结果见
/// `core/database/app_database.dart`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/audio/player_engine.dart' show Track;
import '../../core/audio/player_providers.dart';
import '../../core/database/app_database.dart';
import '../../core/source/source_host.dart';
import '../../core/source/source_store.dart';
import 'library_pool.dart';
import 'webdav_library.dart';

/// 音乐库里一条记录的类型。
enum LibraryEntryKind {
  /// 文件夹：递归扫描里面的音频。
  folder('文件夹', '递归扫描这个目录'),

  /// 单曲：用户单独挑出来的一个音频文件。
  file('单曲', '单独添加的音频文件');

  const LibraryEntryKind(this.label, this.description);

  /// 界面显示名。
  final String label;

  /// 一句话说明。
  final String description;
}

/// 一条音乐库记录（文件夹或单曲）。
@immutable
class LibraryEntry {
  const LibraryEntry({
    required this.path,
    required this.addedAt,
    this.kind = LibraryEntryKind.folder,
    this.trackCount = 0,
  });

  /// 绝对路径（文件夹或音频文件）。
  final String path;

  /// 加入时间。
  final DateTime addedAt;

  /// 这条是文件夹还是单曲。
  final LibraryEntryKind kind;

  /// 上次扫到的曲目数（0 表示还没扫过 / 没扫到）。
  final int trackCount;

  /// 是否文件夹。
  bool get isFolder => kind == LibraryEntryKind.folder;

  /// 用于界面显示的短名（取路径最后一段，单曲会带上扩展名）。
  String get displayName {
    final List<String> parts = path
        .split(RegExp(r'[\\/]'))
        .where((String s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? path : parts.last;
  }

  /// 这条记录指向的东西是否还在磁盘上。
  bool get exists =>
      isFolder ? Directory(path).existsSync() : File(path).existsSync();

  LibraryEntry copyWith({int? trackCount}) => LibraryEntry(
    path: path,
    addedAt: addedAt,
    kind: kind,
    trackCount: trackCount ?? this.trackCount,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'addedAt': addedAt.toIso8601String(),
    'kind': kind.name,
    'trackCount': trackCount,
  };

  static LibraryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    return LibraryEntry(
      path: path,
      addedAt: DateTime.tryParse('${raw['addedAt']}') ?? DateTime.now(),
      // 老记录没有 kind 字段 → 当作文件夹（0.0.11 及以前只存文件夹）
      kind: raw['kind'] == LibraryEntryKind.file.name
          ? LibraryEntryKind.file
          : LibraryEntryKind.folder,
      trackCount: (raw['trackCount'] is int) ? raw['trackCount'] as int : 0,
    );
  }
}

/// 启动行为。
///
/// 0.0.21：默认值从「什么都不做」改成 **autoLoad**（用户要求「默认一下自动载入」），
/// 于是旧记录里存着的 `idle` 会由 [StartupBehaviorController] 迁移一次。
enum StartupBehavior {
  /// **启动后自动载入**（默认）：把扫描记录扫进队列，但**不自动出声**。
  autoLoad('启动后自动载入', '扫入队列但不播放，界面不会是空的'),

  /// 启动后自动恢复音乐库并开始播放。
  autoPlay('启动后自动播放', '扫描已保存的文件夹并直接开始播放'),

  /// 干净启动，什么都不做（音乐库仍在，可一键载入）。
  idle('启动后不播放', '不自动载入；设置页里可随时「载入音乐库」');

  const StartupBehavior(this.label, this.description);

  /// 界面显示名。
  final String label;

  /// 一句话说明。
  final String description;
}

/// 修掉 file_picker 13 在 Windows 上返回的**百分号编码路径**。
///
/// **根因**（0.0.14 查到的真因）：`FilePicker.pickFileAndDirectoryPaths()` 的
/// Windows 实现返回的是 `Uri.path` 而不是 `Uri.toFilePath()`：
///
/// ```dart
/// // windows_file_picker-2.0.0/lib/src/file_picker_windows.dart
/// return files.map((e) => e.uri.path).toList();   // ← 编码后的 URI 路径
/// ```
///
/// 于是「半句再见 - 孙燕姿.flac」变成
/// 「/E:/music/%E5%8D%8A%E5%8F%A5%E5%86%8D%E8%A7%81%20-%20...flac」——
/// 既多一个前导斜杠、又是百分号编码，于是文件放不出来、坏路径还被记进音乐库。
///
/// 选文件的代码已经改走 `FilePicker.pickFiles()`（`PlatformFile.path` 用的是
/// `toFilePath()`，正确）；这个函数用来把**之前存坏的老记录**修回来。
String repairPickedPath(String raw) {
  final String path = raw.trim();
  if (path.isEmpty || !path.contains('%')) return path;

  String decoded;
  try {
    decoded = Uri.decodeComponent(path);
  } catch (_) {
    // 不是合法的百分号编码（例如文件名里本来就有个 %）→ 原样返回
    return path;
  }

  // Windows 上 Uri.path 会多一个前导斜杠：/E:/music/x.flac
  String fixed = decoded;
  if (fixed.length > 3 && fixed.startsWith('/') && fixed[2] == ':') {
    fixed = fixed.substring(1);
  }
  // URI 路径用正斜杠，统一成 Windows 的反斜杠（文件 API 两种都吃，
  // 但界面里显示成一致的更像原生路径）
  if (Platform.isWindows) {
    fixed = fixed.replaceAll('/', r'\');
  }
  return fixed;
}

/// 音乐库内容（文件夹 + 单曲，异步读盘）。
final libraryProvider =
    AsyncNotifierProvider<LibraryController, List<LibraryEntry>>(
      LibraryController.new,
    );

/// 音乐库控制器。
class LibraryController extends AsyncNotifier<List<LibraryEntry>> {
  static const String _key = 'library.folders';

  @override
  Future<List<LibraryEntry>> build() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const <LibraryEntry>[];

      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <LibraryEntry>[];
      final List<LibraryEntry> entries = decoded
          .map(LibraryEntry.fromJson)
          .whereType<LibraryEntry>()
          .toList();

      final List<LibraryEntry> repaired = _repairLegacyPaths(entries);
      if (!identical(repaired, entries)) {
        // 修好了就顺手写回去，只修这一次
        unawaited(_persist(repaired));
        debugPrint('[Library] 已修正编码路径并写回音乐库记录');
      }
      return repaired;
    } catch (error) {
      debugPrint('[Library] 读取音乐库失败（当作空库）：$error');
      return const <LibraryEntry>[];
    }
  }

  /// 把 0.0.13 及以前存下的**编码路径**修成真实路径。
  ///
  /// 只在「原路径不存在、解码后存在」时才替换 —— 这样文件名里真带 `%`
  /// 而恰好能解码的情况也不会被误改。
  List<LibraryEntry> _repairLegacyPaths(List<LibraryEntry> entries) {
    bool changed = false;
    final List<LibraryEntry> next = entries.map((LibraryEntry e) {
      if (e.exists) return e;
      final String fixed = repairPickedPath(e.path);
      if (fixed == e.path) return e;
      final bool fixedExists = e.isFolder
          ? Directory(fixed).existsSync()
          : File(fixed).existsSync();
      if (!fixedExists) return e;

      changed = true;
      debugPrint('[Library] 路径修复：${e.path} → $fixed');
      return LibraryEntry(
        path: fixed,
        addedAt: e.addedAt,
        kind: e.kind,
        trackCount: e.trackCount,
      );
    }).toList();

    return changed ? next : entries;
  }

  /// 添加（或更新）一个**文件夹**记录。
  ///
  /// [trackCount] 传入本次扫到的曲目数；传 null 表示保留原值。
  Future<void> addFolder(String path, {int? trackCount}) =>
      _upsert(path, LibraryEntryKind.folder, trackCount: trackCount);

  /// 添加（或更新）一个**单曲**记录。
  ///
  /// 「添加单曲」走这里：选中的音频文件会被记进音乐库，
  /// 下次启动仍能在「播放设置」里看到它、并一键载入。
  Future<void> addFile(String path) =>
      _upsert(path, LibraryEntryKind.file, trackCount: 1);

  /// 批量添加单曲。
  Future<void> addFiles(Iterable<String> paths) async {
    for (final String path in paths) {
      await addFile(path);
    }
  }

  Future<void> _upsert(
    String path,
    LibraryEntryKind kind, {
    int? trackCount,
  }) async {
    final List<LibraryEntry> current = state.value ?? const <LibraryEntry>[];
    final int index = current.indexWhere((LibraryEntry e) => e.path == path);

    final List<LibraryEntry> next = List<LibraryEntry>.of(current);
    if (index >= 0) {
      // 同一个路径重复添加：保留原类型（文件夹不会被单曲覆盖），只更新曲目数
      next[index] = trackCount == null
          ? next[index]
          : next[index].copyWith(trackCount: trackCount);
    } else {
      next.add(
        LibraryEntry(
          path: path,
          addedAt: DateTime.now(),
          kind: kind,
          trackCount: trackCount ?? 0,
        ),
      );
    }
    state = AsyncData<List<LibraryEntry>>(next);
    await _persist(next);
  }

  /// 批量更新曲目数（载入音乐库后回写实际扫到的数量）。
  Future<void> updateTrackCounts(Map<String, int> counts) async {
    final List<LibraryEntry> current = state.value ?? const <LibraryEntry>[];
    if (current.isEmpty) return;

    bool changed = false;
    final List<LibraryEntry> next = current.map((LibraryEntry e) {
      final int? count = counts[e.path];
      if (count == null || count == e.trackCount) return e;
      changed = true;
      return e.copyWith(trackCount: count);
    }).toList();

    if (!changed) return;
    state = AsyncData<List<LibraryEntry>>(next);
    await _persist(next);
  }

  /// 移除一条记录（文件夹或单曲）。
  Future<void> remove(String path) async {
    final List<LibraryEntry> current = state.value ?? const <LibraryEntry>[];
    final List<LibraryEntry> next = current
        .where((LibraryEntry e) => e.path != path)
        .toList();
    state = AsyncData<List<LibraryEntry>>(next);
    await _persist(next);
  }

  /// 清空音乐库。
  Future<void> clear() async {
    state = const AsyncData<List<LibraryEntry>>(<LibraryEntry>[]);
    await _persist(const <LibraryEntry>[]);
    await appDatabase.clearLocalTracks();
  }

  Future<void> _persist(List<LibraryEntry> entries) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(entries.map((LibraryEntry e) => e.toJson()).toList()),
      );
    } catch (error) {
      debugPrint('[Library] 保存音乐库失败：$error');
    }
  }
}

/// 用户从「所有歌曲」手动移除的曲目 ID。
///
/// 只隐藏曲库条目，不删除音乐文件；即使它仍位于已登记的文件夹中，
/// 后台增量扫描也不会让它重新出现在列表。此集合与扫描缓存分离，
/// 可用于本地路径和 WebDAV 稳定 ID。
final hiddenLibraryTracksProvider =
    AsyncNotifierProvider<HiddenLibraryTracksController, Set<String>>(
      HiddenLibraryTracksController.new,
    );

class HiddenLibraryTracksController extends AsyncNotifier<Set<String>> {
  static const String _key = 'library.hiddenTrackIds';

  @override
  Future<Set<String>> build() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key)?.toSet() ?? <String>{};
  }

  Future<void> hide(String id) => _change(id, hidden: true);
  Future<void> restore(String id) => _change(id, hidden: false);

  Future<void> clear() async {
    state = const AsyncData<Set<String>>(<String>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  Future<void> _change(String id, {required bool hidden}) async {
    final Set<String> next = Set<String>.of(state.value ?? const <String>{});
    if (hidden) {
      next.add(id);
    } else {
      next.remove(id);
    }
    state = AsyncData<Set<String>>(next);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, next.toList(growable: false));
  }
}

/// 启动行为。
final startupBehaviorProvider =
    AsyncNotifierProvider<StartupBehaviorController, StartupBehavior>(
      StartupBehaviorController.new,
    );

/// 启动行为控制器。
class StartupBehaviorController extends AsyncNotifier<StartupBehavior> {
  static const String _key = 'library.startup';

  /// 0.0.21 的一次性迁移标记。
  ///
  /// 0.0.21 把默认值改成「启动后自动载入」（用户要求「默认一下自动载入」），
  /// 但盘里可能已经存着旧版本留下的 `idle`，新默认值就永远生效不了 ——
  /// 用户会以为"改了默认值却没反应"。所以这里迁移**一次**：
  /// - 老记录是 `autoPlay`（用户明确选过要自动播放）→ 保留；
  /// - 其它（`idle` / 没存过）→ 改成 `autoLoad`。
  ///
  /// 迁移后写标记，以后再改设置不会被覆盖。
  static const String _migratedKey = 'library.startup.migratedAutoLoad';

  @override
  Future<StartupBehavior> build() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? name = prefs.getString(_key);

      final bool needsMigrate =
          prefs.getBool(_migratedKey) != true &&
          name != StartupBehavior.autoPlay.name;
      if (needsMigrate) {
        await prefs.setBool(_migratedKey, true);
        await prefs.setString(_key, StartupBehavior.autoLoad.name);
        debugPrint(
          '[Library] 启动行为迁移到新默认值：'
          '${StartupBehavior.autoLoad.label}（原=$name）',
        );
        return StartupBehavior.autoLoad;
      }

      return StartupBehavior.values.firstWhere(
        (StartupBehavior b) => b.name == name,
        // 默认「启动后自动载入」：用户反馈希望一打开就有内容，
        // 但又不该直接出声（见枚举注释）
        orElse: () => StartupBehavior.autoLoad,
      );
    } catch (error) {
      debugPrint('[Library] 读取启动行为失败（用默认）：$error');
      return StartupBehavior.autoLoad;
    }
  }

  /// 设置启动行为。
  Future<void> setBehavior(StartupBehavior behavior) async {
    state = AsyncData<StartupBehavior>(behavior);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, behavior.name);
    } catch (error) {
      debugPrint('[Library] 保存启动行为失败：$error');
    }
  }
}

/// 按「启动行为」在启动后恢复音乐库。
///
/// 挂在 `MaterialApp` 内层（需要 Riverpod 与 `BuildContext`）。
/// 读盘是异步的，所以等两个 provider 都就绪后再动作；
/// 失败只打日志，绝不让界面起不来。
class LibraryBootstrap extends ConsumerStatefulWidget {
  const LibraryBootstrap({super.key, required this.child});

  /// 被包裹的子树。
  final Widget child;

  @override
  ConsumerState<LibraryBootstrap> createState() => _LibraryBootstrapState();
}

class _LibraryBootstrapState extends ConsumerState<LibraryBootstrap> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_restore()));
  }

  /// 预热曲库池：本地扫描 + WebDAV 自动连接同步（0.0.40）。
  ///
  /// 为什么要单独一个方法：这两步是"库"的事，跟"启动播不播"无关；
  /// 而且它们都是网络/磁盘活，失败必须被吞掉（只打日志）。
  Future<void> _warmPools() async {
    try {
      final List<Track> local = await ref.read(localLibraryProvider.future);
      debugPrint('[Library] 本地曲库扫描完成：${local.length} 首');
    } catch (error) {
      debugPrint('[Library] 本地曲库扫描失败：$error');
    }
    if (!mounted) return;
    try {
      final List<Track> dav = await ref.read(webDavLibraryProvider.future);
      debugPrint(
        '[Library] WebDAV 曲库就绪：${dav.length} 首'
        '（${ref.read(webDavLibraryProvider.notifier).lastMessage}）',
      );
    } catch (error) {
      debugPrint('[Library] WebDAV 曲库同步失败：$error');
    }
  }

  Future<void> _restore() async {
    if (!mounted) return;
    // 提前在首帧之后预热音源。在线搜索页只负责展示，不再承担首次加载脚本的卡顿。
    // 音源扫描是启动初始化的一部分，必须等待完成，避免用户先进入音源页
    // 看到空列表、或在线搜索在脚本尚未登记时直接报“没有可用音源”。
    await _warmSourceHost();
    // 0.0.40：**先让曲库池与网盘库起来**（"和本地音乐同步加载"）。
    //    这两件事跟"启动要不要自动播"无关，所以放在启动行为判断之前，
    //    而且各自失败都只打日志 —— 网盘连不上不能拖累本地曲库。
    unawaited(_warmPools());

    try {
      final StartupBehavior behavior = await ref.read(
        startupBehaviorProvider.future,
      );
      if (!mounted || behavior == StartupBehavior.idle) {
        debugPrint('[Library] 启动行为=${behavior.label}，不自动载入');
        return;
      }

      final List<LibraryEntry> entries = await ref.read(libraryProvider.future);
      final List<LibraryEntry> usable = entries
          .where((LibraryEntry e) => e.exists)
          .toList();
      if (!mounted || usable.isEmpty) {
        debugPrint('[Library] 没有可用的音乐库内容，跳过启动载入');
        return;
      }

      // 文件夹会被递归扫描，单曲直接进队列 —— 引擎两种路径都吃
      final PlayerController controller = ref.read(
        playerControllerProvider.notifier,
      );
      final List<String> paths = usable
          .map((LibraryEntry e) => e.path)
          .toList();
      final bool play = behavior == StartupBehavior.autoPlay;
      final int count = play
          ? await controller.playPaths(paths)
          : await controller.loadPathsOnly(paths);
      final int folderCount = usable
          .where((LibraryEntry e) => e.isFolder)
          .length;
      debugPrint(
        '[Library] ${behavior.label}：$folderCount 个文件夹 + '
        '${usable.length - folderCount} 首单曲 / 共 $count 首'
        '${play ? "（已开始播放）" : "（未播放）"}',
      );
    } catch (error) {
      debugPrint('[Library] 启动恢复音乐库失败：$error');
    }
  }

  Future<void> _warmSourceHost() async {
    if (!mounted) return;
    try {
      // 启动阶段主动扫描程序目录 music音源，音源管理页只读取结果。
      await ref.read(sourceRegistryProvider.future);
      await ref.read(sourceHostProvider.future);
    } catch (_) {
      // 在线搜索页会显示具体音源错误，不阻塞主界面启动。
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
