/// app_database.dart
///
/// Drift 数据库入口，启用 SQLite WAL 读写模式。
library;

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';
part 'app_database.g.dart';

@DriftDatabase(tables: <Type>[LocalTracks])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(
        executor ??
            driftDatabase(
              name: 'hoh_music',
              web: DriftWebOptions(
                sqlite3Wasm: Uri.parse('sqlite3.wasm'),
                driftWorker: Uri.parse('drift_worker.js'),
              ),
            ),
      );

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) => m.createAll(),
    onUpgrade: (Migrator m, int from, int to) async {
      // 预留后续专辑、歌手与扫描来源字段的迁移入口。
    },
    beforeOpen: (OpeningDetails details) async {
      await customStatement('PRAGMA journal_mode = WAL');
    },
  );

  Future<List<LocalTrack>> allLocalTracks() => select(localTracks).get();

  Future<void> replaceLocalTracks(Iterable<LocalTracksCompanion> rows) async {
    await batch((Batch batch) {
      batch.insertAllOnConflictUpdate(localTracks, rows.toList());
    });
  }

  Future<void> removeLocalTracks(Iterable<String> paths) async {
    final List<String> values = paths.toList(growable: false);
    if (values.isEmpty) return;
    await (delete(
      localTracks,
    )..where((LocalTracks t) => t.path.isIn(values))).go();
  }

  /// 清空本地曲目索引，不删除任何用户音频文件。
  Future<void> clearLocalTracks() => delete(localTracks).go();
}

final AppDatabase appDatabase = AppDatabase();

Future<void> closeAppDatabase() => appDatabase.close();
