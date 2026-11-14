import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_chrome/native_chrome.dart';

import 'support/fake_host.dart';

/// a transition is tied to the route
/// that moves. Removing or replacing that route ends it exactly once, and a
/// switch whose moving route cannot be determined (several pops or a replace
/// in one frame) starts no transition instead of borrowing another route's
/// animation.
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

  List<Map<Object?, Object?>> phase(String p) =>
      host.transitions.where((t) => t['phase'] == p).toList();

  testWidgets(
    'replacing the bar-less route that drives a transition ends it once',
    (tester) async {
      await start(tester, barPage('A'));
      final b = MaterialPageRoute<void>(builder: (_) => barless('B'));
      nav.currentState!.push(b);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(phase('begin'), hasLength(1));
      expect(controller.transitionActive, isTrue);
      final id = phase('begin').single['id'];
      nav.currentState!.replace(
        oldRoute: b,
        newRoute: MaterialPageRoute<void>(builder: (_) => barless('C')),
      );
      await tester.pumpAndSettle();
      expect(
        phase('end').where((t) => t['id'] == id),
        hasLength(1),
        reason: 'transitions: ${host.transitions}',
      );
      expect(controller.transitionActive, isFalse);
      expect(host.top, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'removing the bar-less route that drives a transition ends it once',
    (tester) async {
      await start(tester, barPage('A'));
      final b = MaterialPageRoute<void>(builder: (_) => barless('B'));
      nav.currentState!.push(b);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final id = phase('begin').single['id'];
      nav.currentState!.removeRoute(b);
      await tester.pumpAndSettle();
      expect(phase('end').where((t) => t['id'] == id), hasLength(1));
      expect(controller.transitionActive, isFalse);
      expect(host.top?['title'], 'A');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'popUntil over two bar-less routes starts no borrowed transition',
    (tester) async {
      await start(tester, barPage('A'));
      nav.currentState!.push(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => barless('B fade'),
          transitionsBuilder: (_, animation, _, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      );
      await tester.pumpAndSettle();
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => barless('C slide')),
      );
      await tester.pumpAndSettle();
      host.calls.clear();
      nav.currentState!.popUntil((r) => r.isFirst);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'A');
      expect(
        phase('begin'),
        isEmpty,
        reason: 'the moving route is ambiguous: ${host.transitions}',
      );
      expect(controller.transitionActive, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'pops in a nested and the root navigator in one frame start no borrowed '
    'transition',
    (tester) async {
      final inner = GlobalKey<NavigatorState>();
      final innerObserver = NativeChromeNavigatorObserver();
      await start(tester, barPage('A'));
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Navigator(
            key: inner,
            observers: <NavigatorObserver>[innerObserver],
            onGenerateRoute: (_) =>
                MaterialPageRoute<void>(builder: (_) => barless('X')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      inner.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => barless('Y')),
      );
      await tester.pumpAndSettle();
      host.calls.clear();
      inner.currentState!.pop();
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'A');
      expect(phase('begin'), isEmpty, reason: '${host.transitions}');
      expect(controller.transitionActive, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a single pop back to a bar page still transitions with its own route',
    (tester) async {
      await start(tester, barPage('A'));
      final b = MaterialPageRoute<void>(builder: (_) => barless('B'));
      nav.currentState!.push(b);
      await tester.pumpAndSettle();
      host.calls.clear();
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(phase('begin'), hasLength(1));
      expect(phase('begin').single['direction'], 'pop');
      expect(phase('begin').single['style'], 'slide');
      await tester.pumpAndSettle();
      expect(phase('end'), hasLength(1));
      expect(controller.transitionActive, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'switching the displayed tab owner starts no transition',
    (tester) async {
      var index = 0;
      late StateSetter update;
      await start(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return NativeChromeTabStack(
              index: index,
              children: <Widget>[barPage('Tab 1'), barPage('Tab 2')],
            );
          },
        ),
      );
      expect(host.top?['title'], 'Tab 1');
      update(() => index = 1);
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'Tab 2');
      expect(host.transitions, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
