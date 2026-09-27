/// app_colors.dart
///
/// 配色常量：深色调 + 霓虹渐变（架构文档 1.4 UI 设计方向）。
///
/// 风格定位：GTA 迈阿密罪恶都市霓虹质感 + iPhone 18 Pro 液态玻璃。
/// 基底为深紫黑，强调色为霓虹青 / 品红 / 紫，用于渐变、光晕与描边。
library;

import 'package:flutter/material.dart';

/// 全项目统一配色常量。
///
/// 使用方式：
/// ```dart
/// Container(
///   decoration: BoxDecoration(
///     gradient: AppColors.primaryGradient,
///     boxShadow: AppColors.neonGlow(AppColors.neonCyan),
///   ),
/// )
/// ```
abstract final class AppColors {
  // ── 深色基底（深色调）────────────────────────────────────────────
  /// 最深背景，用于页面底色。
  static const Color abyss = Color(0xFF05030F);

  /// 次级背景，用于分区与卡片底。
  static const Color midnight = Color(0xFF0B0820);

  /// 表面色，用于抬升的容器。
  static const Color surface = Color(0xFF141031);

  /// 表面高亮，用于悬停 / 选中态。
  static const Color surfaceHigh = Color(0xFF1D1742);

  /// 分隔线。
  static const Color divider = Color(0xFF2A2354);

  // ── 霓虹强调色（霓虹渐变）────────────────────────────────────────
  /// 霓虹青——主强调色。
  static const Color neonCyan = Color(0xFF00E5FF);

  /// 霓虹品红——次强调色。
  static const Color neonMagenta = Color(0xFFFF2D95);

  /// 霓虹紫——过渡色。
  static const Color neonViolet = Color(0xFF9D4EDD);

  /// 霓虹蓝。
  static const Color neonBlue = Color(0xFF3A86FF);

  /// 霓虹青绿——补充色。
  static const Color neonTeal = Color(0xFF00FFB2);

  // ── 文字色 ──────────────────────────────────────────────────────
  /// 主要文字。
  static const Color textPrimary = Color(0xFFF5F2FF);

  /// 次要文字。
  ///
  /// 0.0.20 整体调亮：玻璃面板是半透明的，叠在亮背景（晨曦 / 薄荷汽水 /
  /// 用户自定义图片）上时，原来的 `0xA79FCB` / `0x6B6394` 会明显发灰、看着难受。
  static const Color textSecondary = Color(0xFFC3BCE0);

  /// 弱化文字。
  static const Color textTertiary = Color(0xFF948DBB);

  // ── 玻璃材质参数 ────────────────────────────────────────────────
  /// 玻璃表面填充——极低不透明度的白，叠在模糊层上产生"磨砂"感。
  static const Color glassFill = Color(0x14FFFFFF);

  /// 玻璃描边。
  static const Color glassBorder = Color(0x33FFFFFF);

  /// 玻璃顶部高光——模拟液态玻璃的边缘折射。
  static const Color glassHighlight = Color(0x66FFFFFF);

  // ── 预设渐变 ────────────────────────────────────────────────────

  /// 主渐变：青 → 紫 → 品红（罪恶都市霓虹）。
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [neonCyan, neonViolet, neonMagenta],
  );

  /// 冷色渐变：青 → 蓝。
  static const LinearGradient coolGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [neonCyan, neonBlue],
  );

  /// 暖色渐变：品红 → 紫。
  static const LinearGradient warmGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [neonMagenta, neonViolet],
  );

  /// 玻璃描边渐变：左上亮、右下暗，模拟单侧光源。
  static const LinearGradient glassBorderGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0x80FFFFFF),
      Color(0x1AFFFFFF),
      Color(0x0DFFFFFF),
      Color(0x4DFFFFFF),
    ],
    stops: [0.0, 0.35, 0.65, 1.0],
  );

  /// 玻璃表面纵向渐变，上亮下暗，增强厚度感。
  static const LinearGradient glassSurfaceGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x1FFFFFFF), Color(0x08FFFFFF)],
  );

  // ── 工具方法 ────────────────────────────────────────────────────

  /// 生成霓虹光晕阴影。
  ///
  /// [color] 光晕颜色，建议传霓虹强调色；[strength] 为 0~1 的强度系数，
  /// 低性能档位可以调小以减少模糊阴影的合成开销。
  static List<BoxShadow> neonGlow(
    Color color, {
    double strength = 1.0,
    double radius = 24,
  }) {
    return <BoxShadow>[
      BoxShadow(
        color: color.withValues(alpha: 0.45 * strength),
        blurRadius: radius * strength,
        spreadRadius: -2,
      ),
      BoxShadow(
        color: color.withValues(alpha: 0.22 * strength),
        blurRadius: radius * 2 * strength,
        spreadRadius: 2,
      ),
    ];
  }
}
