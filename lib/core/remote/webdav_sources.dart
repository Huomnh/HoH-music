/// webdav_sources.dart
///
/// **WebDAV 多源**（0.0.53）：可以保存多个网盘连接，随时增删。
///
/// 用户要求：「webdav 添加后在音乐库里创建，后续可以在里面删掉保存的
/// webdav 音乐源链接，想增加或删除 webdav 的时候而不是只能用这一个」。
///
/// 设计：
/// - 每个源 = 一条 `WebDavSource`（id / 名称 / 地址 / 账号 / 密码 / 根目录 /
///   自动同步 / 启用），整表存 `webdav.sources`；
/// - 曲目 id 用 **`dav:<源id>:<路径>`**（多源必须有源 id，否则不同网盘的
///   同名路径会撞 id）；
/// - 兼容旧版：老的 `webdav.url/user/pass` 会在首次读取时**自动迁移**成第一个源。
///
/// ⚠️ 密码只落本机 `shared_preferences`，**绝不进仓库**。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'webdav_client.dart';

/// 保存的连接列表（键 `webdav.sources`）。
const String _kSources = 'webdav.sources';

/// 旧版单份配置的键（迁移用）。
const String _kLegacyUrl = 'webdav.url';
const String _kLegacyUser = 'webdav.user';
const String _kLegacyPass = 'webdav.pass';

/// 一个 WebDAV 源。
class WebDavSource {
  /// 创建源。
  const WebDavSource({
    required this.id,
    required this.name,
    required this.url,
    this.username = '',
    this.password = '',
    this.root = '/',
    this.autoSync = true,
    this.enabled = true,
  });

  /// 稳定 id（地址 + 账号的短哈希：同一个网盘重复添加不会产生两条）。
  final String id;

  /// 展示名（默认取域名）。
  final String name;

  /// 服务器地址（含 `/webdav` 之类的路径）。
  final String url;

  /// 账号。
  final String username;

  /// 密码（应用密码）。
  final String password;

  /// 扫描根目录。
  final String root;

  /// 启动是否自动连接同步。
  final bool autoSync;

  /// 是否启用（停用后不进曲库、不自动连）。
  final bool enabled;

  /// 转成客户端配置。
  WebDavConfig get config =>
      WebDavConfig(baseUrl: url, username: username, password: password);

  /// 配置是否够用。
  bool get isReady => config.isValid && username.trim().isNotEmpty;

  /// 复制并改字段。
  WebDavSource copyWith({
    String? name,
    String? url,
    String? username,
    String? password,
    String? root,
    bool? autoSync,
    bool? enabled,
  }) => WebDavSource(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    username: username ?? this.username,
    password: password ?? this.password,
    root: root ?? this.root,
    autoSync: autoSync ?? this.autoSync,
    enabled: enabled ?? this.enabled,
  );

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'url': url,
    'username': username,
    'password': password,
    'root': root,
    'autoSync': autoSync,
    'enabled': enabled,
  };

  /// 反序列化。
  factory WebDavSource.fromJson(Map<String, dynamic> json) => WebDavSource(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? 'WebDAV',
    url: json['url']?.toString() ?? '',
    username: json['username']?.toString() ?? '',
    password: json['password']?.toString() ?? '',
    root: json['root']?.toString() ?? '/',
    autoSync: json['autoSync'] != false,
    enabled: json['enabled'] != false,
  );

  /// 由地址 + 账号算 id。
  static String idFor(String url, String username) => sha1
      .convert(utf8.encode('${url.trim()}|${username.trim()}'))
      .toString()
      .substring(0, 10);

  /// 由地址猜一个展示名（域名）。
  static String nameFor(String url) {
    final Uri? uri = Uri.tryParse(url.trim());
    final String host = uri?.host ?? '';
    return host.isEmpty ? 'WebDAV' : host;
  }
}

/// 已保存的 WebDAV 源列表。
final webDavSourcesProvider =
    AsyncNotifierProvider<WebDavSourcesController, List<WebDavSource>>(
      WebDavSourcesController.new,
    );

/// 源列表控制器。
class WebDavSourcesController extends AsyncNotifier<List<WebDavSource>> {
  @override
  Future<List<WebDavSource>> build() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<WebDavSource> list = _decode(prefs.getString(_kSources));
    if (list.isNotEmpty) {
      // ⚠️ 0.0.54：`来源 → WebDAV` 页的「保存并连接」仍然写的是旧单份配置，
      //    这里每次读取都顺手把它**并进列表**（同地址同账号视为同一个），
      //    这样"在页面里填一次地址"就等于"新增一个网盘连接"，不用改页面代码。
      final String legacyUrl = prefs.getString(_kLegacyUrl) ?? '';
      if (legacyUrl.isNotEmpty) {
        final String legacyUser = prefs.getString(_kLegacyUser) ?? '';
        final String id = WebDavSource.idFor(legacyUrl, legacyUser);
        if (!list.any((WebDavSource s) => s.id == id)) {
          list.add(
            WebDavSource(
              id: id,
              name: WebDavSource.nameFor(legacyUrl),
              url: legacyUrl,
              username: legacyUser,
              password: prefs.getString(_kLegacyPass) ?? '',
            ),
          );
          await prefs.setString(_kSources, _encode(list));
        }
        await prefs.remove(_kLegacyUrl);
        await prefs.remove(_kLegacyUser);
        await prefs.remove(_kLegacyPass);
      }
      return list;
    }

    // 兼容旧版：把单份配置迁移成第一个源
    final String url = prefs.getString(_kLegacyUrl) ?? '';
    if (url.isEmpty) return const <WebDavSource>[];
    final String user = prefs.getString(_kLegacyUser) ?? '';
    final WebDavSource migrated = WebDavSource(
      id: WebDavSource.idFor(url, user),
      name: WebDavSource.nameFor(url),
      url: url,
      username: user,
      password: prefs.getString(_kLegacyPass) ?? '',
    );
    await prefs.setString(_kSources, _encode(<WebDavSource>[migrated]));
    await prefs.remove(_kLegacyUrl);
    await prefs.remove(_kLegacyUser);
    await prefs.remove(_kLegacyPass);
    return <WebDavSource>[migrated];
  }

  List<WebDavSource> get _current => state.value ?? const <WebDavSource>[];

  Future<void> _commit(List<WebDavSource> list) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSources, _encode(list));
    state = AsyncData<List<WebDavSource>>(list);
  }

  /// 新增 / 更新一个源（同地址同账号视为同一个）。
  Future<WebDavSource> upsert({
    String name = '',
    required String url,
    required String username,
    required String password,
    String root = '/',
    bool autoSync = true,
  }) async {
    final String id = WebDavSource.idFor(url, username);
    final WebDavSource source = WebDavSource(
      id: id,
      name: name.trim().isEmpty ? WebDavSource.nameFor(url) : name.trim(),
      url: url.trim(),
      username: username.trim(),
      password: password,
      root: root.trim().isEmpty ? '/' : root.trim(),
      autoSync: autoSync,
    );
    final List<WebDavSource> next = List<WebDavSource>.of(_current);
    final int index = next.indexWhere((WebDavSource s) => s.id == id);
    if (index >= 0) {
      next[index] = source;
    } else {
      next.add(source);
    }
    await _commit(next);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLegacyUrl);
    await prefs.remove(_kLegacyUser);
    await prefs.remove(_kLegacyPass);
    return source;
  }

  /// 删除一个源（曲目缓存由调用方一并清理）。
  Future<void> remove(String id) async {
    await _commit(
      _current.where((WebDavSource s) => s.id != id).toList(growable: false),
    );
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLegacyUrl);
    await prefs.remove(_kLegacyUser);
    await prefs.remove(_kLegacyPass);
  }

  /// 改某个源的字段（开关 / 名称 / 根目录等）。
  ///
  /// 名字不能叫 `update`：`AsyncNotifier` 自己有一个 `update`，签名不一样会撞。
  Future<void> setFlags(
    String id,
    WebDavSource Function(WebDavSource) change,
  ) async {
    await _commit(<WebDavSource>[
      for (final WebDavSource s in _current)
        if (s.id == id) change(s) else s,
    ]);
  }

  /// 按 id 找一个源。
  WebDavSource? byId(String id) {
    for (final WebDavSource s in _current) {
      if (s.id == id) return s;
    }
    return null;
  }

  static List<WebDavSource> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const <WebDavSource>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <WebDavSource>[];
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map(
            (Map<Object?, Object?> m) => WebDavSource.fromJson(
              m.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
            ),
          )
          .where((WebDavSource s) => s.id.isNotEmpty && s.url.isNotEmpty)
          .toList();
    } on FormatException {
      return const <WebDavSource>[];
    }
  }

  static String _encode(List<WebDavSource> list) =>
      jsonEncode(list.map((WebDavSource s) => s.toJson()).toList());
}

/// 源 id → 客户端（配置不全返回 null）。
WebDavClient? clientFor(WebDavSource? source) {
  if (source == null || !source.isReady) return null;
  return WebDavClient(source.config);
}

/// 从曲目 id 里拆出（源 id, 路径）。
///
/// 格式：`dav:<源id>:<路径>`；兼容旧版 `dav:<路径>`（返回空的源 id）。
(String sourceId, String path) splitDavId(String id) {
  if (!id.startsWith('dav:')) return ('', '');
  final String rest = id.substring(4);
  final int colon = rest.indexOf(':');
  if (colon <= 0) return ('', rest); // 旧格式：没有源 id
  final String sourceId = rest.substring(0, colon);
  final String path = rest.substring(colon + 1);
  // 旧格式的路径是 `/…`（以斜杠开头），源 id 不会是斜杠开头 —— 用这个区分
  if (path.startsWith('/')) return (sourceId, path);
  return ('', rest);
}
