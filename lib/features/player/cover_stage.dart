/// cover_stage.dart
///
/// 播放页封面舞台：**方形专辑封面**（歌词与歌曲信息在主区右侧）。
///
/// 分层：
/// ```
/// Stack
///   ├── 旋转层：黑胶圆盘（圆心是圆形裁切的专辑封面）+ 盘面白色小标记
///   └── 固定层：圆角方形专辑封面（带弥散投影，永不旋转）
/// ```
///
/// 用户可调的项在「外观设置 → 封面黑胶」里：是否开启旋转（关掉就是一张静态图，省帧）。
/// 0.0.21 起黑胶由侧边栏顶部的控制台承载，方形封面单独留在主区。
///
/// ⚠️ 性能（照抄 0.0.8 的教训）：
/// - 旋转只用 `Ticker` + `ValueNotifier` + `AnimatedBuilder` 驱动一个
///   `Transform.rotate`，**不 setState**，封面与圆盘本体（`child`）不重建；
/// - **暂停 / 关闭旋转时不跑 Ticker**，不产生任何帧；
/// - 旋转层用 `RepaintBoundary` 隔离，不让整个播放页跟着重绘。
///
/// 频谱柱（方案 A 的第 4 层）**没做**：media_kit 没有暴露 PCM / visualizer 流，
/// 拿不到实时采样数据；做一个"假频谱"没有意义。等接入真实采样后再说，
/// 见 `docs/项目进度交接.md` 的遗留项。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/player_providers.dart';
import '../../core/metadata/cover_art.dart';
import '../../shared/theme/app_accent.dart';
import 'cover_style.dart';

/// 专辑封面（**只有方形封面**，不含黑胶）。
///
/// 0.0.20 调整：黑胶从封面区搬走（现在是侧边栏控制台顶部的 [VinylRecord]），
/// 这里只负责那张方形专辑封面 —— 带圆角与弥散投影，永不旋转。
class CoverStage extends StatelessWidget {
  /// 创建封面。
  const CoverStage({super.key, required this.size});

  /// 边长。
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    return _SquareCover(size: size, accent: accent);
  }
}

/// 方形专辑封面。
class _SquareCover extends ConsumerWidget {
  const _SquareCover({required this.size, required this.accent});

  final double size;
  final AppAccent accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Uint8List? cover = ref.watch(currentCoverProvider).value;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.42),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: accent.primary.withValues(alpha: 0.18),
            blurRadius: 44,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: cover != null
            ? Image.memory(
                cover,
                fit: BoxFit.cover,
                width: size,
                height: size,
                // 封面数据坏掉时退回占位，不留白
                errorBuilder: (
                  BuildContext context,
                  Object error,
                  StackTrace? _,
                ) => _CoverPlaceholder(accent: accent, size: size),
              )
            : _CoverPlaceholder(accent: accent, size: size),
      ),
    );
  }
}

/// 没有封面时的渐变占位。
class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({required this.accent, required this.size});

  final AppAccent accent;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[accent.secondary, accent.tertiary, accent.primary],
          stops: const <double>[0.0, 0.45, 1.0],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: size * 0.22,
          color: Colors.white.withValues(alpha: 0.42),
        ),
      ),
    );
  }
}

/// 黑胶唱片（旋转层）。
///
/// 圆心是圆形裁切的专辑封面，盘面带纹路、金属亮边与 4×12 白色小标记；
/// 播放时匀速旋转，暂停定格不回正。
/// 是否旋转由「外观设置 → 封面黑胶」控制（关掉后整块静止，不跑 Ticker）。
class VinylRecord extends ConsumerStatefulWidget {
  const VinylRecord({super.key, required this.size, this.labelRatio = 0.46});

  /// 直径。
  final double size;

  /// 圆心封面占直径的比例。
  final double labelRatio;

  /// 转一圈的秒数。
  ///
  /// 一开始按真实转速写的（33⅓ 转/分 → 1.8 秒一圈），结果用户反馈
  /// 「黑胶的转动速度太快了 不够优雅」——真机大小下转得像个加载指示器。
  /// 0.0.21 放慢到 6 秒一圈（10 转/分），看着才像唱片在转。
  static const double secondsPerTurn = 6.0;

  @override
  ConsumerState<VinylRecord> createState() => _VinylRecordState();
}

class _VinylRecordState extends ConsumerState<VinylRecord>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_onTick);
  final ValueNotifier<double> _turns = ValueNotifier<double>(0);
  Duration _last = Duration.zero;
  bool _spinning = false;
  bool _appActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    final bool playing = ref.read(playerControllerProvider).playing;
    final bool spin = ref.read(coverStageStyleProvider).value?.spin ?? true;
    _sync(
      playing && spin && _appActive && TickerMode.valuesOf(context).enabled,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _turns.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final double dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0) return;
    _turns.value = (_turns.value + dt / VinylRecord.secondsPerTurn) % 1.0;
  }

  void _sync(bool shouldSpin) {
    if (shouldSpin == _spinning) return;
    _spinning = shouldSpin;
    if (shouldSpin) {
      _last = Duration.zero;
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppAccent accent = AppAccent.of(context);
    final bool playing = ref.watch(
      playerControllerProvider.select((PlayerUiState s) => s.playing),
    );
    final bool spin = ref.watch(coverStageStyleProvider).value?.spin ?? true;
    final Uint8List? cover = ref.watch(currentCoverProvider).value;
    // 暂停、窗口最小化（TickerMode 关闭）或应用不活跃时都释放 ticker。
    final bool shouldSpin =
        playing && spin && _appActive && TickerMode.valuesOf(context).enabled;

    ref.listen(
      playerControllerProvider.select((PlayerUiState s) => s.playing),
      (bool? previous, bool next) => _sync(playing && spin),
    );
    if (_spinning != shouldSpin) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync(shouldSpin);
      });
    }

    final double labelSize = widget.size * widget.labelRatio;

    final Widget record = RepaintBoundary(
      child: CustomPaint(
        painter: _VinylPainter(accent: accent.primary),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Center(
            // 圆心：圆形裁切的专辑封面
            child: ClipOval(
              child: SizedBox(
                width: labelSize,
                height: labelSize,
                child: cover != null
                    ? Image.memory(
                        cover,
                        fit: BoxFit.cover,
                        errorBuilder: (
                          BuildContext context,
                          Object error,
                          StackTrace? _,
                        ) => _labelFallback(accent),
                      )
                    : _labelFallback(accent),
              ),
            ),
          ),
        ),
      ),
    );

    return AnimatedBuilder(
      animation: _turns,
      child: record,
      builder: (BuildContext context, Widget? child) =>
          Transform.rotate(angle: _turns.value * 2 * math.pi, child: child),
    );
  }

  Widget _labelFallback(AppAccent accent) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[
            accent.secondary,
            accent.tertiary,
            const Color(0xFF120A22),
          ],
          stops: const <double>[0.0, 0.55, 1.0],
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// 黑胶盘面：深黑径向渐变 + 纹路 + 金属亮边 + 盘面白色小标记。
class _VinylPainter extends CustomPainter {
  const _VinylPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = size.shortestSide / 2;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    // 盘体：深黑径向渐变（中间略亮，边缘更黑）
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          colors: <Color>[
            Color(0xFF1A1424),
            Color(0xFF0B0714),
            Color(0xFF05030A),
          ],
          stops: <double>[0.0, 0.62, 1.0],
        ).createShader(rect),
    );

    // 黑胶纹路
    final Paint groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = Colors.white.withValues(alpha: 0.045);
    for (double r = radius * 0.52; r < radius * 0.98; r += radius * 0.055) {
      canvas.drawCircle(center, r, groove);
    }

    // 边缘 2dp 金属亮边
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..shader = SweepGradient(
          colors: <Color>[
            Colors.white.withValues(alpha: 0.42),
            accent.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0.10),
            accent.withValues(alpha: 0.30),
            Colors.white.withValues(alpha: 0.42),
          ],
          stops: const <double>[0.0, 0.25, 0.5, 0.75, 1.0],
        ).createShader(rect),
    );

    // 圆心外圈
    canvas.drawCircle(
      center,
      radius * 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.7),
    );

    // 盘面白色小标记（随唱片旋转，4×12 的小方块）——转不转一眼就能看出来
    final double markerR = radius * 0.82;
    canvas.save();
    canvas.translate(center.dx, center.dy - markerR);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: 4, height: 12),
        const Radius.circular(1.5),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VinylPainter oldDelegate) => oldDelegate.accent != accent;
}
