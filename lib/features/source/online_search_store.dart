/// online_search_store.dart
///
/// 在线搜索页的**会话级状态**（0.0.40）。
///
/// 用户要求：「搜索完如果切到其他页保留我的搜索」。
/// 搜索页在切页时会被整块重建（主区是 `switch (_view)` 直接换 widget），
/// 所以状态不能放在 `State` 里 —— 这里用一个进程内的小 store 存着，
/// 页面进来先读、每次变化再写回。
///
/// 为什么不放进 Riverpod：这份状态只有搜索页自己用，而且里面塞的是
/// 一组"取值/写回"的普通字段；用 `ChangeNotifier` 更直白，
/// 真要跨页面共享（比如别的页面要读搜索结果）再升级成 provider。
library;

import 'package:flutter/foundation.dart';

import '../../core/source/source_models.dart';

/// 在线搜索页状态。
class OnlineSearchStore extends ChangeNotifier {
  /// 关键词（输入框内容）。
  String keyword = '';

  /// 平台（`all` 或平台标识）。
  String platform = 'all';

  /// 音质。
  String quality = '320k';

  /// 结果。
  List<OnlineTrack> results = const <OnlineTrack>[];

  /// 当前页码。
  int page = 1;

  /// 还有没有下一页。
  bool hasMore = false;

  /// 平台报的总数。
  int total = 0;

  /// 状态行文字与配色。
  String status = '';
  bool statusOk = true;

  /// 是否曾经搜过（决定进页面要不要恢复）。
  bool get hasSaved => keyword.isNotEmpty || results.isNotEmpty;

  /// 清空（设置页/调试用）。
  void reset() {
    keyword = '';
    platform = 'all';
    quality = '320k';
    results = const <OnlineTrack>[];
    page = 1;
    hasMore = false;
    total = 0;
    status = '';
    statusOk = true;
    notifyListeners();
  }

  /// 一次性写回（页面每次搜索 / 加载 / 播放后调）。
  void save({
    required String keyword,
    required String platform,
    required String quality,
    required List<OnlineTrack> results,
    required int page,
    required bool hasMore,
    required int total,
    required String status,
    required bool statusOk,
  }) {
    this.keyword = keyword;
    this.platform = platform;
    this.quality = quality;
    this.results = results;
    this.page = page;
    this.hasMore = hasMore;
    this.total = total;
    this.status = status;
    this.statusOk = statusOk;
    notifyListeners();
  }
}

/// 进程内的搜索状态（切页不丢）。
final OnlineSearchStore onlineSearchStore = OnlineSearchStore();
