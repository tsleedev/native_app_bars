import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_chrome/native_chrome.dart';

import 'support/fake_host.dart';

void main() {
  late FakeHost host;
  late NativeChromeController controller;
  late GlobalKey<NavigatorState> nav;
  late List<String> selected;
  late PageRoute<void> cover;
  const rootKey = ValueKey('page-root');
  const childKey = ValueKey('page-child');

  setUp(() {
    host = FakeHost()..install();
    controller = testController();
    nav = GlobalKey<NavigatorState>();
    selected = [];
  });
  tearDown(() {
    controller.dispose();
    host.uninstall();
  });

  Future<void> open(WidgetTester tester, {bool rtl = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [NativeChromeNavigatorObserver()],
        builder: (context, child) => Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: NativeChrome(controller: controller, child: child!),
        ),
        home: NativeChromeScaffold(
          key: rootKey,
          tabBar: NativeTabBar(
            selectedId: 'home',
            onSelect: selected.add,
            items: const [
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
    cover = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(key: childKey, body: Text('child')),
    );
    nav.currentState!.push(cover);
    await tester.pumpAndSettle();
    expect(host.tab, isNull, reason: 'resting opaque child hides root tabs');
  }

  Future<TestGesture> partial(WidgetTester tester) async {
    final g = await tester.startGesture(const Offset(1, 300));
    await g.moveBy(const Offset(160, 0));
    await tester.pump();
    await g.moveBy(const Offset(80, 0));
    await tester.pump();
    return g;
  }

  testWidgets(
    'bottom-only pop publishes actual root and cover paint coordinates',
    (tester) async {
      await open(tester);
      final g = await partial(tester);
      final presentation = host.state['bottomTransition'];
      expect(
        presentation,
        isA<Map>(),
        reason: 'top-less route still needs independent bottom presentation',
      );
      final map = presentation! as Map;
      expect((map['cover'] as Map)['left'], greaterThan(0));
      expect((map['root'] as Map)['left'], lessThan(0));
      await g.up();
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'covered incoming tab rejects valid-stamp input without changing owner',
    (tester) async {
      await open(tester);
      final g = await partial(tester);
      expect(host.tab, isNotNull);
      final before = Map<Object?, Object?>.from(host.tab!);
      await host.tapTab('search');
      expect(
        selected,
        isEmpty,
        reason: 'root tab is still covered by the moving child',
      );
      expect(
        host.tab,
        before,
        reason: 'presentation cannot change tab owner/content stamp',
      );
      await g.up();
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final rtl in [false, true]) {
    testWidgets(
      'actual paint edge during push and settle rtl=$rtl',
      (tester) async {
        await open(tester, rtl: rtl);
        nav.currentState!.pop();
        await tester.pumpAndSettle();
        final stamp = Map<Object?, Object?>.from(host.tab!);
        cover = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(key: childKey, body: Text('child')),
        );
        nav.currentState!.push(cover);
        await tester.pump();
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 60));
          final map = host.state['bottomTransition']! as Map;
          final actualChild = tester.getRect(find.byKey(childKey));
          final actualRoot = tester.getRect(find.byKey(rootKey));
          expect(
            (map['cover'] as Map)['left'],
            closeTo(actualChild.left, .0001),
          );
          expect((map['root'] as Map)['left'], closeTo(actualRoot.left, .0001));
          expect((map['tab'] as Map)['routeSession'], stamp['routeSession']);
          expect(actualChild.left, rtl ? lessThan(0) : greaterThan(0));
        }
        await tester.pumpAndSettle();
        expect(host.state.containsKey('bottomTransition'), isFalse);
        expect(host.tab, isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    for (final commit in [false, true]) {
      testWidgets(
        'pop ${commit ? "commit" : "cancel"} settles atomically rtl=$rtl',
        (tester) async {
          await open(tester, rtl: rtl);
          final width =
              tester.view.physicalSize.width / tester.view.devicePixelRatio;
          final g = await tester.startGesture(Offset(rtl ? width - 1 : 1, 300));
          final sign = rtl ? -1.0 : 1.0;
          await g.moveBy(Offset(sign * 80, 0));
          await tester.pump();
          await g.moveBy(Offset(sign * width * (commit ? .70 : .10), 0));
          await tester.pump(const Duration(milliseconds: 100));
          final stamp = Map<Object?, Object?>.from(host.tab!);
          final map = host.state['bottomTransition']! as Map;
          expect(
            (map['cover'] as Map)['left'],
            closeTo(tester.getRect(find.byKey(childKey)).left, .0001),
          );
          await host.tapTab('search');
          expect(selected, isEmpty);
          await g.up();
          // Inspect each rendered settle frame, including the final state update.
          for (var i = 0; i < 30 && tester.binding.hasScheduledFrame; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            final p = host.state['bottomTransition'];
            if (p is Map && p['cover'] != null) {
              expect(
                (p['cover'] as Map)['left'],
                closeTo(tester.getRect(find.byKey(childKey)).left, .0001),
              );
              expect((p['tab'] as Map)['ownerToken'], stamp['ownerToken']);
              expect((p['tab'] as Map)['routeSession'], stamp['routeSession']);
              expect(
                (p['tab'] as Map)['semanticRevision'],
                stamp['semanticRevision'],
              );
            }
          }
          await tester.pumpAndSettle();
          expect(host.state.containsKey('bottomTransition'), isFalse);
          expect(find.byKey(childKey), commit ? findsNothing : findsOneWidget);
          if (commit) {
            expect(host.tab, isNotNull);
            await host.tapTab('search');
            expect(selected, ['search']);
          } else {
            expect(host.tab, isNull);
            await host.tapTab('search', stamp: stamp);
            expect(selected, isEmpty);
            nav.currentState!.pop();
            await tester.pumpAndSettle();
            expect(
              host.tab!['routeSession'],
              greaterThan(stamp['routeSession'] as int),
            );
            await host.tapTab('search', stamp: stamp);
            expect(
              selected,
              isEmpty,
              reason:
                  'cancelled activation cannot supply late requests to a later root',
            );
            await host.tapTab('search');
            expect(selected, ['search']);
          }
        },
        variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      );
    }
  }

  testWidgets(
    'unmeasurable footprint stays closed; detach removes its observer',
    (tester) async {
      await open(tester);
      final g = await partial(tester);
      cover.offstage = true;
      await tester.pump();
      final map = host.state['bottomTransition']! as Map;
      expect(
        map['cover'],
        isNull,
        reason: 'offstage cannot reuse the last painted clip',
      );
      await host.tapTab('search');
      expect(selected, isEmpty);
      cover.offstage = false;
      await tester.pump();
      expect((host.state['bottomTransition']! as Map)['cover'], isNotNull);
      final lease = host.currentLease;
      controller.detach();
      await tester.pump();
      expect(host.nativeState, isNull);
      await g.up();
      await tester.pumpAndSettle();
      await controller.attach();
      await tester.pumpAndSettle();
      expect(host.currentLease, isNot(lease));
      expect(host.state.containsKey('bottomTransition'), isFalse);
      expect(host.tab, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'presentation uses canonical root priority with two visible tab owners',
    (tester) async {
      NativeTabBar bar(String selection, String badge) => NativeTabBar(
        selectedId: selection,
        onSelect: selected.add,
        items: [
          NativeTabItem(
            id: 'home',
            label: 'Home',
            icon: NativeChromeIcons.home,
            badge: badge,
          ),
          const NativeTabItem(
            id: 'search',
            label: 'Search',
            icon: NativeChromeIcons.search,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [NativeChromeNavigatorObserver()],
          builder: (context, child) =>
              NativeChrome(controller: controller, child: child!),
          home: NativeChromeScaffold(
            tabBar: bar('home', '1'),
            body: NativeChromeScaffold(
              tabBar: bar('search', '9'),
              body: const Text('nested owner root'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final canonical = Map<Object?, Object?>.from(host.tab!);
      expect(canonical['selectedId'], 'search');
      expect((canonical['items'] as List).first['badge'], '9');
      cover = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('child')),
      );
      nav.currentState!.push(cover);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final presentation = host.state['bottomTransition']! as Map;
      expect(
        presentation['tab'],
        canonical,
        reason:
            'presentation borrows the same eligible depth/order winner, including selection, badge and stamp',
      );
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'removeRoute during push disposes presentation and restores root input',
    (tester) async {
      await open(tester);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      cover = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('removed child')),
      );
      nav.currentState!.push(cover);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(host.state['bottomTransition'], isA<Map>());
      expect(cover.animation!.status, AnimationStatus.forward);
      nav.currentState!.removeRoute(cover);
      await tester.pumpAndSettle();
      expect(find.text('removed child'), findsNothing);
      expect(
        host.state.containsKey('bottomTransition'),
        isFalse,
        reason: 'removed route need not emit terminal animation status',
      );
      expect(host.tab, isNotNull);
      await host.tapTab('search');
      expect(
        selected,
        ['search'],
        reason: 'returned root must not retain a dead fail-closed presentation',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
