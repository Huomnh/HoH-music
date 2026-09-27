/// tables.dart
///
/// 本地音乐库数据表定义。
library;

import 'package:drift/drift.dart';

/// 本地文件的增量索引。
///
/// `path` 是本地文件的稳定主键；`modifiedAt` 与 `fileSize` 用来判断是否
/// 需要重新读取标签，避免每次进入音乐库都解析整棵目录。
class LocalTracks extends Table {
  TextColumn get path => text()();
  IntColumn get fileSize => integer()();
  IntColumn get modifiedAt => integer()();
  TextColumn get title => text()();
  TextColumn get artist => text()();
  TextColumn get album => text()();
  IntColumn get durationMs => integer().nullable()();
  IntColumn get sampleRate => integer().nullable()();
  IntColumn get bitrate => integer().nullable()();
  TextColumn get lyrics => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{path};
}
