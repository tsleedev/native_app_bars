import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_app_bars/native_app_bars.dart';

import 'support/fake_host.dart';

/// The native bar transition follows the page it belongs to.
///
/// * A non-gesture iOS Cupertino slide (MaterialPageRoute under the
///   Cupertino builder, CupertinoPageRoute) sends the page's own curve
///   (`fastEaseInToSlowEaseOut`, flipped on reverse); a user gesture stays
///   linear, as `CupertinoPageTransition.linearTransition` does.
/// * A route that does not slide (custom `PageRouteBuilder`, other builders)
///   keeps linear progress and asks for a `fade` style.
/// * A bar also transitions when the other side has no native bar.
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

  Widget barPage(String title) => NativeChromeScaffold(
    topBar: NativeTopBar(title: title),
    body: Text('body $title'),
  );

  Widget barless(String label) => ColoredBox(
    color: Colors.white,
    child: Center(child: Text(label)),
  );

  Future<void> start(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: <NavigatorObserver>[
          NativeChromeNavigatorObserver(),
        ],
        builder: (context, child) =>
            NativeChrome(controller: controller, child: child!),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
    host.calls.clear();
  }

  Map<Object?, Object?> lastMoving() =>
      host.transitions.lastWhere((t) => t['phase'] != 'end');

  double lastProgress() => (lastMoving()['progress']! as num).toDouble();

  Map<Object?, Object?> begin() =>
      host.transitions.firstWhere((t) => t['phase'] == 'begin');

  int indexOfFirstUpdateWithTop(String? title) => host.calls.indexWhere(
    (c) =>
        c.method == 'update' &&
        ((c.arguments as Map)['top'] as Map?)?['title'] == title,
  );

  int indexOfBegin() => host.calls.indexWhere(
    (c) => c.method == 'transition' && (c.arguments as Map)['phase'] == 'begin',
  );

  const curve = Curves.fastEaseInToSlowEaseOut;

  testWidgets(
    'an iOS push sends the Cupertino page curve, not the linear value',
    (tester) async {
      await start(tester, barPage('A'));
      final route = MaterialPageRoute<void>(builder: (_) => barPage('B'));
      nav.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final t = route.animation!.value;
      expect(t, inExclusiveRange(0.05, 0.6));
      expect(begin()['direction'], 'push');
      expect(begin()['style'], 'slide');
      expect(lastProgress(), closeTo(curve.transform(t), 0.01));
      expect((lastProgress() - t).abs(), greaterThan(0.1));
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'an iOS back-button pop sends the flipped page curve',
    (tester) async {
      await start(tester, barPage('A'));
      final route = MaterialPageRoute<void>(builder: (_) => barPage('B'));
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      host.calls.clear();
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final t = route.animation!.value;
      expect(t, inExclusiveRange(0.4, 0.95));
      expect(begin()['direction'], 'pop');
      expect(lastProgress(), closeTo(1 - curve.flipped.transform(t), 0.01));
      expect((lastProgress() - (1 - t)).abs(), greaterThan(0.1));
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'swipe-back stays linear while the finger drives it and after release',
    (tester) async {
      await start(tester, barPage('A'));
      final route = MaterialPageRoute<void>(builder: (_) => barPage('B'));
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      host.calls.clear();
      final g = await tester.startGesture(const Offset(1, 300));
      await g.moveBy(const Offset(120, 0));
      await tester.pump();
      await g.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(begin()['direction'], 'pop');
      expect(lastProgress(), closeTo(1 - route.animation!.value, 0.005));
      // Cancel: the remaining animation still follows the controller value.
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(lastProgress(), closeTo(1 - route.animation!.value, 0.005));
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'B');
      expect(host.transitions.last['phase'], 'end');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a route that does not slide keeps linear progress and asks to fade',
    (tester) async {
      await start(tester, barPage('A'));
      final route = PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => barPage('C'),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      );
      nav.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final t = route.animation!.value;
      expect(t, inExclusiveRange(0.05, 0.95));
      expect(begin()['style'], 'fade');
      expect(lastProgress(), closeTo(t, 0.005));
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'pushing a bar page over a bar-less page slides the incoming bar in',
    (tester) async {
      await start(tester, barless('root'));
      final route = MaterialPageRoute<void>(builder: (_) => barPage('B'));
      nav.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.top?['title'], 'B');
      final b = indexOfBegin();
      expect(b, isNonNegative, reason: 'transitions: ${host.transitions}');
      expect(b, lessThan(indexOfFirstUpdateWithTop('B')));
      expect(begin()['direction'], 'push');
      expect(begin()['style'], 'slide');
      expect(
        lastProgress(),
        closeTo(curve.transform(route.animation!.value), 0.01),
      );
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');
      expect(controller.transitionActive, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'pushing and popping a bar-less page moves the outgoing bar',
    (tester) async {
      await start(tester, barPage('A'));
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => barless('cover')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.top, isNull);
      expect(indexOfBegin(), isNonNegative);
      expect(begin()['direction'], 'push');
      expect(begin()['style'], 'slide');
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');

      host.calls.clear();
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.top?['title'], 'A');
      final b = indexOfBegin();
      expect(b, isNonNegative, reason: 'transitions: ${host.transitions}');
      expect(b, lessThan(indexOfFirstUpdateWithTop('A')));
      expect(begin()['direction'], 'pop');
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');
      expect(controller.transitionActive, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'swiping back to a bar-less page keeps the outgoing bar moving',
    (tester) async {
      await start(tester, barless('root'));
      final route = MaterialPageRoute<void>(builder: (_) => barPage('B'));
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      host.calls.clear();
      final g = await tester.startGesture(const Offset(1, 300));
      await g.moveBy(const Offset(120, 0));
      await tester.pump();
      await g.moveBy(const Offset(120, 0));
      await tester.pump();
      expect(indexOfBegin(), isNonNegative);
      expect(begin()['direction'], 'pop');
      expect(lastProgress(), closeTo(1 - route.animation!.value, 0.005));
      await g.up();
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'B');
      expect(host.transitions.last['phase'], 'end');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a translucent fade route over a bar page fades the bar out and in',
    (tester) async {
      await start(tester, barPage('A'));
      final route = PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, _, _) => barless('overlay'),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      );
      nav.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.top, isNull);
      expect(indexOfBegin(), isNonNegative);
      expect(begin()['direction'], 'push');
      expect(begin()['style'], 'fade');
      expect(lastProgress(), closeTo(route.animation!.value, 0.005));
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');

      host.calls.clear();
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.top?['title'], 'A');
      expect(begin()['direction'], 'pop');
      expect(begin()['style'], 'fade');
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'the tab bar of a page covered by a fade route hides only after '
    '`transition begin`, so the host can fade it with the page',
    (tester) async {
      await start(
        tester,
        NativeChromeScaffold(
          topBar: const NativeTopBar(title: 'A'),
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
      );
      expect(host.tab, isNotNull);
      nav.currentState!.push(
        PageRouteBuilder<void>(
          opaque: false,
          pageBuilder: (_, _, _) => barless('overlay'),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      final firstTabless = host.calls.indexWhere(
        (c) => c.method == 'update' && (c.arguments as Map)['tab'] == null,
      );
      expect(firstTabless, isNonNegative);
      expect(begin()['style'], 'fade');
      expect(indexOfBegin(), lessThan(firstTabless));
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'pushing between two bar-less routes starts no transition',
    (tester) async {
      await start(tester, barless('root'));
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => barless('second')),
      );
      await tester.pumpAndSettle();
      expect(host.transitions, isEmpty, reason: 'no native bar on either side');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'non-Cupertino platforms keep the linear route value',
    (tester) async {
      await start(tester, barPage('A'));
      final route = MaterialPageRoute<void>(builder: (_) => barPage('B'));
      nav.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final t = route.animation!.value;
      expect(t, inExclusiveRange(0.05, 0.95));
      expect(lastProgress(), closeTo(t, 0.005));
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
