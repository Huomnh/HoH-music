/// online_search_view.dart
///
/// 「来源 → 在线搜索」页面（0.0.38 起，0.0.39 扩展成多平台 + 分页）。
///
/// 为什么搜索要自己做：LX 的音源脚本**只有 `musicUrl` / `lyric` / `pic`，没有 `search`**
/// —— 所以「搜什么歌」由宿主负责（`host_search.dart`：网易云 / QQ音乐 / 酷狗 / 酷我 /
/// 咪咕），搜到的平台原始字段塞进 `musicInfo` 再交给音源脚本换播放地址。
///
/// 播放**不落盘**：拿到直链就交给 mpv 流式播放，地址会过期所以每次点都重新解析。
library;

import 'dart:io' show Platform, stderr;
import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/host_search.dart';
import '../../core/source/source_host.dart';
import '../../core/source/source_models.dart';
import '../../core/source/source_store.dart';
import 'online_search_store.dart';
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';
import '../library/playlists.dart';
import 'online_player.dart';
import 'online_track_list.dart';
import 'source_widgets.dart';

/// 每页条数（和各平台接口的 `limit/pagesize/rows` 对应）。
const int _kPageSize = 30;

/// 在线搜索页。
class OnlineSearchView extends ConsumerStatefulWidget {
  /// 创建页面。
  const OnlineSearchView({super.key});

  @override
  ConsumerState<OnlineSearchView> createState() => _OnlineSearchViewState();
}

class _OnlineSearchViewState extends ConsumerState<OnlineSearchView> {
  final TextEditingController _keyword = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// `all` = 所有可用平台一起搜，其它值是平台标识。
  String _platform = 'all';
  String _quality = '320k';
  bool _busy = false;
  bool _loadingMore = false;
  String _status = '';
  bool _statusOk = true;
  List<OnlineTrack> _results = const <OnlineTrack>[];
  int _page = 1;
  bool _hasMore = false;
  int _total = 0;
  int _progressDone = 0;
  int _progressTotal = 0;
  String _progressTitle = '';

  @override
  void initState() {
    super.initState();
    // 切页回来先恢复上次的搜索（用户要求：搜索完切到其他页要保留）
    final OnlineSearchStore saved = onlineSearchStore;
    _keyword.text = saved.keyword;
    _platform = saved.platform;
    _quality = saved.quality;
    _results = saved.results;
    _page = saved.page;
    _hasMore = saved.hasMore;
    _total = saved.total;
    _status = saved.status;
    _statusOk = saved.statusOk;
    _scroll.addListener(_maybeLoadMoreOnScroll);
    _maybeAutoSearchForDebug();
  }

  /// 把当前状态写回会话 store（每次搜索 / 加载 / 播放后调一次）。
  void _persist() {
    onlineSearchStore.save(
      keyword: _keyword.text,
      platform: _platform,
      quality: _quality,
      results: _results,
      page: _page,
      hasMore: _hasMore,
      total: _total,
      status: _status,
      statusOk: _statusOk,
    );
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMoreOnScroll);
    _scroll.dispose();
    _keyword.dispose();
    super.dispose();
  }

  /// 滚到底部附近自动加载下一页（不用手点，但按钮也留着）。
  void _maybeLoadMoreOnScroll() {
    if (!_scroll.hasClients || _busy || _loadingMore || !_hasMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
      _loadMore();
    }
  }

  /// 当前要搜哪些平台：`全部` = 有音源且宿主能搜的平台；
  /// 一个都没有（还没导入音源）时至少还能搜网易云看看结果。
  List<String> _platformsToSearch(SourceHostState host) {
    if (_platform != 'all') return <String>[_platform];
    final List<String> usable = <String>[
      for (final String p in kSearchablePlatforms)
        if (host.platforms.contains(p)) p,
    ];
    return usable.isEmpty ? <String>['wy'] : usable;
  }

  /// 平台下拉里的可选项。
  List<(String, String)> _platformOptions(SourceHostState host) {
    final List<(String, String)> options = <(String, String)>[('all', '全部平台')];
    for (final String p in kSearchablePlatforms) {
      final bool hasSource = host.platforms.contains(p);
      options.add((
        p,
        hasSource ? platformLabel(p) : '${platformLabel(p)}（无音源）',
      ));
    }
    return options;
  }

  List<String> _qualityOptions(SourceHostState host) {
    final List<String> values = _platform == 'all'
        ? host.allQualitys
        : host.qualitysFor(_platform);
    if (values.isEmpty) return kCommonQualities;
    return values;
  }

  /// 调试自检（仅 Debug + `HOH_ONLINE_SEARCH=晴天`）：进页面就自动搜一次，
  /// 并且把「解析播放地址」也跑一遍 —— 截图和无人值守验证都靠它。
  void _maybeAutoSearchForDebug() {
    if (kReleaseMode) return;
    final String? keyword = Platform.environment['HOH_ONLINE_SEARCH'];
    if (keyword == null || keyword.isEmpty) return;
    final String? autoPlay = Platform.environment['HOH_ONLINE_PLAY'];
    final String? autoFavorite = Platform.environment['HOH_ONLINE_FAVORITE'];
    final String? autoPlatform = Platform.environment['HOH_ONLINE_PLATFORM'];
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (autoPlatform != null && autoPlatform.isNotEmpty) {
        _platform = autoPlatform;
      }
      _keyword.text = keyword;
      await _search();
      stderr.writeln(
        '[在线搜索自检] 平台=$_platform 来源=$_lastProvider '
        '结果=${_results.length} 共=$_total 还有更多=$_hasMore',
      );
      stderr.writeln('[在线搜索自检] 状态=$_status');
      final SourceHostState host =
          ref.read(sourceHostProvider).value ?? const SourceHostState();
      stderr.writeln('[在线搜索自检] 可用平台：${host.platforms}');
      // `HOH_ONLINE_FAVORITE=1` 收藏第一首，`=0` 取消收藏
      if (autoFavorite != null && _results.isNotEmpty) {
        final OnlineTrack first = _results.first;
        final bool want = autoFavorite != '0';
        final bool isFav = ref.read(isFavoriteProvider(first.id));
        if (isFav != want) {
          await ref.read(playlistsProvider.notifier).toggleFavorite(first.id);
        }
        if (want) {
          await ref.read(onlineLibraryProvider.notifier).remember(<OnlineTrack>[
            first,
          ]);
        }
        stderr.writeln(
          '[在线搜索自检] 收藏状态（${first.id}）：'
          '目标=$want 现在=${ref.read(isFavoriteProvider(first.id))}',
        );
      }
      if (autoPlay == '1' && _results.isNotEmpty) {
        await _playAll(take: 3);
        stderr.writeln('[在线搜索自检] 播放结果：$_status');
      }
    });
  }

  String _lastProvider = '';

  Future<void> _search() async {
    final String keyword = _keyword.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _busy = true;
      _page = 1;
      _status = '正在搜索…';
      _statusOk = true;
      _results = const <OnlineTrack>[];
      _total = 0;
      _hasMore = false;
    });
    // 搜索不再阻塞等待音源脚本。音源只负责把结果换成播放直链，
    // 搜索本身可以立即开始；宿主初始化在后台完成，首次点击播放时再等待。
    unawaited(
      ref.read(sourceHostProvider.future).catchError((Object _) {
        return const SourceHostState();
      }),
    );
    final SourceHostState host =
        ref.read(sourceHostProvider).value ?? const SourceHostState();
    if (!mounted) return;
    final List<String> platforms = _platformsToSearch(host);
    setState(
      () => _status =
          '正在搜索「$keyword」…'
          '（${platforms.map(platformLabel).join('、')}）',
    );
    try {
      final SearchOutcome outcome = await HostSearch.instance.searchAll(
        platforms,
        keyword,
        page: 1,
        limit: _kPageSize,
      );
      if (!mounted) return;
      _lastProvider = outcome.provider;
      setState(() {
        _busy = false;
        _results = outcome.tracks;
        _total = outcome.total;
        _hasMore = outcome.hasMore;
        _status = _describe(outcome, host, platforms, first: true);
        _statusOk = outcome.tracks.isNotEmpty;
      });
      _persist();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '搜索出错：$error';
        _statusOk = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_busy || _loadingMore || !_hasMore || _results.isEmpty) return;
    final String keyword = _keyword.text.trim();
    if (keyword.isEmpty) return;
    setState(() => _loadingMore = true);
    final SourceHostState host =
        ref.read(sourceHostProvider).value ?? const SourceHostState();
    final List<String> platforms = _platformsToSearch(host);
    final int next = _page + 1;
    try {
      final SearchOutcome outcome = await HostSearch.instance.searchAll(
        platforms,
        keyword,
        page: next,
        limit: _kPageSize,
      );
      if (!mounted) return;
      final Set<String> seen = _results.map((OnlineTrack t) => t.id).toSet();
      final List<OnlineTrack> merged = <OnlineTrack>[
        ..._results,
        ...outcome.tracks.where((OnlineTrack t) => seen.add(t.id)),
      ];
      setState(() {
        _loadingMore = false;
        _page = next;
        _results = merged;
        _total = outcome.total > 0 ? outcome.total : _total;
        _hasMore = outcome.hasMore;
        _status = _describe(
          outcome,
          host,
          platforms,
          first: false,
          loaded: merged.length,
        );
        _statusOk = true;
      });
      _persist();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _status = '加载第 $next 页失败：$error';
        _statusOk = false;
      });
    }
  }

  /// 拼状态文字（搜索来源 / 条数 / 平台可用情况 / 提示）。
  String _describe(
    SearchOutcome outcome,
    SourceHostState host,
    List<String> platforms, {
    required bool first,
    int loaded = 0,
  }) {
    final List<String> parts = <String>[];
    final int count = first ? outcome.tracks.length : loaded;
    if (count > 0) {
      parts.add(
        '${outcome.provider}：'
        '${first ? '找到 $count 首' : '已加载 $count 首'}'
        '${_total > 0 ? '（共 $_total 首）' : ''}'
        '${_hasMore ? '，继续往下滚可加载更多' : ''}',
      );
    } else {
      parts.add('没搜到（${outcome.note.isEmpty ? '换个关键词试试' : outcome.note}）');
    }
    if (outcome.note.isNotEmpty && count > 0) parts.add(outcome.note);

    // 在线播放靠"支持该平台的音源"，提前把可用情况讲清楚
    if (count > 0) {
      final Set<String> resultPlatforms = outcome.tracks
          .map((OnlineTrack t) => t.platform)
          .toSet();
      for (final String p in resultPlatforms) {
        parts.add(host.describePlatformSummary(p));
      }
      if (host.isEmpty) {
        parts.add(
          '⚠️ 还没有可用音源：去「音源管理」导入并加载脚本，'
          '否则只能看信息，不能播放；请先在「音源管理」启用对应平台音源',
        );
      }
    }
    if (platforms.length == 1 && !host.platforms.contains(platforms.first)) {
      parts.add(
        '提示：「${platformLabel(platforms.first)}」目前没有启用的音源，'
        '结果只能看信息，不能播放',
      );
    }
    return parts.join('\n');
  }

  Future<void> _playAll({int take = 0}) async {
    final List<OnlineTrack> targets = take > 0
        ? _results.take(take).toList()
        : _results;
    if (targets.isEmpty) return;
    setState(() {
      _busy = true;
      _progressDone = 0;
      _progressTotal = targets.length;
      _progressTitle = '';
      _status = '正在逐首解析播放地址…（当前音源）';
      _statusOk = true;
    });
    final OnlinePlayResult result = await playOnlineTracks(
      ref,
      targets,
      quality: _quality,
      onProgress: (int done, int total, String title) {
        if (!mounted) return;
        setState(() {
          _progressDone = done;
          _progressTotal = total;
          _progressTitle = title;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusOk = result.played > 0;
      final List<String> parts = <String>[
        result.played > 0
            ? '已开始播放 ${result.played} 首'
                  '${result.providers.isEmpty ? '' : '（${result.providers.join('、')}）'}'
            : '一首都没能播放',
        if (result.failed.isNotEmpty)
          '失败 ${result.failed.length} 首：${result.failed.take(3).join('；')}'
              '${result.failed.length > 3 ? ' …' : ''}',
      ];
      _status = parts.join('\n');
    });
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final SourceHostState host =
        ref.watch(sourceHostProvider).value ?? const SourceHostState();
    final List<String> qualityOptions = _qualityOptions(host);
    if (qualityOptions.isNotEmpty && !qualityOptions.contains(_quality)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || qualityOptions.contains(_quality)) return;
        setState(() => _quality = qualityOptions.first);
        _persist();
      });
    }

    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      initialSweepPhase: 0.1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    colors: <Color>[
                      accent.primary.withValues(alpha: 0.95),
                      accent.secondary.withValues(alpha: 0.8),
                    ],
                  ),
                ),
                child: const Icon(Icons.search_rounded, color: Colors.white),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '在线搜索',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      '搜索歌曲，选择音质后直接播放或下载',
                      style: TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              _InfoPill(
                icon: Icons.graphic_eq_rounded,
                text: host.isEmpty ? '未连接音源' : '单音源模式',
                color: host.isEmpty ? AppColors.textTertiary : accent.primary,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── 搜索行 ────────────────────────────────────────────
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool compact = constraints.maxWidth < 430;
              final Widget keyword = SourceField(
                controller: _keyword,
                label: '',
                hint: '歌曲、歌手或专辑',
                onSubmitted: _busy ? null : _search,
              );
              final Widget platform = _Dropdown<String>(
                value: _platform,
                width: compact ? null : 128,
                items: <(String, String)>[
                  for (final (String, String) o in _platformOptions(host)) o,
                ],
                onChanged: (String value) {
                  setState(() => _platform = value);
                  _persist();
                  if (_results.isNotEmpty) _search();
                },
              );
              final Widget quality = _Dropdown<String>(
                value: qualityOptions.contains(_quality)
                    ? _quality
                    : qualityOptions.first,
                width: compact ? null : 112,
                items: <(String, String)>[
                  for (final String q in qualityOptions) (q, qualityLabel(q)),
                ],
                onChanged: (String value) {
                  setState(() => _quality = value);
                  _persist();
                },
              );
              final Widget searchButton = IconButton.filled(
                tooltip: '搜索',
                onPressed: _busy ? null : _search,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search_rounded, size: 18),
                style: IconButton.styleFrom(
                  backgroundColor: accent.primary.withValues(alpha: 0.9),
                  foregroundColor: Colors.white,
                  fixedSize: const Size(42, 42),
                ),
              );

              // 手机宽度不足以容纳输入框 + 两个下拉框 + 搜索按钮，
              // 输入框独占一行，筛选项放到第二行并平均分配宽度。
              if (compact) {
                return Column(
                  children: <Widget>[
                    keyword,
                    const SizedBox(height: 6),
                    Row(
                      children: <Widget>[
                        Expanded(child: platform),
                        const SizedBox(width: 6),
                        Expanded(child: quality),
                        const SizedBox(width: 6),
                        searchButton,
                      ],
                    ),
                  ],
                );
              }
              return Row(
                children: <Widget>[
                  Expanded(child: keyword),
                  const SizedBox(width: 6),
                  platform,
                  const SizedBox(width: 6),
                  quality,
                  const SizedBox(width: 6),
                  searchButton,
                ],
              );
            },
          ),

          if (_status.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            SourceStatusLine(text: _status, ok: _statusOk, busy: _busy),
          ],
          if (_busy && _progressTotal > 0) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: LinearProgressIndicator(
                    value: _progressDone / _progressTotal,
                    minHeight: 3,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '$_progressDone/$_progressTotal'
                  '${_progressTitle.isEmpty ? '' : ' · $_progressTitle'}',
                  style: const TextStyle(
                    color: Color(0x99FFFFFF),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Text(
                _results.isEmpty ? '搜索结果' : '${_results.length} 首结果',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              if (_total > _results.length)
                Text(
                  '共 $_total 首',
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy || _results.isEmpty ? null : () => _playAll(),
                icon: const Icon(Icons.play_arrow_rounded, size: 17),
                label: const Text('播放全部'),
                style: TextButton.styleFrom(
                  foregroundColor: accent.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
          const Divider(color: AppColors.divider, height: 8),

          // ── 结果 ─────────────────────────────────────────────
          Expanded(
            child: _results.isEmpty
                ? SourceHint(
                    host.isEmpty
                        ? '还没有可用音源。先去「音源管理」导入 lx-music 格式的 .js 脚本，'
                              '这里才能搜歌并播放。'
                        : '输入关键词后回车即可搜索。\n'
                              '当前可用平台：${host.platforms.map(platformLabel).join('、')}',
                    icon: Icons.search_rounded,
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 8),
                    // 末尾多一行：加载更多 / 到头了
                    itemCount: _results.length + 1,
                    itemBuilder: (BuildContext context, int index) {
                      if (index == _results.length) {
                        return _FooterRow(
                          hasMore: _hasMore,
                          loading: _loadingMore,
                          count: _results.length,
                          onLoadMore: _loadMore,
                        );
                      }
                      return OnlineTrackRow(
                        track: _results[index],
                        index: index + 1,
                        quality: _quality,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(color: color, fontSize: 10.5)),
        ],
      ),
    );
  }
}

/// 结果列表末尾那一行：加载更多 / 已到底。
class _FooterRow extends StatelessWidget {
  const _FooterRow({
    required this.hasMore,
    required this.loading,
    required this.count,
    required this.onLoadMore,
  });

  final bool hasMore;
  final bool loading;
  final int count;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (loading)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          TextButton.icon(
            onPressed: hasMore && !loading ? onLoadMore : null,
            icon: Icon(
              hasMore ? Icons.expand_more_rounded : Icons.check_rounded,
              size: 16,
            ),
            label: Text(hasMore ? '加载更多（已 $count 首）' : '已经到底了（共 $count 首）'),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// 带标签的下拉框（平台 / 音质共用）。
class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.width = 150,
  });

  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.black.withValues(alpha: 0.22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          dropdownColor: const Color(0xF21A1A22),
          style: const TextStyle(color: Colors.white, fontSize: 12),
          iconEnabledColor: const Color(0x99FFFFFF),
          items: <DropdownMenuItem<T>>[
            for (final (T, String) item in items)
              DropdownMenuItem<T>(
                value: item.$1,
                child: Text(
                  item.$2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (T? next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    );
  }
}
