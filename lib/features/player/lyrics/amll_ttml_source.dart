/// AMLL TTML DB 的只读歌词源适配。
///
/// 这里只请求按平台 ID 命名的静态文件，不复制数据库内容进安装包，
/// 也不依赖 AMLL 的播放器代码。歌词文本仍由用户当前歌曲和网络源决定。
library;

import 'package:dio/dio.dart';

import '../../../core/audio/player_engine.dart';
import '../../../core/source/host_search.dart';
import '../../../core/source/source_models.dart';

class AmllTtmlSource {
  AmllTtmlSource._();

  static const String repositoryUrl =
      'https://github.com/amll-dev/amll-ttml-db';
  static const String _rawBase =
      'https://raw.githubusercontent.com/amll-dev/amll-ttml-db/refs/heads/main';
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 8),
      responseType: ResponseType.plain,
      headers: <String, String>{'User-Agent': 'HoH-music/0.0.110'},
    ),
  );

  /// 返回 AMLL TTML 文本；找不到或非网易云 ID 时静默返回 null。
  static Future<String?> fetchForTrack(Track track) async {
    String? songId = _neteaseId(track.id);
    if (songId == null && !track.isRemote) {
      try {
        final OnlineTrack? matched = await HostSearch.instance.matchTrack(
          track,
        );
        if (matched?.platform == 'wy') songId = matched!.songId;
      } catch (_) {
        return null;
      }
    }
    if (songId == null || !RegExp(r'^\d+$').hasMatch(songId)) return null;
    try {
      final Response<String> response = await _dio.get<String>(
        '$_rawBase/ncm-lyrics/$songId.ttml',
        options: Options(
          validateStatus: (int? status) => status != null && status < 500,
        ),
      );
      if (response.statusCode != 200) return null;
      final String body = response.data ?? '';
      return body.trim().isEmpty ? null : body;
    } on DioException {
      return null;
    }
  }

  static String? _neteaseId(String id) {
    final (String platform, String songId) = HostSearch.splitTrackId(id);
    return platform == 'wy' ? songId : null;
  }
}
