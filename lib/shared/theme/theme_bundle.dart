/// 可传播的主题包（`.hohtheme`）。它是 ZIP 容器，内含 UTF-8 JSON 和可选的
/// 自定义背景图片和可编辑的 `.hohbg` 动态背景声明，方便传播、修改与跨平台导入。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_background.dart';
import 'performance_tier.dart';

class ThemeBundle {
  const ThemeBundle({
    required this.data,
    this.files = const <String, List<int>>{},
  });

  final Map<String, Object?> data;
  final Map<String, List<int>> files;

  String encode() => const JsonEncoder.withIndent('  ').convert(data);

  static ThemeBundle fromConfig({
    required BackgroundSelection background,
    required Color? themeColor,
    required BlurConfig glass,
  }) {
    int rgb(Color color) => color.toARGB32();
    return ThemeBundle(
      data: <String, Object?>{
        'format': 'hoh-theme',
        'version': 1,
        'background': <String, Object?>{
          'kind': background.kind.name,
          'customImagePath': background.customImagePath,
          'dynamicDefinition': background.dynamicDefinition,
        },
        'themeColor': themeColor == null ? null : rgb(themeColor),
        'glass': <String, Object?>{
          'blurSigma': glass.blurSigma,
          'tintOpacity': glass.tintOpacity,
          'glassSaturation': glass.glassSaturation,
          'glassTone': glass.glassTone,
          'glassThickness': glass.glassThickness,
          'frostIntensity': glass.frostIntensity,
          'refractiveIndex': glass.refractiveIndex,
          'chromaticAberration': glass.chromaticAberration,
          'lightAngle': glass.lightAngle,
          'lightIntensity': glass.lightIntensity,
          'ambientStrength': glass.ambientStrength,
          'liquidSaturation': glass.liquidSaturation,
          'fakeGlassRefraction': glass.fakeGlassRefraction,
          'glowStrength': glass.glowStrength,
          'sweepEnabled': glass.sweepEnabled,
          'animationsEnabled': glass.animationsEnabled,
        },
      },
    );
  }

  /// 导出真正的主题包：JSON + 可选的自定义背景图片。
  Future<Uint8List> encodeArchive() async {
    final Map<String, Object?> output =
        jsonDecode(encode()) as Map<String, Object?>;
    final String? original = (output['background'] as Map?)?['customImagePath']
        ?.toString();
    final Archive archive = Archive();
    final Map<Object?, Object?> background =
        (output['background'] as Map?) ?? <Object?, Object?>{};
    final String? kindName = background['kind']?.toString();
    if (kindName != null && kindName != BackgroundKind.custom.name) {
      final BackgroundKind kind = BackgroundKind.values.firstWhere(
        (BackgroundKind item) => item.name == kindName,
        orElse: () => BackgroundKind.liquidBloom,
      );
      final String name = 'background/${_backgroundFileStem(kind)}.hohbg';
      background['definitionFile'] = name;
      final Object? configuredDefinition = background['dynamicDefinition'];
      final List<int> definition = configuredDefinition is Map
          ? utf8.encode(
              const JsonEncoder.withIndent('  ').convert(configuredDefinition),
            )
          : await _defaultDynamicDefinition(kind);
      archive.addFile(ArchiveFile(name, definition.length, definition));
    }
    if (original != null && original.isNotEmpty) {
      final File image = File(original);
      if (await image.exists()) {
        final String name = 'assets/custom_background${p.extension(original)}';
        (output['background'] as Map?)?['customImagePath'] = name;
        archive.addFile(
          ArchiveFile(name, await image.length(), await image.readAsBytes()),
        );
      }
    }
    final List<int> manifest = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(output),
    );
    archive.addFile(ArchiveFile('theme.json', manifest.length, manifest));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static ThemeBundle fromArchive(Uint8List bytes) {
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final ArchiveFile? manifest = archive.findFile('theme.json');
    if (manifest == null) throw const FormatException('主题包缺少 theme.json');
    final ThemeBundle parsed = parse(
      utf8.decode(manifest.content as List<int>),
    );
    final Map<String, List<int>> files = <String, List<int>>{};
    for (final ArchiveFile file in archive) {
      if (file.isFile) {
        files[file.name] = List<int>.from(file.content as List<int>);
      }
    }
    final Map<String, Object?> data = Map<String, Object?>.from(parsed.data);
    final Object? rawBackground = data['background'];
    if (rawBackground is Map) {
      final Map<Object?, Object?> background = Map<Object?, Object?>.from(
        rawBackground,
      );
      final String? definitionFile = background['definitionFile']?.toString();
      final List<int>? definitionBytes = definitionFile == null
          ? null
          : files[definitionFile];
      if (definitionBytes != null) {
        final Object? decoded = jsonDecode(utf8.decode(definitionBytes));
        if (decoded is Map) {
          background['dynamicDefinition'] = decoded.map(
            (Object? key, Object? value) => MapEntry(key.toString(), value),
          );
        }
      }
      data['background'] = background.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
    }
    return ThemeBundle(data: data, files: files);
  }

  static Future<List<int>> _defaultDynamicDefinition(
    BackgroundKind kind,
  ) async {
    try {
      final ByteData data = await rootBundle.load(
        'assets/backgrounds/${_backgroundFileStem(kind)}.hohbg',
      );
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return utf8.encode(
        jsonEncode(<String, Object?>{
          'format': 'hoh-background',
          'version': 1,
          ...builtInBackgroundDefinition(kind),
        }),
      );
    }
  }

  static String _backgroundFileStem(BackgroundKind kind) => switch (kind) {
    BackgroundKind.liquidBloom => 'liquid_bloom',
    BackgroundKind.deepTide => 'deep_tide',
    BackgroundKind.animeCandy => 'anime_candy',
    BackgroundKind.custom => 'custom',
  };

  static ThemeBundle parse(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('主题包格式错误');
    final Map<String, Object?> data = decoded.map(
      (Object? key, Object? value) => MapEntry(key.toString(), value),
    );
    if (data['format'] != 'hoh-theme') {
      throw const FormatException('不是 HoH music 主题包');
    }
    return ThemeBundle(data: data);
  }

  BackgroundSelection get background {
    final Object? raw = data['background'];
    final Map<Object?, Object?> map = raw is Map
        ? raw
        : const <Object?, Object?>{};
    final BackgroundKind kind = BackgroundKind.values.firstWhere(
      (BackgroundKind item) => item.name == map['kind'],
      orElse: () => BackgroundKind.liquidBloom,
    );
    return BackgroundSelection(
      kind: kind,
      customImagePath: map['customImagePath']?.toString(),
      dynamicDefinition: map['dynamicDefinition'] is Map
          ? (map['dynamicDefinition'] as Map<Object?, Object?>).map(
              (Object? key, Object? value) => MapEntry(key.toString(), value),
            )
          : null,
    );
  }

  Color? get themeColor {
    final Object? value = data['themeColor'];
    return value is num ? Color(value.toInt()) : null;
  }

  Map<Object?, Object?> get glass {
    final Object? raw = data['glass'];
    return raw is Map ? raw : const <Object?, Object?>{};
  }
}
