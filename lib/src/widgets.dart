import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeature;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'config.dart';
import 'controller.dart';
import 'descriptors.dart';
import 'transport.dart';

/// Root of the package. Place it inside `MaterialApp.builder` (so the theme
/// and directionality are available) or above your app.
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [NativeChromeNavigatorObserver()],
///   builder: (context, child) => NativeChrome(child: child!),
/// )
/// ```
class NativeChrome extends StatefulWidget {
  const NativeChrome({
    super.key,
    this.config = const NativeChromeConfig(),
    this.appearance,
    this.controller,
    this.popupOpacity,
    this.iosPopupForegrounds = const [],
    required this.child,
  });

  final NativeChromeConfig config;

  /// Colour overrides for native bars; defaults derive from the theme.
  final NativeChromeAppearance? appearance;

  /// Optional externally owned controller (tests, custom transports).
  final NativeChromeController? controller;

  /// Optional app-resolved black popup opacity. Null keeps automatic popup
  /// dimming. Zero is a transparent modal; input/AX suspension is independent.
  /// Finite values clamp to 0..1; non-finite values use the null default.
  final double? popupOpacity;

  /// Opaque Flutter popup surfaces in the root viewport's logical coordinates.
  /// While suspended, the shared iOS host excludes these areas from native
  /// bar paint, including moving bars. Hit testing and layout stay unchanged.
  final List<RRect> iosPopupForegrounds;
  final Widget child;

  /// The controller of the nearest [NativeChrome]; rebuilds the caller when
  /// geometry, host availability or configuration change.
  static NativeChromeController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'No NativeChrome found in context');
    return controller!;
  }

  static NativeChromeController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_NativeChromeScope>()
      ?.notifier;

  /// Lookup without creating a dependency.
  static NativeChromeController? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_NativeChromeScope>()?.notifier;

  @override
  State<NativeChrome> createState() => _NativeChromeState();
}

class _NativeChromeState extends State<NativeChrome> {
  late NativeChromeController _controller;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    _adopt();
  }

  void _adopt() {
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? NativeChromeController();
    _controller.config = widget.config;
    _controller.popupOpacity = widget.popupOpacity;
    unawaited(_controller.attach());
  }

  @override
  void didUpdateWidget(NativeChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _releaseController();
      _adopt();
    }
    _controller.config = widget.config;
    _controller.popupOpacity = widget.popupOpacity;
  }

  /// Owned controllers are disposed; external ones are only detached so their
  /// bars disappear with this widget and their owner may attach them again.
  void _releaseController() {
    _controller.popupOpacity = null;
    _controller.updateIOSPopupForegrounds(const [], Size.zero);
    if (_ownsController) {
      _controller.dispose();
    } else {
      _controller.detach();
    }
  }

  @override
  void dispose() {
    _releaseController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _controller.updateIOSPopupForegrounds(
        widget.iosPopupForegrounds,
        MediaQuery.maybeSizeOf(context) ?? Size.zero,
      );
    }
    _controller.updateEnvironment(
      appearance: NativeChromeAppearance.resolve(
        widget.appearance,
        theme,
        defaultTargetPlatform,
      ),
      rtl: Directionality.maybeOf(context) == TextDirection.rtl,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    return _NativeChromeScope(
      controller: _controller,
      child: _RailRootInset(
        controller: _controller,
        background: widget.appearance?.backgroundColor,
        child: widget.child,
      ),
    );
  }
}

/// While the Android side rail is shown, the whole Flutter app below
/// [NativeChrome] (every MaterialApp, root navigator, pages, dialogs, sheets,
/// menus and snack bars) starts beside the rail, like the previous Android
/// host whose Flutter view began at the rail's edge. The rail width is removed
/// from [MediaQueryData.size], the start safe area it covers from padding,
/// view padding and gesture insets, and OS display features (hinges) are
/// translated into the inset area. The strip behind the native rail is painted
/// with the shared bar background. Always the same widget structure, so a
/// rail change never remounts the app.
class _RailRootInset extends StatelessWidget {
  const _RailRootInset({
    required this.controller,
    required this.background,
    required this.child,
  });

  final NativeChromeController controller;
  final Color? background;
  final Widget child;

  static MediaQueryData inset(MediaQueryData media, double width, bool rtl) {
    final size = Size(math.max(0, media.size.width - width), media.size.height);
    EdgeInsets cut(EdgeInsets e) => rtl
        ? e.copyWith(right: math.max(0, e.right - width))
        : e.copyWith(left: math.max(0, e.left - width));
    final area = Offset.zero & size;
    final features = <DisplayFeature>[];
    for (final feature in media.displayFeatures) {
      final moved = rtl
          ? feature.bounds
          : feature.bounds.shift(Offset(-width, 0));
      if (moved.right <= 0 || moved.left >= size.width) continue;
      final clipped = Rect.fromLTRB(
        math.max(0, moved.left),
        math.max(0, moved.top),
        math.min(size.width, moved.right),
        math.min(size.height, moved.bottom),
      );
      features.add(
        DisplayFeature(
          bounds: clipped.intersect(area),
          type: feature.type,
          state: feature.state,
        ),
      );
    }
    return media.copyWith(
      size: size,
      padding: cut(media.padding),
      viewPadding: cut(media.viewPadding),
      viewInsets: cut(media.viewInsets),
      systemGestureInsets: cut(media.systemGestureInsets),
      displayFeatures: features,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media == null) return child;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) {
        final geometry = controller.geometry;
        final width =
            controller.rendererFor(ChromeBarKind.tab) ==
                    ChromeRenderer.native &&
                geometry.tabBarVisible
            ? geometry.tabRailWidth
            : 0.0;
        final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
        return ColoredBox(
          color: background ?? const Color(0x00000000),
          child: Stack(
            textDirection: TextDirection.ltr,
            children: <Widget>[
              Positioned.fill(
                child: MediaQuery(
                  data: width > 0 ? inset(media, width, rtl) : media,
                  child: Padding(
                    padding: rtl
                        ? EdgeInsets.only(right: width)
                        : EdgeInsets.only(left: width),
                    child: child,
                  ),
                ),
              ),
              // The rail strip is outside the inset app, so a popup's
              // barrier does not cover it. While a popup suspends the bars the
              // native rail passes touches to Flutter; a tap here then acts
              // on the top popup like its barrier (see dismissPopupFromChrome).
              Positioned(
                top: 0,
                bottom: 0,
                left: rtl ? null : 0,
                right: rtl ? 0 : null,
                width: width,
                // Takes part in hit testing only while a dismissible popup is
                // on top (checked at the tap), and never in the semantics tree.
                child: ExcludeSemantics(
                  child: _HitTestWhen(
                    active: () => width > 0 && controller.dismissiblePopupOpen,
                    child: GestureDetector(
                      key: const ValueKey<String>('native_chrome.railStrip'),
                      behavior: HitTestBehavior.opaque,
                      excludeFromSemantics: true,
                      onTap: controller.dismissPopupFromChrome,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      child: child,
    );
  }
}

/// Hit-testable only while [active] returns true at the time of the hit test;
/// otherwise touches pass through to whatever lies below.
class _HitTestWhen extends SingleChildRenderObjectWidget {
  const _HitTestWhen({required this.active, super.child});

  final bool Function() active;

  @override
  _RenderHitTestWhen createRenderObject(BuildContext context) =>
      _RenderHitTestWhen(active);

  @override
  void updateRenderObject(BuildContext context, _RenderHitTestWhen render) {
    render.active = active;
  }
}

class _RenderHitTestWhen extends RenderProxyBox {
  _RenderHitTestWhen(this.active);

  bool Function() active;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      active() && super.hitTest(result, position: position);
}

class _NativeChromeScope extends InheritedNotifier<NativeChromeController> {
  const _NativeChromeScope({
    required NativeChromeController controller,
    required super.child,
  }) : super(notifier: controller);
}

/// Marks a subtree as visible or hidden for bar ownership. Hidden subtrees
/// (inactive tabs) never own the displayed bars.
class NativeChromeVisibility extends InheritedWidget {
  const NativeChromeVisibility({
    super.key,
    required this.visible,
    required super.child,
  });

  final bool visible;

  static bool of(BuildContext context) {
    final observeAncestors =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    var visible = true;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is! NativeChromeVisibility) return true;
      // A retained route can have its own unchanged visibility scope inside
      // an enclosing scope that closes, e.g. when its parent is covered.
      if (observeAncestors && element is InheritedElement) {
        context.dependOnInheritedElement(element);
      }
      visible = visible && widget.visible;
      return observeAncestors || visible;
    });
    if (!observeAncestors) {
      context.dependOnInheritedWidgetOfExactType<NativeChromeVisibility>();
    }
    return visible;
  }

  @override
  bool updateShouldNotify(NativeChromeVisibility oldWidget) =>
      visible != oldWidget.visible;
}

/// An [IndexedStack] for tab contents that keeps each tab's state while only
/// the selected tab owns bars, tickers, focus and semantics.
class NativeChromeTabStack extends StatelessWidget {
  const NativeChromeTabStack({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => IndexedStack(
    index: index,
    children: <Widget>[
      for (var i = 0; i < children.length; i++)
        NativeChromeVisibility(
          visible: i == index,
          child: TickerMode(
            enabled: i == index,
            child: ExcludeFocus(
              excluding: i != index,
              child: ExcludeSemantics(
                excluding: i != index,
                child: children[i],
              ),
            ),
          ),
        ),
    ],
  );
}

/// Suspends native bar input while [active] (for app overlays such as ads or
/// custom modal layers that are not Flutter popup routes).
class NativeChromeSuspension extends StatefulWidget {
  const NativeChromeSuspension({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  State<NativeChromeSuspension> createState() => _NativeChromeSuspensionState();
}

class _NativeChromeSuspensionState extends State<NativeChromeSuspension> {
  final Object _token = Object();
  NativeChromeController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = NativeChrome.read(context);
    if (!identical(next, _controller)) {
      _controller?.setSuspended(_token, false);
      _controller = next;
    }
    _controller?.setSuspended(_token, widget.active);
  }

  @override
  void didUpdateWidget(NativeChromeSuspension oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller?.setSuspended(_token, widget.active);
  }

  @override
  void dispose() {
    _controller?.setSuspended(_token, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Tracks routes of a navigator so the package can keep bars presented under
/// dialogs, suspend native input while popups are open, and follow page
/// transitions (including the iOS back swipe).
///
/// Add one instance to every navigator whose routes own bars (the root
/// navigator at least, plus nested tab navigators).
class NativeChromeNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];

  NativeChromeController? get _controller {
    final nav = navigator;
    if (nav == null || !nav.mounted) return null;
    return NativeChrome.read(nav.context);
  }

  void _publish() {
    final nav = navigator;
    if (nav == null) return;
    _controller?.observeStack(nav, List<Route<dynamic>>.of(_routes));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _publish();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _publish();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _publish();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) {
      _routes[index] = newRoute;
    } else {
      if (oldRoute != null) _routes.remove(oldRoute);
      if (newRoute != null) _routes.add(newRoute);
    }
    _publish();
  }

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    _controller?.observeUserGesture(route, previousRoute);
  }

  @override
  void didStopUserGesture() {
    _controller?.observeUserGesture(null, null);
  }
}

/// Builds the Flutter top bar when the Flutter renderer is used.
typedef NativeChromeTopBarBuilder =
    PreferredSizeWidget Function(
      BuildContext context,
      NativeTopBarRenderContext bar,
    );

/// What a custom Flutter top bar builder needs to honour the package
/// contract.
///
/// * Run actions through [invoke], never `action.onPressed` directly, so the
///   busy rule is shared with the native renderer (a Future-returning action
///   blocks further actions of the same page until it completes, also across
///   a native ↔ Flutter renderer switch).
/// * [presentation] is never `hidden` here (hidden pages get no app bar slot
///   with any renderer). For `transparent`, draw no background, elevation or
///   surface tint.
@immutable
class NativeTopBarRenderContext {
  const NativeTopBarRenderContext({
    required this.bar,
    required this.leading,
    required this.busy,
    required this.invoke,
  });

  final NativeTopBar bar;

  /// The leading action, including the implied back action.
  final NativeBarAction? leading;
  final bool busy;
  final bool Function(NativeBarAction action) invoke;

  List<NativeBarAction> get actions => bar.actions;
  NativeTopBarPresentation get presentation => bar.presentation;
  String get title => bar.title;
}

/// Builds the Flutter tab bar when the Flutter renderer is used.
typedef NativeChromeTabBarBuilder =
    Widget Function(BuildContext context, NativeTabBar bar);

/// A [Scaffold] whose top bar and tab bar are rendered natively or by Flutter
/// according to [NativeChromeConfig], from one description.
///
/// Typical structure: a shell scaffold with only [tabBar] and a
/// [NativeChromeTabStack] body, and page scaffolds with only [topBar].
class NativeChromeScaffold extends StatefulWidget {
  const NativeChromeScaffold({
    super.key,
    this.topBar,
    this.tabBar,
    required this.body,
    this.flutterTopBarBuilder,
    this.flutterTabBarBuilder,
    this.backgroundColor,
    this.floatingActionButton,
    this.resizeToAvoidBottomInset,
    this.extendBodyBehindTopBar = false,
  });

  final NativeTopBar? topBar;
  final NativeTabBar? tabBar;
  final Widget body;
  final NativeChromeTopBarBuilder? flutterTopBarBuilder;
  final NativeChromeTabBarBuilder? flutterTabBarBuilder;
  final Color? backgroundColor;
  final Widget? floatingActionButton;
  final bool? resizeToAvoidBottomInset;
  final bool extendBodyBehindTopBar;

  /// Estimated heights used until the native host reports measurements.
  static double estimatedTopBarHeight(TargetPlatform platform) =>
      platform == TargetPlatform.iOS ? 44 : 64;
  static double estimatedTabBarHeight(TargetPlatform platform) =>
      platform == TargetPlatform.iOS ? 49 : 80;

  @override
  State<NativeChromeScaffold> createState() => _NativeChromeScaffoldState();
}

class _NativeChromeScaffoldState extends State<NativeChromeScaffold> {
  NativeChromeController? _controller;
  ChromeOwner? _topOwner;
  ChromeOwner? _tabOwner;

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    final c = _controller;
    if (c != null) {
      if (_topOwner != null) c.removeOwner(_topOwner!);
      if (_tabOwner != null) c.removeOwner(_tabOwner!);
    }
    _topOwner = null;
    _tabOwner = null;
  }

  @override
  Widget build(BuildContext context) {
    final controller = NativeChrome.maybeOf(context);
    if (!identical(controller, _controller)) {
      _release();
      _controller = controller;
    }
    final platform = defaultTargetPlatform;
    final media = MediaQuery.of(context);
    final config = controller?.config ?? const NativeChromeConfig();
    final keyboardUp = media.viewInsets.bottom > 0;
    final tabHidden = keyboardUp && config.hideTabBarWhenKeyboardVisible;

    final topNative =
        widget.topBar != null &&
        controller?.rendererFor(ChromeBarKind.top) == ChromeRenderer.native;
    final tabNative =
        widget.tabBar != null &&
        controller?.rendererFor(ChromeBarKind.tab) == ChromeRenderer.native;

    final chain = _routeChainOf(context);
    final visible = NativeChromeVisibility.of(context);
    final navigator = Navigator.maybeOf(context);
    final route = chain.isEmpty ? null : chain.first;
    final canPop =
        route?.impliesAppBarDismissal ?? (navigator?.canPop() ?? false);
    VoidCallback? impliedBack;
    if (canPop && navigator != null) {
      impliedBack = () => unawaited(navigator.maybePop());
    }
    final backLabel = MaterialLocalizations.of(context).backButtonTooltip;

    if (controller != null) {
      if (widget.topBar != null) {
        _topOwner ??= controller.createOwner(ChromeBarKind.top);
        controller.updateTopOwner(
          _topOwner!,
          bar: widget.topBar!,
          routeChain: chain,
          visible: visible,
          native: topNative,
          impliedBack: impliedBack,
          backLabel: backLabel,
        );
      } else if (_topOwner != null) {
        controller.removeOwner(_topOwner!);
        _topOwner = null;
      }
      if (widget.tabBar != null) {
        _tabOwner ??= controller.createOwner(ChromeBarKind.tab);
        controller.updateTabOwner(
          _tabOwner!,
          bar: widget.tabBar!,
          routeChain: chain,
          visible: visible,
          native: tabNative,
          hidden: tabHidden,
        );
      } else if (_tabOwner != null) {
        controller.removeOwner(_tabOwner!);
        _tabOwner = null;
      }
    }

    final geometry = controller?.geometry ?? const NativeChromeGeometry();
    PreferredSizeWidget? appBar;
    final top = widget.topBar;
    // Hidden pages get no app bar slot with any renderer (native, Flutter or
    // host-less fallback); the native host hides its bar from the same flag.
    if (top != null && top.presentation != NativeTopBarPresentation.hidden) {
      if (topNative) {
        final barHeight = geometry.measured
            ? geometry.topBarHeight
            : NativeChromeScaffold.estimatedTopBarHeight(platform);
        final statusInset = geometry.measured
            ? geometry.topInset
            : media.padding.top;
        // Scaffold adds padding.top to the app bar slot itself.
        final slot = math.max(0.0, statusInset + barHeight - media.padding.top);
        appBar = PreferredSize(
          preferredSize: Size.fromHeight(slot),
          child: const _NativeBarPlaceholder(),
        );
      } else {
        final implied = top.leading == null && top.automaticallyImplyBack
            ? (impliedBack == null
                  ? null
                  : NativeBarAction(
                      id: 'back',
                      label: backLabel,
                      icon: NativeChromeIcons.back,
                      onPressed: impliedBack,
                    ))
            : null;
        final renderContext = NativeTopBarRenderContext(
          bar: top,
          leading: top.leading ?? implied,
          busy: _topOwner?.busy ?? _localBusy,
          invoke: _invoke,
        );
        appBar = _withTopOpacity(
          widget.flutterTopBarBuilder?.call(context, renderContext) ??
              _defaultAppBar(context, renderContext),
          top.effectiveOpacity,
        );
      }
    }

    Widget? bottom;
    final tab = widget.tabBar;
    if (tab != null && !tabHidden) {
      if (tabNative) {
        // Android large screens with an opted-in side rail: no bottom slot.
        // NativeChrome insets the whole app beside the rail (_RailRootInset).
        if (geometry.tabRailWidth <= 0) {
          final height = geometry.measured
              ? geometry.tabBarHeight
              : NativeChromeScaffold.estimatedTabBarHeight(platform) +
                    media.padding.bottom;
          bottom = SizedBox(
            height: height,
            child: const _NativeBarPlaceholder(),
          );
        }
      } else {
        bottom =
            widget.flutterTabBarBuilder?.call(context, tab) ??
            _defaultTabBar(tab);
      }
    }

    return Scaffold(
      appBar: appBar,
      bottomNavigationBar: bottom,
      body: widget.body,
      backgroundColor: widget.backgroundColor,
      floatingActionButton: widget.floatingActionButton,
      resizeToAvoidBottomInset: widget.resizeToAvoidBottomInset,
      extendBodyBehindAppBar: widget.extendBodyBehindTopBar,
    );
  }

  bool _localBusy = false;

  /// Shared action dispatcher for the Flutter renderer. With a controller the
  /// owner's busy flag is shared with native input; without one (no
  /// NativeChrome above) a scaffold-local busy flag applies the same rule.
  bool _invoke(NativeBarAction action) {
    final controller = _controller;
    final owner = _topOwner;
    if (controller != null && owner != null) {
      return controller.runFlutterAction(owner, action);
    }
    if (!action.isEnabled || _localBusy) return false;
    final result = action.onPressed!.call();
    if (result is Future) {
      setState(() => _localBusy = true);
      result.whenComplete(() {
        if (mounted) setState(() => _localBusy = false);
      }).ignore();
    }
    return true;
  }

  Widget _defaultTabBar(NativeTabBar bar) {
    final index = math.max(
      0,
      bar.items.indexWhere((i) => i.id == bar.selectedId),
    );
    Widget icon(NativeTabItem item, NativeChromeIcon glyph) {
      Widget child = Icon(glyph.icon);
      if (item.badge != null) {
        child = Badge(
          isLabelVisible: true,
          label: item.badge!.isEmpty ? null : Text(item.badge!),
          child: child,
        );
      }
      final value = item.accessibilityValue;
      if (value == null) return child;
      return Semantics(
        value: value,
        child: ExcludeSemantics(child: child),
      );
    }

    return NavigationBar(
      key: const ValueKey<String>('native_chrome.flutter.tabBar'),
      // Every label always shown, like the native tab bars.
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      selectedIndex: index,
      onDestinationSelected: (i) {
        final item = bar.items[i];
        if (!item.enabled) return;
        if (item.id == bar.selectedId) {
          bar.onReselect?.call(item.id);
        } else {
          bar.onSelect(item.id);
        }
      },
      destinations: <Widget>[
        for (final item in bar.items)
          NavigationDestination(
            key: ValueKey<String>('native_chrome.flutter.tab.${item.id}'),
            enabled: item.enabled,
            label: item.label,
            icon: icon(item, item.icon),
            selectedIcon: icon(item, item.selectedIcon ?? item.icon),
          ),
      ],
    );
  }
}

/// A top bar for an app's own [Scaffold], as `Scaffold(appBar: ...)`.
///
/// Use it when a page already has a [Scaffold] with options that
/// [NativeChromeScaffold] does not forward (bottom sheets, drawers, custom
/// body behaviour). It registers the page's top bar like
/// [NativeChromeScaffold.topBar] and lays out:
///
/// * native renderer: an empty slot as tall as the native bar (plus the
///   status bar inset);
/// * Flutter renderer: [flutterBuilder] (or the default Material `AppBar`),
///   at that widget's own preferred height;
/// * `hidden`: a zero-height slot. A [Scaffold] still removes the top padding
///   from its body when it has an app bar, so a hidden page lays out under the
///   status bar exactly as with a zero-height app bar.
///
/// [preferredSize] is an upper bound ([maxExtent]); [Scaffold] places the body
/// below the height this widget actually lays out.
class NativeChromeAppBar extends StatefulWidget implements PreferredSizeWidget {
  const NativeChromeAppBar({super.key, required this.bar, this.flutterBuilder});

  final NativeTopBar bar;
  final NativeChromeTopBarBuilder? flutterBuilder;

  /// Upper bound of the bar height below the status bar.
  static const double maxExtent = 120;

  @override
  Size get preferredSize => const Size.fromHeight(maxExtent);

  @override
  State<NativeChromeAppBar> createState() => _NativeChromeAppBarState();
}

class _NativeChromeAppBarState extends State<NativeChromeAppBar> {
  NativeChromeController? _controller;
  ChromeOwner? _owner;
  bool _localBusy = false;

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    final owner = _owner;
    if (owner != null) _controller?.removeOwner(owner);
    _owner = null;
  }

  bool _invoke(NativeBarAction action) {
    final controller = _controller;
    final owner = _owner;
    if (controller != null && owner != null) {
      return controller.runFlutterAction(owner, action);
    }
    if (!action.isEnabled || _localBusy) return false;
    final result = action.onPressed!.call();
    if (result is Future) {
      setState(() => _localBusy = true);
      result.whenComplete(() {
        if (mounted) setState(() => _localBusy = false);
      }).ignore();
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final controller = NativeChrome.maybeOf(context);
    if (!identical(controller, _controller)) {
      _release();
      _controller = controller;
    }
    final top = widget.bar;
    final media = MediaQuery.of(context);
    final native =
        controller?.rendererFor(ChromeBarKind.top) == ChromeRenderer.native;
    final chain = _routeChainOf(context);
    final navigator = Navigator.maybeOf(context);
    final route = chain.isEmpty ? null : chain.first;
    final canPop =
        route?.impliesAppBarDismissal ?? (navigator?.canPop() ?? false);
    VoidCallback? impliedBack;
    if (canPop && navigator != null) {
      impliedBack = () => unawaited(navigator.maybePop());
    }
    final backLabel = MaterialLocalizations.of(context).backButtonTooltip;
    if (controller != null) {
      _owner ??= controller.createOwner(ChromeBarKind.top);
      controller.updateTopOwner(
        _owner!,
        bar: top,
        routeChain: chain,
        visible: NativeChromeVisibility.of(context),
        native: native,
        impliedBack: impliedBack,
        backLabel: backLabel,
      );
    }

    if (top.presentation == NativeTopBarPresentation.hidden) {
      return const SizedBox(
        height: 0,
        key: ValueKey<String>('native_chrome.hiddenSlot'),
      );
    }
    if (native) {
      final geometry = controller!.geometry;
      final height = geometry.measured
          ? geometry.topInset + geometry.topBarHeight
          : media.padding.top +
                NativeChromeScaffold.estimatedTopBarHeight(
                  defaultTargetPlatform,
                );
      return SizedBox(
        height: math.max(height, media.padding.top),
        child: const _NativeBarPlaceholder(),
      );
    }
    final implied = top.leading == null && top.automaticallyImplyBack
        ? (impliedBack == null
              ? null
              : NativeBarAction(
                  id: 'back',
                  label: backLabel,
                  icon: NativeChromeIcons.back,
                  onPressed: impliedBack,
                ))
        : null;
    final renderContext = NativeTopBarRenderContext(
      bar: top,
      leading: top.leading ?? implied,
      busy: _owner?.busy ?? _localBusy,
      invoke: _invoke,
    );
    final appBar =
        widget.flutterBuilder?.call(context, renderContext) ??
        _defaultAppBar(context, renderContext);
    // A Material AppBar fills the height it is given; keep it at its own
    // preferred height because this widget reports only an upper bound.
    return SizedBox(
      height:
          AppBar.preferredHeightFor(context, appBar.preferredSize) +
          media.padding.top,
      child: _withTopOpacity(appBar, top.effectiveOpacity),
    );
  }
}

PreferredSizeWidget _withTopOpacity(PreferredSizeWidget bar, double opacity) =>
    opacity == 1
    ? bar
    : PreferredSize(
        preferredSize: bar.preferredSize,
        child: Opacity(
          opacity: opacity,
          alwaysIncludeSemantics: true,
          child: bar,
        ),
      );

/// The page's route followed by the routes of its enclosing navigators.
List<ModalRoute<dynamic>> _routeChainOf(BuildContext context) {
  final chain = <ModalRoute<dynamic>>[];
  var route = ModalRoute.of(context);
  while (route != null && chain.length < 8) {
    chain.add(route);
    final nav = route.navigator;
    if (nav == null || !nav.mounted) break;
    route = ModalRoute.of(nav.context);
  }
  return chain;
}

/// The default Material top bar drawn from a description (Flutter renderer).
PreferredSizeWidget _defaultAppBar(
  BuildContext context,
  NativeTopBarRenderContext bar,
) {
  final leading = bar.leading;
  final top = bar.bar;
  Widget button(NativeBarAction action) {
    final key = ValueKey<String>('native_chrome.flutter.action.${action.id}');
    if (action.loading) {
      return Padding(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Semantics(
          label: action.label,
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: top.foregroundColor,
            ),
          ),
        ),
      );
    }
    final onPressed = action.isEnabled ? () => bar.invoke(action) : null;
    if (action.icon == null || action.style != NativeBarActionStyle.icon) {
      return TextButton(
        key: key,
        onPressed: onPressed,
        style: top.foregroundColor == null
            ? null
            : TextButton.styleFrom(foregroundColor: top.foregroundColor),
        child: Text(
          action.label,
          style: action.style == NativeBarActionStyle.done
              ? const TextStyle(fontWeight: FontWeight.w600)
              : null,
        ),
      );
    }
    final badge = action.badge;
    return IconButton(
      key: key,
      tooltip: action.label,
      onPressed: onPressed,
      icon: badge == null
          ? Icon(action.icon!.icon)
          : Badge(
              // Visual only: the action label carries the meaning (and count).
              label: badge.isEmpty
                  ? null
                  : ExcludeSemantics(child: Text(badge)),
              child: Icon(action.icon!.icon),
            ),
    );
  }

  final expanded =
      top.titleAlignment == NativeTopBarTitleAlignment.expandedLeading;
  Widget title = Text(
    bar.title,
    style: expanded ? Theme.of(context).textTheme.titleLarge : null,
  );
  final titleAction = top.titleAction;
  if (titleAction != null) {
    // Same affordance as the native bars: the icon (or a spinner while
    // loading) follows a centred title and precedes a start-aligned one.
    Widget? adornment;
    if (titleAction.loading) {
      adornment = SizedBox.square(
        key: const ValueKey<String>('native_chrome.flutter.titleLoading'),
        dimension: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: top.foregroundColor,
        ),
      );
    } else if (titleAction.icon != null) {
      adornment = Icon(
        titleAction.icon!.icon,
        key: const ValueKey<String>('native_chrome.flutter.titleIcon'),
        size: 20,
      );
    }
    if (adornment != null) {
      final after = top.titleAlignment == NativeTopBarTitleAlignment.platform;
      title = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (!after) ...<Widget>[adornment, const SizedBox(width: 6)],
          Flexible(child: title),
          if (after) ...<Widget>[const SizedBox(width: 6), adornment],
        ],
      );
    }
    title = Semantics(
      button: true,
      label: titleAction.label,
      enabled: titleAction.isEnabled,
      // excludeSemantics drops the InkWell's own tap action, so the title
      // button exposes it here for screen readers.
      onTap: titleAction.isEnabled ? () => bar.invoke(titleAction) : null,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey<String>('native_chrome.flutter.action.${titleAction.id}'),
        onTap: titleAction.isEnabled ? () => bar.invoke(titleAction) : null,
        child: title,
      ),
    );
  }

  final transparent = bar.presentation == NativeTopBarPresentation.transparent;
  return AppBar(
    key: const ValueKey<String>('native_chrome.flutter.topBar'),
    automaticallyImplyLeading: false,
    title: title,
    centerTitle: top.titleAlignment == NativeTopBarTitleAlignment.platform
        ? null
        : false,
    leading: leading == null ? null : button(leading),
    actions: <Widget>[for (final a in bar.actions) button(a)],
    foregroundColor: top.foregroundColor,
    backgroundColor: transparent ? Colors.transparent : top.backgroundColor,
    surfaceTintColor: transparent ? Colors.transparent : null,
    shadowColor: transparent ? Colors.transparent : null,
    elevation: transparent ? 0 : null,
    scrolledUnderElevation: transparent ? 0 : null,
    forceMaterialTransparency: transparent,
  );
}

class _NativeBarPlaceholder extends StatelessWidget {
  const _NativeBarPlaceholder();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey<String>('native_chrome.placeholder'));
}
