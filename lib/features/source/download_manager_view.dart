/// 下载管理页：查看进度、速度、默认目录和已完成文件。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/source_models.dart' show qualityLabel;
import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';
import 'download_manager.dart';

class DownloadManagerView extends ConsumerWidget {
  const DownloadManagerView({super.key});

  Future<void> _chooseDirectory(BuildContext context, WidgetRef ref) async {
    final String? path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择默认下载位置',
    );
    if (path == null || path.isEmpty) return;
    await ref.read(downloadDirectoryProvider.notifier).setDirectory(path);
  }

  Future<void> _locate(String path) async {
    if (path.isEmpty) return;
    final File file = File(path);
    if (!await file.exists()) return;
    if (Platform.isWindows) {
      await Process.run('explorer.exe', <String>['/select,${file.path}']);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>['-R', file.path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', <String>[file.parent.path]);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final DownloadManagerState state = ref.watch(downloadManagerProvider);
    final String directory =
        ref.watch(downloadDirectoryProvider).value ?? '加载中…';
    return GlassPanel(
      borderRadius: BorderRadius.circular(16),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.download_rounded, color: accent.primary, size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '下载管理',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      '查看进度、速度和已保存的歌曲',
                      style: TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () =>
                    ref.read(downloadManagerProvider.notifier).clearCompleted(),
                icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                label: const Text('清理完成'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.folder_outlined, size: 18, color: accent.primary),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    directory,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () => _chooseDirectory(context, ref),
                  child: const Text('更改位置'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: state.tasks.isEmpty
                ? const Center(
                    child: Text(
                      '还没有下载任务',
                      style: TextStyle(color: AppColors.textTertiary),
                    ),
                  )
                : ListView.separated(
                    itemCount: state.tasks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int index) {
                      final DownloadTask task = state.tasks[index];
                      return _DownloadTaskTile(
                        task: task,
                        onLocate: () => _locate(task.path),
                        onPause: () => ref
                            .read(downloadManagerProvider.notifier)
                            .pause(task.id),
                        onResume: () => ref
                            .read(downloadManagerProvider.notifier)
                            .resume(task.id),
                        onDelete: () => ref
                            .read(downloadManagerProvider.notifier)
                            .delete(task.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _DownloadTaskTile extends StatelessWidget {
  const _DownloadTaskTile({
    required this.task,
    required this.onLocate,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
  });

  final DownloadTask task;
  final VoidCallback onLocate;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final bool active = task.status == DownloadTaskStatus.downloading;
    final bool paused = task.status == DownloadTaskStatus.paused;
    final String status = switch (task.status) {
      DownloadTaskStatus.downloading =>
        '${(task.progress * 100).toStringAsFixed(0)}% · ${formatDownloadSpeed(task.speedBytes)}',
      DownloadTaskStatus.completed => '已完成',
      DownloadTaskStatus.failed => '失败：${task.error}',
      DownloadTaskStatus.queued => '等待中',
      DownloadTaskStatus.paused => '已暂停 · 可继续下载',
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active
              ? accent.primary.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                active ? Icons.downloading_rounded : Icons.audio_file_rounded,
                color: active ? accent.primary : const Color(0xAAFFFFFF),
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      qualityLabel(task.quality),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (task.status == DownloadTaskStatus.completed)
                IconButton(
                  tooltip: '定位文件',
                  onPressed: task.status == DownloadTaskStatus.completed
                      ? onLocate
                      : null,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                ),
              if (active)
                IconButton(
                  tooltip: '暂停',
                  onPressed: onPause,
                  icon: const Icon(
                    Icons.pause_circle_outline_rounded,
                    size: 19,
                  ),
                ),
              if (paused || task.status == DownloadTaskStatus.failed)
                IconButton(
                  tooltip: '继续',
                  onPressed: onResume,
                  icon: const Icon(Icons.play_circle_outline_rounded, size: 19),
                ),
              IconButton(
                tooltip: '删除任务及临时文件',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: task.status == DownloadTaskStatus.failed
                        ? AppColors.neonMagenta
                        : AppColors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ),
              if (task.total > 0)
                Text(
                  '${_size(task.received)} / ${_size(task.total)}',
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
          if (active || paused) ...<Widget>[
            const SizedBox(height: 7),
            LinearProgressIndicator(
              value: task.progress > 0 ? task.progress : null,
              minHeight: 3,
              color: accent.primary,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
            ),
          ],
          if (task.path.isNotEmpty &&
              (task.status == DownloadTaskStatus.completed || paused))
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                task.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0x66FFFFFF), fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
