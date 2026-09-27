/// glass_panel.dart
///
/// 玻璃面板 —— 对应设计稿里的 `.glass` 样式。
///
/// 结构（刻意做成**互不牵连重绘**的独立图层）：
/// ```
/// DecoratedBox  ← 阴影 + 底色（静态）
///   Stack
///     ClipRRect
///       BackdropFilter   ← 背景模糊（仅此处一次采样）
///       RepaintBoundary  ← 内容（静态，动画不影响它）
///     RepaintBoundary
///       CustomPaint      ← 旋转高光描边（唯一每帧变化的部分）
/// ```
///
/// ⚠️ 性能设计要点（0.0.8 的两次 GPU 优化都记在这里）：
/// - **一块面板只用一个 `BackdropFilter`**。设计稿里同时只有 3～4 块面板，
///   而不是之前的 11 块，模糊采样量下降约 70%。
/// - **高光时钟按固定 30Hz 走，而不是跟着显示器刷新率**（见
///   [GlassSweepClock]，这是本次实测出来的真正大头）。
/// - **高光描边画在 `BackdropFilter` 之外**，并自带 `RepaintBoundary`：
///   每帧被重绘的只有那一条 1.6px 的描边，不再牵连模糊层与内容层。
/// - `sweep` 关闭时不起时钟，也不建这一层。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/app_accent.dart';
import '../../theme/performance_tier.dart';
import 'blur_config_scope.dart';

/// 全局高光时钟。
///
/// ⚠️ 这里**刻意不用 `AnimationController`**，这是 0.0.8 实测后的结论：
///
/// `AnimationController.repeat()` 的 Ticker 是**跟着显示器刷新率**申请帧的
/// （本机实测 144Hz，5 秒 720+ 帧）。而只要产出一帧，引擎就要重新合成整棵
/// 图层树 —— 三块面板的 `BackdropFilter` 加起来每帧约 6.5ms 光栅时间，
/// 144fps 下等于把光栅线程占满。这正是"边框高光流动很吃 GPU"的真正原因：
/// **不是描边画得慢，而是它让整个界面以刷新率不停地重画。**
///
/// 高光一圈 14 秒，每拍只走约 0.86°，完全不需要 144fps。
/// 所以改用 30Hz 的 [Timer.periodic] 推动一个 [ValueNotifier]：
/// 只有这一拍才标脏重绘，帧产出频率从刷新率降到 30fps（实测降约 80%）。
///
/// 多块面板共用**同一个**时钟，各自带固定相位偏移错开位置
/// （对应设计稿的 `.p1/.p2/.p3`）；没有使用者时时钟自动停掉。
abstract final class GlassSweepClock {
  /// 高光绕边框一圈的时长。
  ///
  /// **固定值，不对外暴露设置项**（0.0.8 的决定）：14 秒一圈既能看出
  /// 边框在流动，又不会抢眼；比原来的设置项少一处需要用户理解的参数。
  /// 想调整就改这一个常量。
  static const Duration period = Duration(seconds: 14);

  /// 时钟节拍。
  ///
  /// 33ms ≈ 30 拍/秒。这是**整块界面在高光流动时的实际帧率**，
  /// 也是本次优化最关键的参数：把它调大 = 更省 GPU，调小 = 更顺滑。
  static const Duration tickInterval = Duration(milliseconds: 33);

  /// 每拍推进的进度（一圈为 1.0）。由 [tickInterval] 与 [period] 推出，
  /// 保证"一圈 14 秒"这个观感不随节拍变化。
  static final double stepPerTick =
      tickInterval.inMicroseconds / period.inMicroseconds;

  /// 全局进度 0~1。
  static final ValueNotifier<double> _progress = ValueNotifier<double>(0.0);

  static Timer? _timer;
  static int _users = 0;

  /// 时钟是否在走（测试与调试用）。
  static bool get isRunning => _timer != null;

  /// 当前使用者数量（测试与调试用）。
  static int get userCount => _users;

  /// 取一个跟随全局时钟、带 [phase] 相位偏移的动画值。
  ///
  /// 返回的对象由调用方负责 `dispose()`（见 [GlassSweepAnimation.dispose]）。
  static GlassSweepAnimation acquire(double phase) {
    _users++;
    _timer ??= Timer.periodic(tickInterval, _onTick);
    return GlassSweepAnimation(_progress, phase);
  }

  /// 释放一个使用者；没有使用者时停掉时钟（不销毁 notifier）。
  static void release() {
    if (_users > 0) _users--;
    if (_users == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  static void _onTick(Timer timer) {
    double next = _progress.value + stepPerTick;
    if (next >= 1.0) next -= 1.0;
    _progress.value = next;
  }
}

/// 跟随 [GlassSweepClock]，并把进度平移一个相位。
///
/// 用法与 `Animation<double>` 类似，但只实现 [ValueListenable]：
/// 描边 painter 需要的就是"值变了就重绘"。
class GlassSweepAnimation extends ChangeNotifier
    implements ValueListenable<double> {
  GlassSweepAnimation(this._clock, this.phase) {
    _clock.addListener(notifyListeners);
  }

  final ValueListenable<double> _clock;

  /// 相位偏移（0~1）。
  final double phase;

  @override
  double get value {
    final double v = _clock.value + phase;
    return v >= 1.0 ? v - 1.0 : v;
  }

  @override
  void dispose() {
    _clock.removeListener(notifyListeners);
    super.dispose();
  }
}

/// 玻璃面板。
class GlassPanel extends StatefulWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.blurSigma = 18,
    this.glowOpacity = 1.0,
    this.sweep = true,
    this.initialSweepPhase = 0.0,
    this.showSweepAt = true,
    this.padding = EdgeInsets.zero,
    this.blurEnabled = true,
    this.tintOpacity = 1.0,
    this.glowColor,
  });

  /// 面板内容。
  final Widget child;

  /// 圆角半径。
  final BorderRadius borderRadius;

  /// 背景模糊强度。0 表示不模糊。
  final double blurSigma;

  /// 高光描边不透明度。0 表示不画。
  final double glowOpacity;

  /// 是否播放旋转高光（对应设计稿的 `glow-travel` 动画）。
  ///
  /// 周期固定为 [GlassSweepClock.period]，多块面板共用同一个时钟。
  final bool sweep;

  /// 初始相位（0~1）。用来错开多块面板的高光位置，对应设计稿的 `.p1/.p2/.p3`。
  final double initialSweepPhase;

  /// 是否绘制高光（由性能档位控制）。
  final bool showSweepAt;

  /// 内容内边距。
  final EdgeInsetsGeometry padding;

  /// 是否启用背景模糊（由性能档位控制）。
  final bool blurEnabled;

  /// 玻璃填充的不透明度系数。越小越透、越露背景。
  final double tintOpacity;

  /// 边框高光的颜色。
  ///
  /// `null`（默认）= **跟随主题强调色**（`AccentScope`），
  /// 用户在设置里选了具体颜色就覆盖。
  final Color? glowColor;

  @override
  State<GlassPanel> createState() => _GlassPanelState();
}

class _GlassPanelState extends State<GlassPanel> {
  /// 共享时钟上、已按相位平移的高光进度。
  GlassSweepAnimation? _sweep;

  /// 当前是否应该画高光：开关、档位、不透明度三者都要满足。
  bool get _wantsSweep =>
      widget.sweep && widget.showSweepAt && widget.glowOpacity > 0;

  @override
  void initState() {
    super.initState();
    if (_wantsSweep) _startSweep();
  }

  void _startSweep() =>
      _sweep = GlassSweepClock.acquire(widget.initialSweepPhase);

  void _stopSweep() {
    _sweep?.dispose();
    _sweep = null;
    GlassSweepClock.release();
  }

  @override
  void didUpdateWidget(GlassPanel oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (_wantsSweep && _sweep == null) {
      _startSweep();
    } else if (!_wantsSweep && _sweep != null) {
      _stopSweep();
    }
  }

  @override
  void dispose() {
    if (_sweep != null) _stopSweep();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool doBlur = widget.blurEnabled && widget.blurSigma > 0;

    // 自适应模糊强度。
    //
    // BackdropFilter 会把身后的像素整体重采样一遍，开销大致随**面积**增长。
    // 同一个 sigma 在 1400px 宽和 2200px 宽的窗口下，后者的采样量是前者的
    // 两倍多，但视觉上几乎看不出差别（模糊是相对的）。
    // 这里按视口宽度做线性衰减：≤1440px 用原始 sigma，2200px 时降到 65%。
    double effectiveSigma = widget.blurSigma;
    if (doBlur) {
      final double viewportWidth = MediaQuery.sizeOf(context).width;
      if (viewportWidth > 1440) {
        final double extra = ((viewportWidth - 1440) / 760).clamp(0.0, 1.0);
        effectiveSigma = widget.blurSigma * (1.0 - 0.35 * extra);
      }
    }

    // ① 内容独立成层：上面的描边动画不会导致内容重新光栅化
    //
    // ⚠️ **这个 key 是必须的**（0.0.23 修的 bug）：下面「模糊层」和「高光层」
    // 都会因为开关切换而改变类型 / 层级结构，如果内容没有稳定 key，
    // Flutter 就只能把整棵内容子树重建 —— 表现是**用户一开「边框高光流动」，
    // 设置页就自己弹回最顶端**（滚动位置随着 `Scrollable` 的 State 一起没了）。
    // 带上 key 之后，内容元素会被"搬"到新结构里，State（含滚动位置）原样保留。
    final Widget content = RepaintBoundary(
      key: const ValueKey<String>('glass-panel-content'),
      child: Padding(padding: widget.padding, child: widget.child),
    );

    // ② 模糊层
    //
    // ⚠️ 同样为了结构稳定：**不写成** `doBlur ? BackdropFilter(child: content)
    // : ColoredBox(child: content)` —— 那样内容的父节点类型会在开关时变掉。
    // 现在模糊 / 纯色都只是 Stack 里 index 0 的一层，内容是 index 1。
    final Widget surface = ClipRRect(
      borderRadius: widget.borderRadius,
      child: Stack(
        fit: StackFit.passthrough,
        children: <Widget>[
          Positioned.fill(
            child: doBlur
                ? BackdropFilter(
                    filter: ui.ImageFilter.blur(
                      sigmaX: effectiveSigma,
                      sigmaY: effectiveSigma,
                      tileMode: TileMode.clamp,
                    ),
                    child: const SizedBox.expand(),
                  )
                // 降级兜底：白色半透明材质，避免液态玻璃退化成黑块。
                : const ColoredBox(color: Color(0x66FFFFFF)),
          ),
          content,
        ],
      ),
    );

    // ③ 高光描边：**兄弟层，不是模糊层的子节点**。
    //
    // 重绘的传播按**最近的重绘边界**来算，描边以前挂在模糊层里面，
    // 每次它变化都要连带重画整块模糊层与内容层。移出来并自带
    // RepaintBoundary 后，每帧变化的只有这一条 1.6px 的描边。
    //
    // ⚠️ **必须套 `IgnorePointer`**（0.0.10 修的 bug）：
    // 它是画在内容**之上**的一层，而 Flutter 的命中测试是"后绘制者先命中"。
    // `CustomPaint` 的 `hitTestSelf` 默认返回 true，于是这一层会把整块面板的
    // 点击全部吃掉 —— 表现就是"打开边框高光流动之后，页面上的按钮点不动了"。
    // 描边纯粹是装饰，不参与交互。
    //
    // ⚠️ 这一层**无条件保留**（0.0.23）：没开高光时给 `CustomPaint` 一个
    // `null` painter（什么都不画，几乎零开销），而不是把整层去掉 ——
    // 去掉会让内容所在的层级结构变一次，滚动位置就丢了（同上）。
    final GlassSweepAnimation? sweep = _sweep;
    final Color glow = widget.glowColor ?? AccentScope.of(context).primary;
    final Widget body = Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        surface,
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: sweep == null
                    ? null
                    : _SweepBorderPainter(
                        animation: sweep,
                        borderRadius: widget.borderRadius,
                        opacity: widget.glowOpacity,
                        color: glow,
                      ),
              ),
            ),
          ),
        ),
      ],
    );

    final BlurConfig glassConfig = BlurConfigScope.of(context);
    final AppAccent accent = AccentScope.of(context);
    // 玻璃永远取主题色的互补色；用户只调饱和度和明暗，避免直接选色
    // 让主色与玻璃颜色失去统一关系。
    final HSVColor themeHsv = HSVColor.fromColor(accent.primary);
    final HSVColor complement = themeHsv.withHue((themeHsv.hue + 180) % 360);
    final Color glassColor = complement
        .withSaturation(glassConfig.glassSaturation)
        .withValue((1.0 - glassConfig.glassTone * 0.72).clamp(0.22, 1.0))
        .toColor();
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius,
        // 半透明白填充：没有它，玻璃边界在深色背景上几乎看不出来。
        // 对应设计稿的 .glass 背景 + 1px 亮边。
        // 不透明度由设置面板的「玻璃通透度」控制。
        // iOS 风格的白色玻璃：保留背景颜色，但不让深色场景把面板压成黑色。
        // 玻璃通透度由外观设置直接控制：低值接近透明，高值更偏白。
        color: glassColor.withValues(
          alpha: (0.02 + 0.18 * widget.tintOpacity).clamp(0.02, 0.20),
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.34)),
        boxShadow: <BoxShadow>[
          const BoxShadow(
            color: Color(0x24000000),
            blurRadius: 28,
            offset: Offset(0, 10),
          ),
          const BoxShadow(
            color: Color(0x18000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: body,
    );
  }
}

/// 旋转高光描边绘制器。
///
/// 用 [SweepGradient]（Flutter 的 conic-gradient）+ `GradientRotation`
/// 画一段绕边框旋转的亮带，对应设计稿里的 `@property --glow-angle` 动画。
///
/// [animation] 是 30Hz 的高光时钟：`repaint` 监听它，每一拍才重绘一次。
class _SweepBorderPainter extends CustomPainter {
  _SweepBorderPainter({
    required this.animation,
    required this.borderRadius,
    required this.opacity,
    required this.color,
  }) : super(repaint: animation);

  final ValueListenable<double> animation;
  final BorderRadius borderRadius;
  final double opacity;

  /// 高光颜色（默认跟随主题强调色）。
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || opacity <= 0) return;

    final Rect rect = Offset.zero & size;
    final double angle = animation.value * 2 * math.pi;
    // 峰值往白里提一点，纯色带会显得脏
    final Color peak = Color.lerp(color, Colors.white, 0.35)!;

    // 亮带集中在 120° 附近，两侧柔和过渡——与设计稿的色标一致
    final SweepGradient gradient = SweepGradient(
      startAngle: 0,
      endAngle: 2 * math.pi,
      colors: <Color>[
        Colors.transparent,
        color.withValues(alpha: 0.0),
        color.withValues(alpha: 0.4 * opacity),
        peak.withValues(alpha: 0.9 * opacity),
        peak.withValues(alpha: 1.0 * opacity),
        peak.withValues(alpha: 0.9 * opacity),
        color.withValues(alpha: 0.4 * opacity),
        color.withValues(alpha: 0.0),
        Colors.transparent,
      ],
      stops: const <double>[
        0.0,
        0.2917, // 105°
        0.3222, // 116°
        0.3306, // 119°
        0.3333, // 120°
        0.3361, // 121°
        0.3444, // 124°
        0.3750, // 135°
        1.0,
      ],
      transform: GradientRotation(angle),
    );

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      // 描边压在内侧，避免被圆角切掉一半
      ..strokeWidth = 1.6
      ..shader = gradient.createShader(rect);

    final RRect rrect = borderRadius
        .resolve(TextDirection.ltr)
        .toRRect(rect)
        .inflate(-0.8);

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_SweepBorderPainter oldDelegate) {
    return oldDelegate.opacity != opacity ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.color != color ||
        oldDelegate.animation != animation;
  }
}
