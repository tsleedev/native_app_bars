import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_app_bars/native_app_bars.dart';

const _size = Size(400, 800);
const _barBottom = 105.0;
const _tint = Color(0xB0FEF7FF);

Widget _page({double bottom = _barBottom + 60, Color? tint = _tint}) =>
    MediaQuery(
      data: const MediaQueryData(size: _size),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            const Positioned.fill(
              child: ColoredBox(key: Key('document'), color: Color(0xFF2040A0)),
            ),
            NativeChromeAndroidHeaderBackdrop(
              bar: const Rect.fromLTWH(0, 0, 400, _barBottom),
              bottom: bottom,
              tint: tint,
            ),
            const Positioned(
              left: 0,
              right: 0,
              top: _barBottom,
              child: SizedBox(key: Key('header-controls'), height: 60),
            ),
          ],
        ),
      ),
    );

void main() {
  testWidgets('one blur spans bar and header; tint repeats below the bar', (
    tester,
  ) async {
    await tester.pumpWidget(_page());
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      tester.getRect(find.byType(BackdropFilter)),
      const Rect.fromLTWH(0, 0, 400, _barBottom + 60),
    );
    expect(
      tester.getRect(find.byKey(NativeChromeAndroidHeaderBackdrop.tintKey)),
      const Rect.fromLTWH(0, _barBottom, 400, 60),
    );
    final tint = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byKey(NativeChromeAndroidHeaderBackdrop.tintKey),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(tint.color, _tint);
  });

  testWidgets('a bar-only header blurs the bar and adds no tint', (
    tester,
  ) async {
    await tester.pumpWidget(_page(bottom: _barBottom));
    expect(
      tester.getRect(find.byType(BackdropFilter)),
      const Rect.fromLTWH(0, 0, 400, _barBottom),
    );
    expect(
      tester.getSize(find.byKey(NativeChromeAndroidHeaderBackdrop.tintKey)),
      const Size(400, 0),
    );
  });

  testWidgets('without a host tint only the blur is painted', (tester) async {
    await tester.pumpWidget(_page(tint: null));
    expect(
      tester.getRect(find.byType(BackdropFilter)),
      const Rect.fromLTWH(0, 0, 400, _barBottom + 60),
    );
    expect(
      tester
          .getSize(find.byKey(NativeChromeAndroidHeaderBackdrop.tintKey))
          .height,
      0,
    );
  });

  testWidgets('paint only: no pointer input and no semantics', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: _size),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                ),
              ),
              const NativeChromeAndroidHeaderBackdrop(
                bar: Rect.fromLTWH(0, 0, 400, _barBottom),
                bottom: _barBottom + 60,
                tint: _tint,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tapAt(const Offset(200, _barBottom + 30));
    expect(taps, 1);
    expect(
      find.descendant(
        of: find.byType(NativeChromeAndroidHeaderBackdrop),
        matching: find.byType(ExcludeSemantics),
      ),
      findsOneWidget,
    );
    handle.dispose();
  });
}
