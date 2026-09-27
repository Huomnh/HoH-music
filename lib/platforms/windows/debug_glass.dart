/// debug_glass.dart
///
/// 玻璃动效的调试开关与帧耗时统计。
///
/// 用处：GPU 占用是**只能实测**的指标，靠读代码猜不出来。这里留两个
/// 环境变量入口，让"高光流动是不是真的更省了"这件事可以被量出来，
/// 而不是靠感觉。
///
/// 触发方式（仅 Debug / Profile 构建生效，Release 直接跳过）：
/// - `HOH_DEBUG_SWEEP=1` —— 启动即打开「边框高光流动」，
///   免去每次手动点设置面板；
/// - `HOH_DEBUG_STATS=1` —— 每 5 秒往 stderr 打一次帧耗时统计
///   （帧数 / raster 平均 / p50 / p90，单位 ms）。
///
/// 例：
/// ```powershell
/// $env:HOH_DEBUG_STATS='1'; $env:HOH_DEBUG_SWEEP='1'
/// .\build\windows\x64\runner\Profile\hoh_music.exe 2> build\stats.log
/// ```
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/theme/performance_tier.dart';

/// 是否要求启动即开启高光流动。
bool get debugForceSweep =>
    !kReleaseMode && Platform.environment['HOH_DEBUG_SWEEP'] == '1';

/// 是否要求打印帧耗时统计。
bool get debugFrameStats =>
    !kReleaseMode && Platform.environment['HOH_DEBUG_STATS'] == '1';

/// 调试入口：可选地打开高光流动、并统计帧耗时。
///
/// 两个开关都没开时**不进入 widget 树**（见 [wanted]）。
class DebugGlass extends ConsumerStatefulWidget {
  const DebugGlass({super.key, required this.child});

  /// 被包裹的子树。
  final Widget child;

  /// 是否需要这个调试包装（两个环境变量都没设时为 false）。
  static bool get wanted => debugForceSweep || debugFrameStats;

  @override
  ConsumerState<DebugGlass> createState() => _DebugGlassState();
}

class _DebugGlassState extends ConsumerState<DebugGlass> {
  _FrameStatsRecorder? _recorder;

  @override
  void initState() {
    super.initState();

    if (debugForceSweep) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(glassOverridesProvider.notifier).setSweep(true);
        debugPrint('[DebugGlass] 已强制开启边框高光流动');
      });
    }

    if (debugFrameStats) {
      final _FrameStatsRecorder recorder = _FrameStatsRecorder();
      _recorder = recorder;
      SchedulerBinding.instance.addTimingsCallback(recorder.add);
      stderr.writeln('[DebugGlass] frame stats on (one line per 5s)');
    }
  }

  @override
  void dispose() {
    final _FrameStatsRecorder? recorder = _recorder;
    if (recorder != null) {
      SchedulerBinding.instance.removeTimingsCallback(recorder.add);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 汇总 [FrameTiming]，每 5 秒输出一行。
class _FrameStatsRecorder {
  final List<int> _rasterUs = <int>[];
  final List<int> _buildUs = <int>[];
  int _lastReportMs = DateTime.now().millisecondsSinceEpoch;

  void add(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      _rasterUs.add(t.rasterDuration.inMicroseconds);
      _buildUs.add(t.buildDuration.inMicroseconds);
    }

    final int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastReportMs < 5000 || _rasterUs.isEmpty) return;
    _lastReportMs = now;

    stderr.writeln(
      '[FrameStats] frames=${_rasterUs.length} '
      'raster avg=${_avg(_rasterUs)}ms p50=${_pct(_rasterUs, 0.50)}ms '
      'p90=${_pct(_rasterUs, 0.90)}ms | '
      'build avg=${_avg(_buildUs)}ms p90=${_pct(_buildUs, 0.90)}ms',
    );
    _rasterUs.clear();
    _buildUs.clear();
  }

  String _avg(List<int> values) =>
      (values.reduce((int a, int b) => a + b) / values.length / 1000)
          .toStringAsFixed(2);

  String _pct(List<int> values, double p) {
    final List<int> sorted = List<int>.of(values)..sort();
    final int index = ((sorted.length - 1) * p).round().clamp(
      0,
      sorted.length - 1,
    );
    return (sorted[index] / 1000).toStringAsFixed(2);
  }
}
