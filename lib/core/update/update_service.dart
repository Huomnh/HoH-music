import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../shared/constants.dart';

/// GitHub Release 中与当前平台匹配的安装包。
@immutable
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  final String name;
  final String downloadUrl;
  final int size;
}

/// 可安装的新版本信息。
@immutable
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.tagName,
    required this.title,
    required this.notes,
    required this.releaseUrl,
    required this.asset,
    required this.publishedAt,
  });

  final String version;
  final String tagName;
  final String title;
  final String notes;
  final String releaseUrl;
  final ReleaseAsset asset;
  final DateTime? publishedAt;
}

/// GitHub Releases 更新检查。
///
/// 发布约定：Release 至少上传一个包含 `windows-x64` 和 `.exe` 的安装包，
/// 例如 `HoH-music-Setup-0.1.1-Windows-x64.exe`。版本号从 tag 读取，支持
/// `v0.1.1`、`0.1.1`、`0.1.1-beta.2`，不把 build metadata 当作产品版本。
class UpdateService {
  UpdateService({Dio? client}) : _client = client ?? Dio();

  static const String _apiUrl =
      'https://api.github.com/repos/Huomnh/HoH-music/releases';
  final Dio _client;

  Future<AppUpdate?> checkForWindowsUpdate({
    Duration timeout = const Duration(seconds: 8),
    bool allowDebug = false,
  }) async {
    // Debug 构建会被测试和开发热重载频繁重建，默认不访问网络；版本说明页
    // 的“重新检查”仍显式传 allowDebug=true，方便开发阶段手动验证。
    if (kDebugMode && !allowDebug) return null;
    if (kIsWeb || !Platform.isWindows) return null;

    try {
      final Response<Object?> response = await _client.get<Object?>(
        _apiUrl,
        queryParameters: <String, Object?>{'per_page': 10},
        options: Options(
          responseType: ResponseType.json,
          headers: <String, String>{
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      final Object? data = response.data;
      if (data is! List<Object?>) return null;

      final List<AppUpdate> updates = <AppUpdate>[];
      for (final Object? raw in data) {
        if (raw is! Map<Object?, Object?>) continue;
        if (raw['draft'] == true || raw['prerelease'] == true) continue;
        final AppUpdate? update = _parseRelease(raw);
        if (update == null) continue;
        if (_compareVersions(update.version, AppConstants.version) > 0) {
          updates.add(update);
        }
      }
      updates.sort(
        (AppUpdate a, AppUpdate b) => _compareVersions(b.version, a.version),
      );
      return updates.isEmpty ? null : updates.first;
    } on DioException catch (error) {
      debugPrint('[Updater] GitHub Release 检查失败：${error.message}');
    } catch (error) {
      debugPrint('[Updater] GitHub Release 解析失败：$error');
    }
    return null;
  }

  AppUpdate? _parseRelease(Map<Object?, Object?> raw) {
    final String tag = raw['tag_name'] as String? ?? '';
    final String? version = _normalizeVersion(tag);
    if (version == null) return null;

    final Object? assetsRaw = raw['assets'];
    if (assetsRaw is! List<Object?>) return null;
    final ReleaseAsset? asset = _selectWindowsAsset(assetsRaw);
    if (asset == null) return null;

    DateTime? publishedAt;
    final String? published = raw['published_at'] as String?;
    if (published != null) publishedAt = DateTime.tryParse(published);
    return AppUpdate(
      version: version,
      tagName: tag,
      title: raw['name'] as String? ?? tag,
      notes: raw['body'] as String? ?? '',
      releaseUrl: raw['html_url'] as String? ?? AppConstants.repositoryUrl,
      asset: asset,
      publishedAt: publishedAt,
    );
  }

  ReleaseAsset? _selectWindowsAsset(List<Object?> assets) {
    final List<ReleaseAsset> candidates = <ReleaseAsset>[];
    for (final Object? raw in assets) {
      if (raw is! Map<Object?, Object?>) continue;
      final String name = raw['name'] as String? ?? '';
      final String url = raw['browser_download_url'] as String? ?? '';
      final String lower = name.toLowerCase();
      if (!lower.endsWith('.exe') ||
          !(lower.contains('windows') || lower.contains('win')) ||
          !(lower.contains('x64') || lower.contains('amd64'))) {
        continue;
      }
      candidates.add(
        ReleaseAsset(
          name: name,
          downloadUrl: url,
          size: (raw['size'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    if (candidates.isEmpty) return null;
    candidates.sort((ReleaseAsset a, ReleaseAsset b) {
      final int aInstaller = a.name.toLowerCase().contains('setup') ? 0 : 1;
      final int bInstaller = b.name.toLowerCase().contains('setup') ? 0 : 1;
      return aInstaller.compareTo(bInstaller);
    });
    return candidates.first;
  }

  static String? _normalizeVersion(String input) {
    final RegExpMatch? match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?',
    ).firstMatch(input.trim());
    if (match == null) return null;
    final String suffix = match.group(4) == null ? '' : '-${match.group(4)}';
    return '${match.group(1)}.${match.group(2)}.${match.group(3)}$suffix';
  }

  static int _compareVersions(String a, String b) {
    final List<String> left = _versionParts(a);
    final List<String> right = _versionParts(b);
    for (int i = 0; i < 3; i++) {
      final int difference = int.parse(left[i]).compareTo(int.parse(right[i]));
      if (difference != 0) return difference;
    }
    final String leftPre = left[3];
    final String rightPre = right[3];
    if (leftPre.isEmpty && rightPre.isNotEmpty) return 1;
    if (leftPre.isNotEmpty && rightPre.isEmpty) return -1;
    if (leftPre.isEmpty) return 0;
    final List<String> leftIdentifiers = leftPre.split('.');
    final List<String> rightIdentifiers = rightPre.split('.');
    for (
      int i = 0;
      i < leftIdentifiers.length && i < rightIdentifiers.length;
      i++
    ) {
      final String leftIdentifier = leftIdentifiers[i];
      final String rightIdentifier = rightIdentifiers[i];
      final int? leftNumber = int.tryParse(leftIdentifier);
      final int? rightNumber = int.tryParse(rightIdentifier);
      if (leftNumber != null && rightNumber != null) {
        final int difference = leftNumber.compareTo(rightNumber);
        if (difference != 0) return difference;
      } else if (leftNumber != null) {
        return -1;
      } else if (rightNumber != null) {
        return 1;
      } else {
        final int difference = leftIdentifier.compareTo(rightIdentifier);
        if (difference != 0) return difference;
      }
    }
    return leftIdentifiers.length.compareTo(rightIdentifiers.length);
  }

  static List<String> _versionParts(String version) {
    final String normalized = _normalizeVersion(version) ?? '0.0.0';
    final List<String> parts = normalized.split('-');
    final List<String> numbers = parts.first.split('.');
    return <String>[
      numbers[0],
      numbers[1],
      numbers[2],
      parts.length > 1 ? parts[1] : '',
    ];
  }
}

/// 将 GitHub Release 的 Markdown 简化成版本页可安全显示的纯文本。
String releaseNotesToPlainText(String markdown) {
  return markdown
      .replaceAll(RegExp(r'```[\s\S]*?```'), '')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]*\)'), r'\1')
      .replaceAll(RegExp(r'[#*_>`~]'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
