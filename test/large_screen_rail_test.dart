import 'dart:async';
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_chrome/native_chrome.dart';

import 'support/fake_host.dart';

/// Android large screens: an opted-in tab bar is shown by the host as a side
/// rail instead of the bottom bar; the scaffold reserves its width once.
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

  NativeTabBar tabs({bool rail = true}) => NativeTabBar(
    selectedId: 'a',
    onSelect: (_) {},
    largeScreenRail: rail,
    items: const [
      NativeTabItem(id: 'a', label: 'A', icon: NativeChromeIcons.home),
      NativeTabItem(id: 'b', label: 'B', icon: NativeChromeIcons.search),
    ],
  );

  Future<void> pump(WidgetTester tester, NativeTabBar bar) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(left: 24, top: 30);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            NativeChrome(controller: controller, child: child!),
        home: NativeChromeScaffold(
          tabBar: bar,
          body: const SizedBox.expand(key: ValueKey('body')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('wire: rail flag only when opted in', () {
    expect(tabs(rail: false).largeScreenRail, isFalse);
    expect(tabs().largeScreenRail, isTrue);
  });

  testWidgets(
    'tab wire carries the rail opt-in only when set',
    (tester) async {
      await pump(tester, tabs());
      expect(host.tab?['rail'], isTrue);
      await pump(tester, tabs(rail: false));
      expect(host.tab?.containsKey('rail'), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'host rail: body loses the rail width once, no bottom slot',
    (tester) async {
      await pump(tester, tabs());
      await host.send('geometry', <String, Object?>{
        'topInset': 30.0,
        'topBarHeight': 0.0,
        'topBarVisible': false,
        'tabBarHeight': 0.0,
        'tabBarVisible': true,
        'tabBarPlacement': 'start',
        'tabRailWidth': 104.0, // 24 start inset + 80 rail
      });
      await tester.pumpAndSettle();
      expect(controller.geometry.tabRailWidth, 104);
      final body = find.byKey(const ValueKey('body'));
      expect(tester.getTopLeft(body).dx, 104);
      expect(tester.getSize(body).width, 1000 - 104);
      expect(tester.getBottomLeft(body).dy, 800, reason: 'no bottom slot');
      expect(
        MediaQuery.paddingOf(tester.element(body)).left,
        0,
        reason: 'the rail covers the start safe area',
      );
      expect(
        find.byKey(const ValueKey('native_chrome.placeholder')),
        findsNothing,
      );

      // Back to the bottom bar (for example the window became narrower).
      await host.send('geometry', <String, Object?>{
        'topInset': 30.0,
        'topBarHeight': 0.0,
        'topBarVisible': false,
        'tabBarHeight': 80.0,
        'tabBarVisible': true,
        'tabBarPlacement': 'bottom',
        'tabRailWidth': 0.0,
      });
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(body).dx, 0);
      expect(tester.getBottomLeft(body).dy, 800 - 80);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'before measurement: nothing is reserved for a rail until the host '
    'reports one',
    (tester) async {
      // FakeHost reports no geometry on attach: not measured yet.
      await pump(tester, tabs());
      expect(controller.geometry.measured, isFalse);
      final body = find.byKey(const ValueKey('body'));
      expect(tester.getTopLeft(body).dx, 0);
      expect(
        find.byKey(const ValueKey('native_chrome.placeholder')),
        findsOneWidget,
        reason: 'estimated bottom slot',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  Future<void> sendGeometry({required bool rail}) =>
      host.send('geometry', <String, Object?>{
        'topInset': 30.0,
        'topBarHeight': 0.0,
        'topBarVisible': false,
        'tabBarHeight': rail ? 0.0 : 80.0,
        'tabBarVisible': true,
        'tabBarPlacement': rail ? 'start' : 'bottom',
        'tabRailWidth': rail ? 104.0 : 0.0,
      });

  testWidgets(
    'root dialogs, sheets and menus open beside the rail; pages and the '
    'app subtree are not remounted',
    (tester) async {
      await pump(tester, tabs());
      await sendGeometry(rail: true);
      await tester.pumpAndSettle();
      final body = find.byKey(const ValueKey('body'));
      final bodyElement = tester.element(body);
      // The app itself starts beside the rail; no synthetic display feature.
      expect(MediaQuery.of(bodyElement).displayFeatures, isEmpty);
      expect(MediaQuery.of(bodyElement).size.width, 1000 - 104);

      final rootContext = tester.element(find.byType(Navigator).first);
      // Fixed snack bar of the page scaffold (full scaffold width slot).
      ScaffoldMessenger.of(bodyElement).showSnackBar(
        const SnackBar(content: Text('snack', key: ValueKey('snack'))),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byType(SnackBar)).dx,
        greaterThanOrEqualTo(104),
      );
      ScaffoldMessenger.of(bodyElement).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      // Dialog on the root navigator.
      unawaited(
        showDialog<void>(
          context: rootContext,
          builder: (_) => const Dialog(
            child: SizedBox(width: 2000, height: 100, key: ValueKey('dialog')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('dialog'))).dx,
        greaterThanOrEqualTo(104),
      );
      Navigator.of(rootContext).pop();
      await tester.pumpAndSettle();

      unawaited(
        showModalBottomSheet<void>(
          context: rootContext,
          useRootNavigator: true,
          builder: (_) => const SizedBox(height: 80, key: ValueKey('sheet')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('sheet'))).dx,
        greaterThanOrEqualTo(104),
      );
      Navigator.of(rootContext).pop();
      await tester.pumpAndSettle();

      unawaited(
        showMenu<int>(
          context: rootContext,
          position: const RelativeRect.fromLTRB(0, 60, 1000, 0),
          items: const [PopupMenuItem<int>(value: 1, child: Text('menu-item'))],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('menu-item')).dx,
        greaterThanOrEqualTo(104),
      );
      Navigator.of(rootContext).pop();
      await tester.pumpAndSettle();

      // Back to the bottom bar: no feature, same page element (no remount).
      await sendGeometry(rail: false);
      await tester.pumpAndSettle();
      expect(identical(tester.element(body), bodyElement), isTrue);
      expect(MediaQuery.of(tester.element(body)).displayFeatures, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'landscape rail (fractional logical width): root dialog opens without '
    'a sub-screen bounds assertion',
    (tester) async {
      // Pixel 7 class emulator at sw600 in landscape: 2400x1575 px, dpr 2.625.
      tester.view.physicalSize = const Size(2400, 1575);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              NativeChrome(controller: controller, child: child!),
          home: NativeChromeScaffold(
            tabBar: tabs(),
            body: const SizedBox.expand(key: ValueKey('body')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await host.send('geometry', <String, Object?>{
        'topInset': 0.0,
        'topBarHeight': 0.0,
        'topBarVisible': false,
        'tabBarHeight': 0.0,
        'tabBarVisible': true,
        'tabBarPlacement': 'start',
        'tabRailWidth': 346 / 2.625,
      });
      await tester.pumpAndSettle();
      final rootContext = tester.element(find.byType(Navigator).first);
      unawaited(
        showGeneralDialog<void>(
          context: rootContext,
          barrierDismissible: true,
          barrierLabel: 'close',
          pageBuilder: (_, _, _) => const Align(
            child: SizedBox(width: 50, height: 50, key: ValueKey('g')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('g'))).dx,
        greaterThan(346 / 2.625),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'OS hinge with the rail: dialogs and left/right anchored menus stay on '
    'one side of the hinge',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      // Vertical hinge 500..520 (window coordinates).
      tester.view.displayFeatures = const [
        DisplayFeature(
          bounds: Rect.fromLTRB(500, 0, 520, 800),
          type: DisplayFeatureType.hinge,
          state: DisplayFeatureState.postureFlat,
        ),
      ];
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              NativeChrome(controller: controller, child: child!),
          home: NativeChromeScaffold(
            tabBar: tabs(),
            body: const SizedBox.expand(key: ValueKey('body')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await sendGeometry(rail: true);
      await tester.pumpAndSettle();
      final body = tester.element(find.byKey(const ValueKey('body')));
      // Translated into the inset area: 500-104 .. 520-104.
      expect(
        MediaQuery.of(body).displayFeatures.single.bounds,
        const Rect.fromLTRB(396, 0, 416, 800),
      );
      const hinge = Rect.fromLTRB(500, 0, 520, 800);
      bool crosses(Rect r) => r.left < hinge.right && r.right > hinge.left;
      final rootContext = tester.element(find.byType(Navigator).first);

      for (final left in [150.0, 900.0]) {
        unawaited(
          showMenu<int>(
            context: rootContext,
            position: RelativeRect.fromLTRB(left, 60, 1000 - left, 0),
            items: const [
              PopupMenuItem<int>(value: 1, child: Text('menu-item')),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final menu = tester.getRect(
          find
              .ancestor(
                of: find.text('menu-item'),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(crosses(menu), isFalse, reason: 'menu at $left: $menu');
        expect(menu.left, greaterThanOrEqualTo(104));
        Navigator.of(rootContext).pop();
        await tester.pumpAndSettle();
      }

      unawaited(
        showDialog<void>(
          context: rootContext,
          builder: (_) => const Dialog(
            child: SizedBox(width: 2000, height: 100, key: ValueKey('dialog')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dialog = tester.getRect(find.byKey(const ValueKey('dialog')));
      expect(crosses(dialog), isFalse, reason: '$dialog');
      expect(dialog.left, greaterThanOrEqualTo(104));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Flutter tab renderer: no rail inset even if a rail was reported',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => NativeChrome(
            controller: controller,
            config: const NativeChromeConfig(
              android: NativeChromePlatformConfig(
                tabBar: ChromeRenderer.flutter,
              ),
            ),
            child: child!,
          ),
          home: NativeChromeScaffold(
            tabBar: tabs(),
            body: const SizedBox.expand(key: ValueKey('body')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await sendGeometry(rail: true);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const ValueKey('body'))).dx, 0);
      expect(find.byType(NavigationBar), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final rtl in [false, true]) {
    testWidgets('rail tap while a popup is open acts like its barrier '
        '(${rtl ? 'RTL' : 'LTR'}): dismissible closes, non-dismissible stays, '
        'no tab selection', (tester) async {
      var selections = 0;
      final bar = NativeTabBar(
        selectedId: 'a',
        onSelect: (_) => selections++,
        onReselect: (_) => selections++,
        largeScreenRail: true,
        items: const [
          NativeTabItem(id: 'a', label: 'A', icon: NativeChromeIcons.home),
          NativeTabItem(id: 'b', label: 'B', icon: NativeChromeIcons.search),
        ],
      );
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: MaterialApp(
            navigatorObservers: [NativeChromeNavigatorObserver()],
            builder: (context, child) => Directionality(
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              child: NativeChrome(controller: controller, child: child!),
            ),
            home: NativeChromeScaffold(
              tabBar: bar,
              body: const SizedBox.expand(key: ValueKey('body')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await sendGeometry(rail: true);
      await tester.pumpAndSettle();
      final strip = Offset(rtl ? 1000 - 50 : 50, 400);

      // The strip has no semantics node (no unnamed tap target),
      // and without a popup it is not hit-tested (touches pass through).
      final semantics = tester.ensureSemantics();
      final unnamedTaps = <SemanticsNode>[];
      void visit(SemanticsNode node) {
        final data = node.getSemanticsData();
        if (data.hasAction(SemanticsAction.tap) &&
            data.label.isEmpty &&
            data.tooltip.isEmpty &&
            data.value.isEmpty) {
          unnamedTaps.add(node);
        }
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(
        tester
            .binding
            .renderViews
            .first
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!,
      );
      expect(unnamedTaps, isEmpty, reason: 'no unnamed tap node');
      semantics.dispose();
      final stripRender = tester.renderObject(
        find.byKey(const ValueKey('native_chrome.railStrip')),
      );
      HitTestResult hitAt(Offset position) {
        final result = HitTestResult();
        tester.binding.hitTestInView(result, position, tester.view.viewId);
        return result;
      }

      expect(
        hitAt(strip).path.any((entry) => identical(entry.target, stripRender)),
        isFalse,
        reason: 'inactive strip passes touches through',
      );
      final rootContext = tester.element(find.byType(Navigator).first);
      final updatesBefore = host.updateCount;

      for (final dismissible in [true, false]) {
        unawaited(
          showGeneralDialog<void>(
            context: rootContext,
            barrierDismissible: dismissible,
            barrierLabel: 'close',
            pageBuilder: (_, _, _) => const Align(
              child: SizedBox(width: 80, height: 80, key: ValueKey('popup')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('popup')), findsOneWidget);
        expect(
          hitAt(strip).path.any((e) => identical(e.target, stripRender)),
          dismissible,
          reason: 'strip is hit-tested only for a dismissible popup',
        );
        await tester.tapAt(strip);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('popup')),
          dismissible ? findsNothing : findsOneWidget,
          reason: 'dismissible=$dismissible',
        );
        if (!dismissible) {
          Navigator.of(rootContext).pop();
          await tester.pumpAndSettle();
        }
      }
      expect(selections, 0, reason: 'a rail tap never selects a tab');
      expect(
        host.calls.where((c) => c.method == 'event'),
        isEmpty,
        reason: 'no native tab request',
      );
      expect(host.updateCount, greaterThanOrEqualTo(updatesBefore));
      // Without a popup the strip does nothing.
      await tester.tapAt(strip);
      await tester.pumpAndSettle();
      expect(selections, 0);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('Flutter renderer: every tab label is always shown', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          navigationBarTheme: const NavigationBarThemeData(
            labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
          ),
        ),
        home: NativeChrome(
          config: const NativeChromeConfig.allFlutter(),
          controller: controller,
          child: NativeChromeScaffold(tabBar: tabs(), body: const SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bar = tester.widget<NavigationBar>(
      find.byKey(const ValueKey('native_chrome.flutter.tabBar')),
    );
    expect(bar.labelBehavior, NavigationDestinationLabelBehavior.alwaysShow);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets(
    'iOS ignores the opt-in: bottom slot as before',
    (tester) async {
      await pump(tester, tabs());
      final body = find.byKey(const ValueKey('body'));
      expect(tester.getTopLeft(body).dx, 0);
      expect(debugDefaultTargetPlatformOverride, TargetPlatform.iOS);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
