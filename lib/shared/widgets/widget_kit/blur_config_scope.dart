/// blur_config_scope.dart
///
/// 渲染参数作用域——把当前性能档位的 [BlurConfig] 下发给整棵子树。
///
/// 单独成文件是为了打破循环依赖：模糊层、背景层、玻璃表面层都需要读取档位参数，
/// 若把它们两两互相 import 会形成环。所有组件统一依赖本文件。
///
/// 为什么用 [InheritedWidget] 而不是 Riverpod：
/// 一屏可能有十几块玻璃，如果每块都各自监听 Provider，档位一变就会产生
/// 大量独立的重建。用 InheritedWidget 在页面根部一次性下发，切换档位时
/// 整棵子树按新参数重建，路径更短、也更好推理。
library;

import 'package:flutter/widgets.dart';

import '../../theme/performance_tier.dart';

/// 向下传递渲染参数的作用域。
class BlurConfigScope extends InheritedWidget {
  const BlurConfigScope({
    super.key,
    required this.config,
    required super.child,
  });

  /// 当前生效的渲染参数。
  final BlurConfig config;

  /// 读取最近的渲染参数；没有作用域时返回 null。
  static BlurConfig? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<BlurConfigScope>()
        ?.config;
  }

  /// 读取最近的渲染参数；没有作用域时回退到高端档位。
  ///
  /// 兜底行为让单个玻璃组件可以脱离画廊独立使用（例如写单元测试时）。
  static BlurConfig of(BuildContext context) {
    return maybeOf(context) ?? BlurConfig.forTier(PerformanceTier.high);
  }

  @override
  bool updateShouldNotify(BlurConfigScope oldWidget) {
    return oldWidget.config != config;
  }
}
