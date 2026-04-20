import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:base_camp/theme/emergency_theme.dart';

void main() {
  // The full BaseCampApp tree requires a camera, permission handler,
  // and a live LiteRT-LM engine — none of which exist in the test
  // binding. Smoke-test the theme and disclaimer surface instead so
  // `flutter analyze` passes and we still exercise something real.
  testWidgets('Emergency theme builds with red primary and dark surfaces',
      (WidgetTester tester) async {
    final theme = EmergencyTheme.build();

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: Center(child: Text('BASE CAMP')),
        ),
      ),
    );

    expect(find.text('BASE CAMP'), findsOneWidget);
    expect(theme.colorScheme.primary, EmergencyPalette.emergencyRed);
    expect(theme.scaffoldBackgroundColor, EmergencyPalette.background);
    expect(theme.brightness, Brightness.dark);
  });
}
