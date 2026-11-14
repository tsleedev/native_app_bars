import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:native_app_bars/native_app_bars.dart';

void main() => runApp(const ChromeExample());

class ChromeExample extends StatelessWidget {
  const ChromeExample({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorObservers: [NativeChromeNavigatorObserver()],
    builder: (context, child) => NativeChrome(
      appearance: const NativeChromeAppearance(
        backgroundColor: Color(0xFFE0F2F1),
        foregroundColor: Color(0xFF004D40),
        unselectedColor: Color(0xFF455A64),
        indicatorColor: Color(0xFF80CBC4),
      ),
      child: child!,
    ),
    home: const _Tabs(),
  );
}

class _Tabs extends StatefulWidget {
  const _Tabs();

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  String _selected = 'Library';

  @override
  Widget build(BuildContext context) {
    final chrome = NativeChrome.of(context);
    final geometry = chrome.geometry;
    final renderer = chrome.rendererFor(ChromeBarKind.tab);
    final placement = geometry.tabRailWidth > 0 ? 'rail' : 'bottom';

    return NativeChromeScaffold(
      topBar: NativeTopBar(title: _selected),
      tabBar: NativeTabBar(
        selectedId: _selected,
        onSelect: (label) => setState(() => _selected = label),
        largeScreenRail: true,
        items: const [
          NativeTabItem(
            id: 'Library',
            label: 'Library',
            icon: NativeChromeIcon(Icons.book_outlined, iosSymbol: 'book'),
            selectedIcon: NativeChromeIcon(Icons.book, iosSymbol: 'book.fill'),
          ),
          NativeTabItem(
            id: 'Browse',
            label: 'Browse',
            icon: NativeChromeIcons.search,
            badge: '3',
          ),
          NativeTabItem(
            id: 'Saved',
            label: 'Saved',
            icon: NativeChromeIcon(
              Icons.bookmark_outline,
              iosSymbol: 'bookmark',
            ),
          ),
          NativeTabItem(
            id: 'Settings',
            label: 'Settings',
            icon: NativeChromeIcons.settings,
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Selected: $_selected'),
            Text('Tab renderer: ${renderer.name}, $placement'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(
                context,
              ).push(CupertinoPageRoute<void>(builder: (_) => const _Detail())),
              child: const Text('Open detail'),
            ),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(title: Text('Example popup')),
              ),
              child: const Text('Open popup'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail();

  @override
  Widget build(BuildContext context) => const NativeChromeScaffold(
    topBar: NativeTopBar(title: 'Detail'),
    body: Center(child: Text('Detail page')),
  );
}
