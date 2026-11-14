import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_app_bars/native_app_bars.dart';

import 'support/fake_host.dart';

/// turning
/// `syncTransitions` off (for example when Reduce Motion is switched on) ends
/// a running native top bar transition at once, and no new one starts.
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

  Widget page(String title, {Widget? next}) => Builder(
    builder: (context) => NativeChromeScaffold(
      topBar: NativeTopBar(title: title),
      body: next == null
          ? const SizedBox.expand()
          : TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => next)),
              child: Text('open $title'),
            ),
    ),
  );

  testWidgets('disabling syncTransitions ends the running transition', (
    tester,
  ) async {
    var config = const NativeChromeConfig();
    late StateSetter update;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return MaterialApp(
            builder: (context, child) => NativeChrome(
              controller: controller,
              config: config,
              child: child!,
            ),
            home: page('A', next: page('B', next: page('C'))),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.transitionActive, isTrue);
    expect(host.transitions.first['phase'], 'begin');

    final before = host.transitions.length;
    update(() => config = const NativeChromeConfig(syncTransitions: false));
    await tester.pump();
    expect(controller.transitionActive, isFalse);
    await tester.pumpAndSettle();
    final after = host.transitions.skip(before).toList();
    expect(after.map((t) => t['phase']), <String>[
      'end',
    ], reason: 'one end message, then no update');
    final sent = host.transitions.length;
    expect(host.top?['title'], 'B');

    // No new transition while sync is off.
    await tester.tap(find.text('open B'));
    await tester.pumpAndSettle();
    expect(host.top?['title'], 'C');
    expect(host.transitions.length, sent);
  });
}
