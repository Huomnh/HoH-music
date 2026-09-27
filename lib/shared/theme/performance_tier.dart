/// performance_tier.dart
///
/// 性能分级与渲染参数降级策略（架构文档 1.4 性能策略）。
///
/// 文档要求：「高端设备全开动效，低端/TV 端可降级关闭模糊与粒子效果」。
/// 本文件把这句要求落成可读取的参数集 [BlurConfig] 和程序化判定 [PerformanceTier]，
/// 供玻璃组件、霓虹光晕、流光动效统一读取。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 性能档位。
enum PerformanceTier {
  /// 高端：全开模糊、光晕与流光动效。
  high('高端', '全开动效'),

  /// 均衡：保留模糊与光晕，降低强度、关闭外围动效。
  balanced('均衡', '降低强度'),

  /// 省电：关闭模糊与动效，只保留纯色半透明表面（TV 端 / 低端设备）。
  battery('省电', '关闭模糊');

  const PerformanceTier(this.label, this.description);

  /// 档位中文名。
  final String label;

  /// 档位说明。
  final String description;
}

/// 玻璃与动效的渲染参数。
///
/// 所有视觉组件都应经由本对象取值，不要在组件里硬编码模糊半径，
/// 否则性能降级会失效。
///
/// 参数有两条来源：
/// - [BlurConfig.forTier] 按性能档位给出**默认值**；
/// - 用户可在玻璃设置面板里逐项微调（见 `glass_settings.dart`）。
@immutable
class BlurConfig {
  const BlurConfig({
    required this.tier,
    required this.blurSigma,
    required this.highlightEnabled,
    required this.neonStrength,
    required this.animationsEnabled,
    required this.sweepEnabled,
    required this.glowStrength,
    required this.tintOpacity,
    this.glassColor = Colors.white,
    this.glassSaturation = 0.08,
    this.glassTone = 0.08,
    this.glowColor,
  });

  /// 当前档位。
  final PerformanceTier tier;

  /// 背景模糊强度（ImageFilter.blur 的 sigma）。
  /// 为 0 时表示不启用 BackdropFilter。
  final double blurSigma;

  /// 是否渲染玻璃边缘高光。
  final bool highlightEnabled;

  /// 霓虹光晕强度系数，0 表示不发光。
  final double neonStrength;

  /// 是否运行动画（流光、脉冲）。
  /// 关闭后动画会被冻结在静态帧，避免持续重绘。
  final bool animationsEnabled;

  /// 是否绘制面板边框的旋转高光。
  ///
  /// 单独拆出来是因为它是**每帧重绘的描边**，在多块面板叠加时开销明显，
  /// 关掉它能立刻省下不少 GPU。
  final bool sweepEnabled;

  /// 边框高光的强度（0~1）。对应设计稿的「高光强度」滑杆。
  final double glowStrength;

  /// 边框高光的颜色。
  ///
  /// `null` = **跟随主题强调色**（0.0.18 起设为默认行为：
  /// 高光颜色与背景/封面算出来的强调色一致）。
  /// 用户在设置里选了具体颜色就覆盖它。
  final Color? glowColor;

  /// 玻璃填充的不透明度系数。0 表示完全透明（更"露背景"），1 为默认。
  final double tintOpacity;

  /// 玻璃主体颜色。默认白色，可由外观设置持久化覆盖。
  final Color glassColor;

  /// 玻璃互补色的饱和度与明暗，避免直接指定玻璃色破坏主题关系。
  final double glassSaturation;
  final double glassTone;

  /// 是否需要构建 BackdropFilter。
  bool get useBlur => blurSigma > 0;

  /// 按档位返回推荐参数。
  ///
  /// 性能取舍说明（针对"GPU 占用偏高"的优化）：
  /// - 模糊 sigma 从 24 降到 16。sigma 与采样开销是平方级关系，
  ///   16 在视觉上仍然明显，但采样量只有 24 的约 44%。
  /// - 默认关闭旋转高光。它是每帧重绘的描边，三块面板叠加时开销可观。
  /// 用户可以在设置面板里逐项打开，按自己机器的性能取舍。
  factory BlurConfig.forTier(PerformanceTier tier) {
    return switch (tier) {
      PerformanceTier.high => const BlurConfig(
        tier: PerformanceTier.high,
        blurSigma: 1,
        highlightEnabled: true,
        neonStrength: 1.0,
        animationsEnabled: true,
        sweepEnabled: true,
        glowStrength: 1.0,
        tintOpacity: 1.0,
        glassColor: Colors.white,
        glassSaturation: 0.01,
        glassTone: 1.0,
      ),
      PerformanceTier.balanced => const BlurConfig(
        tier: PerformanceTier.balanced,
        blurSigma: 10,
        highlightEnabled: true,
        neonStrength: 0.55,
        animationsEnabled: true,
        sweepEnabled: false,
        glowStrength: 0.7,
        tintOpacity: 0.9,
        glassColor: Colors.white,
        glassSaturation: 0.08,
        glassTone: 0.08,
      ),
      PerformanceTier.battery => const BlurConfig(
        tier: PerformanceTier.battery,
        blurSigma: 0,
        highlightEnabled: false,
        neonStrength: 0.0,
        animationsEnabled: false,
        sweepEnabled: false,
        glowStrength: 0.0,
        tintOpacity: 1.0,
        glassColor: Colors.white,
        glassSaturation: 0.08,
        glassTone: 0.08,
      ),
    };
  }

  /// 覆盖部分字段。用于设置面板逐项微调。
  BlurConfig copyWith({
    PerformanceTier? tier,
    double? blurSigma,
    bool? highlightEnabled,
    double? neonStrength,
    bool? animationsEnabled,
    bool? sweepEnabled,
    double? glowStrength,
    double? tintOpacity,
    Color? glassColor,
    double? glassSaturation,
    double? glassTone,
    Color? glowColor,
    bool clearGlowColor = false,
    bool clearGlassColor = false,
  }) {
    return BlurConfig(
      tier: tier ?? this.tier,
      blurSigma: blurSigma ?? this.blurSigma,
      highlightEnabled: highlightEnabled ?? this.highlightEnabled,
      neonStrength: neonStrength ?? this.neonStrength,
      animationsEnabled: animationsEnabled ?? this.animationsEnabled,
      sweepEnabled: sweepEnabled ?? this.sweepEnabled,
      glowStrength: glowStrength ?? this.glowStrength,
      tintOpacity: tintOpacity ?? this.tintOpacity,
      glassColor: glassColor ?? this.glassColor,
      glassSaturation: glassSaturation ?? this.glassSaturation,
      glassTone: glassTone ?? this.glassTone,
      glowColor: clearGlowColor ? null : (glowColor ?? this.glowColor),
    );
  }
}

/// 依据运行平台与屏幕参数推断性能档位。
///
/// 判定规则：
/// - 桌面端（Windows / macOS / Linux）→ 高端，用户可手动下调；
/// - 移动端：短边 ≥ 400 且像素比 ≤ 3.0 → 高端，否则均衡；
/// - 全部平台都可通过 [PerformanceTierController] 手动覆盖。
PerformanceTier detectPerformanceTier(BuildContext context) {
  if (kIsWeb) return PerformanceTier.balanced;

  final view = View.of(context);
  final size = view.physicalSize / view.devicePixelRatio;
  final shortestSide = size.shortestSide;
  final pixelRatio = view.devicePixelRatio;

  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    return PerformanceTier.high;
  }
  if (shortestSide >= 400 && pixelRatio <= 3.0) {
    return PerformanceTier.high;
  }
  return PerformanceTier.balanced;
}

/// 当前生效的性能档位。
///
/// `null` 表示「自动」——由 [detectPerformanceTier] 按平台推断。
/// 后续接入设置页时用 [PerformanceTierController.setTier] 手动覆盖，
/// 或 [PerformanceTierController.resetToAuto] 恢复自动。
final performanceTierProvider =
    NotifierProvider<PerformanceTierController, PerformanceTier?>(
      PerformanceTierController.new,
    );

/// 性能档位控制器。状态为 `null` 代表自动模式。
class PerformanceTierController extends Notifier<PerformanceTier?> {
  @override
  PerformanceTier? build() => null;

  /// 手动指定档位。
  void setTier(PerformanceTier tier) => state = tier;

  /// 恢复自动判定。
  void resetToAuto() => state = null;

  /// 依据 [context] 所在平台推断并应用档位。
  ///
  /// 必须定义在类内部：`state` 的 setter 是 protected 的，
  /// 写在 extension 里会被分析器判为越权访问。
  void autoDetect(BuildContext context) {
    state = detectPerformanceTier(context);
  }
}

/// 用户对玻璃效果的逐项覆盖。
///
/// 各字段为 `null` 表示「跟随当前性能档位的默认值」，
/// 非 null 表示用户在设置面板里手动改过。
///
/// 这样切换档位时，没动过的项会跟着档位走，动过的项保持不变——
/// 比「档位一把梭」更符合直觉。
@immutable
class GlassOverrides {
  const GlassOverrides({
    this.blurSigma,
    this.tintOpacity,
    this.sweepEnabled,
    this.glowStrength,
    this.glowColor,
    this.glassColor,
    this.glassSaturation,
    this.glassTone,
    this.animationsEnabled,
  });

  /// 模糊强度覆盖。
  final double? blurSigma;

  /// 玻璃填充不透明度覆盖。
  final double? tintOpacity;

  /// 旋转高光开关覆盖。
  final bool? sweepEnabled;

  /// 高光强度覆盖。
  final double? glowStrength;

  /// 高光颜色覆盖。`null` = 跟随主题强调色。
  final Color? glowColor;

  /// 玻璃主体颜色覆盖。
  final Color? glassColor;
  final double? glassSaturation;
  final double? glassTone;

  /// 动画总开关覆盖。
  final bool? animationsEnabled;

  /// 把覆盖项应用到档位默认值上。
  BlurConfig applyTo(BlurConfig base) {
    return base.copyWith(
      blurSigma: blurSigma,
      tintOpacity: tintOpacity,
      sweepEnabled: sweepEnabled,
      glowStrength: glowStrength,
      glowColor: glowColor,
      glassColor: glassColor,
      glassSaturation: glassSaturation,
      glassTone: glassTone,
      animationsEnabled: animationsEnabled,
    );
  }

  /// 是否有任何手动覆盖。
  bool get isEmpty =>
      blurSigma == null &&
      tintOpacity == null &&
      sweepEnabled == null &&
      glowStrength == null &&
      glowColor == null &&
      glassColor == null &&
      glassSaturation == null &&
      glassTone == null &&
      animationsEnabled == null;

  /// 覆盖部分字段。
  GlassOverrides copyWith({
    double? blurSigma,
    double? tintOpacity,
    bool? sweepEnabled,
    double? glowStrength,
    Color? glowColor,
    Color? glassColor,
    double? glassSaturation,
    double? glassTone,
    bool? animationsEnabled,
    bool clearGlowColor = false,
    bool clearGlassColor = false,
    bool clearAll = false,
  }) {
    if (clearAll) return const GlassOverrides();
    return GlassOverrides(
      blurSigma: blurSigma ?? this.blurSigma,
      tintOpacity: tintOpacity ?? this.tintOpacity,
      sweepEnabled: sweepEnabled ?? this.sweepEnabled,
      glowStrength: glowStrength ?? this.glowStrength,
      glowColor: clearGlowColor ? null : (glowColor ?? this.glowColor),
      glassColor: clearGlassColor ? null : (glassColor ?? this.glassColor),
      glassSaturation: glassSaturation ?? this.glassSaturation,
      glassTone: glassTone ?? this.glassTone,
      animationsEnabled: animationsEnabled ?? this.animationsEnabled,
    );
  }
}

/// 用户在设置面板里的逐项覆盖。
final glassOverridesProvider =
    NotifierProvider<GlassOverridesController, GlassOverrides>(
      GlassOverridesController.new,
    );

/// 玻璃设置控制器。
class GlassOverridesController extends Notifier<GlassOverrides> {
  @override
  GlassOverrides build() {
    _load();
    return const GlassOverrides();
  }

  Future<void> _load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    // 0.0.79：按用户要求把旧的个人参数恢复为默认值一次；之后的修改正常保存。
    if (!(prefs.getBool('appearance.parameters.v3') ?? false)) {
      for (final String key in <String>[
        'appearance.blurSigma',
        'appearance.tintOpacity',
        'appearance.glowStrength',
        'appearance.sweepEnabled',
        'appearance.animationsEnabled',
        'appearance.glassColor',
        'appearance.glassSaturation',
        'appearance.glassTone',
        'appearance.glowColor',
        'lyrics.autoScroll',
        'lyrics.desktopOverlay',
        'lyrics.overlayFrame',
        'lyrics.overlayLocked',
      ]) {
        await prefs.remove(key);
      }
      await prefs.setBool('appearance.parameters.v3', true);
      return;
    }
    final double? blur = prefs.getDouble('appearance.blurSigma');
    final double? tint = prefs.getDouble('appearance.tintOpacity');
    final double? glowStrength = prefs.getDouble('appearance.glowStrength');
    final double? glassSaturation = prefs.getDouble(
      'appearance.glassSaturation',
    );
    final double? glassTone = prefs.getDouble('appearance.glassTone');
    final bool? sweep = prefs.getBool('appearance.sweepEnabled');
    final bool? animations = prefs.getBool('appearance.animationsEnabled');
    final int? glassArgb = prefs.getInt('appearance.glassColor');
    final int? glowArgb = prefs.getInt('appearance.glowColor');
    if (blur == null &&
        tint == null &&
        glowStrength == null &&
        glassSaturation == null &&
        glassTone == null &&
        sweep == null &&
        animations == null &&
        glassArgb == null &&
        glowArgb == null) {
      return;
    }
    state = state.copyWith(
      blurSigma: blur,
      tintOpacity: tint,
      glowStrength: glowStrength,
      glassSaturation: glassSaturation,
      glassTone: glassTone,
      sweepEnabled: sweep,
      animationsEnabled: animations,
      glassColor: glassArgb == null ? null : Color(glassArgb),
      glowColor: glowArgb == null ? null : Color(glowArgb),
    );
  }

  Future<void> _save() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('appearance.blurSigma', state.blurSigma ?? 16);
    await prefs.setDouble('appearance.tintOpacity', state.tintOpacity ?? 1);
    await prefs.setDouble('appearance.glowStrength', state.glowStrength ?? 1);
    await prefs.setDouble(
      'appearance.glassSaturation',
      state.glassSaturation ?? 0.08,
    );
    await prefs.setDouble('appearance.glassTone', state.glassTone ?? 0.08);
    await prefs.setBool('appearance.sweepEnabled', state.sweepEnabled ?? false);
    await prefs.setBool(
      'appearance.animationsEnabled',
      state.animationsEnabled ?? true,
    );
    if (state.glassColor == null) {
      await prefs.remove('appearance.glassColor');
    } else {
      await prefs.setInt('appearance.glassColor', state.glassColor!.toARGB32());
    }
    if (state.glowColor == null) {
      await prefs.remove('appearance.glowColor');
    } else {
      await prefs.setInt('appearance.glowColor', state.glowColor!.toARGB32());
    }
  }

  /// 设置模糊强度。传 0 等于关闭模糊。
  Future<void> setBlurSigma(double v) async {
    state = state.copyWith(blurSigma: v.clamp(0, 40));
    await _save();
  }

  /// 设置玻璃填充不透明度。
  Future<void> setTintOpacity(double v) async {
    state = state.copyWith(tintOpacity: v.clamp(0.0, 1.0));
    await _save();
  }

  /// 开关旋转高光。
  Future<void> setSweep(bool v) async {
    state = state.copyWith(sweepEnabled: v);
    await _save();
  }

  /// 设置边框高光强度（0~1）。
  Future<void> setGlowStrength(double v) async {
    state = state.copyWith(glowStrength: v.clamp(0.0, 1.0));
    await _save();
  }

  /// 设置边框高光的自定义颜色。传 `null` = 恢复跟随主题色。
  Future<void> setGlowColor(Color? color) async {
    state = color == null
        ? state.copyWith(clearGlowColor: true)
        : state.copyWith(glowColor: color);
    await _save();
  }

  /// 设置玻璃主体颜色。传 null 恢复白色默认材质。
  Future<void> setGlassColor(Color? color) async {
    state = color == null
        ? state.copyWith(clearGlassColor: true)
        : state.copyWith(glassColor: color);
    await _save();
  }

  Future<void> setGlassSaturation(double value) async {
    state = state.copyWith(glassSaturation: value.clamp(0.0, 1.0));
    await _save();
  }

  Future<void> setGlassTone(double value) async {
    state = state.copyWith(glassTone: value.clamp(0.0, 1.0));
    await _save();
  }

  /// 开关全部动画。
  Future<void> setAnimations(bool v) async {
    state = state.copyWith(animationsEnabled: v);
    await _save();
  }

  /// 清空所有手动覆盖，全部回到档位默认值。
  Future<void> resetAll() async {
    state = const GlassOverrides();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    for (final String key in <String>[
      'appearance.blurSigma',
      'appearance.tintOpacity',
      'appearance.glowStrength',
      'appearance.sweepEnabled',
      'appearance.animationsEnabled',
      'appearance.glassColor',
      'appearance.glassSaturation',
      'appearance.glassTone',
      'appearance.glowColor',
    ]) {
      await prefs.remove(key);
    }
  }
}

/// 读取当前档位对应的渲染参数（已叠加用户覆盖）。
///
/// 自动模式下暂时按高端参数构建，页面挂载后由
/// [PerformanceTierAutoDetector] 依据真实平台改写。
final blurConfigProvider = Provider<BlurConfig>((ref) {
  final PerformanceTier tier =
      ref.watch(performanceTierProvider) ?? PerformanceTier.high;
  final GlassOverrides overrides = ref.watch(glassOverridesProvider);
  return overrides.applyTo(BlurConfig.forTier(tier));
});

/// 在首帧后依据真实平台写入自动档位。
///
/// 放在 `MaterialApp` 内层使用，避免在 build 过程中修改 Provider 状态。
class PerformanceTierAutoDetector extends ConsumerStatefulWidget {
  const PerformanceTierAutoDetector({super.key, required this.child});

  /// 被包裹的子树。
  final Widget child;

  @override
  ConsumerState<PerformanceTierAutoDetector> createState() =>
      _PerformanceTierAutoDetectorState();
}

class _PerformanceTierAutoDetectorState
    extends ConsumerState<PerformanceTierAutoDetector> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(performanceTierProvider.notifier).autoDetect(context);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
