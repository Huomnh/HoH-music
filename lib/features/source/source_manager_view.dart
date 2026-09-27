/// source_manager_view.dart
///
/// 「来源 → 音源管理」页面（0.0.38）。
///
/// 这一页回答三个问题：
///   1. 我导入了哪些音源脚本？（导入文件 / 文件夹 / URL）
///   2. 它们到底能不能用？（每个脚本声明的平台 / 动作 / 失败原因，来自真机沙箱加载）
///
/// ⚠️ 页面上必须写清楚：音源脚本是**第三方**的、走的是**非官方接口**，
/// 只做只读解析；脚本在 QuickJS 沙箱里跑，只给网络能力，不给文件系统。
library;

import 'dart:io' show Platform, stderr;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/lx_sandbox.dart';
import '../../core/source/source_cache.dart';
import '../../core/audio/player_engine.dart'
    show Track, kSupportedAudioExtensions, scanAudioFilesAsync;
import '../../core/audio/player_providers.dart';
import '../library/library_store.dart';
import '../library/library_pool.dart';
import '../../core/remote/webdav_sources.dart';
import '../../core/source/source_host.dart';
import '../../core/source/source_models.dart';
import '../../core/source/source_store.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';
import '../library/webdav_library.dart';
import 'source_widgets.dart';

/// 音源管理面板。
///
/// 0.0.46：既能在「来源 → 音源管理」单独成页，也能**嵌进「播放设置」**
/// （用户要求把音源管理、刮削来源、缓存合并到播放设置里）。
/// [embedded] = true 时不套外层 `GlassPanel`（设置页自带容器）。
class SourceManagerPanel extends ConsumerStatefulWidget {
  /// 创建面板。
  const SourceManagerPanel({super.key, this.embedded = false});

  /// 是否嵌在别的页面里。
  final bool embedded;

  @override
  ConsumerState<SourceManagerPanel> createState() => _SourceManagerViewState();
}

/// 「来源 → 音源管理」页面（单独成页时用）。
class SourceManagerView extends StatelessWidget {
  /// 创建页面。
  const SourceManagerView({super.key});

  @override
  Widget build(BuildContext context) => const SourceManagerPanel();
}

class _SourceManagerViewState extends ConsumerState<SourceManagerPanel> {
  bool _busy = false;
  String? _status;
  bool _statusOk = false;

  @override
  void initState() {
    super.initState();
    _maybeAutoImportForDebug();
  }

  /// 调试自检（仅 Debug + `HOH_SOURCE_IMPORT=<目录>`）：
  /// 启动时自动导入一个目录，方便截图 / 无人值守验证，不用手点。
  void _maybeAutoImportForDebug() {
    if (kReleaseMode) return;
    final String? dir = Platform.environment['HOH_SOURCE_IMPORT'];
    if (dir == null || dir.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      stderr.writeln('[音源管理自检] 自动导入：$dir');
      final ImportReport report = await ref
          .read(sourceRegistryProvider.notifier)
          .importPaths(<String>[dir]);
      stderr.writeln('[音源管理自检] ${report.summary}');
      if (report.failed.isNotEmpty) {
        stderr.writeln('[音源管理自检] 失败：${report.failed.join('；')}');
      }
      await _reload(silent: true);
      final SourceHostState? host = ref.read(sourceHostProvider).value;
      stderr.writeln(
        '[音源管理自检] 可用平台：'
        '${host?.platforms ?? const <String>[]}',
      );
    });
  }

  Future<void> _importFiles() async {
    // ⚠️ file_picker 13.x 的 API 变了：`FilePicker.pickFiles()` 是**静态方法**，
    //    直接返回 `List<PlatformFile>`（没有 FilePickerResult / allowMultiple 了）。
    final List<PlatformFile> picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['js'],
      dialogTitle: '选择音源脚本（LX 格式 .js）',
    );
    final List<String> paths = <String>[
      for (final PlatformFile f in picked)
        if (f.path != null) f.path!,
    ];
    if (paths.isEmpty) return;
    await _runImport(
      () => ref.read(sourceRegistryProvider.notifier).importPaths(paths),
    );
  }

  Future<void> _importFolder() async {
    final String? dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择音源脚本所在文件夹',
    );
    if (dir == null || dir.isEmpty) return;
    await _runImport(
      () =>
          ref.read(sourceRegistryProvider.notifier).importPaths(<String>[dir]),
    );
  }

  Future<void> _importUrl() async {
    final TextEditingController controller = TextEditingController();
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xF21A1A22),
        title: const Text(
          '从 URL 导入音源脚本',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: SizedBox(
          width: 420,
          child: SourceField(
            controller: controller,
            label: '脚本地址（.js）',
            hint: 'https://example.com/my-source.js',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.trim().isEmpty) return;
    await _runImport(
      () => ref.read(sourceRegistryProvider.notifier).importUrl(url),
    );
  }

  Future<void> _runImport(Future<ImportReport> Function() action) async {
    setState(() {
      _busy = true;
      _status = '正在导入…';
      _statusOk = true;
    });
    try {
      final ImportReport report = await action();
      final List<String> lines = <String>[report.summary];
      if (report.failed.isNotEmpty) lines.add('失败：${report.failed.join('；')}');
      setState(() {
        _status = lines.join('\n');
        _statusOk = report.added.isNotEmpty;
      });
      if (report.added.isNotEmpty) await _reload(silent: true);
    } catch (error) {
      setState(() {
        _status = '导入出错：$error';
        _statusOk = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _busy = true;
        _status = '正在把脚本装进沙箱…（有的脚本初始化要联网，最多等 6 秒/个）';
        _statusOk = true;
      });
    }
    try {
      await ref.read(sourceHostProvider.notifier).reload();
      // 把加载结果写回登记表：平台 / 动作 / 失败原因，下次进页面就能直接看到。
      await ref
          .read(sourceRegistryProvider.notifier)
          .applyReports(ref.read(sourceHostProvider.notifier).reports);
      final SourceHostState host =
          ref.read(sourceHostProvider).value ?? const SourceHostState();
      if (!silent) {
        setState(() {
          _statusOk = !host.isEmpty;
          _status = host.isEmpty
              ? '没有可用音源。检查脚本是否有报错（每行下面写了原因），或者先启用它。'
              : '已就绪：${host.ready.length} 个脚本可用，'
                    '平台 ${host.platforms.map(platformLabel).join('、')}';
        });
      }
    } catch (error) {
      if (!silent) {
        setState(() {
          _status = '加载失败：$error';
          _statusOk = false;
        });
      }
    } finally {
      if (mounted && !silent) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final List<MusicSource> sources =
        ref.watch(sourceRegistryProvider).value ?? const <MusicSource>[];
    final AsyncValue<SourceHostState> hostAsync = ref.watch(sourceHostProvider);
    final SourceHostState host = hostAsync.value ?? const SourceHostState();

    // 登记表里的 id → 运行时（拿平台 / 失败原因）
    final Map<String, SourceRuntime> byId = <String, SourceRuntime>{
      for (final SourceRuntime r in host.runtimes) r.meta.id: r,
    };

    // 面板内容（嵌进设置页时直接用它，不套 GlassPanel）
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // ── 音乐库（0.0.56：用户要求放到**这一页最上面**）──────────────
        const LibraryPanel(),
        const SizedBox(height: 10),
        const Divider(color: AppColors.divider, height: 1),
        const SizedBox(height: 10),

        // 单独成页时才有大标题；嵌进设置页时由设置页的分组标题接管
        if (!widget.embedded) ...<Widget>[
          const SourceSectionLabel('SOURCES'),
          const SizedBox(height: 8),
        ],
        const Text(
          '导入 lx-music 格式的音源脚本（.js），就能搜歌并直接在线播放。'
          '脚本在应用内沙箱（QuickJS）里运行：只给网络能力、不给文件系统。',
          style: TextStyle(
            color: AppColors.textTertiary,
            fontSize: 11.5,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '⚠️ 音源脚本来自第三方，用的是各平台的「非官方接口」；'
          '可用性与合规性请自行判断。本项目只做解析和播放，不要求音源脚本登录。',
          style: TextStyle(color: Color(0xCCFFB4D5), fontSize: 11, height: 1.5),
        ),
        const SizedBox(height: 6),
        const Text(
          '当前只使用一个音源。打开某一行的开关即可切换，其他音源会自动停用。',
          style: TextStyle(color: AppColors.textTertiary, fontSize: 11),
        ),
        const SizedBox(height: 14),

        // ── 操作行 ────────────────────────────────────────────
        Row(
          children: <Widget>[
            FilledButton.icon(
              onPressed: _busy ? null : _importFiles,
              icon: const Icon(Icons.file_open_outlined, size: 16),
              label: const Text('导入脚本文件'),
              style: FilledButton.styleFrom(
                backgroundColor: accent.primary.withValues(alpha: 0.85),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _busy ? null : _importFolder,
              icon: const Icon(Icons.folder_open_outlined, size: 16),
              label: const Text('导入文件夹'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      await ref.read(onlineLibraryProvider.notifier).clear();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已清空在线播放历史记录')),
                      );
                    },
              icon: const Icon(Icons.history_toggle_off_rounded, size: 15),
              label: const Text('清空在线播放记录'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _importUrl,
              icon: const Icon(Icons.link_rounded, size: 16),
              label: const Text('从 URL 导入'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _busy ? null : () => _reload(),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('重新加载'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
          ],
        ),

        if (_status != null) ...<Widget>[
          const SizedBox(height: 10),
          SourceStatusLine(text: _status!, ok: _statusOk, busy: _busy),
        ],
        if (hostAsync.isLoading && _status == null) ...<Widget>[
          const SizedBox(height: 10),
          const SourceStatusLine(text: '正在加载音源…', ok: true, busy: true),
        ],
        const SizedBox(height: 14),
        const Divider(color: AppColors.divider, height: 1),
        const SizedBox(height: 10),

        // ── 刮削开关（本地 / WebDAV 曲目也用音源平台）────────────
        const _ScrapeSwitch(),

        const SizedBox(height: 8),
        const Divider(color: AppColors.divider, height: 1),
        const SizedBox(height: 10),

        // ── 缓存（0.0.44）：歌词 / 刮削匹配 / 封面地址 ─────────────
        _CachePanel(),

        const SizedBox(height: 8),
        const Divider(color: AppColors.divider, height: 1),
        const SizedBox(height: 8),

        // ── 列表 ─────────────────────────────────────────────
        //
        // ⚠️ 嵌进「播放设置」时**不能**用 `Expanded`：设置页外层是
        //    `SingleChildScrollView`，高度无界 → `RenderFlex children have
        //    non-zero flex but incoming height constraints are unbounded`。
        //    所以嵌入模式给一个最大高度。
        if (widget.embedded)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: _SourceList(
              sources: sources,
              byId: byId,
              onToggle: (MusicSource source, bool value) async {
                await ref
                    .read(sourceRegistryProvider.notifier)
                    .setEnabled(source.id, value);
                await _reload(silent: true);
              },
              onDelete: (MusicSource source) async {
                await ref
                    .read(sourceRegistryProvider.notifier)
                    .remove(source.id);
                setState(() {
                  _status = '已删除「${source.name}」';
                  _statusOk = true;
                });
              },
            ),
          )
        else
          Expanded(
            child: _SourceList(
              sources: sources,
              byId: byId,
              onToggle: (MusicSource source, bool value) async {
                await ref
                    .read(sourceRegistryProvider.notifier)
                    .setEnabled(source.id, value);
                await _reload(silent: true);
              },
              onDelete: (MusicSource source) async {
                await ref
                    .read(sourceRegistryProvider.notifier)
                    .remove(source.id);
                setState(() {
                  _status = '已删除「${source.name}」';
                  _statusOk = true;
                });
              },
            ),
          ),
      ],
    );

    // 嵌进设置页 → 直接给内容；单独成页 → 套一层玻璃面板
    if (widget.embedded) return content;
    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
      initialSweepPhase: 0.5,
      child: content,
    );
  }
}

/// 刮削开关：本地 / WebDAV 曲目要不要用音源平台刮封面和歌词。
class _ScrapeSwitch extends ConsumerWidget {
  const _ScrapeSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool enabled = ref.watch(sourceScrapeProvider).value ?? false;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '本地 / WebDAV 曲目也用音源平台刮封面与歌词',
                style: TextStyle(color: Colors.white, fontSize: 12.5),
              ),
              const SizedBox(height: 3),
              Text(
                enabled
                    ? '打开后：本地曲目没有内嵌封面 / 歌词时，会用「歌名 + 歌手」'
                          '在已导入音源中匹配一首最像的（相似度门槛 0.72），再取它的封面和歌词。'
                    : '关闭时：封面只看内嵌（没有就不联网刮削），'
                          '歌词只看内嵌 / 同目录 .lrc。',
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 3),
              const Text(
                '标签说明：音源只用于歌词、封面和在线播放匹配，不会修改本地音频文件。',
                style: TextStyle(
                  color: Color(0x99FFFFFF),
                  fontSize: 10.5,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Switch(
          value: enabled,
          onChanged: (bool value) =>
              ref.read(sourceScrapeProvider.notifier).setEnabled(value),
          activeThumbColor: AppAccent.of(context).primary,
        ),
      ],
    );
  }
}

/// **音乐库登记面板**（0.0.55）：从「播放设置」搬到这里（用户要求：来源下统一）。
///
/// 自包含：自己弹文件选择器、自己写 `libraryProvider`，不依赖播放设置页的 State。
class LibraryPanel extends ConsumerStatefulWidget {
  /// 创建面板。
  const LibraryPanel({super.key});

  @override
  ConsumerState<LibraryPanel> createState() => _LibraryPanelState();
}

class _LibraryPanelState extends ConsumerState<LibraryPanel> {
  bool _busy = false;

  Future<void> _addFolder() async {
    final String? dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择音乐文件夹',
    );
    if (dir == null || dir.isEmpty) return;
    setState(() => _busy = true);
    try {
      final int count = (await scanAudioFilesAsync(dir)).length;
      await ref
          .read(libraryProvider.notifier)
          .addFolder(dir, trackCount: count);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addTracks() async {
    final List<PlatformFile> picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: kSupportedAudioExtensions.toList(),
      dialogTitle: '选择音乐文件（可多选）',
    );
    final List<String> paths = <String>[
      for (final PlatformFile f in picked)
        if (f.path != null) f.path!,
    ];
    if (paths.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(libraryProvider.notifier).addFiles(paths);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 载入音乐库（只入队列不播放；和启动时的"自动载入"同一套）。
  Future<void> _load() async {
    final List<LibraryEntry> entries =
        ref.read(libraryProvider).value ?? const <LibraryEntry>[];
    final List<String> paths = <String>[
      for (final LibraryEntry e in entries)
        if (e.exists) e.path,
    ];
    if (paths.isEmpty) return;
    setState(() => _busy = true);
    try {
      final int count = await ref
          .read(playerControllerProvider.notifier)
          .loadPathsOnly(paths);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已载入 $count 首到播放队列'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final AsyncValue<List<LibraryEntry>> library = ref.watch(libraryProvider);
    final List<LibraryEntry> entries = library.value ?? const <LibraryEntry>[];
    final int folderCount = entries
        .where((LibraryEntry e) => e.isFolder)
        .length;
    final int fileCount = entries.length - folderCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          entries.isEmpty
              ? '音乐库：还没有添加（本地文件夹 / 单曲都加到这里）'
              : '音乐库：$folderCount 个文件夹 · $fileCount 首单曲',
          style: const TextStyle(color: Colors.white, fontSize: 12.5),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _busy ? null : _addFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 15),
              label: const Text('添加文件夹'),
              style: FilledButton.styleFrom(
                backgroundColor: accent.primary.withValues(alpha: 0.85),
                foregroundColor: Colors.white,
              ),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _addTracks,
              icon: const Icon(Icons.library_add_outlined, size: 15),
              label: const Text('添加单曲'),
              style: FilledButton.styleFrom(
                backgroundColor: accent.primary.withValues(alpha: 0.55),
                foregroundColor: Colors.white,
              ),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.playlist_play_rounded, size: 15),
              label: const Text('载入音乐库'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () async {
                      await ref.read(libraryProvider.notifier).clear();
                      await ref
                          .read(hiddenLibraryTracksProvider.notifier)
                          .clear();
                      ref.invalidate(localLibraryProvider);
                      ref.invalidate(libraryPoolProvider);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已清空本地曲库记录和索引，音乐文件未删除')),
                      );
                    },
              icon: const Icon(Icons.clear_all_rounded, size: 15),
              label: const Text('清空本地索引'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final LibraryEntry entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: <Widget>[
                Icon(
                  entry.isFolder
                      ? Icons.folder_outlined
                      : Icons.audiotrack_outlined,
                  size: 15,
                  color: entry.exists ? accent.primary : AppColors.neonMagenta,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${entry.path}'
                    '${entry.trackCount > 0 ? '（${entry.trackCount} 首）' : ''}'
                    '${entry.exists ? '' : '（路径不存在）'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xD9FFFFFF),
                      fontSize: 11,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '从音乐库移除',
                  onPressed: () =>
                      ref.read(libraryProvider.notifier).remove(entry.path),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 15,
                    color: Color(0x99FFFFFF),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// WebDAV 源列表（0.0.53，0.0.54 起**只放在「来源 → WebDAV」页**）。
///
/// 用户要求：来源下的 WebDAV、设置里的网盘内容**合并到一处**（来源下）、
/// **不做下拉，所有连接直接列出来**。
class WebDavSourcesPanel extends ConsumerWidget {
  /// 创建面板。
  const WebDavSourcesPanel({super.key, this.onSelect});

  /// 点某个连接 = **用它来浏览**（0.0.59 接上；WebDAV 页传进来）。
  final ValueChanged<WebDavSource>? onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final List<WebDavSource> sources =
        ref.watch(webDavSourcesProvider).value ?? const <WebDavSource>[];
    final List<Track> tracks =
        ref.watch(webDavLibraryProvider).value ?? const <Track>[];
    final Map<String, int> countBySource = <String, int>{};
    for (final Track t in tracks) {
      final String id = splitDavId(t.id).$1;
      countBySource[id] = (countBySource[id] ?? 0) + 1;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.cloud_outlined, size: 15, color: accent.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                sources.isEmpty
                    ? 'WebDAV 网盘：还没有添加。去左侧「来源 → WebDAV」填地址账号，点「保存并连接」就会加到这里。'
                    : 'WebDAV 网盘：${sources.length} 个（共 ${tracks.length} 首已进曲库）',
                style: const TextStyle(
                  color: Color(0xD9FFFFFF),
                  fontSize: 11.5,
                  height: 1.5,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () =>
                  ref.read(webDavLibraryProvider.notifier).refresh(),
              icon: const Icon(Icons.sync_rounded, size: 15),
              label: const Text('全部同步'),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final WebDavSource s in sources)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: MouseRegion(
              cursor: onSelect == null
                  ? MouseCursor.defer
                  : SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onSelect == null ? null : () => onSelect!(s),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '${s.name}　${s.enabled ? '' : '（已停用）'}',
                            style: TextStyle(
                              color: s.enabled
                                  ? Colors.white
                                  : const Color(0x99FFFFFF),
                              fontSize: 12.5,
                            ),
                          ),
                          Text(
                            '${s.url} · ${s.username} · ${countBySource[s.id] ?? 0} 首'
                            '${s.autoSync ? ' · 启动自动同步' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0x99FFFFFF),
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: s.enabled,
                      onChanged: (bool value) => ref
                          .read(webDavSourcesProvider.notifier)
                          .setFlags(
                            s.id,
                            (WebDavSource x) => x.copyWith(enabled: value),
                          ),
                      activeThumbColor: accent.primary,
                    ),
                    IconButton(
                      tooltip: '删除这个网盘连接（曲目会从曲库移除）',
                      onPressed: () async {
                        final ScaffoldMessengerState messenger =
                            ScaffoldMessenger.of(context);
                        await ref
                            .read(webDavSourcesProvider.notifier)
                            .remove(s.id);
                        await ref
                            .read(webDavLibraryProvider.notifier)
                            .clearSourceCache(s.id);
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text('已删除「${s.name}」'),
                            duration: const Duration(seconds: 2),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      },
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: Color(0x99FFFFFF),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 缓存面板（0.0.44）：显示占用 + 一键清理。
///
/// 缓存的是**不会变的东西**：歌词文本、刮削匹配结果（"这首歌是哪个平台的哪首"）、
/// 封面地址。**播放地址不缓存**（会过期）。
class _CachePanel extends ConsumerStatefulWidget {
  @override
  ConsumerState<_CachePanel> createState() => _CachePanelState();
}

class _CachePanelState extends ConsumerState<_CachePanel> {
  SourceCacheStats? _stats;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final SourceCacheStats stats = await SourceCache.instance.stats();
    if (!mounted) return;
    setState(() => _stats = stats);
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final SourceCacheStats stats = _stats ?? const SourceCacheStats();
    return Row(
      children: <Widget>[
        Icon(Icons.sd_storage_outlined, size: 15, color: accent.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '歌曲信息缓存：${stats.entries} 条 · ${stats.sizeLabel}'
                '（歌词 ${stats.lyrics} · 刮削匹配 ${stats.matches} · 封面地址 ${stats.covers}）',
                style: const TextStyle(
                  color: Color(0xD9FFFFFF),
                  fontSize: 11.5,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 3),
              const Text(
                '缓存歌词、刮削匹配结果和封面地址，重启后不用重新刮（播放地址不会缓存，'
                '因为它会过期）。清掉不影响播放，只是下次要重新刮一遍。',
                style: TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: _busy || stats.isEmpty
              ? null
              : () async {
                  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
                    context,
                  );
                  setState(() => _busy = true);
                  final int cleared = await SourceCache.instance.clear();
                  if (!mounted) return;
                  setState(() => _busy = false);
                  await _load();
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('已清理 $cleared 条缓存'),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
          icon: _busy
              ? const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.delete_sweep_outlined, size: 15),
          label: const Text('清理缓存'),
          style: TextButton.styleFrom(foregroundColor: Colors.white),
        ),
      ],
    );
  }
}

/// 音源列表（单独成页时可撑满，嵌进设置页时有最大高度）。
class _SourceList extends StatelessWidget {
  const _SourceList({
    required this.sources,
    required this.byId,
    required this.onToggle,
    required this.onDelete,
  });

  final List<MusicSource> sources;
  final Map<String, SourceRuntime> byId;
  final void Function(MusicSource source, bool value) onToggle;
  final void Function(MusicSource source) onDelete;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return const SourceHint(
        '还没有导入任何音源脚本。\n'
        '点上面的「导入脚本文件 / 文件夹」选本机的 .js 音源；\n'
        '也可以「从 URL 导入」直接粘贴一个脚本地址。\n\n'
        '脚本导入后会复制一份到应用数据目录，原文件挪走也不影响。',
        icon: Icons.extension_outlined,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      shrinkWrap: true,
      itemCount: sources.length,
      itemBuilder: (BuildContext context, int index) {
        final MusicSource source = sources[index];
        return _SourceRow(
          source: source,
          runtime: byId[source.id],
          onToggle: (bool value) => onToggle(source, value),
          onDelete: () => onDelete(source),
        );
      },
    );
  }
}

/// 一行音源脚本。
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.runtime,
    required this.onToggle,
    required this.onDelete,
  });

  final MusicSource source;
  final SourceRuntime? runtime;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    // 运行时里的是**最新**结果；没有运行时就用登记表里上次存下来的。
    final List<String> platforms =
        runtime?.sources.map((LxSourceInfo s) => s.key).toList() ??
        source.platforms;
    final List<String> actions =
        runtime?.sources
            .expand((LxSourceInfo s) => s.actions)
            .toSet()
            .toList() ??
        source.actions;
    final String error = runtime == null
        ? source.error
        : (runtime!.ok ? '' : runtime!.report.summary);
    final bool ok =
        runtime?.ok ?? (source.error.isEmpty && platforms.isNotEmpty);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                ok
                    ? Icons.extension_rounded
                    : Icons.report_gmailerrorred_rounded,
                size: 16,
                color: ok ? accent.primary : AppColors.neonMagenta,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    shadows: <Shadow>[
                      Shadow(color: Color(0x99000000), blurRadius: 6),
                    ],
                  ),
                ),
              ),
              if (source.version.isNotEmpty)
                Text(
                  'v${source.version}',
                  style: const TextStyle(
                    color: Color(0x8CFFFFFF),
                    fontSize: 10.5,
                  ),
                ),
              const SizedBox(width: 6),
              Switch(
                value: source.enabled,
                onChanged: onToggle,
                activeThumbColor: accent.primary,
              ),
              IconButton(
                tooltip: '删除',
                onPressed: onDelete,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: Color(0x99FFFFFF),
                ),
              ),
            ],
          ),
          if (platforms.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: <Widget>[
                  for (final String p in platforms)
                    _Chip(text: platformLabel(p)),
                  for (final String a in actions)
                    _Chip(text: _actionLabel(a), dim: true),
                ],
              ),
            ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 6),
              child: Text(
                error,
                style: const TextStyle(
                  color: AppColors.neonMagenta,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ),
          if (source.location.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 6),
              child: Text(
                '${source.origin == SourceOrigin.url ? 'URL' : '来源'}：'
                '${source.location}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0x66FFFFFF),
                  fontSize: 10.5,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _actionLabel(String action) => switch (action) {
    'musicUrl' => '取播放地址',
    'lyric' => '歌词',
    'pic' => '封面',
    _ => action,
  };
}

/// 小标签。
class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.dim = false});

  final String text;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        color: dim
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.white.withValues(alpha: 0.12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: dim ? const Color(0x99FFFFFF) : Colors.white,
          fontSize: 10.5,
        ),
      ),
    );
  }
}
