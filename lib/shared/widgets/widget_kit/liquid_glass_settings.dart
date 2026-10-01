/// The single HoH configuration bridge for `liquid_glass_plus`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_plus/liquid_glass_plus.dart';

import '../../theme/performance_tier.dart';

/// Builds the production glass settings used by both the main UI and preview.
/// Windows uses the package's supported fake-glass renderer because the shader
/// path is not stable on every Windows Flutter renderer.
LiquidGlassSettings buildHohLiquidGlassSettings(
  BlurConfig config, {
  bool enabled = true,
}) {
  final bool useGlass = enabled && config.frostIntensity > 0;
  final double thickness = useGlass ? config.glassThickness.clamp(0.0, 18.0) : 0;
  final double frost = useGlass ? config.frostIntensity.clamp(0.0, 12.0) : 0;
  final double tintAlpha = useGlass
      ? (0.045 + config.tintOpacity.clamp(0.0, 1.0) * 0.12).clamp(0.04, 0.18)
      : 0.0;

  return LiquidGlassSettings(
    thickness: thickness,
    frostIntensity: frost,
    // Fake Glass selects multiply/screen from luminance. A bright, low-alpha
    // tint prevents a dark theme color from making the background look inverted.
    glassColor: Colors.white.withValues(alpha: tintAlpha),
    lightAngle: config.lightAngle,
    lightIntensity: config.lightIntensity.clamp(0.0, 1.0),
    ambientStrength: config.ambientStrength.clamp(0.0, 1.0),
    saturation: config.liquidSaturation.clamp(0.5, 2.0),
    liquidGlassConfigs: LiquidGlassConfigs(
      chromaticAberration: config.chromaticAberration.clamp(0.0, 0.02),
      refractiveIndex: config.refractiveIndex.clamp(1.0, 2.0),
    ),
    fakeGlassConfigs: FakeGlassConfigs(
      forceEnabled: defaultTargetPlatform == TargetPlatform.windows,
      refraction: useGlass ? config.fakeGlassRefraction.clamp(0.0, 4.0) : 0,
    ),
    animationDuration: Duration.zero,
  );
}
