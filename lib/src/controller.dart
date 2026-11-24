import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoRouteTransitionMixin;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'descriptors.dart';
import 'transport.dart';

/// Kind of bar an owner contributes.
enum ChromeBarKind { top, tab }

/// A widget that contributes a bar description. Created and updated by
/// `NativeChromeScaffold`; exposed for tests and advanced integrations.
class ChromeOwner {
  ChromeOwner._(this.token, this.kind, this.order);

  /// Unique per registration; never reused.
  final int token;
  final ChromeBarKind kind;

  /// Registration order, used to break ties between equally deep owners.
  final int order;

  /// Incremented every time this owner becomes the displayed owner. Native
  /// events carry the session they were produced in; events from an earlier
  /// activation are rejected.
  int session = 0;

  /// Incremented only when the wire content actually changes.
  int semanticRevision = 0;

  NativeChromeIOSAvatar? _iosAvatar;
  int _iosAvatarVersion = 0;
  String? _contentJson;
  Map<String, Object?>? _content;

  NativeTopBar? topBar;
  NativeTabBar? tabBar;
  NativeBarAction? _impliedBack;

  /// Routes from the nearest to the outermost navigator.
  List<ModalRoute<dynamic>> routeChain = const <ModalRoute<dynamic>>[];
  bool visible = true;
  bool native = false;
  bool busy = false;
  bool disposed = false;

  int get depth => routeChain.length;
  ModalRoute<dynamic>? get route =>
      routeChain.isEmpty ? null : routeChain.first;
  Map<String, Object?>? get content => _content;

  NativeBarAction? _findAction(String id) {
    final bar = topBar;
    if (bar == null) return null;
    final leading = bar.leading ?? _impliedBack;
    if (leading?.id == id) return leading;
    if (bar.titleAction?.id == id) return bar.titleAction;
    if (bar.titleAccessory?.id == id) return bar.titleAccessory;
    for (final action in bar.actions) {
      if (action.id == id) return action;
    }
    return null;
  }

  @override
  String toString() =>
      'ChromeOwner(${kind.name}#$token s$session r$semanticRevision)';
}

/// Outcome of trying to start a bar transition for a top owner switch.
enum _Begin { started, none, deferred }

class _TransitionDriver {
  _TransitionDriver(
    this.id,
    this.direction,
    this.animation,
    this.reversed, {
    required this.style,
    required this.route,
    required this.lease,
    this.navigator,
  }) : _curved = style == _slideStyle
           ? CurvedAnimation(
               parent: animation,
               curve: Curves.fastEaseInToSlowEaseOut,
               reverseCurve: Curves.fastEaseInToSlowEaseOut.flipped,
             )
           : null;
  final int id;
  final String direction;
  final Animation<double> animation;
  final bool reversed;

  /// `slide` (iOS Cupertino page) or `fade` (any other page transition).
  final String style;

  /// Navigator of the moving route; its user gesture keeps progress linear.
  final NavigatorState? navigator;

  /// The route whose animation drives this transition;
  /// its removal or disposal ends this transition (same driver and lease).
  final PageRoute<dynamic> route;
  final String? lease;

  // The same curve CupertinoPageTransition applies to
  // the page, created with the same status so its direction matches.
  final CurvedAnimation? _curved;
  VoidCallback? listener;
  AnimationStatusListener? statusListener;
  double lastSent = -1;

  double get progress {
    // CupertinoPageTransition is linear while `popGestureInProgress`
    // (`navigator.userGestureInProgress`), including the settle after the
    // finger lifts; otherwise the page follows the curve.
    final gesture = navigator?.userGestureInProgress ?? false;
    final value = _curved == null || gesture ? animation.value : _curved.value;
    return (reversed ? 1 - value : value).clamp(0.0, 1.0);
  }

  void dispose() => _curved?.dispose();
}

const String _slideStyle = 'slide';
const String _fadeStyle = 'fade';

/// Whether [route] slides like an iOS Cupertino page (the curve and
/// direction the native bar mirrors). Decided by the route's transition
/// mixin and, for Material routes, the theme builder of its platform.
bool _isCupertinoSlide(Route<dynamic> route) {
  if (route is! PageRoute || route.fullscreenDialog) return false;
  if (route is CupertinoRouteTransitionMixin) return true;
  if (route is! MaterialRouteTransitionMixin) return false;
  final context = route.subtreeContext ?? route.navigator?.context;
  if (context == null || !context.mounted) return false;
  // Read without registering a dependency (flush runs after a frame).
  final theme = context.findAncestorWidgetOfExactType<Theme>()?.data;
  final platform = theme?.platform ?? defaultTargetPlatform;
  final transitions =
      theme?.pageTransitionsTheme ?? const PageTransitionsTheme();
  return transitions.builders[platform] is CupertinoPageTransitionsBuilder;
}

// Presentation only: canonical owners/sessions remain selected by _pick.
class _BottomRoutePresentation {
  _BottomRoutePresentation(this.root, this.cover, this.lease);
  final PageRoute<dynamic> root;
  final PageRoute<dynamic> cover;
  final String lease;
  late VoidCallback listener;
  bool started = false;

  /// the cover has produced a measurable painted frame.
  bool coverPainted = false;

  /// this presentation began with the cover's own push
  /// (not a pop, a removal or a back gesture).
  bool fromPush = false;
}

/// Coordinates bar owners, the native host and incoming native events.
///
/// Rules:
/// * Dart owns selection and routing. Native controls only request.
/// * A native event is accepted only if its owner token and session match the
///   currently displayed owner and the id is enabled in the current
///   description, and the bar is not suspended, transitioning or busy.
/// * Rebuilds never change sessions or revisions unless content changes, so
///   ordinary rebuilds cannot invalidate input.
class NativeChromeController extends ChangeNotifier
    with WidgetsBindingObserver {
  NativeChromeController({
    NativeChromeTransport? transport,
    NativeChromeIconRasterizer? rasterizer,
    NativeChromeDiagnostics? diagnostics,
  }) : _transport = transport ?? MethodChannelNativeChromeTransport(),
       _rasterizer = rasterizer ?? const GlyphNativeChromeIconRasterizer(),
       diagnostics = diagnostics ?? NativeChromeDiagnostics() {
    _transport.onMessage = _onMessage;
    _transport.onError = _onTransportError;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _lifecycleActive =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  final NativeChromeTransport _transport;
  final NativeChromeIconRasterizer _rasterizer;
  final NativeChromeDiagnostics diagnostics;

  NativeChromeConfig _config = const NativeChromeConfig();
  NativeChromeConfig get config => _config;
  set config(NativeChromeConfig value) {
    if (value == _config) return;
    final stopSync = _config.syncTransitions && !value.syncTransitions;
    _config = value;
    // Turning transition sync off (for example Reduce
    // Motion) ends a running native transition at once instead of letting it
    // run to the end. Other config changes keep their behaviour.
    if (stopSync) {
      _endTransition();
      _clearBottomPresentation();
    }
    _markDirty();
    _notifySoon();
  }

  double? _popupOpacity;

  /// Single root authority for resolved black popup paint; never suspends input.
  double? get popupOpacity => _popupOpacity;
  set popupOpacity(double? value) {
    final normalized = value != null && value.isFinite
        ? value.clamp(0.0, 1.0)
        : null;
    if (normalized == _popupOpacity) return;
    _popupOpacity = normalized;
    _markDirty();
  }

  List<RRect> _iosPopupForegrounds = const [];
  Size _iosPopupViewport = Size.zero;

  void updateIOSPopupForegrounds(List<RRect> surfaces, Size viewport) {
    final next = surfaces
        .where((surface) => surface.isFinite && !surface.isEmpty)
        .take(16)
        .map((surface) => surface.scaleRadii())
        .toList(growable: false);
    if (viewport == _iosPopupViewport &&
        listEquals(next, _iosPopupForegrounds)) {
      return;
    }
    _iosPopupForegrounds = next;
    _iosPopupViewport = viewport;
    _markDirty();
  }

  Map<String, Object?> _appearance = const <String, Object?>{};
  bool _rtl = false;
  double _devicePixelRatio = 1;

  /// Updated by the `NativeChrome` widget from the ambient theme.
  void updateEnvironment({
    required Map<String, Object?> appearance,
    required bool rtl,
    required double devicePixelRatio,
  }) {
    if (!mapEquals(appearance, _appearance) || rtl != _rtl) {
      _appearance = appearance;
      _rtl = rtl;
      _markDirty();
    }
    _devicePixelRatio = devicePixelRatio;
  }

  bool? _hostInstalled;
  int? _hostGeneration;

  /// Whether a native host exists. Null until the host answered.
  bool? get hostInstalled => _hostInstalled;

  /// Lease the host confirmed (protocol and lease echo checked).
  String? _adoptedLease;
  bool _attachInFlight = false;
  String? _negotiationError;

  NativeChromeGeometry _geometry = const NativeChromeGeometry();
  NativeChromeGeometry get geometry => _geometry;

  bool get _platformSupportsNative =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// Whether the host confirmed the current connection. Only then are state
  /// updates, transitions and icons sent, and native events accepted.
  bool get nativeAvailable =>
      _platformSupportsNative &&
      !_disposed &&
      _hostInstalled == true &&
      _lease != null &&
      _adoptedLease == _lease;

  /// While the first attach is in flight, layout keeps the native renderer
  /// (nothing is sent yet) so a working host does not flash Flutter bars at
  /// launch. Any negotiation failure switches to the Flutter renderer.
  bool get _nativeExpected =>
      nativeAvailable ||
      (_platformSupportsNative &&
          !_disposed &&
          _attachInFlight &&
          _hostInstalled != false &&
          _negotiationError == null);

  /// Effective renderer for [kind] on the current platform.
  ChromeRenderer rendererFor(ChromeBarKind kind) {
    final platformConfig = _config.forPlatform(defaultTargetPlatform);
    final wanted = kind == ChromeBarKind.top
        ? platformConfig.topBar
        : platformConfig.tabBar;
    if (wanted == ChromeRenderer.native && _nativeExpected) {
      return ChromeRenderer.native;
    }
    return ChromeRenderer.flutter;
  }

  // ---------------------------------------------------------------- owners

  int _nextToken = 1;
  int _nextOrder = 0;
  final List<ChromeOwner> _owners = <ChromeOwner>[];
  ChromeOwner? _activeTop;
  ChromeOwner? _activeTab;

  ChromeOwner? get activeTopOwner => _activeTop;
  ChromeOwner? get activeTabOwner => _activeTab;

  ChromeOwner createOwner(ChromeBarKind kind) {
    final owner = ChromeOwner._(_nextToken++, kind, _nextOrder++);
    _owners.add(owner);
    _markDirty();
    return owner;
  }

  void removeOwner(ChromeOwner owner) {
    owner.disposed = true;
    _owners.remove(owner);
    _markDirty();
  }

  /// Updates a top bar owner. Safe to call during build.
  void updateTopOwner(
    ChromeOwner owner, {
    required NativeTopBar bar,
    required List<ModalRoute<dynamic>> routeChain,
    required bool visible,
    required bool native,
    required VoidCallback? impliedBack,
    required String backLabel,
  }) {
    owner
      ..topBar = bar
      ..routeChain = routeChain
      ..visible = visible
      ..native = native;
    owner._impliedBack =
        bar.leading == null && bar.automaticallyImplyBack && impliedBack != null
        ? NativeBarAction(
            id: 'back',
            label: backLabel,
            icon: NativeChromeIcons.back,
            onPressed: impliedBack,
          )
        : null;
    final leading = bar.leading ?? owner._impliedBack;
    for (final action in [
      ?leading,
      ?bar.titleAction,
      ?bar.titleAccessory,
      ...bar.actions,
    ]) {
      if (action.icon != null) rememberIcon(action.icon!);
    }
    final ios = defaultTargetPlatform == TargetPlatform.iOS && native;
    final avatar =
        ios &&
            leading?.style == NativeBarActionStyle.icon &&
            leading?.iosSystemItem == null
        ? leading?.iosAvatar
        : null;
    if (!identical(avatar, owner._iosAvatar)) {
      owner._iosAvatar = avatar;
      owner._iosAvatarVersion++;
    }
    Map<String, Object?>? actionWire(NativeBarAction? action) {
      if (action == null) return null;
      final wire = action.toWire();
      if (ios && action.style == NativeBarActionStyle.icon) {
        final systemItem = action.iosSystemItem;
        if (systemItem != null && !action.loading) {
          wire['iosSystemItem'] = systemItem.name;
        }
        final badgeValue = action.iosBadgeAccessibilityValue;
        if (action.badge != null &&
            badgeValue != null &&
            badgeValue.isNotEmpty) {
          wire['iosBadgeAccessibilityValue'] = badgeValue;
        }
      }
      return wire;
    }

    final leadingWire = actionWire(leading);
    if (avatar != null)
      leadingWire!['iosAvatarVersion'] = owner._iosAvatarVersion;
    _setContent(owner, <String, Object?>{
      'title': bar.title,
      'presentation': bar.presentation.name,
      'titleAlignment': bar.titleAlignment.name,
      if (bar.iosLeadingTitleAccessory case final String accessory when ios)
        'iosLeadingTitleAccessory': accessory,
      if (bar.iosSubtitle case final String subtitle when ios)
        'iosSubtitle': subtitle,
      'pinFirstAction': bar.pinFirstAction,
      if (bar.effectiveOpacity != 1) 'opacity': bar.effectiveOpacity,
      'titleAction': bar.titleAction?.toWire(),
      // Opt-in: omitted when unset so existing bars keep the same wire.
      if (bar.titleAccessory case final NativeBarAction accessory)
        'titleAccessory': accessory.toWire(),
      'background': bar.backgroundColor?.toARGB32(),
      'foreground': bar.foregroundColor?.toARGB32(),
      'leading': leadingWire,
      'actions': <Object?>[for (final a in bar.actions) actionWire(a)],
    });
  }

  /// Updates a tab bar owner. Safe to call during build.
  void updateTabOwner(
    ChromeOwner owner, {
    required NativeTabBar bar,
    required List<ModalRoute<dynamic>> routeChain,
    required bool visible,
    required bool native,
    required bool hidden,
  }) {
    owner
      ..tabBar = bar
      ..routeChain = routeChain
      ..visible = visible
      ..native = native;
    for (final item in bar.items) {
      rememberIcon(item.icon);
      if (item.selectedIcon != null) rememberIcon(item.selectedIcon!);
    }
    _setContent(owner, <String, Object?>{
      'items': <Object?>[for (final item in bar.items) item.toWire()],
      'selectedId': bar.selectedId,
      'hidden': hidden,
      if (bar.largeScreenRail) 'rail': true,
    });
  }

  void _setContent(ChromeOwner owner, Map<String, Object?> content) {
    final json = jsonEncode(content);
    if (json != owner._contentJson) {
      owner._contentJson = json;
      owner._content = content;
      owner.semanticRevision++;
    }
    _markDirty();
  }

  // ------------------------------------------------- navigator observation

  final Map<NavigatorState, List<Route<dynamic>>> _stacks =
      <NavigatorState, List<Route<dynamic>>>{};
  Route<dynamic>? _gestureRoute;
  Route<dynamic>? _gesturePrevious;
  final Set<Object> _suspensionTokens = <Object>{};

  /// Called by `NativeChromeNavigatorObserver`.
  void observeStack(NavigatorState navigator, List<Route<dynamic>> routes) {
    final previous = _stacks[navigator] ?? const <Route<dynamic>>[];
    _stacks[navigator] = routes;
    var prefix = 0;
    while (prefix < previous.length &&
        prefix < routes.length &&
        identical(previous[prefix], routes[prefix])) {
      prefix++;
    }
    // Count changes of existing stacks until the next
    // flush. The first stack of a new navigator is not a move.
    final changed =
        previous.isNotEmpty &&
        (prefix < previous.length || routes.length != previous.length);
    if (changed) _stackMovesSinceFlush++;
    if (prefix == previous.length &&
        routes.length == previous.length + 1 &&
        previous.isNotEmpty) {
      _movedRoute = routes.last;
      _beginBottomPresentation(routes.last, previous.last, push: true);
    } else if (prefix == routes.length &&
        previous.length == routes.length + 1 &&
        routes.isNotEmpty) {
      _movedRoute = previous.last;
      _beginBottomPresentation(previous.last, routes.last);
    } else if (changed) {
      // A replace or a multi-route change names no single moving route.
      _movedRoute = null;
    }
    // Several moves before one flush (popUntil, pops in nested and outer
    // navigators): the moving route cannot be determined, so a switch with a
    // bar-less side must not borrow one of their animations.
    if (_stackMovesSinceFlush > 1) _movedRoute = null;
    final singlePop =
        prefix == routes.length &&
        previous.length == routes.length + 1 &&
        routes.isNotEmpty;
    if (previous.isNotEmpty && prefix < previous.length && !singlePop) {
      // Keep an unaffected adjacent pair; otherwise replace/remove is not
      // this horizontal pop and its old geometry/gesture cannot be reused.
      final d = _bottomPresentation;
      final rootIndex = d == null ? -1 : routes.indexOf(d.root);
      if (d != null &&
          (rootIndex < 0 ||
              rootIndex + 1 >= routes.length ||
              !identical(routes[rootIndex + 1], d.cover))) {
        _clearBottomPresentation();
        if (_gestureRoute != null && !routes.contains(_gestureRoute)) {
          _gestureRoute = null;
          _gesturePrevious = null;
        }
      }
    }
    _stackChanged = true;
    _markDirty();
  }

  /// A navigator stack changed since the last flush (push, pop, replace).
  bool _stackChanged = false;

  /// The route of the latest single push or pop. When
  /// one side of a top bar switch has no native bar, its route chain cannot
  /// name the moving route, so this one is used if it is animating. Cleared
  /// when a replace or several moves before a flush leave the
  /// moving route undetermined.
  Route<dynamic>? _movedRoute;

  /// Existing-stack changes since the last flush.
  int _stackMovesSinceFlush = 0;

  /// The top owner switch waits one frame for its route animation to start
  /// (see [flush]); the previous bar stays shown and top input is rejected.
  bool _switchDeferred = false;
  bool _deferralUsed = false;

  void forgetNavigator(NavigatorState navigator) {
    _stacks.remove(navigator);
    if (identical(_bottomPresentation?.root.navigator, navigator)) {
      _clearBottomPresentation();
    }
    _markDirty();
  }

  void observeUserGesture(Route<dynamic>? route, Route<dynamic>? previous) {
    _gestureRoute = route;
    _gesturePrevious = previous;
    if (route != null && previous != null) {
      _beginBottomPresentation(route, previous);
    }
    _markDirty();
  }

  /// Suspends native input while [token] is registered.
  void setSuspended(Object token, bool suspended) {
    final changed = suspended
        ? _suspensionTokens.add(token)
        : _suspensionTokens.remove(token);
    if (changed) _markDirty();
  }

  /// A tap outside the app's inset area (on the Android side rail, whose
  /// touches reach Flutter while a popup suspends the bars) acts like a tap on
  /// the popup's barrier: a dismissible popup closes, a non-dismissible one
  /// stays. Never selects a tab. Returns whether a popup was asked to close.
  bool dismissPopupFromChrome() {
    if (!dismissiblePopupOpen) return false;
    unawaited(_topPopup()!.navigator!.maybePop());
    return true;
  }

  /// Whether the top observed popup is current and closes on a barrier tap.
  bool get dismissiblePopupOpen {
    final route = _topPopup();
    return route != null &&
        route.navigator != null &&
        route.isCurrent &&
        route.barrierDismissible;
  }

  ModalRoute<dynamic>? _topPopup() {
    for (final stack in _stacks.values) {
      for (final route in stack.reversed) {
        if (route is PopupRoute && route.isActive && !_coveredByPage(route)) {
          return route;
        }
      }
    }
    return null;
  }

  // A popup covered by a page does
  // not suspend input. A page pushed over a sheet (for example a document
  // opened from a sign-in sheet) owns the bars and must take input. Covered
  // means an active, non-leaving, non-popup route above the popup in its
  // navigator, or above the route hosting that navigator (nested navigators,
  // resolved from the owners' route chains).
  bool _coveredByPage(Route<dynamic> route) {
    Route<dynamic>? current = route;
    for (var depth = 0; current != null && depth < 8; depth++) {
      final navigator = current.navigator;
      if (navigator == null) return false;
      final stack = _stacks[navigator];
      final index = stack?.indexOf(current) ?? -1;
      if (index >= 0) {
        for (final above in stack!.skip(index + 1)) {
          if (above is! PopupRoute && above.isActive && !_leaving(above)) {
            return true;
          }
        }
      }
      current = _enclosingRoute(navigator);
    }
    return false;
  }

  Route<dynamic>? _enclosingRoute(NavigatorState navigator) {
    for (final owner in _owners) {
      final chain = owner.routeChain;
      for (var i = 0; i + 1 < chain.length; i++) {
        if (identical(chain[i].navigator, navigator)) return chain[i + 1];
      }
    }
    return null;
  }

  static bool _leaving(Route<dynamic> route) {
    final status = route is TransitionRoute ? route.animation?.status : null;
    return status == AnimationStatus.reverse ||
        status == AnimationStatus.dismissed;
  }

  bool get isSuspended => _suspensionTokens.isNotEmpty || _topPopup() != null;

  bool _onlyPopupsAbove(ModalRoute<dynamic> route) {
    for (final stack in _stacks.values) {
      final index = stack.indexOf(route);
      if (index < 0) continue;
      for (final above in stack.skip(index + 1)) {
        if (above is! PopupRoute) return false;
      }
      return true;
    }
    return false;
  }

  bool _presented(ChromeOwner owner, {ModalRoute<dynamic>? coveredRoot}) {
    if (owner.disposed || !owner.visible) return false;
    for (var i = 0; i < owner.routeChain.length; i++) {
      final route = owner.routeChain[i];
      if (!route.isActive) return false;
      if (identical(route, coveredRoot)) continue;
      if (identical(route, _gestureRoute)) return false;
      if (route.isCurrent) continue;
      if (identical(route, _gesturePrevious)) continue;
      if (_onlyPopupsAbove(route)) continue;
      return false;
    }
    return true;
  }

  static bool _moving(Animation<double>? a) =>
      a != null &&
      (a.status == AnimationStatus.forward ||
          a.status == AnimationStatus.reverse);

  bool _transitioning(ChromeOwner owner) {
    if (_transition != null || _switchDeferred) return true;
    for (final route in owner.routeChain) {
      if (_moving(route.animation) || _moving(route.secondaryAnimation)) {
        return true;
      }
    }
    return false;
  }

  ChromeOwner? _pick(ChromeBarKind kind, {ModalRoute<dynamic>? coveredRoot}) {
    ChromeOwner? best;
    for (final owner in _owners) {
      if (owner.kind != kind ||
          (coveredRoot != null && !identical(owner.route, coveredRoot)) ||
          !_presented(owner, coveredRoot: coveredRoot)) {
        continue;
      }
      if (best == null ||
          owner.depth > best.depth ||
          (owner.depth == best.depth && owner.order > best.order)) {
        best = owner;
      }
    }
    return best;
  }

  // ---------------------------------------------------------------- flush

  /// Connection lease of the current attach; scopes revisions, transitions
  /// and native request ids. Null before the first attach.
  String? _lease;
  String? get lease => _lease;
  int _lastRequestId = 0;
  static final math.Random _random = math.Random();

  static String _newLease() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${_random.nextInt(1 << 32).toRadixString(36)}';

  bool _dirty = false;
  bool _flushScheduled = false;
  bool _disposed = false;
  String? _lastStateJson;
  int _stateRevision = 0;
  bool _forceResend = false;
  final Set<String> _iconsSent = <String>{};
  final Set<String> _iconsPending = <String>{};

  void _markDirty() {
    _dirty = true;
    if (_flushScheduled || _disposed) return;
    _flushScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      if (_dirty) flush();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  bool _notifyScheduled = false;
  void _notifySoon() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  /// Recomputes displayed owners and sends the state when it changed.
  /// Normally called after a frame; public for tests.
  @visibleForTesting
  void flush() {
    if (_disposed) return;
    _dirty = false;
    final previousTop = _activeTop;
    var top = _pick(ChromeBarKind.top);
    var tab = _pick(ChromeBarKind.tab);
    final stackChanged = _stackChanged;
    _stackChanged = false;
    _stackMovesSinceFlush = 0;
    _switchDeferred = false;
    if (!identical(previousTop, top)) {
      final begin = _maybeBeginTransition(
        previousTop,
        top,
        mayDefer: stackChanged && !_deferralUsed,
      );
      if (begin == _Begin.deferred) {
        // A route was pushed or popped but its animation has not started yet
        // (an owner in a nested navigator becomes displayed in the build of
        // its enclosing route). Keep showing the outgoing bar for this frame
        // and decide next frame, so `transition begin` (which snapshots the
        // outgoing bar natively) is still sent before the new state.
        top = previousTop;
        // The tab bar of the outgoing page stays too, so
        // the host still has it when `transition begin` arrives (a fade route
        // fades it with the page instead of dropping it a frame early).
        tab = _activeTab;
        _switchDeferred = true;
        _deferralUsed = true;
        // Flush runs after a frame; this decides after the next one.
        _markDirty();
      } else {
        _deferralUsed = false;
      }
    } else {
      _deferralUsed = false;
    }
    if (!identical(top, _activeTop)) top?.session++;
    if (!identical(tab, _activeTab)) tab?.session++;
    _activeTop = top;
    _activeTab = tab;

    final popupSuspended = isSuspended;
    final suspended = popupSuspended || !_lifecycleActive;
    final popup = _topPopup();
    final resolvedOpacity = _popupOpacity;
    final dimColor = resolvedOpacity == null
        ? popup?.barrierColor
        : Colors.black.withValues(alpha: resolvedOpacity);
    final state = <String, Object?>{
      'protocol': nativeChromeProtocolVersion,
      'lease': _lease,
      'top': top != null && top.native && top.content != null
          ? <String, Object?>{
              ...top.content!,
              'ownerToken': top.token,
              'routeSession': top.session,
              'semanticRevision': top.semanticRevision,
            }
          : null,
      'tab': tab != null && tab.native && tab.content != null
          ? <String, Object?>{
              ...tab.content!,
              'ownerToken': tab.token,
              'routeSession': tab.session,
              'semanticRevision': tab.semanticRevision,
            }
          : null,
      'bottomTransition': ?_bottomPresentationWire(),
      'suspended': suspended,
      if (popupSuspended &&
          !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.iOS &&
          _iosPopupViewport.isFinite &&
          !_iosPopupViewport.isEmpty &&
          _iosPopupForegrounds.isNotEmpty)
        'iosPopupForegrounds': {
          'width': _iosPopupViewport.width,
          'height': _iosPopupViewport.height,
          'surfaces': [
            for (final surface in _iosPopupForegrounds)
              [
                surface.left,
                surface.top,
                surface.width,
                surface.height,
                surface.tlRadiusX,
                surface.tlRadiusY,
                surface.trRadiusX,
                surface.trRadiusY,
                surface.brRadiusX,
                surface.brRadiusY,
                surface.blRadiusX,
                surface.blRadiusY,
              ],
          ],
        },
      if (_androidWindowInactive && !popupSuspended)
        'androidWindowInactive': true,
      'dim': popupSuspended && _config.dimDuringSuspension && dimColor != null
          ? <String, Object?>{
              'color': dimColor.toARGB32(),
              'durationMs': resolvedOpacity == null
                  ? popup!.transitionDuration.inMilliseconds
                  : 0,
            }
          : null,
      'rtl': _rtl,
      'appearance': _appearance,
    };
    final json = jsonEncode(state);
    if (json == _lastStateJson && !_forceResend) return;
    _forceResend = false;
    _lastStateJson = json;
    state['stateRevision'] = ++_stateRevision;
    if (!nativeAvailable || _lease == null) return;
    _ensureIcons(state);
    final avatar = top?._iosAvatar;
    final wireTop = state['top'];
    if (avatar != null && wireTop is Map<String, Object?>) {
      final leading = wireTop['leading'] as Map<String, Object?>;
      // Keep image bytes out of the state signature and the glyph collector.
      wireTop['leading'] = {...leading, 'iosAvatarPNG': avatar.png};
    }
    unawaited(_transport.update(state));
  }

  void _ensureIcons(Map<String, Object?> state) {
    final keys = <String, IconData>{};
    void collect(Object? node, {required bool tab}) {
      if (node is Map) {
        final icon = node['icon'];
        if (icon is Map) _addIcon(keys, icon, tab: tab);
        final selected = node['selectedIcon'];
        if (selected is Map) _addIcon(keys, selected, tab: tab);
        for (final v in node.values) {
          if (v is Map || v is List) collect(v, tab: tab);
        }
      } else if (node is List) {
        for (final v in node) {
          collect(v, tab: tab);
        }
      }
    }

    collect(state['top'], tab: false);
    collect(state['tab'], tab: true);
    for (final entry in keys.entries) {
      if (_iconsSent.contains(entry.key) || _iconsPending.contains(entry.key)) {
        continue;
      }
      _iconsPending.add(entry.key);
      unawaited(_rasterizeAndSend(entry.key, entry.value));
    }
  }

  final Map<String, IconData> _iconData = <String, IconData>{};

  /// Remembers the glyph for an icon key (called while building wire data).
  void rememberIcon(NativeChromeIcon icon) => _iconData[icon.key] = icon.icon;

  void _addIcon(
    Map<String, IconData> into,
    Map<Object?, Object?> wire, {
    required bool tab,
  }) {
    final key = wire['key'];
    if (key is! String) return;
    final needsGlyph =
        defaultTargetPlatform != TargetPlatform.iOS ||
        wire['iosSymbol'] == null;
    if (!needsGlyph) return;
    final data = _iconData[key];
    if (data != null) into[key] = data;
  }

  Future<void> _rasterizeAndSend(String key, IconData icon) async {
    try {
      final image = await _rasterizer.rasterize(
        icon,
        logicalSize: 24,
        devicePixelRatio: _devicePixelRatio,
      );
      if (image == null || _disposed) return;
      await _transport.registerIcons(<String, Object?>{key: image});
      _iconsSent.add(key);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'native_chrome',
          context: ErrorDescription('rasterizing a native bar icon'),
        ),
      );
    } finally {
      _iconsPending.remove(key);
    }
  }

  // iOS root-tab <-> opaque hidden-child presentation. This is independent
  // of the top-bar animation and of native snapshot availability.
  _BottomRoutePresentation? _bottomPresentation;

  void _beginBottomPresentation(
    Route<dynamic> cover,
    Route<dynamic> root, {
    bool push = false,
  }) {
    if (defaultTargetPlatform != TargetPlatform.iOS ||
        !_config.syncTransitions ||
        !nativeAvailable ||
        _lease == null ||
        cover is! PageRoute ||
        root is! PageRoute ||
        !cover.opaque ||
        cover.fullscreenDialog ||
        cover.animation == null) {
      return;
    }
    final existing = _bottomPresentation;
    if (identical(existing?.cover, cover) && identical(existing?.root, root)) {
      return;
    }
    _clearBottomPresentation();
    // Reuse canonical eligibility and depth/order priority. A non-native or
    // hidden winner must not fall through to a different native tab owner.
    final owner = _pick(ChromeBarKind.tab, coveredRoot: root);
    if (owner == null || !owner.native || owner.content?['hidden'] != false) {
      return;
    }
    final d = _BottomRoutePresentation(root, cover, _lease!)..fromPush = push;
    _bottomPresentation = d;
    d.listener = () {
      // Removed observers cannot revive another lease/route's presentation.
      if (!identical(_bottomPresentation, d) ||
          d.lease != _lease ||
          _disposed) {
        return;
      }
      if (_moving(cover.animation)) d.started = true;
      _markDirty(); // one post-frame read of both painted route footprints
    };
    cover.animation!.addListener(d.listener);
    // removeRoute may dispose during forward animation without a terminal
    // status. SDK TransitionRoute.completed also completes on that disposal.
    // Normal pop still follows its reverse animation until the existing end.
    unawaited(
      cover.completed.then((_) {
        if (!identical(_bottomPresentation, d) ||
            d.lease != _lease ||
            _disposed) {
          return;
        }
        _clearBottomPresentation();
        if (identical(_gestureRoute, cover)) {
          _gestureRoute = null;
          _gesturePrevious = null;
        }
        _markDirty();
      }),
    );
    d.listener();
  }

  void _clearBottomPresentation() {
    final d = _bottomPresentation;
    _bottomPresentation = null;
    if (d != null) d.cover.animation?.removeListener(d.listener);
  }

  Map<String, Object?>? _bottomPresentationWire() {
    final d = _bottomPresentation;
    if (d == null) return null;
    // Re-resolve from the same frame as canonical state, so late rebuilds or
    // visibility changes cannot borrow an earlier owner/selection/badge.
    final owner = _pick(ChromeBarKind.tab, coveredRoot: d.root);
    final a = d.cover.animation;
    final childHasTab = _owners.any(
      (o) =>
          o.kind == ChromeBarKind.tab &&
          identical(o.route, d.cover) &&
          o.visible &&
          !o.disposed,
    );
    if (d.lease != _lease ||
        !_config.syncTransitions ||
        childHasTab ||
        a == null) {
      _clearBottomPresentation();
      return null;
    }
    // The final painted frame is observed here, not in an animation status
    // callback. Canonical tab state and removal of the clip share one update.
    // During SDK hero pre-layout, offstage proxies the animation to completed.
    // That is not a terminal painted frame; retain the fail-closed observer.
    if (!d.cover.offstage &&
        !identical(_gestureRoute, d.cover) &&
        ((d.started &&
                (a.status == AnimationStatus.completed ||
                    a.status == AnimationStatus.dismissed)) ||
            (!d.started && a.status == AnimationStatus.completed))) {
      _clearBottomPresentation();
      return null;
    }
    final nav = d.root.navigator;
    final viewport = nav != null && nav.mounted ? View.of(nav.context) : null;
    final size = viewport == null
        ? null
        : viewport.physicalSize / viewport.devicePixelRatio;
    final root = size == null ? null : _paintedPageRect(d.root, size);
    var cover = size == null ? null : _paintedPageRect(d.cover, size);
    if (cover != null) d.coverPainted = true;
    // HeroController lays a pushed route out offstage on
    // its first frame; it paints nothing, so the root is still fully visible.
    // Report that cover just outside the viewport on its entering side (the
    // gap is then the whole root). Only the cover of this presentation's own
    // push, offstage and never painted yet, is admitted. Pops, removals,
    // gestures, a cover that painted before (for example offstage during a
    // gesture), unlaid-out or unsupported paint all stay fail-closed.
    if (cover == null &&
        size != null &&
        root != null &&
        d.fromPush &&
        d.cover.offstage &&
        !d.coverPainted) {
      cover = <String, double>{
        'left': _rtl ? -size.width : size.width,
        'top': 0,
        'width': size.width,
        'height': size.height,
      };
    }
    // Invalid/offstage/unlaid-out/unsupported paint is fail-closed for this
    // presentation, never an end that would expose the full canonical bar.
    return <String, Object?>{
      'tab': <String, Object?>{
        ...?owner?.content,
        if (owner == null || !owner.native) 'hidden': true,
        'ownerToken': owner?.token,
        'routeSession': owner?.session,
        'semanticRevision': owner?.semanticRevision,
      },
      'viewport': size == null
          ? null
          : <String, double>{'width': size.width, 'height': size.height},
      'root': root,
      'cover': cover,
    };
  }

  Map<String, double>? _paintedPageRect(
    PageRoute<dynamic> route,
    Size viewport,
  ) {
    final context = route.subtreeContext;
    if (context == null || !context.mounted || route.offstage) return null;
    // SDK ModalRoute.subtreeContext points to its page RepaintBoundary,
    // inside buildTransitions, not an arbitrary app descendant/app-bar slot.
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final size = box.size;
    if ((size.width - viewport.width).abs() > 0.001 ||
        (size.height - viewport.height).abs() > 0.001 ||
        size.isEmpty) {
      return null;
    }
    final matrix = box.getTransformTo(null).storage;
    // Admit only a full-viewport horizontal translation. Custom scale,
    // perspective/rotation/vertical/fullscreen transitions are not masks.
    for (final i in [0, 5, 10, 15]) {
      if ((matrix[i] - 1).abs() > 0.000001) return null;
    }
    for (final i in [1, 2, 3, 4, 6, 7, 8, 9, 11, 14]) {
      if (matrix[i].abs() > 0.000001) return null;
    }
    final origin = box.localToGlobal(Offset.zero);
    if (!origin.dx.isFinite || !origin.dy.isFinite || origin.dy.abs() > 0.001) {
      return null;
    }
    return <String, double>{
      'left': origin.dx,
      'top': origin.dy,
      'width': size.width,
      'height': size.height,
    };
  }

  // ---------------------------------------------------------- transitions

  _TransitionDriver? _transition;
  int _nextTransitionId = 1;

  /// Whether a native top bar transition is running (apps hide overlays that
  /// would otherwise double the native chrome while it moves).
  bool get transitionActive => _transition != null;

  _Begin _maybeBeginTransition(
    ChromeOwner? from,
    ChromeOwner? to, {
    bool mayDefer = false,
  }) {
    if (!_config.syncTransitions || !nativeAvailable) return _Begin.none;
    // A native bar also moves with its page when the
    // other side shows no native bar (a bar-less page, a sheet, a translucent
    // route), like a UINavigationController bar hidden on one side.
    final fromBar = from != null && from.native ? from : null;
    final toBar = to != null && to.native ? to : null;
    if (fromBar == null && toBar == null) return _Begin.none;
    _endTransition();
    final moved = _movedRoute;
    // A page in a nested navigator moves with whichever route of its chain is
    // animating (for example a settings route pushed with its detail
    // navigator inside), so look past the innermost route.
    // A bar-less side takes the moving route only from a
    // navigator the bar side's route chain lives in (the route covers or
    // uncovers that bar); otherwise it is not this switch's route.
    bool related(Route<dynamic>? r, ChromeOwner bar) =>
        r != null &&
        r.navigator != null &&
        bar.routeChain.any((c) => identical(c.navigator, r.navigator));
    final incoming = toBar == null
        ? (related(moved, fromBar!) ? moved : null)
        : toBar.routeChain
                  .where(
                    (r) =>
                        r is PageRoute &&
                        r.animation?.status == AnimationStatus.forward,
                  )
                  .firstOrNull ??
              toBar.route;
    final outgoing = fromBar == null
        ? <Route<dynamic>?>[
            _gestureRoute,
            moved,
          ].where((r) => related(r, toBar!)).firstOrNull
        : fromBar.routeChain
                  .where(
                    (r) =>
                        r is PageRoute &&
                        (r.animation?.status == AnimationStatus.reverse ||
                            identical(r, _gestureRoute)),
                  )
                  .firstOrNull ??
              fromBar.route;
    _TransitionDriver? driver;
    if (incoming is PageRoute &&
        incoming.animation?.status == AnimationStatus.forward) {
      driver = _TransitionDriver(
        _nextTransitionId++,
        'push',
        incoming.animation!,
        false,
        style: _isCupertinoSlide(incoming) ? _slideStyle : _fadeStyle,
        route: incoming,
        lease: _lease,
        navigator: incoming.navigator,
      );
    } else if (outgoing is PageRoute &&
        outgoing.animation != null &&
        (outgoing.animation!.status == AnimationStatus.reverse ||
            identical(outgoing, _gestureRoute))) {
      driver = _TransitionDriver(
        _nextTransitionId++,
        'pop',
        outgoing.animation!,
        true,
        style: _isCupertinoSlide(outgoing) ? _slideStyle : _fadeStyle,
        route: outgoing,
        lease: _lease,
        navigator: outgoing.navigator,
      );
    }
    if (driver == null) return mayDefer ? _Begin.deferred : _Begin.none;
    _movedRoute = null;
    final d = driver;
    _transition = d;
    _notifySoon();
    unawaited(
      _transport.transition(<String, Object?>{
        'lease': _lease,
        'id': d.id,
        'phase': 'begin',
        'direction': d.direction,
        'style': d.style,
        'progress': d.progress,
        'rtl': _rtl,
      }),
    );
    d.listener = () {
      final p = d.progress;
      if ((p - d.lastSent).abs() < 0.002) return;
      d.lastSent = p;
      unawaited(
        _transport.transition(<String, Object?>{
          'lease': _lease,
          'id': d.id,
          'phase': 'update',
          'progress': p,
        }),
      );
    };
    d.statusListener = (status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        if (identical(_gestureRoute, outgoing) && d.direction == 'pop') {
          // Still dragging; wait for the gesture to end.
          return;
        }
        _endTransition();
        _markDirty();
      }
    };
    d.animation.addListener(d.listener!);
    d.animation.addStatusListener(d.statusListener!);
    // A removed or replaced route is disposed without a
    // terminal animation status; its `completed` future still completes. End
    // only this driver under this lease, once (`_endTransition` is idempotent).
    unawaited(
      d.route.completed.then((_) {
        if (!identical(_transition, d) || d.lease != _lease || _disposed) {
          return;
        }
        _endTransition();
        _markDirty();
      }),
    );
    return _Begin.started;
  }

  void _endTransition() {
    final d = _transition;
    if (d == null) return;
    _transition = null;
    _notifySoon();
    d.animation.removeListener(d.listener!);
    d.animation.removeStatusListener(d.statusListener!);
    unawaited(
      _transport.transition(<String, Object?>{
        'lease': _lease,
        'id': d.id,
        'phase': 'end',
        'progress': d.progress,
      }),
    );
    d.dispose();
  }

  // --------------------------------------------------------------- events

  /// Connects to the native host under a new connection lease. The host
  /// drops state, transitions and pending input of any earlier lease.
  Future<void> attach() async {
    _switchDeferred = false;
    _deferralUsed = false;
    if (!_platformSupportsNative) {
      _hostInstalled = false;
      diagnostics.hostIssue = 'platform without native host';
      _notifySoon();
      return;
    }
    _endTransition();
    _clearBottomPresentation();
    _lease = _newLease();
    _adoptedLease = null;
    _negotiationError = null;
    _lastRequestId = 0;
    _lastStateJson = null;
    _iconsSent.clear();
    await _sendAttach();
  }

  Future<void> _sendAttach() async {
    final lease = _lease;
    if (lease == null) return;
    _attachInFlight = true;
    Map<Object?, Object?>? reply;
    try {
      reply = await _transport.attach(lease);
    } on PlatformException catch (error) {
      if (_disposed || lease != _lease) return;
      _attachInFlight = false;
      _failNegotiation(
        'native host rejected attach: ${error.code} ${error.message ?? ''}',
      );
      return;
    }
    if (_disposed || lease != _lease) return;
    _attachInFlight = false;
    if (reply == null) {
      _applyHostInfo(null); // no plugin: Flutter renderer
      return;
    }
    final protocol = reply['protocol'];
    if (protocol != nativeChromeProtocolVersion || reply['lease'] != lease) {
      _failNegotiation(
        'native protocol mismatch: expected $nativeChromeProtocolVersion '
        'with lease echo, got protocol $protocol, lease '
        '${reply['lease'] == lease ? 'echoed' : 'not echoed'}',
      );
      return;
    }
    _negotiationError = null;
    _adoptedLease = lease;
    if (_acceptHostGeneration(reply)) _applyHostInfo(reply);
    _forceResend = true;
    _markDirty();
    _notifySoon();
  }

  /// Negotiation failed: no native rendering, no further messages to the host,
  /// and a clear reason in diagnostics. Bars use the Flutter renderer.
  ///
  /// If the host had already adopted our lease (a later update was rejected
  /// while native bars were shown), that lease is detached first so its bars
  /// are cleared under the Flutter fallback. A failure before adoption
  /// (protocol mismatch, wrong lease echo, attach exception) sends nothing:
  /// the host never showed our state, and a mis-echoed lease may belong to
  /// another connection that must not be touched. The host only clears a
  /// detach that matches its current lease, so a late detach is harmless.
  void _failNegotiation(String reason) {
    _switchDeferred = false;
    _deferralUsed = false;
    final lease = _lease;
    final wasAdopted = lease != null && _adoptedLease == lease;
    _negotiationError = reason;
    _adoptedLease = null;
    if (wasAdopted && _platformSupportsNative) {
      unawaited(_transport.detach(lease));
    }
    _hostInstalled = false;
    diagnostics.hostIssue = reason;
    diagnostics.recordInfo(reason);
    _endTransition();
    _notifySoon();
    _markDirty();
  }

  void _onTransportError(String method, PlatformException error) {
    if (_disposed) return;
    if (error.code == 'bad-protocol' || error.code == 'bad-state') {
      _failNegotiation(
        'native host rejected $method: ${error.code} ${error.message ?? ''}',
      );
    } else {
      diagnostics.recordInfo('native $method failed: ${error.code}');
    }
  }

  void _applyHostInfo(Map<Object?, Object?>? info) {
    final installed = info?['hostInstalled'] == true;
    if (installed != _hostInstalled) {
      _hostInstalled = installed;
      diagnostics.hostIssue = installed
          ? null
          : info == null
          ? 'native plugin not registered'
          : 'native host not installed (see README: iOS host installation)';
      if (!installed) diagnostics.recordInfo('host unavailable');
      _notifySoon();
    }
    if (!installed) {
      _endTransition();
      _clearBottomPresentation();
      if (_geometry != const NativeChromeGeometry()) {
        _geometry = const NativeChromeGeometry();
        _notifySoon();
      }
      return;
    }
    final geometry = info?['geometry'];
    if (geometry is Map) _applyGeometry(geometry);
  }

  void _applyGeometry(Map<Object?, Object?> data) {
    final next = NativeChromeGeometry.fromWire(data);
    if (next == _geometry) return;
    _geometry = next;
    _notifySoon();
  }

  bool _acceptHostGeneration(Map<Object?, Object?> args) {
    final generation = args['hostGeneration'];
    if (generation is! int) return true; // Older Android hosts and iOS.
    final previous = _hostGeneration;
    if (previous != null && generation < previous) return false;
    if (generation != previous) {
      _hostGeneration = generation;
      if (_geometry != const NativeChromeGeometry()) {
        _geometry = const NativeChromeGeometry();
        _notifySoon();
      }
    }
    return true;
  }

  void _onMessage(String method, Map<Object?, Object?> args) {
    if (_disposed) return;
    switch (method) {
      case 'hostReady':
        final lease = _lease;
        if (_negotiationError != null || lease == null) return;
        final generation = args['hostGeneration'];
        final previousGeneration = _hostGeneration;
        final lostLease = args['lease'] != lease;
        if (generation is int &&
            _attachInFlight &&
            lostLease &&
            previousGeneration != null &&
            generation <= previousGeneration) {
          return;
        }
        if (!_acceptHostGeneration(args)) return;
        _iconsSent.clear();
        _applyHostInfo(args);
        // A newer Android surface can report that its plugin no longer has the
        // lease before an earlier attach reply arrives. A new attach invalidates
        // that reply. Legacy hosts only trigger recovery after lease adoption.
        final newerHost =
            generation is int &&
            (previousGeneration == null || generation > previousGeneration);
        if (lostLease &&
            ((newerHost && _attachInFlight) ||
                (!_attachInFlight && _adoptedLease == lease))) {
          diagnostics.recordInfo('host lost the connection; new lease');
          unawaited(attach());
          return;
        }
        _forceResend = true;
        _markDirty();
      case 'geometry':
        if (args['hostGeneration'] is int &&
            (!nativeAvailable ||
                args['lease'] != _lease ||
                args['hostGeneration'] != _hostGeneration)) {
          return;
        }
        _applyGeometry(args);
      case 'event':
        if (args['hostGeneration'] is int &&
            (!nativeAvailable || args['hostGeneration'] != _hostGeneration)) {
          return;
        }
        handleNativeEvent(args);
    }
  }

  /// Applies the acceptance rules to an event from the native host.
  @visibleForTesting
  void handleNativeEvent(Map<Object?, Object?> args) {
    final type = args['type'];
    final token = args['ownerToken'];
    final session = args['routeSession'];
    final requestId = args['requestId'];
    final what =
        '$type ${args['actionId'] ?? args['tabId']} '
        '(owner $token, session $session, rev ${args['semanticRevision']}, '
        'request $requestId)';
    if (args['lease'] != _lease || _lease == null) {
      diagnostics.recordRejected(NativeChromeRejection.leaseMismatch, what);
      return;
    }
    if (token is! int || session is! int || requestId is! int) {
      diagnostics.recordRejected(NativeChromeRejection.malformed, what);
      return;
    }
    // Request ids are issued per lease in increasing order by the host and
    // delivered in order; anything not newer was already handled.
    if (requestId <= _lastRequestId) {
      diagnostics.recordRejected(NativeChromeRejection.duplicateRequest, what);
      return;
    }
    _lastRequestId = requestId;
    final isTab = type == 'tabRequest';
    if (!isTab && type != 'topAction') {
      diagnostics.recordRejected(NativeChromeRejection.malformed, what);
      return;
    }
    final owner = isTab ? _activeTab : _activeTop;
    final actionId = args['actionId'];
    final overflowWhileInactive =
        !isTab &&
        _androidWindowInactive &&
        args['androidOverflow'] == true &&
        actionId is String &&
        owner?._findAction(actionId)?.androidOverflowIfRoom == true;
    NativeChromeRejection? reason;
    if (owner == null) {
      reason = NativeChromeRejection.noActiveOwner;
    } else if (owner.token != token) {
      reason = NativeChromeRejection.ownerMismatch;
    } else if (owner.session != session) {
      reason = NativeChromeRejection.sessionMismatch;
    } else if (!owner.native) {
      reason = NativeChromeRejection.notNative;
    } else if (isSuspended || (!_lifecycleActive && !overflowWhileInactive)) {
      reason = NativeChromeRejection.suspended;
    } else if ((isTab && _bottomPresentation != null) ||
        (!isTab && _transitioning(owner))) {
      reason = NativeChromeRejection.transition;
    }
    if (reason != null) {
      diagnostics.recordRejected(reason, what);
      return;
    }
    if (isTab) {
      final bar = owner!.tabBar!;
      final id = args['tabId'];
      final item = bar.items.where((i) => i.id == id).firstOrNull;
      if (item == null) {
        diagnostics.recordRejected(NativeChromeRejection.unknownId, what);
        return;
      }
      if (!item.enabled) {
        diagnostics.recordRejected(NativeChromeRejection.disabled, what);
        return;
      }
      diagnostics.recordAccepted(what);
      if (item.id == bar.selectedId) {
        bar.onReselect?.call(item.id);
      } else {
        bar.onSelect(item.id);
      }
      return;
    }
    final id = args['actionId'];
    final action = id is String ? owner!._findAction(id) : null;
    if (action == null) {
      diagnostics.recordRejected(NativeChromeRejection.unknownId, what);
      return;
    }
    if (!action.isEnabled) {
      diagnostics.recordRejected(NativeChromeRejection.disabled, what);
      return;
    }
    if (owner!.busy) {
      diagnostics.recordRejected(NativeChromeRejection.busy, what);
      return;
    }
    diagnostics.recordAccepted(what);
    _run(owner, action);
  }

  /// Runs a top bar action from the Flutter renderer with the same busy rule
  /// as native input. Returns false when rejected (busy or disabled).
  bool runFlutterAction(ChromeOwner owner, NativeBarAction action) {
    final what = 'flutter topAction ${action.id} (owner ${owner.token})';
    if (!action.isEnabled) {
      diagnostics.recordRejected(NativeChromeRejection.disabled, what);
      return false;
    }
    if (owner.busy) {
      diagnostics.recordRejected(NativeChromeRejection.busy, what);
      return false;
    }
    diagnostics.recordAccepted(what);
    _run(owner, action);
    return true;
  }

  void _run(ChromeOwner owner, NativeBarAction action) {
    final result = action.onPressed!.call();
    if (result is Future) {
      owner.busy = true;
      _notifySoon();
      result.whenComplete(() {
        owner.busy = false;
        _notifySoon();
      }).ignore();
    }
  }

  // ------------------------------------------------------------ lifecycle

  /// Null at startup is active, matching the embedding's pre-lifecycle state.
  /// Every lifecycle notification renews both displayed owners' sessions:
  /// queued input from before or during inactivity stays stale after resume.
  late bool _lifecycleActive;
  bool _androidWindowInactive = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleActive = state == AppLifecycleState.resumed;
    _androidWindowInactive =
        defaultTargetPlatform == TargetPlatform.android &&
        state == AppLifecycleState.inactive;
    _activeTop?.session++;
    _activeTab?.session++;
    _forceResend = true;
    diagnostics.recordInfo('lifecycle ${state.name}: active=$_lifecycleActive');
    // No frame may run while inactive. Publish suspension and stamps now,
    // including on resume so the first new native tap has the renewed stamp.
    flush();
  }

  /// Closes the current connection: the host hides this connection's bars,
  /// ends transitions and suspension, and lets touches reach Flutter. A newer
  /// connection is unaffected (the host ignores detach for other leases).
  /// [attach] opens a new connection later.
  void detach() {
    _switchDeferred = false;
    _deferralUsed = false;
    _endTransition();
    _clearBottomPresentation();
    final lease = _lease;
    if (lease == null) return;
    final adopted = _adoptedLease == lease;
    _lease = null;
    _adoptedLease = null;
    _hostGeneration = null;
    _attachInFlight = false;
    _lastStateJson = null;
    // Only a host that adopted the lease is told; nothing is sent to a host
    // whose negotiation failed.
    if (_platformSupportsNative && adopted) {
      unawaited(_transport.detach(lease));
    }
  }

  @override
  void dispose() {
    detach();
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _transport.dispose();
    super.dispose();
  }
}
