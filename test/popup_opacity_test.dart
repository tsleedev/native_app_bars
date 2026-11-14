import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_app_bars/native_app_bars.dart';
import 'support/fake_host.dart';

void main() {
  testWidgets(
    'root popup paint normalizes independently of suspension and lifecycle',
    (tester) async {
      final host = FakeHost()..install();
      final controller = testController();
      final opacity = ValueNotifier<double?>(null);
      final nav = GlobalKey<NavigatorState>();
      addTearDown(host.uninstall);
      addTearDown(controller.dispose);
      addTearDown(opacity.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [NativeChromeNavigatorObserver()],
          builder: (_, child) => ValueListenableBuilder<double?>(
            valueListenable: opacity,
            builder: (_, value, _) => NativeChrome(
              controller: controller,
              popupOpacity: value,
              child: child!,
            ),
          ),
          home: const NativeChromeScaffold(
            topBar: NativeTopBar(title: 'root'),
            body: SizedBox(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final owner = host.top!['ownerToken'];
      final session = host.top!['routeSession'];
      opacity.value = .3;
      await tester.pumpAndSettle();
      expect(host.state['suspended'], false);
      expect(
        host.state['dim'],
        isNull,
        reason: 'paint does not create a modal',
      );
      expect(host.top!['ownerToken'], owner);
      expect(host.top!['routeSession'], session);
      controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      expect(host.state['suspended'], true);
      expect(
        host.state['dim'],
        isNull,
        reason: 'lifecycle alone does not create popup paint',
      );
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      final activeSession = host.top!['routeSession'];
      final semanticRevision = host.top!['semanticRevision'];
      final route = DialogRoute<void>(
        context: nav.currentContext!,
        barrierColor: Colors.black54,
        builder: (_) => const AlertDialog(content: Text('modal')),
      );
      nav.currentState!.push(route);
      await tester.pumpAndSettle();
      for (final row in <(double?, double?, int?)>[
        (null, Colors.black54.a, route.transitionDuration.inMilliseconds),
        (0, 0, 0),
        (.8, .8, 0),
        (-1e100, 0, 0),
        (1e100, 1, 0),
        (double.nan, Colors.black54.a, route.transitionDuration.inMilliseconds),
        (
          double.negativeInfinity,
          Colors.black54.a,
          route.transitionDuration.inMilliseconds,
        ),
      ]) {
        opacity.value = row.$1;
        await tester.pumpAndSettle();
        final dim = host.state['dim'] as Map;
        expect(Color(dim['color'] as int).a, closeTo(row.$2!, 1 / 255));
        expect(dim['durationMs'], row.$3);
        expect(host.state['suspended'], true);
        expect(host.state.containsKey('popupOpacity'), false);
        expect(host.top!['ownerToken'], owner);
        expect(host.top!['semanticRevision'], semanticRevision);
        expect(
          host.top!['routeSession'],
          activeSession,
          reason: 'style ticks do not renew ownership',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(
        controller.popupOpacity,
        isNull,
        reason: 'root removal clears its paint authority',
      );
      expect(host.nativeState, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
  testWidgets(
    'root controller replacement releases the previous popup style',
    (tester) async {
      final host = FakeHost()..install();
      final first = testController();
      final second = testController();
      final selected = ValueNotifier(first);
      addTearDown(host.uninstall);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      addTearDown(selected.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => ValueListenableBuilder<NativeChromeController>(
            valueListenable: selected,
            builder: (_, controller, _) => NativeChrome(
              controller: controller,
              popupOpacity: .4,
              child: child!,
            ),
          ),
          home: const NativeChromeScaffold(
            topBar: NativeTopBar(title: 'root'),
            body: SizedBox(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(first.popupOpacity, .4);
      selected.value = second;
      await tester.pumpAndSettle();
      expect(first.popupOpacity, isNull);
      expect(second.popupOpacity, .4);
      expect(host.state['suspended'], false);
      expect(host.state['dim'], isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(second.popupOpacity, isNull);
      expect(host.nativeState, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
