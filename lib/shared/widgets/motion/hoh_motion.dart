/// HoH music 的低频 UI 动效封装。
///
/// 这个封装只服务于页面、设置面板等低频 UI 入场，不参与歌词、进度条、
/// 频谱或动态背景的高频帧计算。这样可以集中管理动效开关，也避免业务层
/// 到处依赖第三方动画 API。
library;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

abstract final class HoHMotion {
  const HoHMotion._();

  /// 低频内容的轻量淡入 + 微小上移。
  ///
  /// [enabled] 关闭时直接返回原 widget，不创建 AnimationController，也不
  /// 给玻璃/背景增加额外重绘；由现有 BlurConfig.animationsEnabled 传入。
  static Widget enter(
    Widget child, {
    required bool enabled,
    Duration duration = const Duration(milliseconds: 260),
    Duration delay = Duration.zero,
    Offset begin = const Offset(0, 0.025),
  }) {
    if (!enabled) return child;

    return _HoHMotionEnter(
      key: const ValueKey<String>('hoh-motion-enter'),
      begin: begin,
      delay: delay,
      duration: duration,
      child: child,
    );
  }
}

/// 使用 flutter_animate 的 Effect 原语，但由 HoH 自己持有 controller。
///
/// 直接使用 Effect 原语而不是 `Animate` widget，可避免通用 widget 在异步
/// 页面重建时排队零延迟 Future；这对设置页和测试环境更稳定，同时保留
/// flutter_animate 的 Fade/Slide 插值实现。
class _HoHMotionEnter extends StatefulWidget {
  const _HoHMotionEnter({
    super.key,
    required this.child,
    required this.begin,
    required this.delay,
    required this.duration,
  });

  final Widget child;
  final Offset begin;
  final Duration delay;
  final Duration duration;

  @override
  State<_HoHMotionEnter> createState() => _HoHMotionEnterState();
}

class _HoHMotionEnterState extends State<_HoHMotionEnter>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late final Animate _effectOwner;

  Duration get _totalDuration => widget.delay + widget.duration;

  @override
  void initState() {
    super.initState();
    _effectOwner = Animate(autoPlay: false);
    _controller = AnimationController(vsync: this, duration: _totalDuration)
      ..forward();
  }

  @override
  void didUpdateWidget(_HoHMotionEnter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.delay != widget.delay ||
        oldWidget.duration != widget.duration) {
      _controller
        ..duration = _totalDuration
        ..value = 0
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FadeEffect fade = FadeEffect(
      begin: 0,
      end: 1,
      delay: widget.delay,
      duration: widget.duration,
      curve: Curves.easeOutCubic,
    );
    final SlideEffect slide = SlideEffect(
      begin: widget.begin,
      end: Offset.zero,
      delay: widget.delay,
      duration: widget.duration,
      curve: Curves.easeOutCubic,
    );
    EffectEntry entryFor(Effect<dynamic> effect) => EffectEntry(
      effect: effect,
      delay: widget.delay,
      duration: widget.duration,
      curve: Curves.easeOutCubic,
      owner: _effectOwner,
    );

    Widget result = fade.build(
      context,
      widget.child,
      _controller,
      entryFor(fade),
    );
    result = slide.build(context, result, _controller, entryFor(slide));
    return result;
  }
}
