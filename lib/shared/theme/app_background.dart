/// app_background.dart
///
/// 应用背景：可选的内置场景 + 自定义图片。
///
/// 设计要点：
/// - **同一份渲染代码同时给主背景和缩略图用**（[BackgroundLayer]）：
///   设置页里的预览就是真实场景的小尺寸渲染，永远不会和实际效果不一致，
///   也不需要额外准备缩略图资源。
/// - 自定义图片用 `file_picker` 选（已有依赖），路径存 `shared_preferences`；
///   文件被删/移动时用 `errorBuilder` 兜底回内置场景，不会白屏。
/// - 动态背景仍由共享 CustomPainter 实时渲染，但只以低频整层重绘，避免
///   粒子级动画拖慢主界面；主题包只保存声明文件和资源，不绑定平台视频格式。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/widget_kit/background_scenes.dart';
import 'performance_tier.dart';

/// 背景场景种类。
///
enum BackgroundKind {
  /// 动态液态光场：默认推荐的现代玻璃背景。
  liquidBloom('液态流光', '缓慢流动的柔和彩色光场'),

  /// 暖霞流光；保留 deepTide 标识以兼容旧设置和主题包。
  deepTide('暖霞流光', '暖橙珊瑚与金色光晕缓慢呼吸'),

  animeCandy('彩虹甜心', '轻快彩虹、云朵和卡通小伙伴缓慢漂浮'),

  /// 自定义图片。
  custom('自定义图片', '从本地选一张图片');

  const BackgroundKind(this.label, this.description);

  /// 界面显示名。
  final String label;

  /// 一句话说明。
  final String description;
}

/// 内置动态背景的声明，可直接写入主题包，避免绑定到平台视频格式。
Map<String, Object?> builtInBackgroundDefinition(BackgroundKind kind) {
  return switch (kind) {
    BackgroundKind.liquidBloom => <String, Object?>{
      'format': 'hoh-background',
      'version': 1,
      'renderer': 'liquid-bloom',
      'speed': 1.0,
      'colors': <String>['0xFF5D7CFF', '0xFFFF78C8', '0xFF47E5C2'],
    },
    BackgroundKind.deepTide => <String, Object?>{
      'format': 'hoh-background',
      'version': 1,
      'renderer': 'sunset-ember',
      'speed': 0.58,
      'colors': <String>['0xFFFF8A5B', '0xFFFFC857', '0xFFE85D75'],
    },
    BackgroundKind.animeCandy => <String, Object?>{
      'format': 'hoh-background',
      'version': 1,
      'renderer': 'anime-candy',
      'speed': 1.15,
      'colors': <String>[
        '0xFFFFDDF1',
        '0xFFDDF6FF',
        '0xFFFFF1BF',
        '0xFFE4D9FF',
      ],
    },
    BackgroundKind.custom => <String, Object?>{},
  };
}

/// 当前背景选择。
@immutable
class BackgroundSelection {
  const BackgroundSelection({
    required this.kind,
    this.customImagePath,
    this.dynamicDefinition,
  });

  /// 选中的种类。
  final BackgroundKind kind;

  /// 自定义图片路径（仅 [BackgroundKind.custom] 有意义）。
  final String? customImagePath;

  /// `.hohbg` 动态背景文件解析后的声明，随 `.hohtheme` 一起传播。
  final Map<String, Object?>? dynamicDefinition;

  /// 是否已经选过自定义图片。
  bool get hasCustomImage =>
      customImagePath != null && customImagePath!.isNotEmpty;

  /// 用 [BackgroundKind.custom] 但还没选图片时，退回到默认场景。
  BackgroundKind get effectiveKind =>
      kind == BackgroundKind.custom && !hasCustomImage
      ? BackgroundKind.liquidBloom
      : kind;

  BackgroundSelection copyWith({
    BackgroundKind? kind,
    String? customImagePath,
    bool clearCustomImage = false,
    Map<String, Object?>? dynamicDefinition,
  }) {
    return BackgroundSelection(
      kind: kind ?? this.kind,
      customImagePath: clearCustomImage
          ? null
          : (customImagePath ?? this.customImagePath),
      dynamicDefinition: dynamicDefinition ?? this.dynamicDefinition,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BackgroundSelection &&
      other.kind == kind &&
      other.customImagePath == customImagePath &&
      jsonEncode(other.dynamicDefinition) == jsonEncode(dynamicDefinition);

  @override
  int get hashCode =>
      Object.hash(kind, customImagePath, jsonEncode(dynamicDefinition));
}

/// 当前背景选择（持久化到 `shared_preferences`）。
final backgroundProvider =
    NotifierProvider<BackgroundController, BackgroundSelection>(
      BackgroundController.new,
    );

/// 背景选择控制器。
class BackgroundController extends Notifier<BackgroundSelection> {
  static const String _kindKey = 'background.kind';
  static const String _pathKey = 'background.customPath';
  static const String _definitionKey = 'background.dynamicDefinition';

  @override
  BackgroundSelection build() {
    // 先给默认值，读盘回来再覆盖 —— 不能为了读设置让首帧等待
    unawaited(_restore());
    return const BackgroundSelection(kind: BackgroundKind.liquidBloom);
  }

  /// 选择某个内置场景（自定义图片路径会保留，方便切回来）。
  void select(BackgroundKind kind) {
    state = BackgroundSelection(
      kind: kind,
      customImagePath: state.customImagePath,
      dynamicDefinition: kind == BackgroundKind.custom
          ? null
          : builtInBackgroundDefinition(kind),
    );
    unawaited(_persist());
  }

  void apply(BackgroundSelection selection) {
    state = selection;
    unawaited(_persist());
  }

  /// 选用自定义图片。
  void setCustomImage(String path) {
    state = BackgroundSelection(
      kind: BackgroundKind.custom,
      customImagePath: path,
    );
    unawaited(_persist());
  }

  /// 清除自定义图片；如果当前正在用它，回退到液态流光。
  void clearCustomImage() {
    state = BackgroundSelection(
      kind: state.kind == BackgroundKind.custom
          ? BackgroundKind.liquidBloom
          : state.kind,
    );
    unawaited(_persist());
  }

  Future<void> _restore() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? kindName = prefs.getString(_kindKey);
      final String? path = prefs.getString(_pathKey);
      final String? rawDefinition = prefs.getString(_definitionKey);
      final Object? decodedDefinition = rawDefinition == null
          ? null
          : jsonDecode(rawDefinition);

      final BackgroundKind kind = BackgroundKind.values.firstWhere(
        (BackgroundKind k) => k.name == kindName,
        orElse: () => BackgroundKind.liquidBloom,
      );

      Map<String, Object?>? definition = decodedDefinition is Map
          ? decodedDefinition.map(
              (Object? key, Object? value) => MapEntry(key.toString(), value),
            )
          : null;
      // 0.0.98：把已保存的旧“深海潮汐”定义迁移为暖霞流光。
      if (kind == BackgroundKind.deepTide &&
          definition?['renderer'] == 'deep-tide') {
        definition = builtInBackgroundDefinition(kind);
      }
      state = BackgroundSelection(
        kind: kind,
        customImagePath: (path == null || path.isEmpty) ? null : path,
        dynamicDefinition: definition,
      );
    } catch (error) {
      // 测试环境 / 平台不支持时忽略：默认背景照常用
      debugPrint('[Background] 读取背景设置失败（用默认值）：$error');
    }
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kindKey, state.kind.name);
      final String? path = state.customImagePath;
      if (path == null || path.isEmpty) {
        await prefs.remove(_pathKey);
      } else {
        await prefs.setString(_pathKey, path);
      }
      final Map<String, Object?>? definition = state.dynamicDefinition;
      if (definition == null) {
        await prefs.remove(_definitionKey);
      } else {
        await prefs.setString(_definitionKey, jsonEncode(definition));
      }
    } catch (error) {
      debugPrint('[Background] 保存背景设置失败：$error');
    }
  }
}

/// 背景层。挂在页面 `Stack` 的最底层（`Positioned.fill`）。
class AppBackground extends ConsumerWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BackgroundSelection selection = ref.watch(backgroundProvider);
    final BlurConfig config = ref.watch(blurConfigProvider);
    return BackgroundLayer(
      selection: selection,
      animated: config.animationsEnabled,
    );
  }
}

/// 按 [selection] 渲染背景。
///
/// **不读 provider**：设置页的缩略图直接复用这个组件，
/// 传入"假设选中某场景"的选择即可得到真实预览。
class BackgroundLayer extends StatelessWidget {
  const BackgroundLayer({
    super.key,
    required this.selection,
    this.customImageCacheWidth,
    this.animated = true,
  });

  /// 要渲染的背景。
  final BackgroundSelection selection;

  /// 自定义图片解码宽度上限（缩略图传小值，避免为了一张预览图解码 4K 原图）。
  final int? customImageCacheWidth;

  /// 设置页缩略图可关闭动画，避免同时运行多个预览控制器。
  final bool animated;

  @override
  Widget build(BuildContext context) {
    if (selection.effectiveKind == BackgroundKind.custom) {
      return _CustomImageBackground(
        path: selection.customImagePath!,
        cacheWidth: customImageCacheWidth,
      );
    }

    final Widget scene = switch (selection.effectiveKind) {
      BackgroundKind.liquidBloom => LiquidBloomScene(
        animated: animated,
        definition: selection.dynamicDefinition,
      ),
      BackgroundKind.deepTide => LiquidBloomScene(
        animated: animated,
        definition:
            selection.dynamicDefinition ??
            builtInBackgroundDefinition(BackgroundKind.deepTide),
      ),
      BackgroundKind.animeCandy => LiquidBloomScene(
        animated: animated,
        definition:
            selection.dynamicDefinition ??
            builtInBackgroundDefinition(BackgroundKind.animeCandy),
      ),
      BackgroundKind.custom => LiquidBloomScene(
        animated: animated,
        definition: selection.dynamicDefinition,
      ), // 上面已拦截，兜底
    };

    // 统一压一层暗色。
    //
    // 背景轻压暗，保证玻璃面板的浅色文字对比度。
    final bool lightScene =
        selection.effectiveKind == BackgroundKind.animeCandy;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        scene,
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: (lightScene ? Colors.white : Colors.black).withValues(
                alpha: lightScene ? 0.28 : 0.12,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 自定义图片背景：图片铺满 + 一层压暗，保证玻璃与文字仍然读得清。
class _CustomImageBackground extends StatelessWidget {
  const _CustomImageBackground({required this.path, this.cacheWidth});

  final String path;

  /// 解码宽度上限（缩略图用）。
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Image.file(
          File(path),
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          // 图片被删除 / 移动 / 不是图片时，退回默认场景而不是留白屏
          errorBuilder: (BuildContext context, Object error, StackTrace? _) {
            debugPrint('[Background] 自定义背景加载失败，退回液态流光：$error');
            return const LiquidBloomScene();
          },
        ),
        // 压暗：玻璃面板的对比度靠它撑住
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[Color(0x40000000), Color(0x73000000)],
            ),
          ),
        ),
      ],
    );
  }
}
