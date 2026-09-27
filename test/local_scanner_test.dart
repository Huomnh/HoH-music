import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hoh_music/core/database/app_database.dart';
import 'package:hoh_music/core/audio/player_engine.dart';
import 'package:hoh_music/features/library/local_scanner.dart';

void main() {
  late Directory temp;
  late AppDatabase database;
  late LocalScanner scanner;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hoh-library-');
    database = AppDatabase(NativeDatabase.memory());
    scanner = LocalScanner(database: database);
  });

  tearDown(() async {
    await database.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('新增曲目入 Drift，重复扫描复用索引，删除文件清理记录', () async {
    final File first = File('${temp.path}${Platform.pathSeparator}one.mp3');
    final File second = File('${temp.path}${Platform.pathSeparator}two.mp3');
    await first.writeAsBytes(<int>[1, 2, 3]);
    await second.writeAsBytes(<int>[4, 5]);

    final List<Track> initial = await scanner.scan(<String>[temp.path]);
    expect(initial.map((Track track) => track.id).toSet(), <String>{
      first.path,
      second.path,
    });
    expect((await database.allLocalTracks()).length, 2);

    final List<Track> unchanged = await scanner.scan(<String>[temp.path]);
    expect(unchanged.map((Track track) => track.title).toSet(), <String>{
      'one',
      'two',
    });
    expect((await database.allLocalTracks()).length, 2);

    await second.delete();
    final List<Track> afterDelete = await scanner.scan(<String>[temp.path]);
    expect(afterDelete.map((Track track) => track.id), <String>[first.path]);
    expect((await database.allLocalTracks()).map((row) => row.path), <String>[
      first.path,
    ]);
  });
}
