/// lyrics_style.dart
///
/// 歌词显示样式（用户可调，持久化）。
///
/// 放在 `features/player/lyrics/` 下：只服务于歌词面板，
/// 与 `GlassOverrides`（玻璃参数）一样是"用户覆盖优先"的思路。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌词专用字体。与应用字体独立保存。
enum LyricFontFamily {
  kirakara('耀圆体', 'KirakaraMaru'),
  custom('导入字体', 'HoHImportedLyricsFont'),
  system('系统默认', null),
  segoe('Segoe UI', 'Segoe UI'),
  microsoftYahei('微软雅黑', 'Microsoft YaHei'),
  notoSans('Noto Sans', 'Noto Sans'),
  sourceHanSans('思源黑体', 'Source Han Sans SC'),
  microsoftJhengHei('微软正黑', 'Microsoft JhengHei'),
  kaiti('楷体', 'KaiTi'),
  simsun('宋体', 'SimSun');

  const LyricFontFamily(this.label, this.family);
  final String label;
  final String? family;
}

enum LyricWeight {
  regular('常规', FontWeight.w400),
  medium('中等', FontWeight.w500),
  semibold('半粗', FontWeight.w600),
  bold('粗体', FontWeight.w700);

  const LyricWeight(this.label, this.value);
  final String label;
  final FontWeight value;
}

/// 歌词行距档位。
enum LyricLineSpacing {
  /// 紧凑。
  tight('紧凑', 1.5),

  /// 标准。
  normal('标准', 1.9),

  /// 宽松。
  loose('宽松', 2.4);

  const LyricLineSpacing(this.label, this.factor);

  /// 界面显示名。
  final String label;

  /// 行高系数（相对于字号）。
  final double factor;
}

/// 歌词对齐方式。
enum LyricAlign {
  /// 靠左。
  left('靠左'),

  /// 居中。
  center('居中'),

  /// 靠右（歌词面板在右侧时的观感更整）。
  right('靠右');

  const LyricAlign(this.label);

  /// 界面显示名。
  final String label;

  /// 转成 Flutter 的对齐枚举。
  TextAlign get textAlign => switch (this) {
    LyricAlign.left => TextAlign.left,
    LyricAlign.center => TextAlign.center,
    LyricAlign.right => TextAlign.right,
  };

  /// 行内对齐。
  Alignment get alignment => switch (this) {
    LyricAlign.left => Alignment.centerLeft,
    LyricAlign.center => Alignment.center,
    LyricAlign.right => Alignment.centerRight,
  };
}

/// HoH 歌词视觉预设。
///
/// 名称是 HoH 自己的产品语义，不把用户界面绑定到参考项目名称；
/// 预设只替换呈现，不替换 HoH 的时间轴、歌词获取或播放后端。
enum LyricsLayoutMode {
  starIsland('星屿'),
  ripple('微澜'),
  floatingLight('浮光'),
  stringPulse('弦动'),
  albumVoice('留声'),
  afterglow('余晖');

  const LyricsLayoutMode(this.label);

  // Compatibility aliases for tests and integrations compiled against the
  // pre-0.1.0-beta.2 enum. They are not enum values, so they never appear in
  // the settings UI or in exported mode lists.
  @Deprecated('Use LyricsLayoutMode.ripple')
  static const LyricsLayoutMode zeroBitKaraoke = LyricsLayoutMode.ripple;
  @Deprecated('Use LyricsLayoutMode.starIsland')
  static const LyricsLayoutMode zeroBitLine = LyricsLayoutMode.starIsland;
  @Deprecated('Use LyricsLayoutMode.stringPulse')
  static const LyricsLayoutMode pureMusicWord = LyricsLayoutMode.stringPulse;

  final String label;

  /// 字符重叠波形：只给“微澜”使用，名称不暴露参考项目来源。
  bool get usesGlyphRipple => this == LyricsLayoutMode.ripple;

  bool get usesWordTiming => switch (this) {
    LyricsLayoutMode.ripple ||
    LyricsLayoutMode.stringPulse ||
    LyricsLayoutMode.albumVoice ||
    LyricsLayoutMode.afterglow => true,
    _ => false,
  };

  /// “留声”把专辑信息与歌词放在同一页。
  bool get showsAlbumInfo => this == LyricsLayoutMode.albumVoice;

  LyricDisplayMode get displayMode => switch (this) {
    LyricsLayoutMode.starIsland ||
    LyricsLayoutMode.floatingLight => LyricDisplayMode.lineByLine,
    LyricsLayoutMode.afterglow => LyricDisplayMode.enhanced,
    _ => LyricDisplayMode.wordByWord,
  };

  /// 兼容此前版本保存的布局名；旧品牌名只在迁移层出现，不再作为当前模式。
  static LyricsLayoutMode fromStoredName(String? name) {
    for (final LyricsLayoutMode mode in values) {
      if (mode.name == name) return mode;
    }
    return switch (name) {
      'zeroBitLine' => LyricsLayoutMode.starIsland,
      'zeroBitKaraoke' ||
      'zeroBit' ||
      'scrollingList' => LyricsLayoutMode.ripple,
      'pureMusicLine' => LyricsLayoutMode.floatingLight,
      'pureMusicPlain' => LyricsLayoutMode.floatingLight,
      'pureMusicEnhanced' => LyricsLayoutMode.afterglow,
      'pureMusicWord' || 'pureMusic' => LyricsLayoutMode.stringPulse,
      _ => LyricsLayoutMode.albumVoice,
    };
  }
}

/// HoH painter 的歌词显示方式。
enum LyricDisplayMode {
  lineByLine('逐行'),
  wordByWord('逐字'),
  enhanced('增强歌词');

  const LyricDisplayMode(this.label);
  final String label;
}

/// 当前字的抬升曲线。
enum LyricLiftStyle {
  vertical('垂直抬升'),
  cosine('余弦抬升');

  const LyricLiftStyle(this.label);
  final String label;
}

/// 行切换方式。
enum LyricStaggerStyle {
  smooth('平滑'),
  spring('弹性');

  const LyricStaggerStyle(this.label);
  final String label;
}

/// 歌词显示样式。
@immutable
class LyricsStyle {
  /// 创建样式。
  const LyricsStyle({
    this.fontSize = 19,
    this.spacing = LyricLineSpacing.normal,
    this.autoScroll = true,
    this.activeScale = 1.25,
    this.align = LyricAlign.right,
    this.layout = LyricsLayoutMode.albumVoice,
    this.liftStyle = LyricLiftStyle.vertical,
    this.staggerStyle = LyricStaggerStyle.smooth,
    this.enableBlur = true,
    this.enableGlow = false,
    this.fontFamily = LyricFontFamily.kirakara,
    this.weight = LyricWeight.semibold,
    this.letterSpacing = 0.2,
    this.lyricsOpacity = 1.0,
    this.subtitleOpacity = 0.62,
    this.showTranslation = true,
    this.desktopOverlay = true,
    this.overlayLocked = false,
  });

  /// 普通行字号（当前行会再乘 [activeScale]）。
  ///
  /// 默认 19：0.0.17 之前是 14，用户反馈"字体不够大"。
  final double fontSize;

  /// 行距档位。
  final LyricLineSpacing spacing;

  /// 是否自动把当前行滚到中间。
  final bool autoScroll;

  /// 当前行相对普通行的放大倍数。
  final double activeScale;

  /// 对齐方式。
  final LyricAlign align;

  /// 正在播放页使用的歌词布局。
  final LyricsLayoutMode layout;

  /// 当前字抬升曲线、行切换方式和视觉开关。
  final LyricLiftStyle liftStyle;
  final LyricStaggerStyle staggerStyle;
  final bool enableBlur;
  final bool enableGlow;

  /// 由当前 HoH 预设决定，不另存一份易冲突的设置。
  LyricDisplayMode get displayMode => layout.displayMode;

  final LyricFontFamily fontFamily;
  final LyricWeight weight;
  final double letterSpacing;
  final double lyricsOpacity;
  final double subtitleOpacity;
  final bool showTranslation;

  /// 是否显示**桌面歌词浮层**（0.0.25：置顶、鼠标穿透的独立小窗）。
  final bool desktopOverlay;

  /// 锁定桌面歌词后不再拖动，桌面区域完全可点击。
  final bool overlayLocked;

  /// 浮层字号（比面板大一点才看得清）。
  static const double overlayFontSize = 26;

  /// 当前行字号。
  double get activeFontSize => fontSize * activeScale;

  /// 每行占用的高度（滚动定位按它算，必须与渲染一致）。
  double get lineExtent => activeFontSize * spacing.factor;

  LyricsStyle copyWith({
    double? fontSize,
    LyricLineSpacing? spacing,
    bool? autoScroll,
    double? activeScale,
    LyricAlign? align,
    LyricsLayoutMode? layout,
    LyricLiftStyle? liftStyle,
    LyricStaggerStyle? staggerStyle,
    bool? enableBlur,
    bool? enableGlow,
    LyricFontFamily? fontFamily,
    LyricWeight? weight,
    double? letterSpacing,
    double? lyricsOpacity,
    double? subtitleOpacity,
    bool? showTranslation,
    bool? desktopOverlay,
    bool? overlayLocked,
  }) {
    return LyricsStyle(
      fontSize: fontSize ?? this.fontSize,
      spacing: spacing ?? this.spacing,
      autoScroll: autoScroll ?? this.autoScroll,
      activeScale: activeScale ?? this.activeScale,
      align: align ?? this.align,
      layout: layout ?? this.layout,
      liftStyle: liftStyle ?? this.liftStyle,
      staggerStyle: staggerStyle ?? this.staggerStyle,
      enableBlur: enableBlur ?? this.enableBlur,
      enableGlow: enableGlow ?? this.enableGlow,
      fontFamily: fontFamily ?? this.fontFamily,
      weight: weight ?? this.weight,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      lyricsOpacity: lyricsOpacity ?? this.lyricsOpacity,
      subtitleOpacity: subtitleOpacity ?? this.subtitleOpacity,
      showTranslation: showTranslation ?? this.showTranslation,
      desktopOverlay: desktopOverlay ?? this.desktopOverlay,
      overlayLocked: overlayLocked ?? this.overlayLocked,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LyricsStyle &&
      other.fontSize == fontSize &&
      other.spacing == spacing &&
      other.autoScroll == autoScroll &&
      other.activeScale == activeScale &&
      other.align == align &&
      other.layout == layout &&
      other.liftStyle == liftStyle &&
      other.staggerStyle == staggerStyle &&
      other.enableBlur == enableBlur &&
      other.enableGlow == enableGlow &&
      other.fontFamily == fontFamily &&
      other.weight == weight &&
      other.letterSpacing == letterSpacing &&
      other.lyricsOpacity == lyricsOpacity &&
      other.subtitleOpacity == subtitleOpacity &&
      other.showTranslation == showTranslation &&
      other.desktopOverlay == desktopOverlay &&
      other.overlayLocked == overlayLocked;

  @override
  int get hashCode => Object.hash(
    fontSize,
    spacing,
    autoScroll,
    activeScale,
    align,
    layout,
    liftStyle,
    staggerStyle,
    enableBlur,
    enableGlow,
    fontFamily,
    weight,
    letterSpacing,
    lyricsOpacity,
    subtitleOpacity,
    showTranslation,
    desktopOverlay,
    overlayLocked,
  );
}

/// 歌词样式设置。
final lyricsStyleProvider =
    AsyncNotifierProvider<LyricsStyleController, LyricsStyle>(
      LyricsStyleController.new,
    );

/// 歌词样式控制器。
class LyricsStyleController extends AsyncNotifier<LyricsStyle> {
  static const String _sizeKey = 'lyrics.fontSize';
  static const String _spacingKey = 'lyrics.spacing';
  static const String _autoScrollKey = 'lyrics.autoScroll';
  static const String _alignKey = 'lyrics.align';
  static const String _layoutKey = 'lyrics.layout';
  static const String _liftStyleKey = 'lyrics.liftStyle';
  static const String _staggerStyleKey = 'lyrics.staggerStyle';
  static const String _blurKey = 'lyrics.enableBlur';
  static const String _glowKey = 'lyrics.enableGlow';
  static const String _fontKey = 'lyrics.fontFamily';
  static const String _kirakaraDefaultKey = 'lyrics.kirakaraDefaultApplied';
  static const String _weightKey = 'lyrics.weight';
  static const String _letterSpacingKey = 'lyrics.letterSpacing';
  static const String _lyricsOpacityKey = 'lyrics.lyricsOpacity';
  static const String _subtitleOpacityKey = 'lyrics.subtitleOpacity';
  static const String _showTranslationKey = 'lyrics.showTranslation';
  static const String _overlayKey = 'lyrics.desktopOverlay';
  static const String _overlayLockedKey = 'lyrics.overlayLocked';

  @override
  Future<LyricsStyle> build() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? spacingName = prefs.getString(_spacingKey);
      final String? alignName = prefs.getString(_alignKey);
      final String? layoutName = prefs.getString(_layoutKey);
      final String? liftStyleName = prefs.getString(_liftStyleKey);
      final String? staggerStyleName = prefs.getString(_staggerStyleKey);
      final String? fontName = prefs.getString(_fontKey);
      final String? weightName = prefs.getString(_weightKey);
      final bool applyKirakaraDefault =
          prefs.getBool(_kirakaraDefaultKey) != true;
      if (applyKirakaraDefault) {
        await prefs.setString(_fontKey, LyricFontFamily.kirakara.name);
        await prefs.setBool(_kirakaraDefaultKey, true);
      }
      final String? selectedFontName = applyKirakaraDefault
          ? LyricFontFamily.kirakara.name
          : fontName;
      return LyricsStyle(
        fontSize: (prefs.getDouble(_sizeKey) ?? 19).clamp(12.0, 34.0),
        spacing: LyricLineSpacing.values.firstWhere(
          (LyricLineSpacing s) => s.name == spacingName,
          orElse: () => LyricLineSpacing.normal,
        ),
        autoScroll: prefs.getBool(_autoScrollKey) ?? true,
        align: LyricAlign.values.firstWhere(
          (LyricAlign a) => a.name == alignName,
          orElse: () => LyricAlign.right,
        ),
        layout: LyricsLayoutMode.fromStoredName(layoutName),
        liftStyle: LyricLiftStyle.values.firstWhere(
          (LyricLiftStyle value) => value.name == liftStyleName,
          orElse: () => LyricLiftStyle.vertical,
        ),
        staggerStyle: LyricStaggerStyle.values.firstWhere(
          (LyricStaggerStyle value) => value.name == staggerStyleName,
          orElse: () => LyricStaggerStyle.smooth,
        ),
        enableBlur: prefs.getBool(_blurKey) ?? true,
        enableGlow: prefs.getBool(_glowKey) ?? false,
        fontFamily: LyricFontFamily.values.firstWhere(
          (LyricFontFamily item) => item.name == selectedFontName,
          orElse: () => LyricFontFamily.kirakara,
        ),
        weight: LyricWeight.values.firstWhere(
          (LyricWeight item) => item.name == weightName,
          orElse: () => LyricWeight.semibold,
        ),
        letterSpacing: (prefs.getDouble(_letterSpacingKey) ?? 0.2).clamp(
          -1.0,
          4.0,
        ),
        lyricsOpacity: (prefs.getDouble(_lyricsOpacityKey) ?? 1.0).clamp(
          0.2,
          1.0,
        ),
        subtitleOpacity: (prefs.getDouble(_subtitleOpacityKey) ?? 0.62).clamp(
          0.0,
          1.0,
        ),
        showTranslation: prefs.getBool(_showTranslationKey) ?? true,
        desktopOverlay: prefs.getBool(_overlayKey) ?? true,
        overlayLocked: prefs.getBool(_overlayLockedKey) ?? false,
      );
    } catch (error) {
      debugPrint('[Lyrics] 读取歌词样式失败（用默认）：$error');
      return const LyricsStyle();
    }
  }

  /// 设置对齐方式。
  Future<void> setAlign(LyricAlign align) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(align: align),
    );
    await _write((SharedPreferences p) => p.setString(_alignKey, align.name));
  }

  /// 设置正在播放页歌词布局。
  Future<void> setLayout(LyricsLayoutMode layout) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(layout: layout),
    );
    await _write((SharedPreferences p) => p.setString(_layoutKey, layout.name));
  }

  Future<void> setLiftStyle(LyricLiftStyle value) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(liftStyle: value),
    );
    await _write(
      (SharedPreferences p) => p.setString(_liftStyleKey, value.name),
    );
  }

  Future<void> setStaggerStyle(LyricStaggerStyle value) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(staggerStyle: value),
    );
    await _write(
      (SharedPreferences p) => p.setString(_staggerStyleKey, value.name),
    );
  }

  Future<void> setEnableBlur(bool value) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(enableBlur: value),
    );
    await _write((SharedPreferences p) => p.setBool(_blurKey, value));
  }

  Future<void> setEnableGlow(bool value) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(enableGlow: value),
    );
    await _write((SharedPreferences p) => p.setBool(_glowKey, value));
  }

  Future<void> setFontFamily(LyricFontFamily value) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(fontFamily: value),
    );
    await _write((SharedPreferences p) => p.setString(_fontKey, value.name));
  }

  Future<void> useImportedFont() => setFontFamily(LyricFontFamily.custom);

  Future<void> setWeight(LyricWeight value) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(weight: value),
    );
    await _write((SharedPreferences p) => p.setString(_weightKey, value.name));
  }

  Future<void> setLetterSpacing(double value) async {
    final double next = value.clamp(-1.0, 4.0);
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(letterSpacing: next),
    );
    await _write((SharedPreferences p) => p.setDouble(_letterSpacingKey, next));
  }

  Future<void> setLyricsOpacity(double value) async {
    final double next = value.clamp(0.2, 1.0);
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(lyricsOpacity: next),
    );
    await _write((SharedPreferences p) => p.setDouble(_lyricsOpacityKey, next));
  }

  Future<void> setSubtitleOpacity(double value) async {
    final double next = value.clamp(0.0, 1.0);
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(subtitleOpacity: next),
    );
    await _write(
      (SharedPreferences p) => p.setDouble(_subtitleOpacityKey, next),
    );
  }

  Future<void> setShowTranslation(bool value) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(showTranslation: value),
    );
    await _write(
      (SharedPreferences p) => p.setBool(_showTranslationKey, value),
    );
  }

  /// 设置字号。
  Future<void> setFontSize(double size) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(
        fontSize: size.clamp(12, 34),
      ),
    );
    await _write((SharedPreferences p) => p.setDouble(_sizeKey, size));
  }

  /// 设置行距档位。
  Future<void> setSpacing(LyricLineSpacing spacing) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(spacing: spacing),
    );
    await _write(
      (SharedPreferences p) => p.setString(_spacingKey, spacing.name),
    );
  }

  /// 开关自动滚动。
  Future<void> setAutoScroll(bool value) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(autoScroll: value),
    );
    await _write((SharedPreferences p) => p.setBool(_autoScrollKey, value));
  }

  /// 开关桌面歌词浮层（0.0.25）。
  Future<void> setDesktopOverlay(bool value) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(desktopOverlay: value),
    );
    await _write((SharedPreferences p) => p.setBool(_overlayKey, value));
  }

  /// 锁定桌面歌词：锁定后窗口不参与拖动，桌面区域可直接点击。
  Future<void> setOverlayLocked(bool value) async {
    state = AsyncData<LyricsStyle>(
      (state.value ?? const LyricsStyle()).copyWith(overlayLocked: value),
    );
    await _write((SharedPreferences p) => p.setBool(_overlayLockedKey, value));
  }

  Future<void> _write(
    Future<void> Function(SharedPreferences prefs) action,
  ) async {
    try {
      await action(await SharedPreferences.getInstance());
    } catch (error) {
      debugPrint('[Lyrics] 保存歌词样式失败：$error');
    }
  }
}
