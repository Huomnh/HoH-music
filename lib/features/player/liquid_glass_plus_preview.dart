/// liquid_glass_plus_preview.dart
///
/// `liquid_glass_plus` 的玻璃试用面板。
/// 主界面和这里共用同一个配置桥接，避免两套参数产生视觉漂移。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_plus/liquid_glass_plus.dart';

import '../../shared/theme/performance_tier.dart';
import '../../shared/widgets/widget_kit/liquid_glass_settings.dart';

Future<void> showLiquidGlassPlusPreview(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => const Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.all(24),
      child: LiquidGlassPlusPreview(),
    ),
  );
}

class LiquidGlassPlusPreview extends ConsumerWidget {
  const LiquidGlassPlusPreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BlurConfig config = ref.watch(blurConfigProvider);
    final LiquidGlassSettings settings = buildHohLiquidGlassSettings(config);
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        width: 760,
        height: 480,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const _DemoBackdrop(),
            LiquidGlassLayer(
              settings: settings,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Positioned(
                    left: 28,
                    top: 28,
                    child: LiquidGlass(
                      shape: const LiquidRoundedSuperellipse(borderRadius: 24),
                      child: const SizedBox(
                        width: 200,
                        height: 78,
                        child: _DemoLabel(
                          icon: Icons.blur_on_rounded,
                          title: 'LiquidGlassLayer',
                          subtitle: '插件折射 / 模糊 / 高光',
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 32,
                    top: 42,
                    child: LiquidGlass(
                      shape: const LiquidOval(),
                      child: const SizedBox.square(
                        dimension: 82,
                        child: Icon(
                          Icons.auto_awesome_rounded,
                          color: Colors.white,
                          size: 34,
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: LiquidGlass(
                      shape: const LiquidRoundedSuperellipse(borderRadius: 38),
                      child: const SizedBox(
                        width: 500,
                        height: 190,
                        child: _DemoCenterContent(),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 28,
                    right: 28,
                    bottom: 26,
                    child: LiquidGlass(
                      shape: const LiquidRoundedSuperellipse(borderRadius: 22),
                      child: const SizedBox(
                        height: 66,
                        child: _DemoBottomBar(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 14,
              right: 14,
              child: IconButton(
                tooltip: '关闭试用',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DemoBackdrop extends StatelessWidget {
  const _DemoBackdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF293D72),
            Color(0xFF563A70),
            Color(0xFF1D6870),
          ],
        ),
      ),
      child: Stack(
        children: <Widget>[
          const Positioned(
            left: -70,
            top: 120,
            child: _GlowOrb(color: Color(0xFF6EE7E1), size: 240),
          ),
          const Positioned(
            right: -50,
            top: 70,
            child: _GlowOrb(color: Color(0xFFFF83C8), size: 220),
          ),
          const Positioned(
            right: 130,
            bottom: -110,
            child: _GlowOrb(color: Color(0xFFFFC76B), size: 260),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.color, required this.size});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color.withValues(alpha: 0.72),
      boxShadow: <BoxShadow>[
        BoxShadow(color: color.withValues(alpha: 0.65), blurRadius: 80),
      ],
    ),
  );
}

class _DemoLabel extends StatelessWidget {
  const _DemoLabel({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: <Widget>[
      Icon(icon, color: Colors.white, size: 22),
      const SizedBox(width: 10),
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ],
      ),
    ],
  );
}

class _DemoCenterContent extends StatelessWidget {
  const _DemoCenterContent();

  @override
  Widget build(BuildContext context) => const Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: <Widget>[
      Text(
        'HoH music',
        style: TextStyle(
          color: Colors.white,
          fontSize: 30,
          fontWeight: FontWeight.w800,
        ),
      ),
      SizedBox(height: 6),
      Text(
        'liquid_glass_plus 试用面板',
        style: TextStyle(color: Colors.white70, fontSize: 13),
      ),
      SizedBox(height: 20),
      Text(
        '拖动、切换主题和改变窗口尺寸后观察玻璃是否稳定',
        style: TextStyle(color: Colors.white70, fontSize: 12),
      ),
    ],
  );
}

class _DemoBottomBar extends StatelessWidget {
  const _DemoBottomBar();

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: <Widget>[
      const Icon(Icons.music_note_rounded, color: Colors.white70, size: 18),
      const SizedBox(width: 12),
      const Text(
        '请重点观察折射边缘、圆角和 GPU 开销',
        style: TextStyle(color: Colors.white, fontSize: 12),
      ),
      const SizedBox(width: 18),
      IconButton(
        tooltip: '关闭试用',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.check_rounded, color: Colors.white),
      ),
    ],
  );
}
