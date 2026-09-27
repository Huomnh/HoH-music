/// 紧凑播放器的窗口位置设置。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CompactCorner {
  topLeft('左上'),
  topRight('右上'),
  bottomLeft('左下'),
  bottomRight('右下');

  const CompactCorner(this.label);
  final String label;
}

final compactCornerProvider =
    NotifierProvider<CompactCornerController, CompactCorner>(
      CompactCornerController.new,
    );

class CompactCornerController extends Notifier<CompactCorner> {
  static const String _key = 'window.compactCorner';

  @override
  CompactCorner build() {
    _load();
    return CompactCorner.topLeft;
  }

  Future<void> _load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    final CompactCorner? value = raw == null
        ? null
        : CompactCorner.values
              .where((CompactCorner item) => item.name == raw)
              .firstOrNull;
    if (value != null) state = value;
  }

  Future<void> setCorner(CompactCorner value) async {
    state = value;
    await (await SharedPreferences.getInstance()).setString(_key, value.name);
  }
}
