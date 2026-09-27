/// 用户导入的 TTF 字体。
///
/// UI 字体和歌词字体使用两个独立的 FontLoader family；字体文件复制到
/// 应用数据目录，不进入安装包，也不修改 Windows 系统字体。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CustomFontSlot { ui, lyrics }

@immutable
class CustomFontSettings {
  const CustomFontSettings({
    this.uiPath,
    this.uiFamily,
    this.lyricsPath,
    this.lyricsFamily,
  });

  final String? uiPath;
  final String? uiFamily;
  final String? lyricsPath;
  final String? lyricsFamily;

  bool get hasUi => uiFamily != null && uiFamily!.isNotEmpty;
  bool get hasLyrics => lyricsFamily != null && lyricsFamily!.isNotEmpty;
}

final customFontsProvider =
    AsyncNotifierProvider<CustomFontsController, CustomFontSettings>(
      CustomFontsController.new,
    );

class CustomFontsController extends AsyncNotifier<CustomFontSettings> {
  static const String uiFamily = 'HoHImportedUiFont';
  static const String lyricsFamily = 'HoHImportedLyricsFont';
  static const String _uiPathKey = 'appearance.customUiFontPath';
  static const String _uiFamilyKey = 'appearance.customUiFontFamily';
  static const String _lyricsPathKey = 'lyrics.customFontPath';
  static const String _lyricsFamilyKey = 'lyrics.customFontFamily';

  @override
  Future<CustomFontSettings> build() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    String? uiPath = prefs.getString(_uiPathKey);
    String? uiFamily = prefs.getString(_uiFamilyKey);
    String? lyricsPath = prefs.getString(_lyricsPathKey);
    String? lyricsFamily = prefs.getString(_lyricsFamilyKey);

    if (uiPath == null || uiFamily == null || !File(uiPath).existsSync()) {
      uiPath = null;
      uiFamily = null;
    } else if (!await _load(uiPath, uiFamily)) {
      uiPath = null;
      uiFamily = null;
    }
    if (lyricsPath == null ||
        lyricsFamily == null ||
        !File(lyricsPath).existsSync()) {
      lyricsPath = null;
      lyricsFamily = null;
    } else if (!await _load(lyricsPath, lyricsFamily)) {
      lyricsPath = null;
      lyricsFamily = null;
    }
    return CustomFontSettings(
      uiPath: uiPath,
      uiFamily: uiFamily,
      lyricsPath: lyricsPath,
      lyricsFamily: lyricsFamily,
    );
  }

  Future<void> importFont(CustomFontSlot slot, String sourcePath) async {
    final File source = File(sourcePath);
    if (!source.existsSync() || !sourcePath.toLowerCase().endsWith('.ttf')) {
      throw const FormatException('请选择有效的 TTF 文件');
    }
    final Directory directory = Directory(
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}fonts',
    );
    await directory.create(recursive: true);
    final String family = slot == CustomFontSlot.ui ? uiFamily : lyricsFamily;
    final File target = File(
      '${directory.path}${Platform.pathSeparator}$family.ttf',
    );
    await source.copy(target.path);
    if (!await _load(target.path, family)) {
      await target.delete().catchError((_) => target);
      throw const FormatException('字体加载失败，请确认文件是有效的 TTF 字体');
    }

    final CustomFontSettings current =
        state.value ?? const CustomFontSettings();
    final CustomFontSettings next = slot == CustomFontSlot.ui
        ? CustomFontSettings(
            uiPath: target.path,
            uiFamily: family,
            lyricsPath: current.lyricsPath,
            lyricsFamily: current.lyricsFamily,
          )
        : CustomFontSettings(
            uiPath: current.uiPath,
            uiFamily: current.uiFamily,
            lyricsPath: target.path,
            lyricsFamily: family,
          );
    state = AsyncData<CustomFontSettings>(next);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (slot == CustomFontSlot.ui) {
      await prefs.setString(_uiPathKey, target.path);
      await prefs.setString(_uiFamilyKey, family);
    } else {
      await prefs.setString(_lyricsPathKey, target.path);
      await prefs.setString(_lyricsFamilyKey, family);
    }
  }

  Future<bool> _load(String path, String family) async {
    try {
      final bytes = await File(path).readAsBytes();
      final FontLoader loader = FontLoader(family);
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      return true;
    } catch (_) {
      return false;
    }
  }
}
