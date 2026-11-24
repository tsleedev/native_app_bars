import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_app_bars/native_app_bars.dart';

void main() {
  Future<void> life(WidgetTester tester, AppLifecycleState state) async {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pumpAndSettle();
  }

  Widget page(
    List<int> selections, {
    int selected = 0,
    bool active = true,
    bool stacked = false,
    bool Function(Route<dynamic>?)? routeIsActive,
  }) => MaterialApp(
    home: Scaffold(
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NativeChromeSegmentedControl(
            key: const Key('main'),
            labels: const ['기록', '성장', '예방접종'],
            selectedIndex: selected,
            active: active,
            routeIsActive: routeIsActive,
            onChanged: selections.add,
          ),
          // A second control flush below the first, as a sub-segment.
          if (stacked)
            NativeChromeSegmentedControl(
              key: const Key('sub'),
              labels: const ['성장 차트', '활동 통계'],
              selectedIndex: 0,
              onChanged: (_) {},
            ),
        ],
      ),
    ),
  );

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('48dp targets for every segment, flush stacking, inset taps', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final selections = <int>[];
    await tester.pumpWidget(page(selections, stacked: true));
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    for (final label in ['기록', '성장', '예방접종', '성장 차트', '활동 통계']) {
      expect(
        tester.getSemantics(find.text(label)).rect.height,
        greaterThanOrEqualTo(NativeChromeSegmentedControl.minTargetSize),
        reason: label,
      );
    }
    final main = tester.getRect(find.byKey(const Key('main')));
    final sub = tester.getRect(find.byKey(const Key('sub')));
    expect(sub.top, main.bottom);
    expect(main.height, greaterThanOrEqualTo(48));
    // A tap in the inset outside the visible pill still selects.
    final growth = tester.getRect(find.text('성장'));
    await tester.tapAt(Offset(growth.center.dx, main.top + 1));
    await tester.pumpAndSettle();
    expect(selections, [1]);
    expect(
      tester.getSemantics(find.text('기록')),
      matchesSemantics(
        label: '기록',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    expect(
      tester.getSemantics(find.text('성장')),
      matchesSemantics(
        label: '성장',
        isButton: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    // The current segment does not report a change.
    await tester.tap(find.text('기록'));
    expect(selections, [1]);
    handle.dispose();
  });

  testWidgets('no selection while the app is not resumed', (tester) async {
    final handle = tester.ensureSemantics();
    final selections = <int>[];
    await tester.pumpWidget(page(selections));
    await tester.pumpAndSettle();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      await life(tester, state);
      expect(
        tester.getSemantics(find.text('성장')),
        matchesSemantics(
          label: '성장',
          isButton: true,
          hasSelectedState: true,
          isInMutuallyExclusiveGroup: true,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
        reason: '$state',
      );
      await tester.tap(find.text('성장'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(selections, isEmpty, reason: '$state');
    }
    await life(tester, AppLifecycleState.resumed);
    expect(
      tester
          .getSemantics(find.text('성장'))
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    await tester.tap(find.text('성장'));
    await tester.pumpAndSettle();
    expect(selections, [1]);
    handle.dispose();
  });

  testWidgets('re-checks the lifecycle when a tap lands before rebuild', (
    tester,
  ) async {
    final selections = <int>[];
    await tester.pumpWidget(page(selections));
    await tester.pumpAndSettle();
    // Window focus moves away; the tap arrives before the next frame.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.tap(find.text('예방접종'));
    expect(selections, isEmpty);
    await life(tester, AppLifecycleState.resumed);
    await tester.tap(find.text('예방접종'));
    await tester.pumpAndSettle();
    expect(selections, [2]);
  });

  testWidgets('re-asks the route policy when a tap lands before rebuild', (
    tester,
  ) async {
    final selections = <int>[];
    var allowed = true;
    Route<dynamic>? asked;
    await tester.pumpWidget(
      page(
        selections,
        routeIsActive: (route) {
          asked = route;
          return allowed;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(asked, isNotNull);
    // Only the policy result changes (for example an outer barrier opens);
    // nothing rebuilds before the tap is delivered.
    allowed = false;
    await tester.tap(find.text('예방접종'));
    expect(selections, isEmpty);
    allowed = true;
    await tester.tap(find.text('예방접종'));
    expect(selections, [2]);
  });

  testWidgets('an inactive owner gets no selection', (tester) async {
    final selections = <int>[];
    await tester.pumpWidget(page(selections, active: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('예방접종'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
  });

  testWidgets('a covered or animating route gets no selection', (tester) async {
    final selections = <int>[];
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: NativeChromeSegmentedControl(
            labels: const ['A', 'B'],
            selectedIndex: 0,
            onChanged: selections.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.text('B')))!;
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
    await tester.pumpAndSettle();
    expect(route.isCurrent, isFalse);
    await tester.tap(find.text('B'), warnIfMissed: false);
    expect(selections, isEmpty);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    expect(selections, [1]);
  });

  testWidgets('colors and text style follow the owner', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NativeChromeSegmentedControl(
            labels: const ['A', 'B'],
            selectedIndex: 0,
            onChanged: (_) {},
            trackColor: const Color(0xFF000001),
            selectedColor: const Color(0xFF000002),
            foregroundColor: const Color(0xFF000003),
            selectedForegroundColor: const Color(0xFF000004),
            textStyle: const TextStyle(fontSize: 13),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<Material>(
            find.descendant(
              of: find.byType(NativeChromeSegmentedControl),
              matching: find.byType(Material),
            ),
          )
          .color,
      const Color(0xFF000001),
    );
    final selected = tester.widget<Text>(find.text('A'));
    final other = tester.widget<Text>(find.text('B'));
    expect(selected.style!.color, const Color(0xFF000004));
    expect(other.style!.color, const Color(0xFF000003));
    expect(other.style!.fontSize, 13);
    final pill = tester.widget<DecoratedBox>(
      find
          .ancestor(of: find.text('A'), matching: find.byType(DecoratedBox))
          .first,
    );
    expect((pill.decoration as BoxDecoration).color, const Color(0xFF000002));
  });
}
