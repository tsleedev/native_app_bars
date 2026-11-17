import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_app_bars/native_app_bars.dart';

void main() {
  testWidgets(
    'a retained header observes its ancestor visibility through a local scope',
    (tester) async {
      final ancestor = ValueNotifier(true);
      addTearDown(ancestor.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ValueListenableBuilder<bool>(
            valueListenable: ancestor,
            child: NativeChromeVisibility(
              visible: true,
              child: Builder(
                builder: (context) => Text(
                  NativeChromeVisibility.of(context) ? 'shown' : 'hidden',
                ),
              ),
            ),
            builder: (_, visible, child) =>
                NativeChromeVisibility(visible: visible, child: child!),
          ),
        ),
      );
      expect(find.text('shown'), findsOneWidget);

      ancestor.value = false;
      await tester.pump();
      expect(find.text('hidden'), findsOneWidget);

      ancestor.value = true;
      await tester.pump();
      expect(find.text('shown'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );
}
