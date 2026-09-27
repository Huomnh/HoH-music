/// 主题扩展契约：为第三方主题提供稳定的数据入口。
library;

import 'package:flutter/material.dart';

@immutable
class AppThemeDefinition {
  const AppThemeDefinition({
    required this.id,
    required this.name,
    required this.primary,
    required this.secondary,
    this.background = const Color(0xFF080912),
    this.glassTint = 0.08,
    this.glassTone = 0.08,
  });

  final String id;
  final String name;
  final Color primary;
  final Color secondary;
  final Color background;
  final double glassTint;
  final double glassTone;
}

/// 运行时可发现的主题目录，主题包只需注册定义即可被宿主读取。
abstract final class AppThemeCatalog {
  static final List<AppThemeDefinition> _items = <AppThemeDefinition>[];

  static List<AppThemeDefinition> get items =>
      List<AppThemeDefinition>.unmodifiable(_items);

  static void register(AppThemeDefinition theme) {
    _items.removeWhere((AppThemeDefinition item) => item.id == theme.id);
    _items.add(theme);
  }
}
