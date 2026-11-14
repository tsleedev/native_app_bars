import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_chrome_example/main.dart';

void main() {
  testWidgets('the standalone example falls back and can select a tab', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(const ChromeExample());
      await tester.pumpAndSettle();
      expect(find.text('Selected: Library'), findsOneWidget);
      expect(find.text('Tab renderer: flutter, bottom'), findsOneWidget);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Selected: Browse'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
