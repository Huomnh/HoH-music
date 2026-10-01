import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hoh_music/shared/theme/app_background.dart';
import 'package:hoh_music/shared/theme/theme_bundle.dart';
import 'package:hoh_music/shared/widgets/widget_kit/background_scenes.dart';

void main() {
  group('removed background migration', () {
    test('theme bundle with the removed kind falls back to liquid bloom', () {
      final ThemeBundle bundle = ThemeBundle(
        data: <String, Object?>{
          'format': 'hoh-theme',
          'background': <String, Object?>{'kind': 'animeCandy'},
        },
      );

      expect(bundle.background.kind, BackgroundKind.liquidBloom);
      expect(bundle.background.dynamicDefinition?['renderer'], 'liquid-bloom');
    });

    test('theme bundle with the removed renderer falls back too', () {
      final ThemeBundle bundle = ThemeBundle(
        data: <String, Object?>{
          'format': 'hoh-theme',
          'background': <String, Object?>{
            'kind': 'deepTide',
            'dynamicDefinition': <String, Object?>{'renderer': 'anime-candy'},
          },
        },
      );

      expect(bundle.background.kind, BackgroundKind.liquidBloom);
      expect(bundle.background.dynamicDefinition?['renderer'], 'liquid-bloom');
    });

    testWidgets('ink fold background paints without errors', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BackgroundLayer(
              selection: BackgroundSelection(
                kind: BackgroundKind.inkFold,
                dynamicDefinition: builtInBackgroundDefinition(
                  BackgroundKind.inkFold,
                ),
              ),
              animated: false,
            ),
          ),
        ),
      );

      expect(find.byType(LiquidBloomScene), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
