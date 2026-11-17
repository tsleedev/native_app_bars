import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_app_bars/native_app_bars.dart';

import 'support/fake_host.dart';

void main() {
  testWidgets(
    'one iOS layer paints the whole header, ignores input and respects accessibility',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(402, 874);
      addTearDown(tester.view.reset);
      Map<String, Object?> geometry({
        bool visible = true,
        bool? reduced = false,
      }) => {
        'topInset': 62.0,
        'topBarHeight': 54.0,
        'topBarVisible': visible,
        'iosTopBarFrame': {
          'left': 5.0,
          'top': 62.0,
          'width': 390.0,
          'height': 54.0,
        },
        'iosReduceTransparency': ?reduced,
      };
      final host = FakeHost(geometry: geometry())..install();
      addTearDown(host.uninstall);
      final opacity = ValueNotifier(1.0);
      addTearDown(opacity.dispose);
      var presses = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => NativeChrome(child: child!),
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 10,
                  top: 20,
                  child: TextButton(
                    onPressed: () => presses++,
                    child: const Text('Document action'),
                  ),
                ),
                ValueListenableBuilder(
                  valueListenable: opacity,
                  builder: (_, value, _) => NativeChromeDocumentBackdrop(
                    opacity: value,
                    reducedTransparencyColor: Colors.orange,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final blur = find.byType(BackdropFilter);
      final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
      if (!isIOS) {
        expect(blur, findsNothing);
        return;
      }
      expect(blur, findsOneWidget);
      expect(tester.getRect(blur), const Rect.fromLTRB(5, 0, 395, 116));
      final action = find.text('Document action');
      await tester.tap(action);
      expect(presses, 1);
      final reducedSurface = find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == Colors.orange,
      );
      await host.send('geometry', geometry(reduced: true));
      await tester.pumpAndSettle();
      expect(blur, findsNothing);
      expect(
        tester.getRect(reducedSurface),
        const Rect.fromLTRB(5, 0, 395, 116),
      );
      final semantics = tester.ensureSemantics();
      try {
        await tester.pump();
        expect(find.bySemanticsLabel('Document action'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
      await host.send('geometry', geometry(visible: false));
      await tester.pumpAndSettle();
      expect(reducedSurface, findsNothing);
      await host.send('geometry', geometry());
      await tester.pumpAndSettle();
      opacity.value = 0;
      await tester.pumpAndSettle();
      expect(blur, findsNothing);
      opacity.value = 1;
      await host.send('geometry', geometry(reduced: null));
      await tester.pumpAndSettle();
      expect(blur, findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    'attached iOS with a Flutter top renderer never paints a stale native frame',
    (tester) async {
      final host = FakeHost(
        geometry: {
          'topInset': 62.0,
          'topBarHeight': 54.0,
          'topBarVisible': true,
          'iosTopBarFrame': {
            'left': 0.0,
            'top': 62.0,
            'width': 402.0,
            'height': 54.0,
          },
          'iosReduceTransparency': false,
        },
      )..install();
      addTearDown(host.uninstall);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => NativeChrome(
            config: const NativeChromeConfig(
              ios: NativeChromePlatformConfig.allFlutter(),
            ),
            child: child!,
          ),
          home: const Scaffold(
            body: Stack(children: [NativeChromeDocumentBackdrop()]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );
}
