import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_chrome/native_chrome.dart';

import 'support/fake_host.dart';

/// Records callbacks made by test pages.
class Log {
  final List<String> events = <String>[];
  void add(String e) => events.add(e);
  int count(String e) => events.where((x) => x == e).length;
}

Widget testApp({
  required NativeChromeController controller,
  NativeChromeConfig config = const NativeChromeConfig(),
  required Widget home,
  List<NavigatorObserver> observers = const <NavigatorObserver>[],
}) => MaterialApp(
  navigatorObservers: observers,
  builder: (context, child) =>
      NativeChrome(controller: controller, config: config, child: child!),
  home: home,
);

class TopPage extends StatelessWidget {
  const TopPage({
    super.key,
    required this.title,
    required this.log,
    this.next,
    this.saveEnabled = true,
    this.slowSave = false,
  });

  final String title;
  final Log log;
  final Widget? next;
  final bool saveEnabled;
  final bool slowSave;

  @override
  Widget build(BuildContext context) => NativeChromeScaffold(
    topBar: NativeTopBar(
      title: title,
      actions: <NativeBarAction>[
        NativeBarAction(
          id: 'save',
          label: 'Save',
          icon: NativeChromeIcons.save,
          enabled: saveEnabled,
          onPressed: () async {
            log.add('save:$title');
            if (slowSave) {
              await Future<void>.delayed(const Duration(seconds: 1));
            }
          },
        ),
      ],
    ),
    body: Center(
      child: next == null
          ? Text('body $title')
          : TextButton(
              key: ValueKey<String>('open-from-$title'),
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => next!)),
              child: Text('open from $title'),
            ),
    ),
  );
}

class TabsPage extends StatefulWidget {
  const TabsPage({super.key, required this.log, this.rejectSearch = false});

  final Log log;
  final bool rejectSearch;

  @override
  State<TabsPage> createState() => TabsPageState();
}

class TabsPageState extends State<TabsPage> {
  String selected = 'home';
  String? badge = '1';
  int rebuilds = 0;

  void rebuild() => setState(() => rebuilds++);
  void setBadge(String? value) => setState(() => badge = value);

  @override
  Widget build(BuildContext context) => NativeChromeScaffold(
    tabBar: NativeTabBar(
      selectedId: selected,
      onSelect: (id) {
        widget.log.add('select:$id');
        if (id == 'search' && widget.rejectSearch) return;
        setState(() => selected = id);
      },
      onReselect: (id) => widget.log.add('reselect:$id'),
      items: <NativeTabItem>[
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
        const NativeTabItem(
          id: 'off',
          label: 'Off',
          icon: NativeChromeIcons.settings,
          enabled: false,
        ),
      ],
    ),
    body: NativeChromeTabStack(
      index: selected == 'home' ? 0 : 1,
      children: <Widget>[
        TopPage(title: 'HomeTop', log: widget.log),
        TopPage(title: 'SearchTop', log: widget.log),
      ],
    ),
  );
}

void main() {
  late FakeHost host;
  late NativeChromeController controller;
  late Log log;

  setUp(() {
    host = FakeHost()..install();
    controller = testController();
    log = Log();
  });

  tearDown(() => controller.dispose());

  tearDown(() {
    host.uninstall();
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets(
      'top opacity normalizes and restores without owner/input changes $platform',
      (tester) async {
        final alpha = ValueNotifier<double>(1);
        addTearDown(alpha.dispose);
        var taps = 0;
        await tester.pumpWidget(
          testApp(
            controller: controller,
            home: ValueListenableBuilder<double>(
              valueListenable: alpha,
              builder: (context, value, _) => NativeChromeScaffold(
                topBar: NativeTopBar(
                  title: 'fade',
                  opacity: value,
                  actions: [
                    NativeBarAction(
                      id: 'save',
                      label: 'save',
                      onPressed: () {
                        taps++;
                      },
                    ),
                  ],
                ),
                body: const SizedBox(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final owner = host.top!['ownerToken'];
        final session = host.top!['routeSession'];
        expect(host.top!.containsKey('opacity'), false);
        for (final row in <(double, double)>[
          (.5, .5),
          (0, 0),
          (-2, 0),
          (3, 1),
          (double.nan, 1),
          (double.infinity, 1),
          (1, 1),
        ]) {
          alpha.value = row.$1;
          await tester.pumpAndSettle();
          expect(host.top?['opacity'] ?? 1, row.$2);
          expect(host.top?['ownerToken'], owner);
          expect(host.top?['routeSession'], session);
          expect(host.state['suspended'], false);
          await host.tapTop('save');
        }
        expect(taps, 7, reason: 'alpha is visual only, including zero');
        expect(
          host.top!.containsKey('opacity'),
          false,
          reason: 'default wire stays unchanged',
        );
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
  for (final scaffold in [false, true]) {
    testWidgets(
      'Flutter opacity is applied once with semantics scaffold=$scaffold',
      (tester) async {
        final alpha = ValueNotifier<double>(.5);
        addTearDown(alpha.dispose);
        await tester.pumpWidget(
          testApp(
            controller: controller,
            config: const NativeChromeConfig.allFlutter(),
            home: ValueListenableBuilder<double>(
              valueListenable: alpha,
              builder: (context, value, _) {
                final top = NativeTopBar(title: 'fade', opacity: value);
                return scaffold
                    ? NativeChromeScaffold(topBar: top, body: const SizedBox())
                    : Scaffold(
                        appBar: NativeChromeAppBar(bar: top),
                        body: const SizedBox(),
                      );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        List<Opacity> fades() => tester
            .widgetList<Opacity>(
              find.ancestor(
                of: find.byType(AppBar),
                matching: find.byType(Opacity),
              ),
            )
            .toList();
        expect(fades(), hasLength(1));
        expect(fades().single.opacity, .5);
        expect(fades().single.alwaysIncludeSemantics, true);
        alpha.value = 0;
        await tester.pumpAndSettle();
        expect(fades().single.opacity, 0);
        alpha.value = double.nan;
        await tester.pumpAndSettle();
        expect(fades(), isEmpty);
      },
    );
  }

  group('renderer selection', () {
    testWidgets('per platform and per bar, host required', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          config: const NativeChromeConfig(
            ios: NativeChromePlatformConfig(tabBar: ChromeRenderer.flutter),
            android: NativeChromePlatformConfig.allFlutter(),
          ),
          home: const SizedBox(),
        ),
      );
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(controller.rendererFor(ChromeBarKind.top), ChromeRenderer.native);
      expect(controller.rendererFor(ChromeBarKind.tab), ChromeRenderer.flutter);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(controller.rendererFor(ChromeBarKind.top), ChromeRenderer.flutter);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(controller.rendererFor(ChromeBarKind.top), ChromeRenderer.flutter);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Flutter renderer draws the same description', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          config: const NativeChromeConfig.allFlutter(),
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('HomeTop'), findsOneWidget);
      expect(host.top, isNull);
      expect(host.tab, isNull);
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(log.events, contains('select:search'));
      expect(find.text('SearchTop'), findsOneWidget);
    });

    testWidgets('falls back to Flutter when the host is not installed', (
      tester,
    ) async {
      host.installed = false;
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(title: 'A', log: log),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.hostInstalled, isFalse);
      expect(find.byType(AppBar), findsOneWidget);
      expect(controller.diagnostics.hostIssue, contains('not installed'));
    });

    testWidgets('runtime switch between native and Flutter', (tester) async {
      var config = const NativeChromeConfig();
      late StateSetter setOuter;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return testApp(
              controller: controller,
              config: config,
              home: TopPage(title: 'A', log: log),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      expect(host.top?['title'], 'A');
      setOuter(() => config = const NativeChromeConfig.allFlutter());
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(host.top, isNull);
      setOuter(() => config = const NativeChromeConfig());
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      expect(host.top?['title'], 'A');
    });
  });

  group('native layout', () {
    testWidgets('reserves measured bar geometry', (tester) async {
      host.geometry = <String, Object?>{
        'topInset': 20.0,
        'topBarHeight': 50.0,
        'tabBarHeight': 70.0,
        'topBarVisible': true,
        'tabBarVisible': true,
      };
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.geometry.measured, isTrue);
      final body = tester.getTopLeft(find.text('body HomeTop'));
      final size = tester.getSize(find.byType(TabsPage));
      // Body is laid out between the native bars.
      expect(
        tester.getRect(find.byType(TopPage).first).top,
        greaterThanOrEqualTo(0),
      );
      final pageScaffold = find
          .descendant(
            of: find.byType(TopPage).first,
            matching: find.byType(Scaffold),
          )
          .first;
      final bodyRect = tester.getRect(
        find.descendant(of: pageScaffold, matching: find.byType(Center)).first,
      );
      expect(bodyRect.top, 70); // topInset + topBarHeight
      expect(bodyRect.bottom, size.height - 70); // tab bar height
      expect(body.dy, greaterThan(70));
    });

    testWidgets('keyboard hides the tab bar', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      expect(host.tab?['hidden'], isFalse);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(host.tab?['hidden'], isTrue);
    });
  });

  group('tab selection is owned by Dart', () {
    testWidgets('request accepted, reselect, app rejection, disabled', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log, rejectSearch: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(host.tab?['selectedId'], 'home');

      await host.tapTab('home');
      expect(log.events, contains('reselect:home'));

      await host.tapTab('search'); // app rejects by not changing state
      await tester.pumpAndSettle();
      expect(log.events, contains('select:search'));
      expect(host.tab?['selectedId'], 'home');

      await host.tapTab('off');
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.disabled],
        1,
      );
    });

    testWidgets('accepted selection is reflected back to native', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      await host.tapTab('search');
      await tester.pumpAndSettle();
      expect(host.tab?['selectedId'], 'search');
      expect(host.top?['title'], 'SearchTop');
    });

    testWidgets('rebuilds neither resend nor invalidate input', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state<TabsPageState>(find.byType(TabsPage));
      final updates = host.updates.length;
      final stamp = Map<Object?, Object?>.from(host.tab!);
      for (var i = 0; i < 50; i++) {
        state.rebuild();
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(host.updates.length, updates, reason: 'no content change');
      expect(host.tab?['semanticRevision'], stamp['semanticRevision']);
      await host.tapTab('search', stamp: stamp);
      expect(log.events, contains('select:search'));
    });

    testWidgets('content change keeps earlier input valid', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state<TabsPageState>(find.byType(TabsPage));
      final stamp = Map<Object?, Object?>.from(host.tab!);
      state.setBadge('2');
      await tester.pumpAndSettle();
      expect(
        host.tab?['semanticRevision'],
        (stamp['semanticRevision']! as int) + 1,
      );
      // An input produced before the badge update still selects.
      await host.tapTab('search', stamp: stamp);
      expect(log.events, contains('select:search'));
    });
  });

  group('owner and session checks', () {
    testWidgets('late event from a previous page never runs on the new page', (
      tester,
    ) async {
      final observer = NativeChromeNavigatorObserver();
      await tester.pumpWidget(
        testApp(
          controller: controller,
          observers: <NavigatorObserver>[observer],
          home: TopPage(
            title: 'A',
            log: log,
            next: TopPage(title: 'B', log: log),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final stampA = Map<Object?, Object?>.from(host.top!);
      await tester.tap(find.byKey(const ValueKey<String>('open-from-A')));
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'B');
      expect(host.top?['ownerToken'], isNot(stampA['ownerToken']));

      // A's save arrives late while B (which also has 'save') is shown.
      await host.tapTop('save', stamp: stampA);
      expect(log.events, isEmpty);
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.ownerMismatch],
        1,
      );

      // Back to A: A has a new session, so its pre-push event stays invalid.
      await host.tapTop('back');
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'A');
      expect(host.top?['ownerToken'], stampA['ownerToken']);
      expect(host.top?['routeSession'], isNot(stampA['routeSession']));
      await host.tapTop('save', stamp: stampA);
      expect(log.events, isEmpty);
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.sessionMismatch],
        1,
      );
      await host.tapTop('save');
      expect(log.events, <String>['save:A']);
    });

    testWidgets('inactive tab page never owns the bar', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'HomeTop');
      final homeStamp = Map<Object?, Object?>.from(host.top!);
      await host.tapTab('search');
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'SearchTop');
      await host.tapTop('save', stamp: homeStamp);
      expect(log.events.where((e) => e.startsWith('save')), isEmpty);
    });

    testWidgets('disabled and busy actions are rejected', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(title: 'A', log: log, slowSave: true),
        ),
      );
      await tester.pumpAndSettle();
      await host.tapTop('save');
      await host.tapTop('save');
      expect(log.count('save:A'), 1);
      expect(controller.diagnostics.rejected[NativeChromeRejection.busy], 1);
      await tester.pump(const Duration(seconds: 2));
      await host.tapTop('save');
      expect(log.count('save:A'), 2);
      await host.tapTop('unknown');
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.unknownId],
        1,
      );
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('disabled action is not executed', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(title: 'A', log: log, saveEnabled: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        (host.top?['actions'] as List).first,
        containsPair('enabled', false),
      );
      await host.tapTop('save');
      expect(log.events, isEmpty);
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.disabled],
        1,
      );
    });

    testWidgets('malformed events are rejected', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(title: 'A', log: log),
        ),
      );
      await tester.pumpAndSettle();
      await host.send('event', <String, Object?>{
        'type': 'topAction',
        'actionId': 'save',
        'lease': host.currentLease,
        'requestId': host.nextRequestId(),
      });
      expect(log.events, isEmpty);
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.malformed],
        1,
      );
    });
  });

  group('back and pop', () {
    testWidgets('implied back pops with Navigator 1', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(
            title: 'A',
            log: log,
            next: TopPage(title: 'B', log: log),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(host.top?['leading'], isNull);
      await tester.tap(find.byKey(const ValueKey<String>('open-from-A')));
      await tester.pumpAndSettle();
      expect((host.top?['leading'] as Map)['id'], 'back');
      await host.tapTop('back');
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'A');
      expect(find.text('open from A'), findsOneWidget);
    });

    testWidgets('implied back pops with Navigator 2 pages', (tester) async {
      final pages = <String>['A', 'B'];
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              NativeChrome(controller: controller, child: child!),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Navigator(
                pages: <Page<void>>[
                  for (final p in pages)
                    MaterialPage<void>(
                      key: ValueKey<String>(p),
                      child: TopPage(title: p, log: log),
                    ),
                ],
                onDidRemovePage: (page) => update(
                  () => pages.remove((page.key! as ValueKey<String>).value),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(host.top?['title'], 'B');
      await host.tapTop('back');
      await tester.pumpAndSettle();
      expect(pages, <String>['A']);
      expect(host.top?['title'], 'A');
    });
  });

  group('suspension, transitions and lifecycle', () {
    testWidgets('popup suspends native input and keeps the bar', (
      tester,
    ) async {
      final observer = NativeChromeNavigatorObserver();
      await tester.pumpWidget(
        testApp(
          controller: controller,
          observers: <NavigatorObserver>[observer],
          home: Builder(
            builder: (context) => NativeChromeScaffold(
              topBar: NativeTopBar(
                title: 'A',
                actions: <NativeBarAction>[
                  NativeBarAction(
                    id: 'save',
                    label: 'Save',
                    onPressed: () => log.add('save'),
                  ),
                ],
              ),
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(content: Text('dialog')),
                ),
                child: const Text('dialog'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      expect(host.state['suspended'], isTrue);
      expect(host.state['dim'], isNotNull);
      expect(host.top?['title'], 'A', reason: 'bar stays under the dialog');
      await host.tapTop('save');
      expect(log.events, isEmpty);
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.suspended],
        1,
      );
      await tester.tapAt(const Offset(5, 300)); // dismiss via barrier
      await tester.pumpAndSettle();
      expect(host.state['suspended'], isFalse);
      await host.tapTop('save');
      expect(log.events, <String>['save']);
    });

    testWidgets('NativeChromeSuspension for app overlays', (tester) async {
      var active = false;
      late StateSetter update;
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return NativeChromeSuspension(
                active: active,
                child: TopPage(title: 'A', log: log),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      update(() => active = true);
      await tester.pumpAndSettle();
      expect(host.state['suspended'], isTrue);
      await host.tapTop('save');
      expect(log.events, isEmpty);
      update(() => active = false);
      await tester.pumpAndSettle();
      await host.tapTop('save');
      expect(log.events, <String>['save:A']);
    });

    testWidgets('push transition is synced and input waits for it', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(
            title: 'A',
            log: log,
            next: TopPage(title: 'B', log: log),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('open-from-A')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.top?['title'], 'B');
      // Regression: a route that is already moving starts at once.
      final firstB = host.calls.indexWhere(
        (c) =>
            c.method == 'update' &&
            ((c.arguments as Map)['top'] as Map?)?['title'] == 'B',
      );
      final firstBegin = host.calls.indexWhere(
        (c) =>
            c.method == 'transition' &&
            (c.arguments as Map)['phase'] == 'begin',
      );
      expect(firstBegin, isNonNegative);
      expect(firstBegin, lessThan(firstB));
      final phases = host.transitions.map((t) => t['phase']).toList();
      expect(phases.first, 'begin');
      expect(host.transitions.first['direction'], 'push');
      expect(phases, contains('update'));
      expect(controller.transitionActive, isTrue);
      await host.tapTop('save');
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.transition],
        1,
      );
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');
      expect(controller.transitionActive, isFalse);
      await host.tapTop('save');
      expect(log.events, <String>['save:B']);
    });

    testWidgets('a bar inside a pushed nested navigator syncs with the outer '
        'route', (tester) async {
      final outerObserver = NativeChromeNavigatorObserver();
      final innerObserver = NativeChromeNavigatorObserver();
      await tester.pumpWidget(
        testApp(
          controller: controller,
          observers: <NavigatorObserver>[outerObserver],
          home: Builder(
            builder: (context) => NativeChromeScaffold(
              topBar: const NativeTopBar(title: 'Root'),
              body: TextButton(
                key: const ValueKey<String>('open-nested'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Navigator(
                      observers: <NavigatorObserver>[innerObserver],
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => const NativeChromeScaffold(
                          topBar: NativeTopBar(title: 'Nested detail'),
                          body: SizedBox(),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      host.transitions.clear();
      await tester.tap(find.byKey(const ValueKey<String>('open-nested')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.top?['title'], 'Nested detail');
      expect(host.transitions, isNotEmpty, reason: 'outer push drives it');
      // The native host snapshots the outgoing bar on `transition begin`, so
      // begin must reach it before any state showing the incoming bar (T1).
      final order = <String>[
        for (final c in host.calls)
          if (c.method == 'transition' &&
              (c.arguments as Map)['phase'] == 'begin')
            'begin'
          else if (c.method == 'update' &&
              ((c.arguments as Map)['top'] as Map?)?['title'] ==
                  'Nested detail')
            'update(B)',
      ];
      expect(order.first, 'begin', reason: 'order: $order');
      expect(order, contains('update(B)'));
      expect(host.transitions.first['phase'], 'begin');
      expect(host.transitions.first['direction'], 'push');
      await tester.pumpAndSettle();
      expect(host.transitions.last['phase'], 'end');
      expect(controller.transitionActive, isFalse);
    });

    testWidgets('hostReady and resume resend the full state', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(title: 'A', log: log),
        ),
      );
      await tester.pumpAndSettle();
      final before = host.updates.length;
      await host.send('hostReady', <String, Object?>{'hostInstalled': true});
      await tester.pumpAndSettle();
      expect(host.updates.length, before + 1);
      expect(host.top?['title'], 'A');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Leaving resumed sends the renewed stamps at once (lifecycle guard).
      expect(host.updates.length, before + 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(host.updates.length, before + 3);
    });

    testWidgets(
      'lifecycle: queued stale events are rejected, the first tap after resume is not',
      (tester) async {
        await tester.pumpWidget(
          testApp(
            controller: controller,
            home: TopPage(title: 'A', log: log),
          ),
        );
        await tester.pumpAndSettle();
        final shown = Map<Object?, Object?>.of(host.top!);
        // Leaving resumed: renewed stamps are sent at once (no frame needed).
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.idle();
        expect(host.top?['routeSession'], isNot(shown['routeSession']));
        // An event queued before the lifecycle change (old stamp) is stale.
        await host.tapTop('save', stamp: shown);
        await tester.pump();
        expect(log.events, isEmpty);
        expect(
          controller.diagnostics.rejected[NativeChromeRejection
              .sessionMismatch],
          1,
        );
        // While not resumed, even a current stamp is suspended input.
        await host.tapTop('save');
        await tester.pump();
        expect(log.events, isEmpty);
        expect(
          controller.diagnostics.rejected[NativeChromeRejection.suspended],
          1,
        );
        // Back to resumed: the host already shows the current stamp, so the
        // first tap (before any further frame or resend) is accepted.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await host.tapTop('save');
        await tester.pump();
        expect(log.events, <String>['save:A']);
        // A short inactive (control centre) round trip keeps the page usable.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        await host.tapTop('save');
        await tester.pumpAndSettle();
        expect(log.events, <String>['save:A', 'save:A']);
      },
    );

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets(
        'lifecycle initial inactive ${platform.name}: rejects input until resume',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          addTearDown(
            () => tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            ),
          );
          controller.dispose();
          controller = testController();
          await tester.pumpWidget(
            testApp(
              controller: controller,
              home: TabsPage(log: log),
            ),
          );
          await tester.pumpAndSettle();
          await host.tapTop('save');
          await host.tapTab('search');
          expect(
            log.events,
            isEmpty,
            reason: 'already inactive before controller creation',
          );
          expect(host.state['suspended'], isTrue);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          // Host update must precede the first new input, without a frame.
          await host.tapTop('save');
          await host.tapTab('search');
          expect(log.events, ['save:HomeTop', 'select:search']);
          expect(host.state['suspended'], isFalse);
          await tester.pumpAndSettle();
          debugDefaultTargetPlatformOverride = null;
        },
      );

      testWidgets(
        'lifecycle inactive stamp ${platform.name}: delayed input stays stale after resume',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(
            () => tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            ),
          );
          await tester.pumpWidget(
            testApp(
              controller: controller,
              home: TabsPage(log: log),
            ),
          );
          await tester.pumpAndSettle();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          await tester.idle();
          final inactiveTop = Map<Object?, Object?>.of(host.top!);
          final inactiveTab = Map<Object?, Object?>.of(host.tab!);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await host.tapTop('save', stamp: inactiveTop);
          await host.tapTab('search', stamp: inactiveTab);
          expect(
            log.events,
            isEmpty,
            reason: 'input stamped during inactive must not run after resume',
          );
          expect(
            controller.diagnostics.rejected[NativeChromeRejection
                .sessionMismatch],
            2,
          );
          await host.tapTop('save');
          await host.tapTab('search');
          expect(log.events, ['save:HomeTop', 'select:search']);
          expect(host.state['suspended'], isFalse);
          await tester.pumpAndSettle();
          debugDefaultTargetPlatformOverride = null;
        },
      );
    }

    testWidgets('icons are rasterised once for native hosts', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      final iconCalls = host.calls.where((c) => c.method == 'icons').toList();
      final keys = <Object?>{
        for (final c in iconCalls) ...(c.arguments as Map).keys,
      };
      expect(keys, contains(NativeChromeIcons.home.key));
      expect(keys, contains(NativeChromeIcons.save.key));
      final count = iconCalls.length;
      tester.state<TabsPageState>(find.byType(TabsPage)).setBadge('9');
      await tester.pumpAndSettle();
      expect(host.calls.where((c) => c.method == 'icons').length, count);
    });
  });

  group('connection lease (R1, R4)', () {
    testWidgets(
      'replacing the controller shows new state at once and rejects old lease',
      (tester) async {
        final a = testController();
        final b = testController();
        addTearDown(b.dispose);
        var current = a;
        late StateSetter setOuter;
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) {
              setOuter = setState;
              return MaterialApp(
                builder: (c, child) =>
                    NativeChrome(controller: current, child: child!),
                home: TabsPage(log: log),
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        final page = tester.state<TabsPageState>(find.byType(TabsPage));
        for (var i = 0; i < 10; i++) {
          page.setBadge('$i');
          await tester.pumpAndSettle();
        }
        final oldLease = host.currentLease;
        final oldTop = Map<Object?, Object?>.from(host.top!);
        final oldRevision = host.state['stateRevision']! as int;
        expect(oldRevision, greaterThan(5));

        setOuter(() => current = b);
        await tester.pumpAndSettle();
        expect(host.currentLease, b.lease);
        expect(host.currentLease, isNot(oldLease));
        expect(
          host.top?['title'],
          'HomeTop',
          reason: 'new state shown at once',
        );
        expect(host.state['stateRevision'] as int, lessThan(oldRevision));
        // Nothing of the new lease was dropped (only late updates of the
        // old controller, which the host must ignore).
        expect(host.droppedUpdateLeases, isNot(contains(b.lease)));
        // Same owner token/session numbers exist in the new connection, so
        // only the lease protects against the old bar's Save.
        expect(host.top?['ownerToken'], oldTop['ownerToken']);
        expect(host.top?['routeSession'], oldTop['routeSession']);
        await host.tapTop('save', stamp: oldTop, lease: oldLease);
        expect(log.events.where((e) => e.startsWith('save')), isEmpty);
        expect(b.diagnostics.rejected[NativeChromeRejection.leaseMismatch], 1);
        await host.tapTop('save');
        expect(log.events, contains('save:HomeTop'));

        // The old controller's late detach must not clear the new connection.
        a.dispose();
        await tester.pump();
        expect(host.currentLease, b.lease);
        expect(host.top?['title'], 'HomeTop');
      },
    );

    testWidgets(
      'removing NativeChrome clears native bars; stale detach ignored',
      (tester) async {
        var show = true;
        late StateSetter setOuter;
        Widget page() => const NativeChromeScaffold(
          topBar: NativeTopBar(title: 'Plain'),
          body: Center(child: Text('body')),
        );
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) {
              setOuter = setState;
              return MaterialApp(
                // NativeChrome owns its controller here (no controller
                // argument): removing the subtree must detach it.
                builder: (c, child) =>
                    show ? NativeChrome(child: child!) : child!,
                home: page(),
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        final firstLease = host.currentLease;
        expect(host.top?['title'], 'Plain');

        // Remove the NativeChrome subtree while the engine/host stay alive.
        setOuter(() => show = false);
        await tester.pumpAndSettle();
        expect(host.currentLease, isNull, reason: 'detach cleared the host');
        expect(host.nativeState, isNull);
        expect(find.byType(AppBar), findsOneWidget, reason: 'Flutter fallback');

        // New connection; a late detach of the first lease must be ignored.
        setOuter(() => show = true);
        await tester.pumpAndSettle();
        expect(host.currentLease, isNot(firstLease));
        expect(host.top?['title'], 'Plain');
        host.handleDetach(firstLease);
        expect(host.top?['title'], 'Plain');
      },
    );
  });

  group('request ids', () {
    testWidgets('same request id is handled once, a new id is accepted', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      final stamp = Map<Object?, Object?>.from(host.tab!);
      await host.tapTab('home', stamp: stamp, requestId: 5);
      await host.tapTab('home', stamp: stamp, requestId: 5);
      expect(log.count('reselect:home'), 1);
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.duplicateRequest],
        1,
      );
      await host.tapTab('home', stamp: stamp, requestId: 6);
      expect(log.count('reselect:home'), 2);
      final topStamp = Map<Object?, Object?>.from(host.top!);
      await host.tapTop('save', stamp: topStamp, requestId: 7);
      await host.tapTop('save', stamp: topStamp, requestId: 7);
      expect(log.count('save:HomeTop'), 1);
      await host.tapTop('save', stamp: topStamp, requestId: 8);
      expect(log.count('save:HomeTop'), 2);
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.duplicateRequest],
        2,
      );
    });
  });

  group('shared busy dispatcher', () {
    Future<void> tapFlutterSave(WidgetTester tester) async {
      await tester.tap(
        find.byKey(const ValueKey<String>('native_chrome.flutter.action.save')),
      );
      await tester.pump();
    }

    testWidgets('Flutter renderer: one Future action at a time', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          config: const NativeChromeConfig.allFlutter(),
          home: TopPage(title: 'A', log: log, slowSave: true),
        ),
      );
      await tester.pumpAndSettle();
      await tapFlutterSave(tester);
      await tapFlutterSave(tester);
      expect(log.count('save:A'), 1);
      expect(controller.diagnostics.rejected[NativeChromeRejection.busy], 1);
      await tester.pump(const Duration(seconds: 2));
      await tapFlutterSave(tester);
      expect(log.count('save:A'), 2);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('without NativeChrome the same busy rule applies', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TopPage(title: 'A', log: log, slowSave: true),
        ),
      );
      await tester.pumpAndSettle();
      await tapFlutterSave(tester);
      await tapFlutterSave(tester);
      expect(log.count('save:A'), 1);
      await tester.pump(const Duration(seconds: 2));
      await tapFlutterSave(tester);
      expect(log.count('save:A'), 2);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('busy survives a native → Flutter renderer switch', (
      tester,
    ) async {
      var config = const NativeChromeConfig();
      late StateSetter setOuter;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return testApp(
              controller: controller,
              config: config,
              home: TopPage(title: 'A', log: log, slowSave: true),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await host.tapTop('save'); // native, still running
      setOuter(() => config = const NativeChromeConfig.allFlutter());
      await tester.pump();
      await tester.pump();
      await tapFlutterSave(tester);
      expect(log.count('save:A'), 1, reason: 'busy shared across renderers');
      await tester.pump(const Duration(seconds: 2));
      await tapFlutterSave(tester);
      expect(log.count('save:A'), 2);
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('presentation contract', () {
    Widget hiddenPage() => const NativeChromeScaffold(
      topBar: NativeTopBar(
        title: 'Hidden',
        presentation: NativeTopBarPresentation.hidden,
      ),
      body: Align(alignment: Alignment.topLeft, child: Text('hidden body')),
    );

    for (final mode in <String>['native', 'flutter', 'noHost']) {
      testWidgets('hidden has no app bar slot ($mode)', (tester) async {
        if (mode == 'noHost') host.installed = false;
        await tester.pumpWidget(
          testApp(
            controller: controller,
            config: mode == 'flutter'
                ? const NativeChromeConfig.allFlutter()
                : const NativeChromeConfig(),
            home: hiddenPage(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsNothing);
        expect(
          find.byKey(const ValueKey<String>('native_chrome.placeholder')),
          findsNothing,
        );
        // Body starts at the top safe area, not below a bar.
        expect(tester.getTopLeft(find.text('hidden body')).dy, lessThan(60));
        if (mode == 'native') {
          expect(host.top?['presentation'], 'hidden');
        }
      });
    }

    testWidgets('transparent is drawn transparent by the Flutter renderer', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          config: const NativeChromeConfig.allFlutter(),
          home: const NativeChromeScaffold(
            topBar: NativeTopBar(
              title: 'Clear',
              presentation: NativeTopBarPresentation.transparent,
            ),
            body: SizedBox(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester.widget<AppBar>(find.byType(AppBar));
      expect(bar.backgroundColor, Colors.transparent);
      expect(bar.elevation, 0);
      expect(bar.surfaceTintColor, Colors.transparent);
      expect(bar.forceMaterialTransparency, isTrue);
    });

    testWidgets('custom builder receives presentation and shared invoke', (
      tester,
    ) async {
      NativeTopBarRenderContext? seen;
      await tester.pumpWidget(
        testApp(
          controller: controller,
          config: const NativeChromeConfig.allFlutter(),
          home: NativeChromeScaffold(
            topBar: NativeTopBar(
              title: 'Custom',
              presentation: NativeTopBarPresentation.transparent,
              actions: <NativeBarAction>[
                NativeBarAction(
                  id: 'save',
                  label: 'Save',
                  onPressed: () async {
                    log.add('save:custom');
                    await Future<void>.delayed(const Duration(seconds: 1));
                  },
                ),
              ],
            ),
            flutterTopBarBuilder: (context, bar) {
              seen = bar;
              return AppBar(title: Text(bar.title));
            },
            body: const SizedBox(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(seen!.presentation, NativeTopBarPresentation.transparent);
      expect(seen!.invoke(seen!.actions.first), isTrue);
      expect(seen!.invoke(seen!.actions.first), isFalse, reason: 'busy');
      expect(log.count('save:custom'), 1);
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('receiver ownership', () {
    Future<void> pumpWith(WidgetTester tester, NativeChromeController c) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              NativeChrome(controller: c, child: child!),
          home: TopPage(title: 'A', log: log),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final keepB in <bool>[true, false]) {
      testWidgets(
        'A → B → A reuse keeps native input (B ${keepB ? 'kept' : 'disposed'})',
        (tester) async {
          final a = controller;
          await pumpWith(tester, a);
          await host.tapTop('save');
          expect(log.count('save:A'), 1, reason: 'A receives');

          final b = testController();
          await pumpWith(tester, b);
          await host.tapTop('save');
          expect(log.count('save:A'), 2, reason: 'B receives after swap');

          await pumpWith(tester, a);
          if (!keepB) {
            b.dispose(); // late dispose must not remove A's receiver
            await tester.pump();
          }
          await host.tapTop('save');
          expect(log.count('save:A'), 3, reason: 'A receives again');
          expect(a.lease, host.currentLease);
          if (keepB) b.dispose();
        },
      );
    }

    testWidgets('creating an unused controller does not steal input', (
      tester,
    ) async {
      await pumpWith(tester, controller);
      final idle = testController(); // created, never attached
      addTearDown(idle.dispose);
      await host.tapTop('save');
      expect(log.count('save:A'), 1);
    });
  });

  group('connection recovery', () {
    testWidgets('lost host connection negotiates a new lease', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await host.tapTab('home');
      }
      expect(log.count('reselect:home'), 5);
      final oldLease = controller.lease;

      host.resetConnection(); // native lost the connection; Dart still alive
      await host.send('hostReady', <String, Object?>{'hostInstalled': true});
      await tester.pumpAndSettle();
      expect(controller.lease, isNot(oldLease), reason: 'new lease negotiated');
      expect(host.currentLease, controller.lease);
      expect(host.top?['title'], 'HomeTop', reason: 'state resent');

      await host.tapTab('home'); // first id of the new lease (1)
      expect(log.count('reselect:home'), 6, reason: 'accepted immediately');
      await host.tapTab('home', lease: oldLease, requestId: 99);
      expect(log.count('reselect:home'), 6);
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.leaseMismatch],
        1,
      );
    });

    testWidgets('hostReady with our lease keeps the counter running', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      await host.tapTab('home');
      await host.tapTab('home');
      final lease = controller.lease;
      // Activity overlay re-installed on the same engine: connection kept.
      await host.send('hostReady', <String, Object?>{
        'hostInstalled': true,
        'lease': lease,
      });
      await tester.pumpAndSettle();
      expect(controller.lease, lease, reason: 'no reset');
      await host.tapTab('home'); // id 3 continues
      expect(log.count('reselect:home'), 3);
      await host.tapTab('home', requestId: 2); // replay of an old id
      expect(log.count('reselect:home'), 3);
    });
  });

  group('protocol negotiation', () {
    Future<void> expectFlutterFallback(
      WidgetTester tester,
      String issue,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(title: 'A', log: log),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'no unhandled error');
      expect(controller.nativeAvailable, isFalse);
      expect(controller.diagnostics.hostIssue, contains(issue));
      expect(find.byType(AppBar), findsOneWidget, reason: 'Flutter bar');
      expect(host.updateCount, 0, reason: 'nothing sent to the host');
      await tester.tap(
        find.byKey(const ValueKey<String>('native_chrome.flutter.action.save')),
      );
      await tester.pump();
      expect(log.count('save:A'), 1, reason: 'Flutter button works');
    }

    testWidgets('protocol 1 reply → Flutter fallback', (tester) async {
      host.protocolReply = 1;
      await expectFlutterFallback(tester, 'protocol mismatch');
    });

    testWidgets('other lease echoed → Flutter fallback', (tester) async {
      host.echoOtherLease = true;
      await expectFlutterFallback(tester, 'not echoed');
    });

    testWidgets('attach bad-protocol exception → Flutter fallback', (
      tester,
    ) async {
      host.throwOnAttach = 'bad-protocol';
      await expectFlutterFallback(tester, 'bad-protocol');
    });

    testWidgets('update rejected by host → Flutter fallback, no async error', (
      tester,
    ) async {
      host.rejectUpdatesWith = 'bad-state';
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(title: 'A', log: log),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(controller.nativeAvailable, isFalse);
      expect(controller.diagnostics.hostIssue, contains('bad-state'));
      expect(find.byType(AppBar), findsOneWidget);
    });

    testWidgets('missing plugin → Flutter fallback', (tester) async {
      host.simulateMissingPlugin();
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(title: 'A', log: log),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(controller.diagnostics.hostIssue, contains('not registered'));
      expect(find.byType(AppBar), findsOneWidget);
    });

    testWidgets(
      'protocol 2 with lease echo → native, sent only after adoption',
      (tester) async {
        await tester.pumpWidget(
          testApp(
            controller: controller,
            home: TopPage(title: 'A', log: log),
          ),
        );
        // Before the attach reply is processed nothing has been sent.
        final firstUpdateIndex = host.calls.indexWhere(
          (c) => c.method == 'update',
        );
        final attachIndex = host.calls.indexWhere((c) => c.method == 'attach');
        await tester.pumpAndSettle();
        expect(controller.nativeAvailable, isTrue);
        expect(find.byType(AppBar), findsNothing);
        expect(host.top?['title'], 'A');
        final updateIndex = host.calls.indexWhere((c) => c.method == 'update');
        expect(attachIndex, 0);
        expect(
          firstUpdateIndex == -1 || firstUpdateIndex > attachIndex,
          isTrue,
        );
        expect(updateIndex, greaterThan(attachIndex));
      },
    );
  });

  group('failure after adoption (G1)', () {
    testWidgets(
      'rejected later update clears the adopted lease, falls back, recovers',
      (tester) async {
        await tester.pumpWidget(
          testApp(
            controller: controller,
            home: TabsPage(log: log),
          ),
        );
        await tester.pumpAndSettle();
        final firstLease = controller.lease!;
        expect(host.top?['title'], 'HomeTop', reason: 'first update shown');

        host.rejectUpdatesWith = 'bad-state'; // only later updates fail
        tester.state<TabsPageState>(find.byType(TabsPage)).setBadge('9');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(controller.nativeAvailable, isFalse);
        expect(controller.diagnostics.hostIssue, contains('bad-state'));
        expect(
          host.calls.where((c) => c.method == 'detach'),
          hasLength(1),
          reason: 'adopted lease detached',
        );
        expect(host.nativeState, isNull, reason: 'native bars cleared');
        expect(host.currentLease, isNull);
        expect(find.byType(AppBar), findsOneWidget, reason: 'Flutter bar');
        await tester.tap(
          find.byKey(
            const ValueKey<String>('native_chrome.flutter.action.save'),
          ),
        );
        await tester.pump();
        expect(log.count('save:HomeTop'), 1, reason: 'Flutter button works');

        // Explicit re-attach once the host accepts updates again.
        host.rejectUpdatesWith = null;
        await controller.attach();
        await tester.pumpAndSettle();
        expect(controller.nativeAvailable, isTrue);
        expect(host.currentLease, controller.lease);
        expect(host.top?['title'], 'HomeTop');
        expect(find.byType(AppBar), findsNothing);
        // A late detach of the failed lease does not clear the new connection.
        host.handleDetach(firstLease);
        expect(host.top?['title'], 'HomeTop');
      },
    );

    testWidgets('failure before adoption sends no detach', (tester) async {
      host.echoOtherLease = true;
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TopPage(title: 'A', log: log),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.nativeAvailable, isFalse);
      expect(host.calls.where((c) => c.method == 'detach'), isEmpty);
      await tester.pumpWidget(const SizedBox()); // NativeChrome released
      controller.dispose();
      controller = testController(); // tearDown disposes this one
      await tester.pump();
      expect(
        host.calls.where((c) => c.method == 'detach'),
        isEmpty,
        reason: 'dispose after a failed negotiation sends nothing',
      );
    });

    testWidgets('dispose after a later failure does not detach again', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: TabsPage(log: log),
        ),
      );
      await tester.pumpAndSettle();
      host.rejectUpdatesWith = 'bad-protocol';
      tester.state<TabsPageState>(find.byType(TabsPage)).setBadge('7');
      await tester.pumpAndSettle();
      expect(host.calls.where((c) => c.method == 'detach'), hasLength(1));
      await tester.pumpWidget(const SizedBox()); // NativeChrome released
      controller.dispose();
      controller = testController(); // tearDown disposes this one
      await tester.pump();
      expect(host.calls.where((c) => c.method == 'detach'), hasLength(1));
    });
  });

  group('top bar extensions', () {
    NativeChromeScaffold page({required bool saving}) => NativeChromeScaffold(
      topBar: NativeTopBar(
        title: 'August 2026',
        titleAlignment: NativeTopBarTitleAlignment.expandedLeading,
        titleAction: NativeBarAction(
          id: 'pickDate',
          label: 'Pick date',
          icon: NativeChromeIcons.back,
          onPressed: () => log.add('pickDate'),
        ),
        backgroundColor: const Color(0xFF112233),
        foregroundColor: const Color(0xFFEEEEEE),
        actions: <NativeBarAction>[
          NativeBarAction(
            id: 'save',
            label: 'Save',
            icon: NativeChromeIcons.save,
            loading: saving,
            onPressed: () => log.add('save'),
          ),
          NativeBarAction(
            id: 'done',
            label: 'Done',
            style: NativeBarActionStyle.done,
            onPressed: () => log.add('done'),
          ),
        ],
      ),
      body: const SizedBox(),
    );

    testWidgets('native wire carries colours, title action, loading, style', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(controller: controller, home: page(saving: true)),
      );
      await tester.pumpAndSettle();
      final top = host.top!;
      expect(top['titleAlignment'], 'expandedLeading');
      expect((top['titleAction'] as Map)['id'], 'pickDate');
      expect(top['background'], 0xFF112233);
      expect(top['foreground'], 0xFFEEEEEE);
      final actions = (top['actions'] as List).cast<Map<Object?, Object?>>();
      expect(actions.first['loading'], isTrue);
      expect(actions.first['enabled'], isFalse, reason: 'loading disables');
      expect(actions.last['style'], 'done');
      expect(actions.last['icon'], isNull);
      await host.tapTop('pickDate');
      expect(log.events, contains('pickDate'));
      await host.tapTop('save');
      expect(log.events, isNot(contains('save')));
      expect(
        controller.diagnostics.rejected[NativeChromeRejection.disabled],
        1,
      );
    });

    testWidgets('Flutter renderer draws the same extensions', (tester) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          config: const NativeChromeConfig.allFlutter(),
          home: page(saving: true),
        ),
      );
      // The progress indicator animates forever; pump frames instead of settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final bar = tester.widget<AppBar>(find.byType(AppBar));
      expect(bar.backgroundColor, const Color(0xFF112233));
      expect(bar.foregroundColor, const Color(0xFFEEEEEE));
      expect(bar.centerTitle, isFalse);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('native_chrome.flutter.action.pickDate'),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('native_chrome.flutter.action.done')),
      );
      expect(log.events, containsAll(<String>['pickDate', 'done']));
    });

    for (final alignment in NativeTopBarTitleAlignment.values) {
      testWidgets('Flutter title icon and loading (${alignment.name})', (
        tester,
      ) async {
        Widget titled({required bool loading}) => NativeChromeScaffold(
          topBar: NativeTopBar(
            title: 'Title',
            titleAlignment: alignment,
            titleAction: NativeBarAction(
              id: 't',
              label: 'Pick',
              icon: NativeChromeIcons.save,
              loading: loading,
              onPressed: () => log.add('t'),
            ),
          ),
          body: const SizedBox(),
        );
        await tester.pumpWidget(
          testApp(
            controller: controller,
            config: const NativeChromeConfig.allFlutter(),
            home: titled(loading: false),
          ),
        );
        await tester.pumpAndSettle();
        final icon = find.byKey(
          const ValueKey<String>('native_chrome.flutter.titleIcon'),
        );
        expect(icon, findsOneWidget);
        final iconX = tester.getCenter(icon).dx;
        final textX = tester.getCenter(find.text('Title')).dx;
        if (alignment == NativeTopBarTitleAlignment.platform) {
          expect(iconX, greaterThan(textX), reason: 'icon follows');
        } else {
          expect(iconX, lessThan(textX), reason: 'icon precedes');
        }
        await tester.pumpWidget(
          testApp(
            controller: controller,
            config: const NativeChromeConfig.allFlutter(),
            home: titled(loading: true),
          ),
        );
        await tester.pump();
        expect(
          find.byKey(
            const ValueKey<String>('native_chrome.flutter.titleLoading'),
          ),
          findsOneWidget,
        );
        expect(icon, findsNothing);
        await tester.tap(find.text('Title'));
        expect(log.events, isNot(contains('t')), reason: 'loading disables');
      });
    }

    testWidgets('pinFirstAction is opt-in and actions keep their order', (
      tester,
    ) async {
      NativeChromeScaffold bar({required bool pin}) => NativeChromeScaffold(
        topBar: NativeTopBar(
          title: 'T',
          pinFirstAction: pin,
          actions: <NativeBarAction>[
            for (final id in <String>['a', 'b', 'c'])
              NativeBarAction(
                id: id,
                label: id,
                icon: NativeChromeIcons.save,
                onPressed: () {},
              ),
          ],
        ),
        body: const SizedBox(),
      );
      await tester.pumpWidget(
        testApp(controller: controller, home: bar(pin: false)),
      );
      await tester.pumpAndSettle();
      expect(host.top!['pinFirstAction'], isFalse);
      expect(
        (host.top!['actions'] as List).map((a) => (a as Map)['id']).toList(),
        <String>['a', 'b', 'c'],
      );
      await tester.pumpWidget(
        testApp(controller: controller, home: bar(pin: true)),
      );
      await tester.pumpAndSettle();
      expect(host.top!['pinFirstAction'], isTrue);
    });

    testWidgets('occlusion geometry is parsed', (tester) async {
      host.geometry = <String, Object?>{
        'topInset': 20.0,
        'topBarHeight': 44.0,
        'tabBarHeight': 0.0,
        'hiddenActionSlot': <String, Object?>{
          'left': 340.0,
          'top': 60.0,
          'width': 48.0,
          'height': 48.0,
        },
        'occlusion': <String, Object?>{
          'supported': true,
          'regions': <Object?>[
            <String, Object?>{
              'left': 300.0,
              'top': 0.0,
              'width': 80.0,
              'height': 40.0,
            },
          ],
        },
      };
      await tester.pumpWidget(
        testApp(controller: controller, home: page(saving: false)),
      );
      await tester.pumpAndSettle();
      expect(controller.geometry.occlusionSupported, isTrue);
      expect(
        controller.geometry.hiddenActionSlot,
        const Rect.fromLTWH(340, 60, 48, 48),
      );
      expect(controller.geometry.occlusionRegions, <Rect>[
        const Rect.fromLTWH(300, 0, 80, 40),
      ]);
    });
  });

  group('NativeChromeAppBar in an app Scaffold', () {
    Widget appPage({
      NativeTopBarPresentation presentation = NativeTopBarPresentation.opaque,
      NativeChromeTopBarBuilder? flutterBuilder,
    }) => Scaffold(
      appBar: NativeChromeAppBar(
        flutterBuilder: flutterBuilder,
        bar: NativeTopBar(
          title: 'Own scaffold',
          presentation: presentation,
          automaticallyImplyBack: false,
          actions: <NativeBarAction>[
            NativeBarAction(
              id: 'save',
              label: 'Save',
              icon: NativeChromeIcons.save,
              onPressed: () async {
                log.add('save');
                await Future<void>.delayed(const Duration(seconds: 1));
              },
            ),
          ],
        ),
      ),
      body: const SizedBox.expand(key: ValueKey<String>('body')),
    );

    testWidgets('native: registers the owner and reserves the bar height', (
      tester,
    ) async {
      host.geometry = <String, Object?>{
        'topInset': 20.0,
        'topBarHeight': 44.0,
        'tabBarHeight': 0.0,
      };
      await tester.pumpWidget(testApp(controller: controller, home: appPage()));
      await tester.pumpAndSettle();
      expect(host.top!['title'], 'Own scaffold');
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<String>('body'))).dy,
        64,
      );
      await host.tapTop('save');
      await host.tapTop('save');
      expect(log.count('save'), 1, reason: 'busy rule applies');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('hidden: zero-height slot, bar hidden natively', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          home: appPage(presentation: NativeTopBarPresentation.hidden),
        ),
      );
      await tester.pumpAndSettle();
      expect(host.top!['presentation'], 'hidden');
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<String>('body'))).dy,
        0,
      );
    });

    testWidgets('Flutter renderer uses the app builder at its own height', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          controller: controller,
          config: const NativeChromeConfig.allFlutter(),
          home: appPage(
            flutterBuilder: (context, bar) => AppBar(
              key: const ValueKey<String>('app-bar'),
              title: Text(bar.title),
              actions: <Widget>[
                for (final a in bar.actions)
                  IconButton(
                    key: ValueKey<String>('app-${a.id}'),
                    onPressed: () => bar.invoke(a),
                    icon: Icon(a.icon!.icon),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('app-bar')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<String>('body'))).dy,
        kToolbarHeight,
      );
      await tester.tap(find.byKey(const ValueKey<String>('app-save')));
      await tester.tap(find.byKey(const ValueKey<String>('app-save')));
      expect(log.count('save'), 1, reason: 'shared busy rule');
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('tab accessibility value (optional wire field)', () {
    test('absent by default; sent only when set', () {
      const plain = NativeTabItem(
        id: 'cart',
        label: 'Cart',
        icon: NativeChromeIcons.home,
        badge: '99+',
      );
      expect(plain.toWire().containsKey('accessibilityValue'), isFalse);
      const counted = NativeTabItem(
        id: 'cart',
        label: 'Cart',
        icon: NativeChromeIcons.home,
        badge: '99+',
        accessibilityValue: '1000개',
      );
      expect(counted.toWire()['accessibilityValue'], '1000개');
      expect(counted.toWire()['badge'], '99+');
    });

    testWidgets('Flutter renderer exposes the value to semantics', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: NativeChrome(
            config: const NativeChromeConfig.allFlutter(),
            controller: testController(),
            child: NativeChromeScaffold(
              tabBar: NativeTabBar(
                selectedId: 'home',
                onSelect: (_) {},
                items: const [
                  NativeTabItem(
                    id: 'home',
                    label: 'Home',
                    icon: NativeChromeIcons.home,
                  ),
                  NativeTabItem(
                    id: 'cart',
                    label: 'Cart',
                    icon: NativeChromeIcons.home,
                    badge: '99+',
                    accessibilityValue: '1000개',
                  ),
                ],
              ),
              body: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('Cart')), findsWidgets);
      final node = tester.getSemantics(
        find
            .descendant(
              of: find.byKey(
                const ValueKey<String>('native_chrome.flutter.tab.cart'),
              ),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(node.getSemanticsData().value, contains('1000개'));
      handle.dispose();
    });
  });

  group('top action badge (optional wire field)', () {
    test('absent by default; sent only when set on an icon action', () {
      const plain = NativeBarAction(
        id: 'inbox',
        label: 'Inbox',
        icon: NativeChromeIcons.home,
      );
      expect(plain.toWire().containsKey('badge'), isFalse);
      const counted = NativeBarAction(
        id: 'inbox',
        label: 'Inbox, 3 unread',
        icon: NativeChromeIcons.home,
        badge: '3',
      );
      expect(counted.toWire()['badge'], '3');
      const text = NativeBarAction(
        id: 'inbox',
        label: 'Inbox',
        icon: NativeChromeIcons.home,
        style: NativeBarActionStyle.text,
        badge: '3',
      );
      expect(
        text.toWire().containsKey('badge'),
        isFalse,
        reason: 'badges belong to icon actions only',
      );
      expect(
        const NativeBarAction.back().toWire().containsKey('badge'),
        isFalse,
      );
    });

    testWidgets('Flutter renderer shows the badge on the icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: NativeChrome(
            config: const NativeChromeConfig.allFlutter(),
            controller: testController(),
            child: NativeChromeScaffold(
              topBar: NativeTopBar(
                title: 'Today',
                actions: [
                  NativeBarAction(
                    id: 'inbox',
                    label: 'Inbox, 3 unread',
                    icon: NativeChromeIcons.home,
                    badge: '3',
                    onPressed: () {},
                  ),
                ],
              ),
              body: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(
        const ValueKey<String>('native_chrome.flutter.action.inbox'),
      );
      expect(
        find.descendant(of: button, matching: find.byType(Badge)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: button, matching: find.text('3')),
        findsOneWidget,
      );
    });

    testWidgets('Flutter renderer: badge text is not read; title action is '
        'activatable by screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      var titleTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NativeChrome(
            config: const NativeChromeConfig.allFlutter(),
            controller: testController(),
            child: NativeChromeScaffold(
              topBar: NativeTopBar(
                title: 'Today',
                titleAction: NativeBarAction(
                  id: 'title',
                  label: 'Choose view, Month',
                  icon: NativeChromeIcons.more,
                  onPressed: () => titleTaps++,
                ),
                actions: [
                  NativeBarAction(
                    id: 'inbox',
                    label: 'Inbox, 3 unread',
                    icon: NativeChromeIcons.home,
                    badge: '3',
                    onPressed: () {},
                  ),
                ],
              ),
              body: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final inbox = tester
          .getSemantics(
            find.byKey(
              const ValueKey<String>('native_chrome.flutter.action.inbox'),
            ),
          )
          .getSemanticsData();
      expect(inbox.label, isNot(contains('3')), reason: 'badge is visual');
      expect(inbox.tooltip, 'Inbox, 3 unread');
      final title = find.bySemanticsLabel('Choose view, Month');
      final data = tester.getSemantics(title).getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      tester.semantics.tap(find.semantics.byLabel('Choose view, Month'));
      await tester.pump();
      expect(titleTaps, 1);
      handle.dispose();
    });
  });
}
