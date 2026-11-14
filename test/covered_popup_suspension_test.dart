import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_app_bars/native_app_bars.dart';

import 'support/fake_host.dart';

/// A page pushed over a popup (for example a policy document opened from a
/// sign-in sheet) covers that popup. The page's bar must take input; only an
/// uncovered popup suspends native input.
void main() {
  late FakeHost host;
  late NativeChromeController controller;

  setUp(() {
    host = FakeHost()..install();
    controller = testController();
  });

  tearDown(() {
    controller.dispose();
    host.uninstall();
  });

  testWidgets('page pushed over a sheet is not suspended; the sheet is', (
    tester,
  ) async {
    final log = <String>[];
    final observer = NativeChromeNavigatorObserver();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: <NavigatorObserver>[observer],
        builder: (context, child) =>
            NativeChrome(controller: controller, child: child!),
        home: Builder(
          builder: (context) => NativeChromeScaffold(
            topBar: const NativeTopBar(title: 'Start'),
            body: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (sheetContext) => TextButton(
                  onPressed: () => Navigator.of(sheetContext).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => NativeChromeScaffold(
                        topBar: NativeTopBar(
                          title: 'Document',
                          actions: <NativeBarAction>[
                            NativeBarAction(
                              id: 'share',
                              label: 'Share',
                              onPressed: () => log.add('share'),
                            ),
                          ],
                        ),
                        body: const Text('document body'),
                      ),
                    ),
                  ),
                  child: const Text('open document'),
                ),
              ),
              child: const Text('open sheet'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(host.state['suspended'], isFalse);

    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    expect(host.state['suspended'], isTrue, reason: 'uncovered sheet');
    expect(host.top?['title'], 'Start');

    await tester.tap(find.text('open document'));
    await tester.pumpAndSettle();
    expect(host.top?['title'], 'Document');
    expect(
      host.state['suspended'],
      isFalse,
      reason: 'the document page covers the sheet',
    );
    await host.tapTop('share');
    expect(log, <String>['share']);

    // A dialog over the document suspends again.
    showDialog<void>(
      context: navigatorKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();
    expect(host.state['suspended'], isTrue, reason: 'dialog above the page');
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(host.state['suspended'], isFalse);

    // Back to the sheet: suspended again until it closes.
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(host.top?['title'], 'Start');
    expect(host.state['suspended'], isTrue, reason: 'sheet uncovered again');
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(host.state['suspended'], isFalse);
  });

  Widget sheetThenPage(GlobalKey<NavigatorState> key, NavigatorObserver o) =>
      MaterialApp(
        navigatorKey: key,
        navigatorObservers: <NavigatorObserver>[o],
        builder: (context, child) =>
            NativeChrome(controller: controller, child: child!),
        home: Builder(
          builder: (context) => NativeChromeScaffold(
            topBar: const NativeTopBar(title: 'Start'),
            body: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (sheetContext) => TextButton(
                  onPressed: () => Navigator.of(sheetContext).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const NativeChromeScaffold(
                        topBar: NativeTopBar(title: 'Document'),
                        body: SizedBox.expand(),
                      ),
                    ),
                  ),
                  child: const Text('open document'),
                ),
              ),
              child: const Text('open sheet'),
            ),
          ),
        ),
      );

  testWidgets('iOS swipe-back over a sheet: cancel keeps input, complete '
      'uncovers the sheet', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        sheetThenPage(key, NativeChromeNavigatorObserver()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open sheet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open document'));
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'Document');
      expect(host.state['suspended'], isFalse);

      // Cancel: a short slow edge drag released before half way.
      final cancel = await tester.startGesture(const Offset(2, 300));
      for (var i = 0; i < 8; i++) {
        await cancel.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 600));
      await cancel.up();
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'Document');
      expect(host.state['suspended'], isFalse, reason: 'cancelled back');

      // Complete: drag across most of the width.
      final commit = await tester.startGesture(const Offset(2, 300));
      for (var i = 0; i < 12; i++) {
        await commit.moveBy(const Offset(50, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await commit.up();
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'Start');
      expect(host.state['suspended'], isTrue, reason: 'sheet uncovered');
      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(host.state['suspended'], isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('popup in a nested navigator covered by a root page', (
    tester,
  ) async {
    final rootKey = GlobalKey<NavigatorState>();
    final innerKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootKey,
        navigatorObservers: <NavigatorObserver>[
          NativeChromeNavigatorObserver(),
        ],
        builder: (context, child) =>
            NativeChrome(controller: controller, child: child!),
        home: Navigator(
          key: innerKey,
          observers: <NavigatorObserver>[NativeChromeNavigatorObserver()],
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => NativeChromeScaffold(
              topBar: const NativeTopBar(title: 'Inner'),
              body: TextButton(
                // Sheet on the nested navigator (useRootNavigator false).
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (sheetContext) => TextButton(
                    onPressed: () =>
                        Navigator.of(
                          sheetContext,
                          rootNavigator: true,
                        ).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => const NativeChromeScaffold(
                              topBar: NativeTopBar(title: 'Root page'),
                              body: SizedBox.expand(),
                            ),
                          ),
                        ),
                    child: const Text('open root page'),
                  ),
                ),
                child: const Text('open inner sheet'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open inner sheet'));
    await tester.pumpAndSettle();
    expect(host.state['suspended'], isTrue, reason: 'uncovered inner sheet');
    await tester.tap(find.text('open root page'));
    await tester.pumpAndSettle();
    expect(host.top?['title'], 'Root page');
    expect(
      host.state['suspended'],
      isFalse,
      reason: 'root page covers the route hosting the inner navigator',
    );
    rootKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(host.top?['title'], 'Inner');
    expect(host.state['suspended'], isTrue, reason: 'inner sheet uncovered');
    innerKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(host.state['suspended'], isFalse);
  });
}
