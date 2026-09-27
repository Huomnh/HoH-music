/// 在线下载任务、历史记录与默认下载目录。
library;

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/source/source_models.dart';
import 'online_track_download.dart';

const String _kDownloadDirectory = 'downloads.directory';
const String _kDownloadHistory = 'downloads.history';

enum DownloadTaskStatus { queued, downloading, paused, completed, failed }

class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.title,
    required this.path,
    required this.status,
    this.received = 0,
    this.total = 0,
    this.speedBytes = 0,
    this.error = '',
    this.track,
    this.quality = '320k',
  });

  final String id;
  final String title;
  final String path;
  final DownloadTaskStatus status;
  final int received;
  final int total;
  final int speedBytes;
  final String error;
  final OnlineTrack? track;
  final String quality;

  double get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : 0;

  DownloadTask copyWith({
    DownloadTaskStatus? status,
    int? received,
    int? total,
    int? speedBytes,
    String? error,
    String? path,
    OnlineTrack? track,
    String? quality,
  }) => DownloadTask(
    id: id,
    title: title,
    path: path ?? this.path,
    status: status ?? this.status,
    received: received ?? this.received,
    total: total ?? this.total,
    speedBytes: speedBytes ?? this.speedBytes,
    error: error ?? this.error,
    track: track ?? this.track,
    quality: quality ?? this.quality,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'path': path,
    'status': status.name,
    'received': received,
    'total': total,
    'speedBytes': speedBytes,
    'error': error,
    'track': track?.toJson(),
    'quality': quality,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
    id: json['id']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    path: json['path']?.toString() ?? '',
    status: DownloadTaskStatus.values.firstWhere(
      (DownloadTaskStatus value) => value.name == json['status'],
      orElse: () => DownloadTaskStatus.completed,
    ),
    received: int.tryParse('${json['received'] ?? 0}') ?? 0,
    total: int.tryParse('${json['total'] ?? 0}') ?? 0,
    speedBytes: int.tryParse('${json['speedBytes'] ?? 0}') ?? 0,
    error: json['error']?.toString() ?? '',
    track: json['track'] is Map
        ? OnlineTrack.fromJson(
            (json['track'] as Map<Object?, Object?>).map(
              (Object? key, Object? value) => MapEntry(key.toString(), value),
            ),
          )
        : null,
    quality: json['quality']?.toString() ?? '320k',
  );
}

class DownloadManagerState {
  const DownloadManagerState({this.tasks = const <DownloadTask>[]});

  final List<DownloadTask> tasks;
}

final downloadManagerProvider =
    NotifierProvider<DownloadManagerController, DownloadManagerState>(
      DownloadManagerController.new,
    );

class DownloadManagerController extends Notifier<DownloadManagerState> {
  Timer? _persistTimer;
  final Map<String, CancelToken> _tokens = <String, CancelToken>{};
  final Set<String> _pauseRequested = <String>{};

  @override
  DownloadManagerState build() {
    // 下载任务属于应用级状态，不随下载管理页离开而销毁。
    ref.keepAlive();
    ref.onDispose(() {
      _persistTimer?.cancel();
      for (final CancelToken token in _tokens.values) {
        token.cancel('应用关闭');
      }
    });
    _restore();
    return const DownloadManagerState();
  }

  Future<void> _restore() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_kDownloadHistory);
    if (raw == null || raw.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        final List<DownloadTask> restored = decoded
            .whereType<Map<Object?, Object?>>()
            .map(
              (Map<Object?, Object?> item) => DownloadTask.fromJson(
                item.map(
                  (Object? key, Object? value) =>
                      MapEntry(key.toString(), value),
                ),
              ),
            )
            .where((DownloadTask task) => task.id.isNotEmpty)
            .map(
              (DownloadTask task) =>
                  task.status == DownloadTaskStatus.downloading
                  ? task.copyWith(
                      status: DownloadTaskStatus.failed,
                      error: '应用关闭时下载未完成',
                    )
                  : task,
            )
            .take(50)
            .toList();
        final Set<String> currentIds = state.tasks
            .map((DownloadTask task) => task.id)
            .toSet();
        state = DownloadManagerState(
          tasks: <DownloadTask>[
            ...state.tasks,
            ...restored.where(
              (DownloadTask task) => !currentIds.contains(task.id),
            ),
          ].take(50).toList(growable: false),
        );
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), _flushPersist);
  }

  Future<void> _flushPersist() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kDownloadHistory,
      jsonEncode(
        state.tasks.map((DownloadTask task) => task.toJson()).toList(),
      ),
    );
  }

  String begin(
    String title,
    String path, {
    OnlineTrack? track,
    String quality = '320k',
  }) {
    final String id = '${DateTime.now().microsecondsSinceEpoch}';
    final DownloadTask task = DownloadTask(
      id: id,
      title: title,
      path: path,
      status: DownloadTaskStatus.downloading,
      track: track,
      quality: quality,
    );
    state = DownloadManagerState(tasks: <DownloadTask>[task, ...state.tasks]);
    _persist();
    return id;
  }

  /// 启动独立下载任务。调用方页面销毁后，任务仍由应用级 provider 持续运行。
  Future<void> start(OnlineTrack track, {required String quality}) async {
    final String directory = await ref.read(downloadDirectoryProvider.future);
    final String provisionalPath =
        '$directory${Platform.pathSeparator}${track.title}';
    final String taskId = begin(
      track.title,
      provisionalPath,
      track: track,
      quality: quality,
    );
    await _run(taskId, track, quality: quality);
  }

  Future<void> _run(
    String taskId,
    OnlineTrack track, {
    required String quality,
    String? outputPath,
  }) async {
    final CancelToken token = CancelToken();
    _tokens[taskId] = token;
    try {
      final File saved = await OnlineTrackDownloadService().download(
        ref,
        track,
        outputPath == null
            ? (await ref.read(downloadDirectoryProvider.future))
            : File(outputPath).parent.path,
        quality: quality,
        outputPath: outputPath,
        cancelToken: token,
        onResolvedPath: (String path) => updatePath(taskId, path),
        onTaskProgress: (int received, int total, int speedBytes) => update(
          taskId,
          received: received,
          total: total,
          speedBytes: speedBytes,
        ),
      );
      complete(taskId, saved.path);
    } catch (error) {
      if (_pauseRequested.remove(taskId) || token.isCancelled) {
        _replace(
          taskId,
          (DownloadTask task) => task.copyWith(
            status: DownloadTaskStatus.paused,
            speedBytes: 0,
            error: '',
          ),
        );
      } else {
        fail(taskId, '$error');
      }
    } finally {
      _tokens.remove(taskId);
    }
  }

  void updatePath(String id, String path) {
    _replace(id, (DownloadTask task) => task.copyWith(path: path));
  }

  void pause(String id) {
    final DownloadTask? task = _task(id);
    final CancelToken? token = _tokens[id];
    if (task == null || task.status != DownloadTaskStatus.downloading) return;
    _pauseRequested.add(id);
    _replace(
      id,
      (DownloadTask value) =>
          value.copyWith(status: DownloadTaskStatus.paused, speedBytes: 0),
    );
    token?.cancel('用户暂停下载');
  }

  Future<void> resume(String id) async {
    final DownloadTask? task = _task(id);
    final OnlineTrack? track = task?.track;
    if (task == null || track == null) return;
    if (task.status != DownloadTaskStatus.paused &&
        task.status != DownloadTaskStatus.failed) {
      return;
    }
    _replace(
      id,
      (DownloadTask value) =>
          value.copyWith(status: DownloadTaskStatus.downloading, error: ''),
    );
    final bool hasAudioExtension = RegExp(
      r'\.(mp3|flac|m4a|aac|wav|ogg|opus)(?:\.part)?$',
      caseSensitive: false,
    ).hasMatch(task.path);
    await _run(
      id,
      track,
      quality: task.quality,
      outputPath: hasAudioExtension ? task.path : null,
    );
  }

  Future<void> delete(String id) async {
    final DownloadTask? task = _task(id);
    if (task == null) return;
    _pauseRequested.add(id);
    _tokens[id]?.cancel('用户删除下载');
    final File output = File(task.path);
    final File partial = File('${task.path}.part');
    for (final File file in <File>[output, partial]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    state = DownloadManagerState(
      tasks: state.tasks.where((DownloadTask value) => value.id != id).toList(),
    );
    _persist();
  }

  void update(
    String id, {
    required int received,
    required int total,
    required int speedBytes,
  }) {
    _replace(
      id,
      (DownloadTask task) => task.copyWith(
        received: received,
        total: total,
        speedBytes: speedBytes,
        status: DownloadTaskStatus.downloading,
      ),
    );
  }

  void complete(String id, String path) {
    _replace(
      id,
      (DownloadTask task) => task.copyWith(
        path: path,
        received: task.total > 0 ? task.total : task.received,
        status: DownloadTaskStatus.completed,
        speedBytes: 0,
      ),
    );
  }

  void fail(String id, String error) {
    _replace(
      id,
      (DownloadTask task) => task.copyWith(
        status: DownloadTaskStatus.failed,
        error: error,
        speedBytes: 0,
      ),
    );
  }

  void remove(String id) {
    unawaited(delete(id));
  }

  void clearCompleted() {
    state = DownloadManagerState(
      tasks: state.tasks
          .where(
            (DownloadTask task) => task.status != DownloadTaskStatus.completed,
          )
          .toList(),
    );
    _persist();
  }

  void _replace(String id, DownloadTask Function(DownloadTask) update) {
    state = DownloadManagerState(
      tasks: <DownloadTask>[
        for (final DownloadTask task in state.tasks)
          task.id == id ? update(task) : task,
      ],
    );
    _persist();
  }

  DownloadTask? _task(String id) {
    for (final DownloadTask task in state.tasks) {
      if (task.id == id) return task;
    }
    return null;
  }
}

final downloadDirectoryProvider =
    AsyncNotifierProvider<DownloadDirectoryController, String>(
      DownloadDirectoryController.new,
    );

class DownloadDirectoryController extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kDownloadDirectory) ?? await _defaultDirectory();
  }

  Future<void> setDirectory(String directory) async {
    final Directory target = Directory(directory);
    await target.create(recursive: true);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDownloadDirectory, target.path);
    state = AsyncData<String>(target.path);
  }

  static Future<String> _defaultDirectory() async {
    final Directory base =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    return '${base.path}${Platform.pathSeparator}HoH music';
  }
}

String formatDownloadSpeed(int bytes) {
  if (bytes < 1024) return '$bytes B/s';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB/s';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB/s';
}
