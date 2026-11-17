import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_app_bars/native_app_bars.dart';

import 'support/fake_host.dart';

void main() {
  testWidgets(
    'only a suspended opted-in iOS host receives opaque popup surfaces',
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
    (tester) async {
      final host = FakeHost()..install();
      addTearDown(host.uninstall);
      final controller = NativeChromeController();
      addTearDown(controller.dispose);
      final token = Object();
      const key = 'iosPopupForegrounds';
      final shape = RRect.fromRectAndCorners(
        const Rect.fromLTWH(11, 42, 100, 240),
        topLeft: const Radius.elliptical(8, 12),
      );
      var surfaces = <RRect>[shape, RRect.zero];
      Widget app() => MaterialApp(
        builder: (_, child) => NativeChrome(
          controller: controller,
          iosPopupForegrounds: surfaces,
          child: child!,
        ),
        home: const Scaffold(body: Text('page')),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(host.updates.last[key], isNull);
      controller.setSuspended(token, true);
      await tester.pumpAndSettle();
      if (Theme.of(tester.element(find.text('page'))).platform ==
          TargetPlatform.iOS) {
        final wire = host.updates.last[key] as Map;
        expect(wire['width'], greaterThan(0));
        expect(wire['height'], greaterThan(0));
        expect(wire['surfaces'], [
          [11.0, 42.0, 100.0, 240.0, 8.0, 12.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        ]);
      } else {
        expect(host.updates.last[key], isNull);
      }

      surfaces = [];
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(host.updates.last[key], isNull);
      expect(host.updates.last['suspended'], isTrue);

      surfaces = [shape];
      controller.setSuspended(token, false);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(host.updates.last[key], isNull);
      expect(host.updates.last['suspended'], isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
