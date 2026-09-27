/// text_match.dart
///
/// 曲名 / 歌手名的归一化与相似度（**纯函数，不碰网络，方便单测**）。
///
/// 抽出来单独放的原因：封面刮削（`cover_art.dart`）和宿主搜索匹配
/// （`core/source/host_search.dart`）都要用同一套判定 ——
/// 两边各写一份迟早会不一致，而且 `cover_art` 与 `host_search` 互相引用会成环。
library;

/// 归一化歌名 / 艺术家名：小写、去掉括号内容与标点空格。
///
/// 去掉 `(...)` / `（...）` / `[...]` 很重要：搜索结果的
/// `半句再见 (Live)` 与我们的 `半句再见` 应当算同一个名字。
String normalizeTrackText(String raw) {
  String s = raw.toLowerCase();
  // 平台返回的名字里常有 HTML 实体（酷我的 `晴天&nbsp;(KTV版伴奏)`），
  // 不处理的话归一化后会变成 `晴天nbsp`，跟 `晴天` 只算"包含"（0.8），
  // 跨平台兜底就匹配不上了（0.0.39 实测踩到）。
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  s = s.replaceAll(RegExp(r'[\(\[（【].*?[\)\]）】]'), '');
  s = s.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');
  return s.trim();
}

/// 相似度，0~1。
///
/// 规则：归一化后完全相等 → 1；一方包含另一方 → 0.8；
/// 否则用 **bigram Dice 系数**（对中英文都适用，比编辑距离省事）：
/// `2·|A∩B| / (|A|+|B|)`。
double similarityOf(String a, String b) {
  final String x = normalizeTrackText(a);
  final String y = normalizeTrackText(b);
  if (x.isEmpty || y.isEmpty) return 0;
  if (x == y) return 1;
  if (x.contains(y) || y.contains(x)) return 0.8;

  final List<String> ax = _bigrams(x);
  final List<String> by = _bigrams(y);

  final Map<String, int> pool = <String, int>{};
  for (final String g in ax) {
    pool[g] = (pool[g] ?? 0) + 1;
  }
  int overlap = 0;
  for (final String g in by) {
    final int left = pool[g] ?? 0;
    if (left > 0) {
      pool[g] = left - 1;
      overlap++;
    }
  }
  return 2 * overlap / (ax.length + by.length);
}

List<String> _bigrams(String s) {
  final List<String> out = <String>[];
  for (int i = 0; i + 1 < s.length; i++) {
    out.add(s.substring(i, i + 2));
  }
  // 单字也要能比：补一个字符本身
  if (out.isEmpty) out.add(s);
  return out;
}
