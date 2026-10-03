/// webdav_view.dart
///
/// 「来源 → WebDAV」页面（0.0.36）。
///
/// 用户的要求：
/// - 填地址 / 账号 / 密码 → **测试连接** → 浏览目录；
/// - **不要下载到本地**：识别出歌曲后，**每次播放都从网盘流式取**
///   （`PlayerController.playRemoteTracks`，`Track.uri` 就是带鉴权的 WebDAV 地址）。
///
/// 所以这一页只做三件事：**配置 → 浏览 → 播放**（外加"整个目录一起播"）。
library;

import 'dart:io' show Platform, stderr;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_engine.dart' show Track;
import '../../core/audio/player_providers.dart';
import '../../core/remote/webdav_client.dart';
import '../../core/remote/webdav_settings.dart';
import '../../core/remote/webdav_sources.dart';
import '../library/webdav_library.dart';
import '../source/source_manager_view.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';

/// WebDAV 页面。
class WebDavView extends ConsumerStatefulWidget {
  /// 创建页面。
  const WebDavView({super.key});

  @override
  ConsumerState<WebDavView> createState() => _WebDavViewState();
}

class _WebDavViewState extends ConsumerState<WebDavView> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pass = TextEditingController();

  /// 只读模式（环境变量兜底时不让改，免得误存）。
  bool _readOnlyConfig = false;
  bool _prefilled = false;
  bool _busy = false;
  String? _status;
  bool _statusOk = false;

  /// 当前目录路径（以 `/` 开头）。
  String _path = '/';
  List<WebDavEntry> _entries = const <WebDavEntry>[];
  WebDavClient? _client;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  /// 调试用自检（仅 Debug + `HOH_DAV_AUTOPLAY=1`）：
  /// 自动连接 → 找到第一个音频 → 直接流式播放，并把每一步写到 stderr。
  ///
  /// 目的：**不用手点**就能复现"点了歌一直转圈然后跳下一首"这类播放问题，
  /// 日志里能看到 mpv 的真实报错（`stderr`，不是会丢行的 debugPrint）。
  void _maybeAutoPlayForDebug() {
    if (kReleaseMode) return;
    if (Platform.environment['HOH_DAV_AUTOPLAY'] != '1') return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      stderr.writeln('[WebDAV自检] 自动连接…');
      await _connect(save: false);
      stderr.writeln('[WebDAV自检] 连接状态：$_status');
      if (_client == null) return;

      // 优先「音乐」目录，其次根目录往下找一层
      final List<String> candidates = <String>[
        for (final WebDavEntry e in _entries)
          if (e.isDirectory && e.name.contains('音乐')) e.path,
        '/',
      ];
      for (final String dir in candidates) {
        try {
          if (dir != _path) await _open(dir);
          List<WebDavEntry> audio = _playable;
          if (audio.isEmpty) {
            for (final WebDavEntry sub
                in _entries.where((WebDavEntry e) => e.isDirectory).take(3)) {
              await _open(sub.path);
              audio = _playable;
              if (audio.isNotEmpty) break;
            }
          }
          if (audio.isEmpty) continue;
          final WebDavEntry first = audio.first;
          stderr.writeln('[WebDAV自检] 试播：${first.name}');
          stderr.writeln(
            '[WebDAV自检] URL 路径：'
            '${Uri.parse(_client!.streamUrl(first.path)).path}',
          );
          await _playAll(startAt: first);
          return;
        } catch (error) {
          stderr.writeln('[WebDAV自检] 目录 $dir 失败：$error');
        }
      }
      stderr.writeln('[WebDAV自检] 没找到可播的音频');
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final WebDavConfig? config = ref.watch(webDavConfigProvider).value;

    // 已保存的连接展示在下方列表；表单保持空白，方便继续添加新网盘。
    if (!_prefilled) {
      _prefilled = true;
      if (config != null &&
          config.baseUrl.isNotEmpty &&
          Platform.environment['HOH_DAV_URL']?.isNotEmpty == true) {
        _url.text = config.baseUrl;
        _user.text = config.username;
        _pass.text = config.password;
        _readOnlyConfig = true;
        _maybeAutoPlayForDebug();
      }
    }

    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
      initialSweepPhase: 0.75,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'WEBDAV',
            style: TextStyle(
              color: accent.uiMutedText,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 2.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _readOnlyConfig
                ? '配置来自环境变量（调试用，不会写盘）。点「保存并连接」可存到本机。'
                : '填好服务器地址与账号后点「保存并连接」。播放**不下载文件**，每次都从网盘流式取。',
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11.5,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),

          // ── 配置 ─────────────────────────────────────────────
          Row(
            children: <Widget>[
              Expanded(
                flex: 4,
                child: _Field(
                  controller: _url,
                  label: '服务器地址（含 /webdav 路径）',
                  hint: 'https://webdav.123pan.cn/webdav',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _Field(controller: _user, label: '账号', hint: '手机号 / 邮箱'),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _Field(
                  controller: _pass,
                  label: '应用密码',
                  hint: '不是登录密码',
                  obscure: true,
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _busy ? null : () => _connect(save: true),
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_sync_outlined, size: 16),
                label: const Text('保存并连接'),
                style: FilledButton.styleFrom(
                  backgroundColor: accent.primary.withValues(alpha: 0.85),
                  foregroundColor: accent.uiText,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                ),
              ),
            ],
          ),
          if (_status != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Icon(
                  _statusOk ? Icons.check_circle_outline : Icons.error_outline,
                  size: 15,
                  color: _statusOk ? accent.primary : AppColors.neonMagenta,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _status!,
                    style: TextStyle(
                      color: _statusOk ? accent.uiText : AppColors.neonMagenta,
                      fontSize: 12,
                      shadows: const <Shadow>[
                        Shadow(color: Color(0x99000000), blurRadius: 6),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 14),
          // ── 已保存的网盘连接（0.0.54）────────────────────────────
          //     用户要求：和"设置 → 音源与刮削来源"里那份**合并到来源下**，
          //     **不做下拉，所有连接直接列出来**。
          const WebDavSourcesPanel(),
          const SizedBox(height: 10),
          // ── 音乐库同步（0.0.40）：网盘曲目会进统一曲库池 ──────────
          _LibrarySyncRow(),
          const SizedBox(height: 8),
          const Divider(color: AppColors.divider, height: 1),
          const SizedBox(height: 10),

          // ── 面包屑 ───────────────────────────────────────────
          Row(
            children: <Widget>[
              IconButton(
                tooltip: '上一级',
                onPressed: _path == '/' ? null : () => _open(_parentOf(_path)),
                icon: const Icon(Icons.arrow_upward_rounded, size: 16),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _client == null ? null : () => _open(_path),
                icon: const Icon(Icons.refresh_rounded, size: 16),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _client == null ? '未连接' : _path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent.uiText,
                    fontSize: 12.5,
                    shadows: <Shadow>[
                      Shadow(color: Color(0x99000000), blurRadius: 6),
                    ],
                  ),
                ),
              ),
              if (_client != null)
                TextButton.icon(
                  onPressed: _playable.isEmpty ? null : () => _playAll(),
                  icon: const Icon(Icons.play_circle_outline, size: 16),
                  label: Text('播放本目录 ${_playable.length} 首'),
                  style: TextButton.styleFrom(foregroundColor: accent.primary),
                ),
            ],
          ),
          const SizedBox(height: 6),

          // ── 列表 ─────────────────────────────────────────────
          Expanded(
            child: _client == null
                ? const _Hint('还没有连接。填好地址与账号后点「保存并连接」。')
                : _entries.isEmpty
                ? const _Hint('这个目录是空的（或没有可显示的内容）')
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: _entries.length,
                    itemBuilder: (BuildContext context, int index) {
                      final WebDavEntry e = _entries[index];
                      return _EntryRow(
                        entry: e,
                        onTap: e.isDirectory
                            ? () => _open(e.path)
                            : () => _playAll(startAt: e),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 当前目录里能播的（按名字排序，目录在前是列表自己的事）。
  List<WebDavEntry> get _playable => _entries
      .where((WebDavEntry e) => !e.isDirectory && e.looksLikeAudio)
      .toList();

  Future<void> _connect({required bool save}) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final WebDavConfig config = WebDavConfig(
        baseUrl: _url.text,
        username: _user.text,
        password: _pass.text,
      );
      final WebDavClient client = WebDavClient(config);
      final ({bool ok, String message}) result = await client.testConnection();
      if (!mounted) return;
      setState(() {
        _statusOk = result.ok;
        _status = result.message;
        _client = result.ok ? client : null;
      });
      if (result.ok) {
        if (save) {
          await ref
              .read(webDavSourcesProvider.notifier)
              .upsert(
                url: config.baseUrl,
                username: config.username,
                password: config.password,
              );
          // 不再保留旧的单份配置；已保存的连接由 webdav.sources 管理。
          await ref.read(webDavConfigProvider.notifier).clear();
          if (mounted) {
            _url.clear();
            _user.clear();
            _pass.clear();
            setState(() => _readOnlyConfig = false);
          }
        }
        await _open('/');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String path) async {
    final WebDavClient? client = _client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final List<WebDavEntry> entries = await client.list(path);
      // 目录在前、同类型按名字排
      entries.sort((WebDavEntry a, WebDavEntry b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _path = path.isEmpty ? '/' : path;
        _entries = entries;
        _statusOk = true;
        _status = '${entries.length} 项';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusOk = false;
        _status = '读取失败：$error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// **流式播放**：只把带鉴权的 URL 交给播放器，不下载（用户明确要求）。
  Future<void> _playAll({WebDavEntry? startAt}) async {
    final WebDavClient? client = _client;
    if (client == null) return;
    final List<WebDavEntry> list = startAt == null
        ? _playable
        : <WebDavEntry>[
            startAt,
            ..._playable.where((WebDavEntry e) => e.path != startAt.path),
          ];
    if (list.isEmpty) return;

    final String folder = _nameOfDirectory(_path);
    final List<Track> tracks = <Track>[
      for (final WebDavEntry e in list)
        Track(
          id: client.streamUrl(e.path),
          uri: client.streamUrl(e.path),
          title: _titleOf(e.name),
          artist: folder.isEmpty ? 'WebDAV' : folder,
          album: folder.isEmpty ? 'WebDAV' : folder,
          duration: null,
          isRemote: true,
        ),
    ];
    final int count = await ref
        .read(playerControllerProvider.notifier)
        // 「其他来源」点播放 = **追加到播放队列并跳到这一首**（0.0.41：
        // 点了某一首就必须播它，之前只入队不跳，用户只能靠"下一首"翻过去）
        .enqueueTracks(
          tracks,
          // `list` 的第一项就是用户点的那首（见上面构造），所以跳 0
          autoPlayIndex: 0,
          // ⚠️ 鉴权与 UA 都走**显式请求头**：只把账号密码塞在 URL 里，
          //    mpv 对 https + userinfo 不一定认（表现：一直转圈然后跳下一首）。
          httpHeaders: <String, String>{
            ...client.config.authHeaders,
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) HoH-music',
          },
        );
    if (!mounted) return;
    setState(() {
      _statusOk = true;
      _status = '已追加 $count 首到播放队列（流式，未下载到本地）';
    });
  }

  static String _parentOf(String path) {
    String p = path;
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    final int slash = p.lastIndexOf('/');
    return slash <= 0 ? '/' : p.substring(0, slash + 1);
  }

  static String _nameOfDirectory(String path) {
    String p = path;
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    final int slash = p.lastIndexOf('/');
    return slash < 0 ? '' : p.substring(slash + 1);
  }

  static String _titleOf(String fileName) {
    final int dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }
}

/// 输入框。
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: TextStyle(color: accent.uiText, fontSize: 12.5),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        labelStyle: TextStyle(color: accent.uiMutedText, fontSize: 11.5),
        hintStyle: TextStyle(color: accent.uiDisabledText, fontSize: 11.5),
        filled: true,
        fillColor: accent.uiPanelFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accent.uiBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: accent.uiBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: AppColors.neonCyan.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

/// 网盘曲目进音乐库的那一行（开关 + 同步 + 数量）。
class _LibrarySyncRow extends ConsumerStatefulWidget {
  @override
  ConsumerState<_LibrarySyncRow> createState() => _LibrarySyncRowState();
}

class _LibrarySyncRowState extends ConsumerState<_LibrarySyncRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final List<Track> tracks =
        ref.watch(webDavLibraryProvider).value ?? const <Track>[];
    final bool auto = ref.watch(_autoSyncProvider).value ?? true;

    return Row(
      children: <Widget>[
        Icon(Icons.library_music_outlined, size: 15, color: accent.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            tracks.isEmpty
                ? '音乐库里的网盘曲目：还没有同步（配好地址后点「同步到音乐库」）'
                : '音乐库里的网盘曲目：${tracks.length} 首'
                      '${auto ? '（启动自动同步已开）' : '（自动同步已关）'}',
            style: TextStyle(color: accent.uiText, fontSize: 11.5, height: 1.5),
          ),
        ),
        Text(
          '启动自动同步',
          style: TextStyle(
            color: auto ? accent.uiText : accent.uiDisabledText,
            fontSize: 11.5,
          ),
        ),
        Switch(
          value: auto,
          onChanged: (bool value) async {
            // 0.0.53：自动同步开关改成**每个源各自一份**（多源时得能单独关）
            final WebDavSource? first = ref
                .read(webDavSourcesProvider)
                .value
                ?.where((WebDavSource s) => s.enabled)
                .firstOrNull;
            if (first == null) return;
            await ref
                .read(webDavSourcesProvider.notifier)
                .setFlags(
                  first.id,
                  (WebDavSource s) => s.copyWith(autoSync: value),
                );
            ref.invalidate(_autoSyncProvider);
          },
          activeThumbColor: accent.primary,
        ),
        TextButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
                    context,
                  );
                  setState(() => _busy = true);
                  final WebDavSyncResult result = await ref
                      .read(webDavLibraryProvider.notifier)
                      .refresh();
                  if (!mounted) return;
                  setState(() => _busy = false);
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        result.ok
                            ? '已同步 ${result.tracks} 首到音乐库'
                            : '同步失败：${result.message}',
                      ),
                      duration: const Duration(seconds: 3),
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
              : const Icon(Icons.sync_rounded, size: 15),
          label: const Text('同步到音乐库'),
          style: TextButton.styleFrom(foregroundColor: accent.primary),
        ),
      ],
    );
  }
}

/// 自动同步开关的当前值（取第一个启用的源，0.0.53 起开关是按源存的）。
final _autoSyncProvider = FutureProvider<bool>((ref) async {
  final List<WebDavSource> sources = await ref.watch(
    webDavSourcesProvider.future,
  );
  return sources.where((WebDavSource s) => s.enabled).firstOrNull?.autoSync ??
      true;
});

/// 一行条目。
class _EntryRow extends StatefulWidget {
  const _EntryRow({required this.entry, required this.onTap});

  final WebDavEntry entry;
  final VoidCallback onTap;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final WebDavEntry e = widget.entry;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: _hovered ? Colors.white.withValues(alpha: 0.06) : null,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                e.isDirectory
                    ? Icons.folder_rounded
                    : (e.looksLikeAudio
                          ? Icons.play_circle_outline
                          : Icons.insert_drive_file_outlined),
                size: 16,
                color: e.isDirectory
                    ? accent.primary
                    : (e.looksLikeAudio
                          ? accent.secondary
                          : accent.uiMutedText),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: e.looksLikeAudio
                        ? accent.uiText
                        : accent.uiMutedText,
                    fontSize: 13,
                    shadows: const <Shadow>[
                      Shadow(color: Color(0x99000000), blurRadius: 6),
                    ],
                  ),
                ),
              ),
              if (!e.isDirectory && e.size > 0)
                Text(
                  '${(e.size / 1024 / 1024).toStringAsFixed(1)} MB',
                  style: TextStyle(color: accent.uiMutedText, fontSize: 11),
                ),
              if (e.modified != null) ...<Widget>[
                const SizedBox(width: 10),
                Text(
                  '${e.modified!.year}-${e.modified!.month.toString().padLeft(2, '0')}-'
                  '${e.modified!.day.toString().padLeft(2, '0')}',
                  style: TextStyle(color: accent.uiMutedText, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 空状态提示。
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: accent.uiMutedText,
          fontSize: 13,
          height: 1.6,
          shadows: <Shadow>[Shadow(color: Color(0x99000000), blurRadius: 6)],
        ),
      ),
    );
  }
}
