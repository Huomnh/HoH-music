/// local_scanner.dart
///
/// 本地文件夹增量扫描的数据库入口。
library;

import 'dart:io';

import 'package:drift/drift.dart';

import '../../core/audio/player_engine.dart';
import '../../core/database/database.dart';

class LocalScanner {
  LocalScanner({AppDatabase? database}) : _database = database ?? appDatabase;

  final AppDatabase _database;

  /// 先读 Drift 缓存，让曲库页面立即有内容；实际目录扫描在后台更新。
  Future<List<Track>> cached() async =>
      (await _database.allLocalTracks()).map(_trackFromRow).toList();

  /// 只解析新增或被修改的文件，并清理已经删除的文件。
  Future<List<Track>> scan(Iterable<String> roots) async {
    final List<File> files = <File>[];
    final Set<String> seenFiles = <String>{};
    for (final String root in roots) {
      final FileSystemEntity entity = FileSystemEntity.isDirectorySync(root)
          ? Directory(root)
          : File(root);
      if (entity is Directory) {
        for (final File file in await scanAudioFilesAsync(entity.path)) {
          if (seenFiles.add(file.path)) files.add(file);
        }
      } else if (entity is File && isSupportedAudioFile(entity.path)) {
        if (seenFiles.add(entity.path)) files.add(entity);
      }
    }

    final Map<String, LocalTrack> cached = <String, LocalTrack>{
      for (final LocalTrack row in await _database.allLocalTracks())
        row.path: row,
    };
    final List<LocalTracksCompanion> changed = <LocalTracksCompanion>[];
    final List<Track> tracks = <Track>[];
    final Set<String> present = <String>{};

    for (final File file in files) {
      final String path = file.path;
      present.add(path);
      final FileStat stat = await file.stat();
      final LocalTrack? old = cached[path];
      if (old != null &&
          old.fileSize == stat.size &&
          old.modifiedAt == stat.modified.millisecondsSinceEpoch) {
        tracks.add(_trackFromRow(old));
        continue;
      }
      final Track track = await Track.fromFile(file);
      changed.add(_rowFromTrack(track, stat));
      tracks.add(track);
    }

    final List<String> removed = cached.keys
        .where((String path) => !present.contains(path))
        .toList();
    await _database.removeLocalTracks(removed);
    await _database.replaceLocalTracks(changed);
    return tracks;
  }

  static LocalTracksCompanion _rowFromTrack(Track track, FileStat stat) =>
      LocalTracksCompanion.insert(
        path: track.id,
        fileSize: stat.size,
        modifiedAt: stat.modified.millisecondsSinceEpoch,
        title: track.title,
        artist: track.artist,
        album: track.album,
        durationMs: Value(track.duration?.inMilliseconds),
        sampleRate: Value(track.sampleRate),
        bitrate: Value(track.bitrate),
        lyrics: Value(track.lyrics),
      );

  static Track _trackFromRow(LocalTrack row) => Track(
    id: row.path,
    uri: File(row.path).uri.toString(),
    title: row.title,
    artist: row.artist,
    album: row.album,
    duration: row.durationMs == null
        ? null
        : Duration(milliseconds: row.durationMs!),
    lyrics: row.lyrics,
    sampleRate: row.sampleRate,
    bitrate: row.bitrate,
    fileSize: row.fileSize,
  );
}
