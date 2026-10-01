/// appearance_settings.dart
///
/// 外观设置页（0.0.10 起不再是弹窗；入口在左侧边栏「来源」下面，
/// 内容显示在右侧主区，与播放面板同一套排版）。
///
/// 三组内容：
/// 1. **背景** —— 内置场景缩略图 + 自定义背景图（0.0.11 新增）；
/// 2. **模糊与通透** —— 玻璃模糊强度、通透度；
/// 3. **边框高光 / 开关** —— 高光强度、高光流动、玻璃效果、界面动画。
///
/// 参数机制：默认跟随性能档位（桌面端自动判定「高端」），
/// 一旦手动调整过就保持用户取值（见 [GlassOverrides]）。
///
/// 历史：0.0.8 去掉「高光流动速度 / 背景粒子 / 磨砂噪点」；
/// 0.0.10 从弹窗改为内嵌页；0.0.11 加背景图选择；
/// 0.0.23 去掉「低配显卡模式」（档位本来就是自动判定的，这个手开关是多余的）。
library;

import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart'
    show FilePicker, FileType, PlatformFile;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../shared/theme/app_accent.dart';
import '../../shared/theme/app_background.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/theme/custom_fonts.dart';
import '../../shared/theme/performance_tier.dart';
import '../../shared/theme/theme_bundle.dart';
import '../../shared/widgets/widget_kit/glass_panel.dart';
import '../../shared/widgets/motion/hoh_motion.dart';
import 'cover_style.dart';
import 'compact_player_settings.dart';
import 'lyrics/lyrics_style.dart';
import 'liquid_glass_plus_preview.dart';
import 'player_layout_settings.dart';

/// 外观设置页（内嵌在播放页右侧主区）。
class AppearanceSettingsView extends ConsumerWidget {
  const AppearanceSettingsView({super.key});

  /// 与播放面板一致的小标题样式（「正在播放」用的就是这套）。
  static const TextStyle _sectionLabel = TextStyle(
    color: Color(0x8CFFFFFF),
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 2.2,
  );

  /// 内容区最大宽度。太宽的话滑杆会被拉得很长，读数反而难对。
  static const double _maxContentWidth = 880;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BlurConfig config = ref.watch(blurConfigProvider);
    final GlassOverrides overrides = ref.watch(glassOverridesProvider);
    final GlassOverridesController controller = ref.read(
      glassOverridesProvider.notifier,
    );
    // 强调色跟随背景：这里读到的颜色正是当前背景算出来的那套
    final AppAccent accent = AppAccent.of(context);

    return HoHMotion.enter(
      GlassPanel(
        borderRadius: BorderRadius.circular(16),
        // 与其它面板完全同一套取参方式：改设置时，这块面板本身就是预览
        blurSigma: config.blurSigma,
        blurEnabled: config.useBlur,
        showSweepAt: config.sweepEnabled && config.animationsEnabled,
        glowOpacity: config.glowStrength,
        glowColor: config.glowColor,
        tintOpacity: config.tintOpacity,
        initialSweepPhase: 0.5,
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('外观设置', style: _sectionLabel),
            const SizedBox(height: 8),
            Text(
              '背景随时可换；玻璃参数默认跟随性能档位「${config.tier.label}」'
              '（桌面端自动判定），调整过的项会保持你的取值。',
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),

            Expanded(
              child: SingleChildScrollView(
                // 切到别的页再回来，滚动位置也能记住
                // （页面内改设置不会丢位置是靠 GlassPanel 的稳定 key，见那个文件）
                key: const PageStorageKey<String>('appearance-settings-scroll'),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: _maxContentWidth,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _GroupLabel('背景', color: accent.primary),
                        const BackgroundPicker(),
                        const SizedBox(height: 18),

                        const _ImportedFontsSection(),
                        const SizedBox(height: 18),

                        _GroupLabel('主题颜色', color: accent.primary),
                        _RgbColorWheel(
                          selected: ref.watch(themeColorProvider),
                          accent: accent,
                          onChanged: (Color color) => ref
                              .read(themeColorProvider.notifier)
                              .setColor(color),
                          onReset: () => ref
                              .read(themeColorProvider.notifier)
                              .setColor(null),
                        ),
                        const SizedBox(height: 8),
                        _ThemeBundleActions(
                          accent: accent,
                          onExport: () => _exportTheme(context, ref),
                          onImport: () => _importTheme(context, ref),
                        ),
                        const SizedBox(height: 18),

                        _GroupLabel('播放页布局', color: accent.primary),
                        const PlayerControlLayoutSection(),
                        const SizedBox(height: 18),

                        _CompactCornerSection(accent: accent),
                        const SizedBox(height: 18),

                        _GroupLabel('歌词', color: accent.primary),
                        const LyricsStyleSection(),
                        const SizedBox(height: 18),

                        _GroupLabel('封面黑胶', color: accent.primary),
                        const CoverStageSection(),
                        const SizedBox(height: 18),

                        _GroupLabel('Liquid Glass Plus', color: accent.primary),
                        _SliderRow(
                          accent: accent,
                          label: '玻璃染色强度',
                          hint: '${(config.tintOpacity * 100).round()}%',
                          value: config.tintOpacity,
                          max: 1,
                          onChanged: controller.setTintOpacity,
                        ),
                        _SliderRow(
                          accent: accent,
                          label: '玻璃厚度',
                          hint:
                              '${config.glassThickness.toStringAsFixed(1)} px',
                          value: config.glassThickness,
                          max: 30,
                          onChanged: controller.setGlassThickness,
                        ),
                        _SliderRow(
                          accent: accent,
                          label: '磨砂强度',
                          hint: config.frostIntensity.toStringAsFixed(1),
                          value: config.frostIntensity,
                          max: 20,
                          onChanged: controller.setFrostIntensity,
                        ),
                        _SliderRow(
                          accent: accent,
                          label: '折射率',
                          hint: config.refractiveIndex.toStringAsFixed(3),
                          value: config.refractiveIndex,
                          min: 1,
                          max: 1.5,
                          onChanged: controller.setRefractiveIndex,
                        ),
                        _SliderRow(
                          accent: accent,
                          label: '色散强度',
                          hint: config.chromaticAberration.toStringAsFixed(3),
                          value: config.chromaticAberration,
                          max: 0.03,
                          onChanged: controller.setChromaticAberration,
                        ),
                        _SliderRow(
                          accent: accent,
                          label: '光照角度',
                          hint:
                              '${(config.lightAngle * 180 / 3.1415926535).round()}°',
                          value: config.lightAngle,
                          max: 6.283,
                          onChanged: controller.setLightAngle,
                        ),
                        _SliderRow(
                          accent: accent,
                          label: '光照强度',
                          hint: config.lightIntensity.toStringAsFixed(2),
                          value: config.lightIntensity,
                          max: 2,
                          onChanged: controller.setLightIntensity,
                        ),
                        _SliderRow(
                          accent: accent,
                          label: '环境光',
                          hint: config.ambientStrength.toStringAsFixed(2),
                          value: config.ambientStrength,
                          max: 1,
                          onChanged: controller.setAmbientStrength,
                        ),
                        _SliderRow(
                          accent: accent,
                          label: '背景饱和度倍率',
                          hint: config.liquidSaturation.toStringAsFixed(2),
                          value: config.liquidSaturation,
                          min: 0.5,
                          max: 2,
                          onChanged: controller.setLiquidSaturation,
                        ),
                        _SliderRow(
                          accent: accent,
                          label: 'Skia 回退折射',
                          hint: config.fakeGlassRefraction.toStringAsFixed(1),
                          value: config.fakeGlassRefraction,
                          max: 8,
                          onChanged: controller.setFakeGlassRefraction,
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () => showLiquidGlassPlusPreview(context),
                          icon: const Icon(Icons.science_outlined, size: 16),
                          label: const Text('试用 liquid_glass_plus 液态玻璃'),
                        ),
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            '试用面板与主界面使用同一套插件参数。',
                            style: TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: 10.5,
                            ),
                          ),
                        ),

                        const SizedBox(height: 12),
                        _GroupLabel('边框高光', color: accent.primary),
                        _SliderRow(
                          accent: accent,
                          label: '高光强度',
                          hint: '${(config.glowStrength * 100).round()}%',
                          value: config.glowStrength.clamp(0.0, 1.0),
                          max: 1.0,
                          onChanged: controller.setGlowStrength,
                        ),
                        _SwitchRow(
                          accent: accent,
                          label: '边框高光流动',
                          hint: '边框本身被照亮并绕行；固定 14 秒一圈',
                          value: config.sweepEnabled,
                          onChanged: controller.setSweep,
                        ),
                        const SizedBox(height: 10),
                        _GlowColorPicker(
                          selected: config.glowColor,
                          accent: accent,
                          onChanged: controller.setGlowColor,
                        ),

                        const SizedBox(height: 12),
                        _GroupLabel('开关', color: accent.primary),
                        _SwitchRow(
                          accent: accent,
                          label: '玻璃效果',
                          hint: '液态玻璃模糊。关掉后用纯色半透明代替，最省 GPU',
                          value: config.useBlur,
                          onChanged: (bool on) =>
                              controller.setBlurSigma(on ? 16 : 0),
                        ),
                        _SwitchRow(
                          accent: accent,
                          label: '界面动画',
                          hint: '关闭后所有过渡立即生效',
                          value: config.animationsEnabled,
                          onChanged: controller.setAnimations,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),
            const Divider(color: AppColors.divider, height: 1),
            const SizedBox(height: 12),

            // ── 底部操作行（与面板同一套排版）────────────────────────
            Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: overrides.isEmpty
                      ? null
                      : () {
                          controller.resetAll();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('已恢复为档位默认值'),
                              duration: Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                  icon: const Icon(Icons.restart_alt_rounded, size: 15),
                  label: const Text('恢复默认'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.neonCyan,
                    textStyle: const TextStyle(fontSize: 12.5),
                  ),
                ),
                const Spacer(),
                if (!overrides.isEmpty)
                  const Text(
                    '已自定义',
                    style: TextStyle(
                      color: AppColors.neonMagenta,
                      fontSize: 11.5,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      enabled: config.animationsEnabled,
    );
  }

  Future<void> _exportTheme(BuildContext context, WidgetRef ref) async {
    try {
      final ThemeBundle bundle = ThemeBundle.fromConfig(
        background: ref.read(backgroundProvider),
        themeColor: ref.read(themeColorProvider),
        glass: ref.read(blurConfigProvider),
      );
      final Uint8List bytes = await bundle.encodeArchive();
      await FilePicker.saveFile(
        dialogTitle: '导出 HoH music 主题',
        fileName: 'hoh-theme.hohtheme',
        bytes: bytes,
      );
      if (context.mounted) _toast(context, '主题已导出');
    } catch (error) {
      if (context.mounted) _toast(context, '导出失败：$error', isError: true);
    }
  }

  Future<void> _importTheme(BuildContext context, WidgetRef ref) async {
    try {
      final List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['hohtheme', 'json'],
        dialogTitle: '导入 HoH music 主题',
      );
      if (files.isEmpty) return;
      final String? path = files.first.path;
      if (path == null || path.isEmpty) return;
      final Uint8List bytes = await File(path).readAsBytes();
      final ThemeBundle bundle = ThemeBundle.fromArchive(bytes);
      BackgroundSelection importedBackground = bundle.background;
      final String? bundledImage = importedBackground.customImagePath;
      if (bundledImage != null && bundle.files.containsKey(bundledImage)) {
        final Directory targetDir = Directory(
          '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}themes',
        );
        await targetDir.create(recursive: true);
        final String target =
            '${targetDir.path}${Platform.pathSeparator}imported_${DateTime.now().millisecondsSinceEpoch}${pExtension(bundledImage)}';
        await File(target).writeAsBytes(bundle.files[bundledImage]!);
        importedBackground = BackgroundSelection(
          kind: BackgroundKind.custom,
          customImagePath: target,
          dynamicDefinition: importedBackground.dynamicDefinition,
        );
      }
      final BackgroundController backgrounds = ref.read(
        backgroundProvider.notifier,
      );
      backgrounds.apply(importedBackground);
      await ref.read(themeColorProvider.notifier).setColor(bundle.themeColor);
      final Map<Object?, Object?> glass = bundle.glass;
      final GlassOverridesController controller = ref.read(
        glassOverridesProvider.notifier,
      );
      if (glass['blurSigma'] is num) {
        await controller.setBlurSigma((glass['blurSigma'] as num).toDouble());
      }
      if (glass['tintOpacity'] is num) {
        await controller.setTintOpacity(
          (glass['tintOpacity'] as num).toDouble(),
        );
      }
      if (glass['glassSaturation'] is num) {
        await controller.setGlassSaturation(
          (glass['glassSaturation'] as num).toDouble(),
        );
      }
      if (glass['glassTone'] is num) {
        await controller.setGlassTone((glass['glassTone'] as num).toDouble());
      }
      if (glass['glassThickness'] is num) {
        await controller.setGlassThickness(
          (glass['glassThickness'] as num).toDouble(),
        );
      }
      if (glass['frostIntensity'] is num) {
        await controller.setFrostIntensity(
          (glass['frostIntensity'] as num).toDouble(),
        );
      }
      if (glass['refractiveIndex'] is num) {
        await controller.setRefractiveIndex(
          (glass['refractiveIndex'] as num).toDouble(),
        );
      }
      if (glass['chromaticAberration'] is num) {
        await controller.setChromaticAberration(
          (glass['chromaticAberration'] as num).toDouble(),
        );
      }
      if (glass['lightAngle'] is num) {
        await controller.setLightAngle((glass['lightAngle'] as num).toDouble());
      }
      if (glass['lightIntensity'] is num) {
        await controller.setLightIntensity(
          (glass['lightIntensity'] as num).toDouble(),
        );
      }
      if (glass['ambientStrength'] is num) {
        await controller.setAmbientStrength(
          (glass['ambientStrength'] as num).toDouble(),
        );
      }
      if (glass['liquidSaturation'] is num) {
        await controller.setLiquidSaturation(
          (glass['liquidSaturation'] as num).toDouble(),
        );
      }
      if (glass['fakeGlassRefraction'] is num) {
        await controller.setFakeGlassRefraction(
          (glass['fakeGlassRefraction'] as num).toDouble(),
        );
      }
      if (glass['glowStrength'] is num) {
        await controller.setGlowStrength(
          (glass['glowStrength'] as num).toDouble(),
        );
      }
      if (glass['sweepEnabled'] is bool) {
        await controller.setSweep(glass['sweepEnabled'] as bool);
      }
      if (glass['animationsEnabled'] is bool) {
        await controller.setAnimations(glass['animationsEnabled'] as bool);
      }
      if (context.mounted) _toast(context, '主题已导入并应用');
    } catch (error) {
      if (context.mounted) _toast(context, '导入失败：$error', isError: true);
    }
  }

  String pExtension(String path) {
    final int dot = path.lastIndexOf('.');
    return dot < 0 ? '.png' : path.substring(dot);
  }

  void _toast(BuildContext context, String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? const Color(0xFF8B1A3A) : null,
      ),
    );
  }
}

class _ThemeBundleActions extends StatelessWidget {
  const _ThemeBundleActions({
    required this.accent,
    required this.onExport,
    required this.onImport,
  });

  final AppAccent accent;
  final VoidCallback onExport;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text('主题包', style: TextStyle(color: accent.primary, fontSize: 12)),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: onImport,
          icon: const Icon(Icons.file_open_outlined, size: 15),
          label: const Text('导入'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: onExport,
          icon: const Icon(Icons.ios_share_outlined, size: 15),
          label: const Text('导出'),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            '可传播的 .hohtheme 文件（图片仅保存路径）',
            style: TextStyle(color: AppColors.textTertiary, fontSize: 10.5),
          ),
        ),
      ],
    );
  }
}

class _CompactCornerSection extends ConsumerWidget {
  const _CompactCornerSection({required this.accent});

  final AppAccent accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CompactCorner selected = ref.watch(compactCornerProvider);
    final CompactCornerController controller = ref.read(
      compactCornerProvider.notifier,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _GroupLabel('紧凑播放器', color: accent.primary),
        const SizedBox(height: 6),
        const Text(
          '固定尺寸 · 选择出现位置',
          style: TextStyle(color: AppColors.textTertiary, fontSize: 11),
        ),
        const SizedBox(height: 8),
        SegmentedButton<CompactCorner>(
          segments: <ButtonSegment<CompactCorner>>[
            for (final CompactCorner corner in CompactCorner.values)
              ButtonSegment<CompactCorner>(
                value: corner,
                label: Text(corner.label),
              ),
          ],
          selected: <CompactCorner>{selected},
          onSelectionChanged: (Set<CompactCorner> values) {
            final CompactCorner? value = values.firstOrNull;
            if (value != null) controller.setCorner(value);
          },
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity(horizontal: -2, vertical: -2),
            textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  背景选择
// ════════════════════════════════════════════════════════════════

/// 背景选择器：缩略图网格 + 自定义图片。
///
/// 缩略图就是 [BackgroundLayer] 的小尺寸渲染 —— 预览必然与实际一致。
class BackgroundPicker extends ConsumerWidget {
  const BackgroundPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BackgroundSelection selection = ref.watch(backgroundProvider);
    final BackgroundController controller = ref.read(
      backgroundProvider.notifier,
    );
    final AppAccent accent = AppAccent.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            const double gap = 12;
            final int columns = c.maxWidth >= 820
                ? 4
                : (c.maxWidth >= 560 ? 3 : 2);
            final double tileWidth =
                (c.maxWidth - gap * (columns - 1)) / columns;

            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                for (final BackgroundKind kind in BackgroundKind.values)
                  SizedBox(
                    width: tileWidth,
                    child: _BackgroundTile(
                      kind: kind,
                      selection: selection,
                      accent: accent,
                      onTap: () => _onTap(context, ref, kind),
                    ),
                  ),
              ],
            );
          },
        ),
        if (selection.hasCustomImage) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              TextButton.icon(
                onPressed: () => _pickImage(context, ref),
                icon: const Icon(Icons.image_outlined, size: 14),
                label: const Text('更换图片'),
                style: TextButton.styleFrom(
                  foregroundColor: accent.primary,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                onPressed: () {
                  controller.clearCustomImage();
                  _toast(context, '已清除自定义背景');
                },
                icon: const Icon(Icons.delete_outline_rounded, size: 14),
                label: const Text('清除'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.textTertiary,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              const Spacer(),
              const Text(
                '图片只记录路径，不会被复制进程序目录',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 10.5),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 点某个缩略图：内置场景直接选中；自定义项则先选图片。
  void _onTap(BuildContext context, WidgetRef ref, BackgroundKind kind) {
    final BackgroundController controller = ref.read(
      backgroundProvider.notifier,
    );

    if (kind != BackgroundKind.custom) {
      controller.select(kind);
      return;
    }

    final BackgroundSelection selection = ref.read(backgroundProvider);
    if (selection.hasCustomImage) {
      // 已经有图片：点它只是切回来（换图用下面的「更换图片」）
      controller.select(BackgroundKind.custom);
    } else {
      _pickImage(context, ref);
    }
  }

  /// 打开系统文件框选一张图片。
  Future<void> _pickImage(BuildContext context, WidgetRef ref) async {
    try {
      final PlatformFile? file = await FilePicker.pickFile(
        type: FileType.image,
        dialogTitle: '选择背景图片',
      );
      final String? path = file?.path;
      if (path == null || path.isEmpty) return;
      ref.read(backgroundProvider.notifier).setCustomImage(path);
      if (context.mounted) _toast(context, '已设置为自定义背景');
    } catch (error) {
      debugPrint('[Background] 选择图片失败：$error');
      if (context.mounted) _toast(context, '选择图片失败：$error', isError: true);
    }
  }

  void _toast(BuildContext context, String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? const Color(0xFF8B1A3A) : null,
      ),
    );
  }
}

/// 单张背景缩略图卡片。
class _BackgroundTile extends StatelessWidget {
  const _BackgroundTile({
    required this.kind,
    required this.selection,
    required this.accent,
    required this.onTap,
  });

  final BackgroundKind kind;
  final BackgroundSelection selection;
  final AppAccent accent;
  final VoidCallback onTap;

  /// 该项是否是当前选中的背景。
  bool get _selected {
    if (kind == BackgroundKind.custom) {
      return selection.kind == BackgroundKind.custom &&
          selection.hasCustomImage;
    }
    // 自定义项选了但还没图片时，实际生效的是液态流光
    return selection.kind == kind ||
        (selection.kind == BackgroundKind.custom &&
            !selection.hasCustomImage &&
            kind == BackgroundKind.liquidBloom);
  }

  @override
  Widget build(BuildContext context) {
    final bool isCustom = kind == BackgroundKind.custom;
    final bool hasImage = isCustom && selection.hasCustomImage;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AspectRatio(
              aspectRatio: 16 / 10,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _selected
                        ? accent.primary
                        : Colors.white.withValues(alpha: 0.14),
                    width: _selected ? 2 : 1,
                  ),
                  boxShadow: _selected
                      ? AppColors.neonGlow(
                          accent.primary,
                          strength: 0.35,
                          radius: 14,
                        )
                      : null,
                ),
                padding: const EdgeInsets.all(2),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if (isCustom && !hasImage)
                        const _CustomPlaceholder()
                      else if (isCustom)
                        BackgroundLayer(
                          // ⚠️ 这里**不能**传当前 selection：那样一来，
                          // 选中别的场景时这张"自定义图片"缩略图会跟着变成
                          // 那个场景（0.0.12 修的 bug）。只渲染图片本身。
                          selection: BackgroundSelection(
                            kind: BackgroundKind.custom,
                            customImagePath: selection.customImagePath,
                          ),
                          // 预览图不需要原图分辨率
                          customImageCacheWidth: 480,
                        )
                      else
                        BackgroundLayer(
                          selection: BackgroundSelection(kind: kind),
                          animated: false,
                        ),
                      if (_selected)
                        Positioned(
                          right: 5,
                          top: 5,
                          child: _SelectedBadge(color: accent.primary),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              kind.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: _selected ? FontWeight.w600 : FontWeight.w400,
                color: _selected ? Colors.white : const Color(0xBFFFFFFF),
              ),
            ),
            Text(
              kind.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「自定义图片」还没有图片时的占位块。
class _CustomPlaceholder extends StatelessWidget {
  const _CustomPlaceholder();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF16102A), Color(0xFF0B0718)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.add_photo_alternate_outlined,
            size: 22,
            color: Colors.white.withValues(alpha: 0.72),
          ),
          const SizedBox(height: 4),
          Text(
            '添加图片',
            style: TextStyle(
              fontSize: 10.5,
              color: Colors.white.withValues(alpha: 0.66),
            ),
          ),
        ],
      ),
    );
  }
}

/// 选中角标。
class _SelectedBadge extends StatelessWidget {
  const _SelectedBadge({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      child: const Icon(
        Icons.check_rounded,
        size: 11,
        color: Color(0xFF06121C),
      ),
    );
  }
}

/// 歌词显示设置：字号 / 行距 / 自动滚动。
/// 播放页控制区布局选择。
///
/// 这是共享 Flutter 设置；侧栏/底部的实际过渡由 [PlayerPage] 用
/// `AnimatedSize` 驱动，设置页本身只负责持久化当前选择。
class PlayerControlLayoutSection extends ConsumerWidget {
  const PlayerControlLayoutSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final PlayerControlLayout layout =
        ref.watch(playerControlLayoutProvider).value ??
        PlayerControlLayout.sidebar;
    final PlayerControlLayoutController controller = ref.read(
      playerControlLayoutProvider.notifier,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _ChoiceRow<PlayerControlLayout>(
          label: '控制区位置',
          values: PlayerControlLayout.values,
          current: layout,
          labelOf: (PlayerControlLayout value) => value.label,
          onChanged: controller.setLayout,
          accent: accent,
        ),
        Text(
          layout.description,
          style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
        ),
      ],
    );
  }
}

class LyricsStyleSection extends ConsumerWidget {
  const LyricsStyleSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final LyricsStyle style =
        ref.watch(lyricsStyleProvider).value ?? const LyricsStyle();
    final LyricsStyleController controller = ref.read(
      lyricsStyleProvider.notifier,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ChoiceRow<LyricsLayoutMode>(
          label: '歌词视觉模式',
          values: LyricsLayoutMode.values,
          current: style.layout,
          labelOf: (LyricsLayoutMode value) => value.label,
          onChanged: controller.setLayout,
          accent: accent,
        ),
        const SizedBox(height: 8),
        _ChoiceRow<LyricLiftStyle>(
          label: '当前字抬升',
          values: LyricLiftStyle.values,
          current: style.liftStyle,
          labelOf: (LyricLiftStyle value) => value.label,
          onChanged: controller.setLiftStyle,
          accent: accent,
        ),
        _ChoiceRow<LyricStaggerStyle>(
          label: '歌词行切换',
          values: LyricStaggerStyle.values,
          current: style.staggerStyle,
          labelOf: (LyricStaggerStyle value) => value.label,
          onChanged: controller.setStaggerStyle,
          accent: accent,
        ),
        _SwitchRow(
          accent: accent,
          label: '歌词模糊',
          hint: '按歌词与当前行的距离柔和淡出',
          value: style.enableBlur,
          onChanged: controller.setEnableBlur,
        ),
        _SwitchRow(
          accent: accent,
          label: '逐字辉光',
          hint: '仅在有逐字时间轴时显示当前字辉光',
          value: style.enableGlow,
          onChanged: controller.setEnableGlow,
        ),
        const SizedBox(height: 12),
        _SliderRow(
          accent: accent,
          label: '字号',
          hint: '${style.fontSize.toStringAsFixed(0)} px',
          value: style.fontSize.clamp(12.0, 34.0),
          max: 34,
          min: 12,
          onChanged: controller.setFontSize,
        ),
        _GroupLabel('歌词字体', color: accent.primary),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final LyricFontFamily option in LyricFontFamily.values)
              _PillButton(
                label: option.label,
                selected: option == style.fontFamily,
                accent: accent,
                onTap: () => controller.setFontFamily(option),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _ChoiceRow<LyricWeight>(
          label: '字重',
          values: LyricWeight.values,
          current: style.weight,
          labelOf: (LyricWeight value) => value.label,
          onChanged: controller.setWeight,
          accent: accent,
        ),
        _SliderRow(
          accent: accent,
          label: '字距',
          hint: '${style.letterSpacing.toStringAsFixed(1)} px',
          value: style.letterSpacing,
          min: -1,
          max: 4,
          onChanged: controller.setLetterSpacing,
        ),
        _ChoiceRow<LyricAlign>(
          label: '对齐',
          values: LyricAlign.values,
          current: style.align,
          labelOf: (LyricAlign value) => value.label,
          onChanged: controller.setAlign,
          accent: accent,
        ),
        _ChoiceRow<LyricLineSpacing>(
          label: '行距',
          values: LyricLineSpacing.values,
          current: style.spacing,
          labelOf: (LyricLineSpacing value) => value.label,
          onChanged: controller.setSpacing,
          accent: accent,
        ),
        _SliderRow(
          accent: accent,
          label: '歌词透明度',
          hint: '${(style.lyricsOpacity * 100).round()}%',
          value: style.lyricsOpacity,
          max: 1,
          min: 0.2,
          onChanged: controller.setLyricsOpacity,
        ),
        _SwitchRow(
          accent: accent,
          label: '显示翻译',
          hint: '在当前歌词下方显示翻译或副标题',
          value: style.showTranslation,
          onChanged: controller.setShowTranslation,
        ),
        _SliderRow(
          accent: accent,
          label: '副标题透明度',
          hint: '${(style.subtitleOpacity * 100).round()}%',
          value: style.subtitleOpacity,
          max: 1,
          onChanged: controller.setSubtitleOpacity,
        ),
        _SwitchRow(
          accent: accent,
          label: '歌词自动滚动',
          hint: '当前行自动滚到面板中间',
          value: style.autoScroll,
          onChanged: controller.setAutoScroll,
        ),
        _SwitchRow(
          accent: accent,
          label: '桌面歌词',
          hint: '在屏幕底部显示同步歌词浮层',
          value: style.desktopOverlay,
          onChanged: controller.setDesktopOverlay,
        ),
        if (style.desktopOverlay)
          _SwitchRow(
            accent: accent,
            label: '锁定桌面歌词',
            hint: '锁定后不可拖动，桌面区域可直接点击',
            value: style.overlayLocked,
            onChanged: controller.setOverlayLocked,
          ),
      ],
    );
  }
}

class _ImportedFontsSection extends ConsumerWidget {
  const _ImportedFontsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final CustomFontSettings fonts =
        ref.watch(customFontsProvider).value ?? const CustomFontSettings();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _GroupLabel('导入 TTF 字体', color: accent.primary),
        const Text(
          'UI 字体和歌词字体分开保存；字体只复制到应用数据目录，不修改系统字体。',
          style: TextStyle(color: AppColors.textTertiary, fontSize: 11.5),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            _fontButton(
              context,
              ref,
              CustomFontSlot.ui,
              fonts.hasUi ? '替换 UI 字体' : '导入 UI 字体',
              fonts.uiPath,
            ),
            _fontButton(
              context,
              ref,
              CustomFontSlot.lyrics,
              fonts.hasLyrics ? '替换歌词字体' : '导入歌词字体',
              fonts.lyricsPath,
            ),
          ],
        ),
        if (fonts.uiPath != null || fonts.lyricsPath != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            'UI：${_fileName(fonts.uiPath)}  ·  歌词：${_fileName(fonts.lyricsPath)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10.5,
            ),
          ),
        ],
      ],
    );
  }

  Widget _fontButton(
    BuildContext context,
    WidgetRef ref,
    CustomFontSlot slot,
    String label,
    String? path,
  ) {
    return OutlinedButton.icon(
      onPressed: () => _pick(context, ref, slot),
      icon: const Icon(Icons.font_download_outlined, size: 15),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppAccent.of(context).primary,
        textStyle: const TextStyle(fontSize: 12),
      ),
    );
  }

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    CustomFontSlot slot,
  ) async {
    final List<PlatformFile> result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['ttf'],
      dialogTitle: '选择 TTF 字体',
    );
    final String? path = result.isEmpty ? null : result.first.path;
    if (path == null || path.isEmpty) return;
    try {
      await ref.read(customFontsProvider.notifier).importFont(slot, path);
      if (slot == CustomFontSlot.lyrics) {
        await ref.read(lyricsStyleProvider.notifier).useImportedFont();
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(slot == CustomFontSlot.ui ? 'UI 字体已替换' : '歌词字体已替换'),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('字体导入失败：$error')));
      }
    }
  }

  static String _fileName(String? path) {
    if (path == null || path.isEmpty) return '系统默认';
    return path.split(RegExp(r'[\\/]')).last;
  }
}

class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.values,
    required this.current,
    required this.labelOf,
    required this.onChanged,
    required this.accent,
  });

  final String label;
  final List<T> values;
  final T current;
  final String Function(T value) labelOf;
  final ValueChanged<T> onChanged;
  final AppAccent accent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        for (final T value in values)
          _PillButton(
            label: labelOf(value),
            selected: value == current,
            accent: accent,
            onTap: () => onChanged(value),
          ),
      ],
    ),
  );
}

/// 小圆角选择按钮（行距这类少数几个选项用）。
class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final AppAccent accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: selected
                ? accent.primary.withValues(alpha: 0.18)
                : Colors.black.withValues(alpha: 0.22),
            border: Border.all(
              color: selected
                  ? accent.primary.withValues(alpha: 0.75)
                  : Colors.white.withValues(alpha: 0.12),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: selected ? accent.primary : const Color(0xBFFFFFFF),
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面黑胶设置：是否旋转。
class CoverStageSection extends ConsumerWidget {
  const CoverStageSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAccent accent = AppAccent.of(context);
    final CoverStageStyle style =
        ref.watch(coverStageStyleProvider).value ?? const CoverStageStyle();
    final CoverStageStyleController controller = ref.read(
      coverStageStyleProvider.notifier,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SwitchRow(
          accent: accent,
          label: '黑胶旋转',
          hint:
              '底部控制条那颗黑胶：播放时 33⅓ 转/分匀速转，'
              '暂停定格不回正；关掉后整块静止（省 GPU）',
          value: style.spin,
          onChanged: controller.setSpin,
        ),
        const SizedBox(height: 2),
        const Text(
          '专辑封面是固定层（永不旋转），只有控制条上的黑胶在转。',
          style: TextStyle(
            color: AppColors.textTertiary,
            fontSize: 10.5,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

/// RGB 色轮：外圈选色相，内方块选饱和度和明度，玻璃自动使用互补色。
///
/// 旧实现只有固定饱和度/明度的色相环，因此黑、白、灰永远选不出来。
/// 现在内方块的左上角是白色，右上角是当前色相的高饱和色，底部渐变到
/// 黑色，覆盖完整 HSV 取色范围且不依赖平台原生颜色选择器。
class _RgbColorWheel extends StatelessWidget {
  const _RgbColorWheel({
    required this.selected,
    required this.accent,
    required this.onChanged,
    required this.onReset,
  });

  final Color? selected;
  final AppAccent accent;
  final ValueChanged<Color> onChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final Color current = selected ?? accent.primary;
    return Row(
      children: <Widget>[
        GestureDetector(
          onPanDown: (DragDownDetails details) => _pick(details.localPosition),
          onPanUpdate: (DragUpdateDetails details) =>
              _pick(details.localPosition),
          child: CustomPaint(
            size: const Size.square(120),
            painter: _RgbWheelPainter(current),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                selected == null ? '跟随背景主题' : '自定义 RGB 主题色',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                '#${current.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                ),
              ),
              const Text(
                '外圈色相 · 内部饱和度/明度（支持黑、白、灰）',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 10.5),
              ),
              TextButton(
                onPressed: onReset,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('跟随背景'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _pick(Offset point) {
    const Offset center = Offset(60, 60);
    final Offset delta = point - center;
    final double distance = delta.distance;
    final HSVColor hsv = HSVColor.fromColor(selected ?? accent.primary);

    // 色相环：保留当前的饱和度和明度，只改变色相。
    if (distance >= 43 && distance <= 58) {
      final double hue =
          (math.atan2(delta.dy, delta.dx) * 180 / math.pi + 90) % 360;
      onChanged(HSVColor.fromAHSV(1, hue, hsv.saturation, hsv.value).toColor());
      return;
    }

    // 内部 SV 方块：左=低饱和/白，右=高饱和；上=高明度，下=黑。
    const Rect square = Rect.fromLTWH(28, 28, 64, 64);
    if (!square.contains(point)) return;
    final double saturation = ((point.dx - square.left) / square.width).clamp(
      0.0,
      1.0,
    );
    final double value = (1 - (point.dy - square.top) / square.height).clamp(
      0.0,
      1.0,
    );
    onChanged(HSVColor.fromAHSV(1, hsv.hue, saturation, value).toColor());
  }
}

class _RgbWheelPainter extends CustomPainter {
  const _RgbWheelPainter(this.selected);
  final Color selected;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = size.shortestSide / 2;
    final HSVColor selectedHsv = HSVColor.fromColor(selected);
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..shader = SweepGradient(
        colors: <Color>[
          for (int i = 0; i <= 12; i++)
            HSVColor.fromAHSV(1, i * 30.0, 0.92, 0.98).toColor(),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius - 7));
    canvas.drawCircle(center, radius - 7, ring);

    const Rect square = Rect.fromLTWH(28, 28, 64, 64);
    final Color hueColor = HSVColor.fromAHSV(
      1,
      selectedHsv.hue,
      1,
      1,
    ).toColor();
    canvas.drawRect(
      square,
      Paint()
        ..shader = const LinearGradient(
          colors: <Color>[Colors.white, Colors.transparent],
        ).createShader(square),
    );
    canvas.drawRect(
      square,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Colors.transparent, Colors.black],
        ).createShader(square),
    );
    canvas.drawRect(
      square,
      Paint()
        ..shader = LinearGradient(colors: <Color>[Colors.transparent, hueColor])
            .createShader(square),
    );

    final double hueAngle = (selectedHsv.hue - 90) * math.pi / 180;
    final Offset huePoint =
        center + Offset(math.cos(hueAngle), math.sin(hueAngle)) * (radius - 7);
    final Paint hueMarker = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Colors.white;
    canvas.drawCircle(huePoint, 7, hueMarker);

    final Offset svPoint = Offset(
      square.left + selectedHsv.saturation * square.width,
      square.top + (1 - selectedHsv.value) * square.height,
    );
    final Paint svMarker = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white;
    canvas.drawCircle(svPoint, 5, svMarker);
    final Paint svShadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.black.withValues(alpha: 0.72);
    canvas.drawCircle(svPoint, 7, svShadow);
  }

  @override
  bool shouldRepaint(_RgbWheelPainter oldDelegate) =>
      oldDelegate.selected != selected;
}

/// 边框高光颜色选择：跟随主题色 + 若干预设色。
class _GlowColorPicker extends StatelessWidget {
  const _GlowColorPicker({
    required this.selected,
    required this.accent,
    required this.onChanged,
  });

  /// 当前自定义颜色（null = 跟随主题色）。
  final Color? selected;
  final AppAccent accent;
  final ValueChanged<Color?> onChanged;

  /// 预设高光色（「几个渐变的颜色」）。
  static const List<(String, Color)> presets = <(String, Color)>[
    ('青', Color(0xFF00E5FF)),
    ('品红', Color(0xFFFF2E88)),
    ('薄荷', Color(0xFF3DFFC0)),
    ('琥珀', Color(0xFFFFB259)),
    ('紫', Color(0xFF9B6BFF)),
    ('玫瑰', Color(0xFFFF6B9A)),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '高光颜色',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              selected == null ? '跟随主题色（${accent.source}）' : '自定义',
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            // 跟随主题色
            _Swatch(
              label: '主题色',
              colors: <Color>[accent.primary, accent.secondary],
              selected: selected == null,
              onTap: () => onChanged(null),
            ),
            for (final (String label, Color color) in presets)
              _Swatch(
                label: label,
                colors: <Color>[color, Color.lerp(color, Colors.white, 0.5)!],
                selected: selected == color,
                onTap: () => onChanged(color),
              ),
          ],
        ),
      ],
    );
  }
}

/// 一个渐变色块（点一下选中）。
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.label,
    required this.colors,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final List<Color> colors;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Tooltip(
          message: label,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.black.withValues(alpha: 0.22),
              border: Border.all(
                color: selected
                    ? colors.first
                    : Colors.white.withValues(alpha: 0.12),
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 22,
                  height: 10,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: LinearGradient(colors: colors),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: selected ? Colors.white : const Color(0xBFFFFFFF),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 分组小标题（颜色跟随强调色）。
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.title, {required this.color});

  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// 滑杆行。
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.accent,
    required this.label,
    required this.hint,
    required this.value,
    required this.max,
    required this.onChanged,
    this.min = 0,
  });

  final AppAccent accent;
  final String label;
  final String hint;
  final double value;
  final double max;
  final double min;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                hint,
                style: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: accent.primary,
              inactiveTrackColor: AppColors.divider,
              thumbColor: accent.primary,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

/// 开关行。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.accent,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final AppAccent accent;
  final String label;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 10.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: accent.primary,
            activeTrackColor: accent.primary.withValues(alpha: 0.35),
            inactiveThumbColor: AppColors.textTertiary,
            inactiveTrackColor: AppColors.divider,
          ),
        ],
      ),
    );
  }
}
