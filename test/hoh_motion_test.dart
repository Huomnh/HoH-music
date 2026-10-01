import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hoh_music/shared/widgets/motion/hoh_motion.dart';

void main() {
  testWidgets('关闭界面动画时不创建第三方动画层', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HoHMotion.enter(const Text('设置'), enabled: false)),
    );

    expect(find.text('设置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('hoh-motion-enter')),
      findsNothing,
    );
  });

  testWidgets('开启界面动画时创建低频入场动画层', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HoHMotion.enter(const Text('设置'), enabled: true)),
    );

    expect(
      find.byKey(const ValueKey<String>('hoh-motion-enter')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('设置'), findsOneWidget);
  });
}
