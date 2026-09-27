/// webdav_settings.dart
///
/// WebDAV 连接配置的持久化（0.0.36）。
///
/// - 落 `shared_preferences`：`webdav.url` / `webdav.user` / `webdav.pass`；
/// - ⚠️ **凭据不进仓库**：这里只存到**用户自己的机器**上；
///   调试时可以用环境变量 `HOH_DAV_URL/USER/PASS` 兜底（仅 Debug，且**不会写盘**）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'webdav_client.dart';

/// 当前 WebDAV 配置。
final webDavConfigProvider =
    AsyncNotifierProvider<WebDavConfigController, WebDavConfig>(
      WebDavConfigController.new,
    );

/// 配置控制器。
class WebDavConfigController extends AsyncNotifier<WebDavConfig> {
  static const String _urlKey = 'webdav.url';
  static const String _userKey = 'webdav.user';
  static const String _passKey = 'webdav.pass';

  @override
  Future<WebDavConfig> build() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String url = prefs.getString(_urlKey) ?? '';
      final String user = prefs.getString(_userKey) ?? '';
      final String pass = prefs.getString(_passKey) ?? '';
      if (url.isNotEmpty) {
        return WebDavConfig(baseUrl: url, username: user, password: pass);
      }
    } catch (error) {
      debugPrint('[WebDAV] 读取配置失败：$error');
    }
    return _fromEnvironment();
  }

  /// 调试用兜底：环境变量里给了就直接用（**不写盘**）。
  static WebDavConfig _fromEnvironment() {
    if (kReleaseMode) return const WebDavConfig(baseUrl: '');
    final String url = Platform.environment['HOH_DAV_URL'] ?? '';
    if (url.isEmpty) return const WebDavConfig(baseUrl: '');
    return WebDavConfig(
      baseUrl: url,
      username: Platform.environment['HOH_DAV_USER'] ?? '',
      password: Platform.environment['HOH_DAV_PASS'] ?? '',
    );
  }

  /// 保存（用户点了「保存并连接」才写盘）。
  Future<void> save(WebDavConfig config) async {
    state = AsyncData<WebDavConfig>(config);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_urlKey, config.baseUrl);
      await prefs.setString(_userKey, config.username);
      await prefs.setString(_passKey, config.password);
    } catch (error) {
      debugPrint('[WebDAV] 保存配置失败：$error');
    }
  }

  /// 清空配置。
  Future<void> clear() async {
    state = const AsyncData<WebDavConfig>(WebDavConfig(baseUrl: ''));
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_urlKey);
      await prefs.remove(_userKey);
      await prefs.remove(_passKey);
    } catch (error) {
      debugPrint('[WebDAV] 清空配置失败：$error');
    }
  }
}
