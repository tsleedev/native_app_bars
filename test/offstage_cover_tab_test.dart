import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_chrome/native_chrome.dart';

import 'support/fake_host.dart';

/// on the first frame of a push, HeroController lays the
/// new route out offstage (not painted). The covered root is still fully
/// visible, so its tab bar must not be clipped away for that frame; from the
/// next (painted) frame the tab bar is clipped to the uncovered root area.
/// Other missing or invalid geometry stays fail-closed.
void main() {
  late FakeHost host;
  late NativeChromeController controller;
  late GlobalKey<NavigatorState> nav;

  setUp(() {
    host = FakeHost()..install();
    controller = testController();
    nav = GlobalKey<NavigatorState>();
  });

  tearDown(() {
    controller.dispose();
    host.uninstall();
  });

  Future<void> open(WidgetTester tester, {bool rtl = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: <NavigatorObserver>[
          NativeChromeNavigatorObserver(),
        ],
        builder: (context, child) => Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: NativeChrome(controller: controller, child: child!),
        ),
        home: NativeChromeScaffold(
          topBar: const NativeTopBar(title: 'Root'),
          tabBar: NativeTabBar(
            selectedId: 'home',
            onSelect: (_) {},
            items: const <NativeTabItem>[
              NativeTabItem(
                id: 'home',
                label: 'Home',
                icon: NativeChromeIcons.home,
              ),
              NativeTabItem(
                id: 'search',
                label: 'Search',
                icon: NativeChromeIcons.search,
              ),
            ],
          ),
          body: const Text('root'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    host.calls.clear();
  }

  Map<Object?, Object?>? firstBottomTransition() {
    for (final u in host.updates) {
      final b = u['bottomTransition'];
      if (b is Map) return b;
    }
    return null;
  }

  for (final rtl in <bool>[false, true]) {
    testWidgets(
      'an offstage cover on the first push frame leaves the root tab bar '
      'fully visible, then clips it (rtl=$rtl)',
      (tester) async {
        await open(tester, rtl: rtl);
        final width = tester.view.physicalSize.width /
            tester.view.devicePixelRatio;
        nav.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const NativeChromeScaffold(
              topBar: NativeTopBar(title: 'Detail'),
              body: Text('detail'),
            ),
          ),
        );
        await tester.pump();
        final first = firstBottomTransition();
        expect(first, isNotNull, reason: 'updates: ${host.updates}');
        final root = first!['root'] as Map?;
        final cover = first['cover'] as Map?;
        expect(root?['left'], 0.0);
        expect(
          cover,
          isNotNull,
          reason: 'an unpainted cover must not fail closed over the root',
        );
        // The cover is reported entirely outside the viewport on the side it
        // enters from, so the uncovered gap is the whole root.
        expect(cover!['left'], rtl ? -width : width);
        expect(cover['width'], width);

        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 100));
        final moving = host.state['bottomTransition'] as Map?;
        expect(moving, isNotNull);
        final left = ((moving!['cover'] as Map)['left'] as num).toDouble();
        expect(left.abs(), inExclusiveRange(0, width));
        await tester.pumpAndSettle();
        expect(host.state['bottomTransition'], isNull);
        expect(host.tab, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'a pop with an offstage cover stays fail-closed (only a push first frame '
    'is admitted)',
    (tester) async {
      await open(tester);
      final route = MaterialPageRoute<void>(
        builder: (_) => const NativeChromeScaffold(
          topBar: NativeTopBar(title: 'Detail'),
          body: Text('detail'),
        ),
      );
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      host.calls.clear();
      nav.currentState!.pop();
      route.offstage = true;
      await tester.pump();
      final first = firstBottomTransition();
      expect(first, isNotNull, reason: 'updates: ${host.updates}');
      expect(first!['cover'], isNull);
      route.offstage = false;
      await tester.pumpAndSettle();
      expect(host.state['bottomTransition'], isNull);
      expect(host.tab, isNotNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
