/// app_accent.dart
///
/// 主题强调色：**跟随当前背景**。
///
/// 内置液态流光使用固定强调色；自定义图片则**从图片里提取**
/// 主色调，让界面颜色和背景是一套的。
///
/// 下发方式与 [BlurConfigScope] 一致：`app.dart` 在根部一次下发
/// [AccentScope]，叶子组件用 `AppAccent.of(context)` 读取，
/// 避免一屏十几块玻璃各自监听 provider。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_background.dart';

/// 一套强调色。
@immutable
class AppAccent {
  const AppAccent({
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.source,
  });

  /// 主强调色：滑块、开关、选中描边。
  final Color primary;

  /// 次强调色：图标、渐变另一端。
  final Color secondary;

  /// 第三色：渐变中段。
  final Color tertiary;

  /// 这套色来自哪里（用于设置页显示）。
  final String source;

  /// 读取当前生效的强调色（等价于 `AccentScope.of`）。
  ///
  /// 放在 [AppAccent] 上是为了调用处更短：`AppAccent.of(context)`；
  /// 没有作用域时回退到默认液态流光配色。
  static AppAccent of(BuildContext context) => AccentScope.of(context);

  /// 默认液态流光配色。
  static const AppAccent liquidBloom = AppAccent(
    primary: Color(0xFF7C8CFF),
    secondary: Color(0xFFFF78C8),
    tertiary: Color(0xFF47E5C2),
    source: '液态流光',
  );

  /// 按背景场景给出协调的强调色。
  ///
  /// 这些是**手工挑过**的：直接取场景里的亮色往往会偏灰或偏暗，
  /// 用作 UI 强调色时对比度不够。
  static AppAccent forKind(BackgroundKind kind) {
    return switch (kind) {
      BackgroundKind.liquidBloom => liquidBloom,
      BackgroundKind.deepTide => const AppAccent(
        primary: Color(0xFFFF996B),
        secondary: Color(0xFFFFC857),
        tertiary: Color(0xFFE85D75),
        source: '暖霞流光',
      ),
      // 自定义图片：先用液态流光色，等提取结果回来再替换
      BackgroundKind.custom => const AppAccent(
        primary: Color(0xFF7C8CFF),
        secondary: Color(0xFFFF78C8),
        tertiary: Color(0xFF47E5C2),
        source: '自定义图片',
      ),
    };
  }

  /// 为主题/封面提取色选择 WCAG 对比度更高的安全文字色。
  ///
  /// 提取色可能非常亮，不能假定白字总是可读；在白色和深墨色之间选择
  /// 对比度更高的一项，最低可避免把正文画成接近背景的颜色。
  static Color safeTextOn(Color background) {
    const Color light = Colors.white;
    const Color dark = Color(0xFF0A0B12);
    final double luminance = background.computeLuminance();
    final double lightRatio = (1.0 + 0.05) / (luminance + 0.05);
    final double darkRatio = (luminance + 0.05) / 0.05;
    return lightRatio >= darkRatio ? light : dark;
  }

  /// 从一张图片里推出一套强调色。
  ///
  /// 做法：把图片解码成 48×48 的小图（不是原图，省内存也够准），
  /// 按色相分桶统计，桶内评分 = 像素数 × 饱和度权重，
  /// 取分数最高的三个**不同色相**的桶，再统一提亮到适合当强调色的明度。
  ///
  /// 全黑 / 全白的图会拿不到有效桶，这时返回 null，调用方沿用预设色。
  static Future<AppAccent?> fromImage(String path) async {
    final File file = File(path);
    if (!file.existsSync()) return null;

    final ui.Codec codec = await ui.instantiateImageCodec(
      await file.readAsBytes(),
      targetWidth: 48,
      targetHeight: 48,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ByteData? data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    frame.image.dispose();
    codec.dispose();
    if (data == null) return null;

    final Uint8List pixels = data.buffer.asUint8List();
    // 色相分桶：每 15° 一桶
    final List<double> weight = List<double>.filled(24, 0);
    final List<double> satSum = List<double>.filled(24, 0);
    final List<double> valSum = List<double>.filled(24, 0);
    final List<int> count = List<int>.filled(24, 0);

    for (int i = 0; i + 3 < pixels.length; i += 4) {
      final int a = pixels[i + 3];
      if (a < 128) continue; // 透明像素不算

      final HSVColor hsv = HSVColor.fromColor(
        Color.fromARGB(255, pixels[i], pixels[i + 1], pixels[i + 2]),
      );
      // 太暗或太灰的像素对"强调色"没有参考价值
      if (hsv.value < 0.16 || hsv.saturation < 0.14) continue;

      final int bucket = (hsv.hue / 15).floor().clamp(0, 23);
      // 明度太高的（接近白）权重压低，避免整张亮图都算到同一个桶
      final double w =
          hsv.saturation * (1.0 - (hsv.value - 0.9).clamp(0.0, 1.0));
      weight[bucket] += w;
      satSum[bucket] += hsv.saturation * w;
      valSum[bucket] += hsv.value * w;
      count[bucket]++;
    }

    final List<int> ranked = List<int>.generate(24, (int i) => i)
      ..sort((int a, int b) => weight[b].compareTo(weight[a]));
    final List<int> picked = <int>[];
    for (final int bucket in ranked) {
      if (picked.length >= 3) break;
      if (count[bucket] < 4 || weight[bucket] <= 0) continue;
      // 与已选色相至少差 45°，保证三个色"看得出来不一样"
      final bool tooClose = picked.any((int p) {
        final int diff = (p - bucket).abs();
        return diff < 3 || diff > 21;
      });
      if (tooClose) continue;
      picked.add(bucket);
    }

    if (picked.isEmpty) return null;

    Color toAccent(int bucket, {required double lightness}) {
      final double sat = (satSum[bucket] / weight[bucket]).clamp(0.45, 1.0);
      final double val = (valSum[bucket] / weight[bucket]);
      final HSVColor hsv = HSVColor.fromAHSV(
        1,
        bucket * 15.0 + 7.5,
        sat,
        // 统一压到适合当强调色的明度：原图很亮/很暗都能用
        lightness.clamp(0.35, 0.95) * (val > 0.5 ? 1.0 : 1.15),
      );
      return hsv.toColor();
    }

    final Color primary = toAccent(picked[0], lightness: 0.82);
    final Color secondary = picked.length > 1
        ? toAccent(picked[1], lightness: 0.78)
        : primary;
    final Color tertiary = picked.length > 2
        ? toAccent(picked[2], lightness: 0.72)
        : Color.lerp(primary, secondary, 0.5)!;

    return AppAccent(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
      source: '自定义图片',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppAccent &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.tertiary == tertiary &&
      other.source == source;

  @override
  int get hashCode => Object.hash(primary, secondary, tertiary, source);
}

/// 当前强调色（跟随背景）。
final accentProvider = NotifierProvider<AccentController, AppAccent>(
  AccentController.new,
);

/// 用户通过 RGB 色轮选择的主题基准色；为空时继续跟随背景预设。
final themeColorProvider = NotifierProvider<ThemeColorController, Color?>(
  ThemeColorController.new,
);

class ThemeColorController extends Notifier<Color?> {
  static const String _key = 'appearance.themeColor';

  @override
  Color? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('appearance.parameters.v3') ?? false)) {
      await prefs.remove(_key);
      return;
    }
    final int? value = prefs.getInt(_key);
    if (value != null) state = Color(value);
  }

  Future<void> setColor(Color? color) async {
    state = color;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (color == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setInt(_key, color.toARGB32());
    }
  }
}

/// 强调色控制器：内置场景走预设表，自定义图片走取色。
class AccentController extends Notifier<AppAccent> {
  /// 每次重建 +1，用来丢弃过期的取色结果。
  int _generation = 0;

  @override
  AppAccent build() {
    final BackgroundSelection selection = ref.watch(backgroundProvider);
    final int generation = ++_generation;
    final AppAccent preset = AppAccent.forKind(selection.effectiveKind);
    final Color? customTheme = ref.watch(themeColorProvider);

    if (customTheme != null) {
      final HSVColor hsv = HSVColor.fromColor(customTheme);
      final Color complementary = hsv
          .withHue((hsv.hue + 180) % 360)
          .withSaturation((hsv.saturation * 0.9).clamp(0.25, 1.0))
          .withValue(0.86)
          .toColor();
      return AppAccent(
        primary: customTheme,
        secondary: complementary,
        tertiary: Color.lerp(customTheme, complementary, 0.5)!,
        source: 'RGB 色轮',
      );
    }

    if (selection.effectiveKind == BackgroundKind.custom &&
        selection.hasCustomImage) {
      unawaited(_extract(selection.customImagePath!, generation, preset));
    }
    return preset;
  }

  Future<void> _extract(String path, int generation, AppAccent fallback) async {
    try {
      final AppAccent? extracted = await AppAccent.fromImage(path);
      // 期间用户又换了背景 / provider 已销毁 → 丢弃这次结果
      if (!ref.mounted || generation != _generation || extracted == null) {
        return;
      }
      state = extracted;
      debugPrint(
        '[Accent] 从图片取色：primary=#${extracted.primary.toARGB32().toRadixString(16)}',
      );
    } catch (error) {
      debugPrint('[Accent] 取色失败，沿用默认强调色：$error');
    }
  }
}

/// 把当前强调色下发给整棵子树。
class AccentScope extends InheritedWidget {
  const AccentScope({super.key, required this.accent, required super.child});

  /// 当前生效的强调色。
  final AppAccent accent;

  /// 读取最近的强调色；没有作用域时返回默认（霓虹海滩）那套。
  static AppAccent of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AccentScope>()?.accent ??
        AppAccent.liquidBloom;
  }

  @override
  bool updateShouldNotify(AccentScope oldWidget) => oldWidget.accent != accent;
}
