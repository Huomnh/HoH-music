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
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/metadata/cover_art.dart';
import 'app_background.dart';

/// 一套强调色。
@immutable
class AppAccent {
  const AppAccent({
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.source,
    this.scenePrimary,
    this.sceneSecondary,
    this.sceneTertiary,
  });

  /// 主强调色：滑块、开关、选中描边。
  final Color primary;

  /// 次强调色：图标、渐变另一端。
  final Color secondary;

  /// 第三色：渐变中段。
  final Color tertiary;

  /// 这套色来自哪里（用于设置页显示）。
  final String source;

  /// 给动态背景使用的原始色。
  ///
  /// UI 强调色需要保证文字和控件可读，不能简单等于封面上的黑/白/灰；
  /// 背景则应该保留封面的真实色相。因此这里把“UI 安全色”和“场景色”
  /// 分开，黑白封面也不会被强行伪装成高饱和色。
  final Color? scenePrimary;
  final Color? sceneSecondary;
  final Color? sceneTertiary;

  List<Color> get sceneColors => <Color>[
    scenePrimary ?? primary,
    sceneSecondary ?? secondary,
    sceneTertiary ?? tertiary,
  ];

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
      BackgroundKind.inkFold => const AppAccent(
        primary: Color(0xFF78B7FF),
        secondary: Color(0xFF4DE0C1),
        tertiary: Color(0xFFED86B8),
        source: '墨潮折影',
      ),
      BackgroundKind.monochromeDark => const AppAccent(
        primary: Color(0xFFEAEAEA),
        secondary: Color(0xFFB8B8B8),
        tertiary: Color(0xFFFFFFFF),
        source: '墨白极简',
      ),
      BackgroundKind.monochromeLight => const AppAccent(
        primary: Color(0xFF202020),
        secondary: Color(0xFF585858),
        tertiary: Color(0xFF000000),
        source: '白墨极简',
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
  /// 同时统计 24 个彩色色相桶和 3 个黑/灰/白中性桶。彩色桶使用压缩后的
  /// 面积评分，避免一块大面积底色把小面积但有辨识度的辅助色完全挤掉；
  /// 中性桶则直接参与场景色，保证黑白封面不会回退到默认蓝紫色。
  static Future<AppAccent?> fromImage(String path) async {
    final File file = File(path);
    if (!file.existsSync()) return null;

    return fromBytes(await file.readAsBytes(), source: '自定义图片');
  }

  /// 从已经获得的封面字节取色。
  ///
  /// 播放页的当前封面可能来自音频内嵌图片、缓存或网络，直接处理字节
  /// 可以避免为了主题取色再次写入临时文件。取色仍只解码成 48×48，
  /// 不会把原图长期保留在主题状态中。
  static Future<AppAccent?> fromBytes(
    Uint8List bytes, {
    String source = '专辑封面',
  }) async {
    if (bytes.isEmpty) return null;

    final ui.Codec codec = await ui.instantiateImageCodec(
      bytes,
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
    // 色相分桶：每 15° 一桶。weight 不直接作为最终排序分数，
    // 后面会做幂次压缩，降低“占比最大颜色”的支配性。
    final List<double> weight = List<double>.filled(24, 0);
    final List<double> satSum = List<double>.filled(24, 0);
    final List<double> valSum = List<double>.filled(24, 0);
    final List<double> redSum = List<double>.filled(24, 0);
    final List<double> greenSum = List<double>.filled(24, 0);
    final List<double> blueSum = List<double>.filled(24, 0);
    final List<int> count = List<int>.filled(24, 0);

    // 中性桶：0=暗色，1=中灰，2=亮色。
    final List<double> neutralWeight = List<double>.filled(3, 0);
    final List<double> neutralRed = List<double>.filled(3, 0);
    final List<double> neutralGreen = List<double>.filled(3, 0);
    final List<double> neutralBlue = List<double>.filled(3, 0);
    double allNeutralWeight = 0;
    double allNeutralRed = 0;
    double allNeutralGreen = 0;
    double allNeutralBlue = 0;

    for (int i = 0; i + 3 < pixels.length; i += 4) {
      final int a = pixels[i + 3];
      if (a < 128) continue; // 透明像素不算

      final int red = pixels[i];
      final int green = pixels[i + 1];
      final int blue = pixels[i + 2];
      final HSVColor hsv = HSVColor.fromColor(
        Color.fromARGB(255, red, green, blue),
      );
      final int pixel = i ~/ 4;
      final int x = pixel % 48;
      final int y = pixel ~/ 48;
      // 封面中心通常比边缘更能代表主体，但只做温和加权，避免裁切构图失真。
      final double centerDistance =
          math.sqrt(math.pow(x - 23.5, 2) + math.pow(y - 23.5, 2)) / 34.0;
      final double spatialWeight = (1.12 - centerDistance * 0.22).clamp(
        0.82,
        1.12,
      );

      if (hsv.saturation < 0.14) {
        final int neutralBucket = hsv.value < 0.22
            ? 0
            : hsv.value > 0.78
            ? 2
            : 1;
        final double w = spatialWeight * (0.7 + (1 - hsv.saturation));
        neutralWeight[neutralBucket] += w;
        neutralRed[neutralBucket] += red * w;
        neutralGreen[neutralBucket] += green * w;
        neutralBlue[neutralBucket] += blue * w;
        allNeutralWeight += w;
        allNeutralRed += red * w;
        allNeutralGreen += green * w;
        allNeutralBlue += blue * w;
        continue;
      }

      final int bucket = (hsv.hue / 15).floor().clamp(0, 23);
      // 暗色仍然保留，避免黑底彩字封面被丢掉；接近白色只轻微降权。
      final double w =
          spatialWeight *
          (0.2 + hsv.saturation * 0.8) *
          (0.42 + hsv.value * 0.58);
      weight[bucket] += w;
      satSum[bucket] += hsv.saturation * w;
      valSum[bucket] += hsv.value * w;
      redSum[bucket] += red * w;
      greenSum[bucket] += green * w;
      blueSum[bucket] += blue * w;
      count[bucket]++;
    }

    final List<double> score = List<double>.generate(24, (int i) {
      if (count[i] < 4 || weight[i] <= 0) return 0;
      final double saturation = satSum[i] / weight[i];
      // 面积幂次压缩：大色块仍是主色，但不会吞掉小面积辅助色。
      return math.pow(weight[i], 0.58).toDouble() * (0.55 + saturation * 0.9);
    });
    final List<int> ranked = List<int>.generate(24, (int i) => i)
      ..sort((int a, int b) => score[b].compareTo(score[a]));
    final List<int> picked = <int>[];
    for (final int bucket in ranked) {
      if (picked.length >= 3) break;
      if (score[bucket] <= 0) continue;
      // 与已选色相至少差 45°，保证三个色“看得出来不一样”。
      final bool tooClose = picked.any((int p) {
        final int diff = (p - bucket).abs();
        return diff < 3 || diff > 21;
      });
      if (tooClose) continue;
      picked.add(bucket);
    }

    Color neutralColor() {
      if (allNeutralWeight <= 0) return const Color(0xFF555A68);
      final int dominantBucket = <int>[
        0,
        1,
        2,
      ].reduce((int a, int b) => neutralWeight[a] >= neutralWeight[b] ? a : b);
      // 单一黑/灰/白基调占到中性色的大半时保留它；黑白拼贴则使用总体均值。
      if (neutralWeight[dominantBucket] >= allNeutralWeight * 0.55) {
        final double weight = neutralWeight[dominantBucket];
        return Color.fromARGB(
          255,
          (neutralRed[dominantBucket] / weight).round().clamp(0, 255),
          (neutralGreen[dominantBucket] / weight).round().clamp(0, 255),
          (neutralBlue[dominantBucket] / weight).round().clamp(0, 255),
        );
      }
      return Color.fromARGB(
        255,
        (allNeutralRed / allNeutralWeight).round().clamp(0, 255),
        (allNeutralGreen / allNeutralWeight).round().clamp(0, 255),
        (allNeutralBlue / allNeutralWeight).round().clamp(0, 255),
      );
    }

    Color neutralUiColor(Color color) {
      final double luminance = color.computeLuminance();
      if (luminance < 0.18) return const Color(0xFF9AA9D0);
      if (luminance > 0.82) return const Color(0xFF4D5872);
      return const Color(0xFFB5C1DE);
    }

    // 全黑/全白/大面积灰度封面也要返回结果，而不是沿用上一首主题。
    if (picked.isEmpty) {
      final Color raw = neutralColor();
      final Color uiColor = neutralUiColor(raw);
      final Color secondary = Color.lerp(uiColor, Colors.white, 0.18)!;
      final Color tertiary = Color.lerp(uiColor, Colors.black, 0.18)!;
      return AppAccent(
        primary: uiColor,
        secondary: secondary,
        tertiary: tertiary,
        scenePrimary: raw,
        sceneSecondary: Color.lerp(raw, Colors.white, 0.12),
        sceneTertiary: Color.lerp(raw, Colors.black, 0.16),
        source: source,
      );
    }

    Color toScene(int bucket) {
      return Color.fromARGB(
        255,
        (redSum[bucket] / weight[bucket]).round().clamp(0, 255),
        (greenSum[bucket] / weight[bucket]).round().clamp(0, 255),
        (blueSum[bucket] / weight[bucket]).round().clamp(0, 255),
      );
    }

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
    final Color colorfulScene = toScene(picked[0]);
    final bool neutralIsDominant = allNeutralWeight > weight[picked[0]] * 1.15;
    final Color dominantScene = neutralIsDominant
        ? neutralColor()
        : colorfulScene;
    final Color secondaryScene = neutralIsDominant
        ? colorfulScene
        : picked.length > 1
        ? toScene(picked[1])
        : (allNeutralWeight > 0 ? neutralColor() : colorfulScene);
    final Color tertiaryScene = neutralIsDominant
        ? (picked.length > 1 ? toScene(picked[1]) : colorfulScene)
        : picked.length > 2
        ? toScene(picked[2])
        : Color.lerp(dominantScene, secondaryScene, 0.5)!;

    return AppAccent(
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
      scenePrimary: dominantScene,
      sceneSecondary: secondaryScene,
      sceneTertiary: tertiaryScene,
      source: source,
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

/// 强调色控制器：内置场景走预设表；液态流光模式跟随当前专辑封面取色；
/// 自定义图片背景继续从图片里取色。
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
      final AppAccent accent = AppAccent(
        primary: customTheme,
        secondary: complementary,
        tertiary: Color.lerp(customTheme, complementary, 0.5)!,
        scenePrimary: customTheme,
        sceneSecondary: complementary,
        sceneTertiary: Color.lerp(customTheme, complementary, 0.5),
        source: 'RGB 色轮',
      );
      _resolved = accent;
      return accent;
    }

    if (selection.effectiveKind == BackgroundKind.liquidBloom) {
      // currentCoverProvider 已经负责内嵌封面 / 缓存 / 网络来源和去重，
      // 这里仅消费它的结果，不重新请求图片。
      final AsyncValue<Uint8List?> currentCover = ref.watch(
        currentCoverProvider,
      );
      final Uint8List? bytes = currentCover.asData?.value;
      if (bytes != null) {
        unawaited(_extractBytes(bytes, generation));
      }
      // 切歌后先保持上一首的颜色，直到新封面取色完成；避免先闪回默认
      // 蓝紫色，再跳到新颜色。
      return _resolved ?? preset;
    }

    if (selection.effectiveKind == BackgroundKind.custom &&
        selection.hasCustomImage) {
      unawaited(_extract(selection.customImagePath!, generation));
    }
    _resolved = preset;
    return preset;
  }

  AppAccent? _resolved;

  Future<void> _extract(String path, int generation) async {
    try {
      final AppAccent? extracted = await AppAccent.fromImage(path);
      // 期间用户又换了背景 / provider 已销毁 → 丢弃这次结果
      if (!ref.mounted || generation != _generation || extracted == null) {
        return;
      }
      _resolved = extracted;
      state = extracted;
      debugPrint(
        '[Accent] 从图片取色：primary=#${extracted.primary.toARGB32().toRadixString(16)}',
      );
    } catch (error) {
      debugPrint('[Accent] 取色失败，沿用默认强调色：$error');
    }
  }

  Future<void> _extractBytes(Uint8List bytes, int generation) async {
    try {
      final AppAccent? extracted = await AppAccent.fromBytes(bytes);
      if (!ref.mounted || generation != _generation || extracted == null) {
        return;
      }
      _resolved = extracted;
      state = extracted;
      debugPrint(
        '[Accent] 从专辑封面取色：primary=#${extracted.primary.toARGB32().toRadixString(16)}',
      );
    } catch (error) {
      debugPrint('[Accent] 专辑封面取色失败，沿用当前强调色：$error');
    }
  }
}

/// 让当前强调色在切歌/切背景时平滑过渡，而不是整棵界面瞬间换色。
class AnimatedAccentScope extends StatefulWidget {
  const AnimatedAccentScope({
    super.key,
    required this.accent,
    required this.child,
    this.duration = const Duration(milliseconds: 820),
  });

  final AppAccent accent;
  final Widget child;
  final Duration duration;

  @override
  State<AnimatedAccentScope> createState() => _AnimatedAccentScopeState();
}

class _AnimatedAccentScopeState extends State<AnimatedAccentScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late AppAccent _from;
  late AppAccent _to;

  @override
  void initState() {
    super.initState();
    _from = widget.accent;
    _to = widget.accent;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1,
    );
  }

  @override
  void didUpdateWidget(covariant AnimatedAccentScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (oldWidget.accent == widget.accent) return;

    final double progress = Curves.easeInOutCubic.transform(_controller.value);
    _from = _lerpAccent(_from, _to, progress);
    _to = widget.accent;
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double progress = Curves.easeInOutCubic.transform(
          _controller.value,
        );
        return AccentScope(
          accent: _lerpAccent(_from, _to, progress),
          child: child!,
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static AppAccent _lerpAccent(AppAccent a, AppAccent b, double t) {
    return AppAccent(
      primary: Color.lerp(a.primary, b.primary, t)!,
      secondary: Color.lerp(a.secondary, b.secondary, t)!,
      tertiary: Color.lerp(a.tertiary, b.tertiary, t)!,
      scenePrimary: Color.lerp(a.scenePrimary, b.scenePrimary, t),
      sceneSecondary: Color.lerp(a.sceneSecondary, b.sceneSecondary, t),
      sceneTertiary: Color.lerp(a.sceneTertiary, b.sceneTertiary, t),
      source: b.source,
    );
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
