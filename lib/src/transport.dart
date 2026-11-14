import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// Wire protocol version shared with the iOS and Android hosts.
/// Protocol 2 adds the connection lease (`lease`) to every Dart → native
/// message and native → Dart event, plus `detach` and per-lease `requestId`s.
const int nativeChromeProtocolVersion = 2;

/// Channel name shared with the native hosts.
const String nativeChromeChannelName = 'native_chrome/host';

/// Native bar geometry in Flutter logical pixels.
@immutable
class NativeChromeGeometry {
  const NativeChromeGeometry({
    this.topInset = 0,
    this.topBarHeight = 0,
    this.topBarVisible = false,
    this.tabBarHeight = 0,
    this.tabBarVisible = false,
    this.tabRailWidth = 0,
    this.measured = false,
    this.occlusionSupported = false,
    this.occlusionRegions = const <Rect>[],
    this.hiddenActionSlot,
  });

  factory NativeChromeGeometry.fromWire(Map<Object?, Object?> data) {
    double d(String key) => (data[key] as num?)?.toDouble() ?? 0;
    final occlusion = data['occlusion'];
    final regions = <Rect>[];
    if (occlusion is Map && occlusion['regions'] is List) {
      for (final raw in occlusion['regions'] as List) {
        if (raw is! Map) continue;
        double v(String k) => (raw[k] as num?)?.toDouble() ?? 0;
        final r = Rect.fromLTWH(v('left'), v('top'), v('width'), v('height'));
        if (r.isFinite && !r.isEmpty) regions.add(r);
      }
    }
    Rect? slot;
    final rawSlot = data['hiddenActionSlot'];
    if (rawSlot is Map) {
      double v(String k) => (rawSlot[k] as num?)?.toDouble() ?? 0;
      final r = Rect.fromLTWH(v('left'), v('top'), v('width'), v('height'));
      if (r.isFinite && !r.isEmpty) slot = r;
    }
    return NativeChromeGeometry(
      hiddenActionSlot: slot,
      occlusionSupported: occlusion is Map && occlusion['supported'] == true,
      occlusionRegions: List<Rect>.unmodifiable(regions),
      topInset: d('topInset'),
      topBarHeight: d('topBarHeight'),
      topBarVisible: data['topBarVisible'] == true,
      tabBarHeight: d('tabBarHeight'),
      tabBarVisible: data['tabBarVisible'] == true,
      tabRailWidth: data['tabBarPlacement'] == 'start' ? d('tabRailWidth') : 0,
      measured: true,
    );
  }

  /// Distance from the top of the Flutter view to the top bar's top edge
  /// (the status bar / top safe area).
  final double topInset;

  /// Intrinsic height of the native top bar (excluding [topInset]).
  final double topBarHeight;
  final bool topBarVisible;

  /// Distance from the bottom of the Flutter view to the tab bar's top edge,
  /// including the bottom safe area.
  final double tabBarHeight;
  final bool tabBarVisible;

  /// Width of the side navigation rail shown instead of the bottom tab bar
  /// (Android large screens, [NativeTabBar.largeScreenRail]), including the
  /// start safe area it covers. 0 when the tab bar is at the bottom.
  final double tabRailWidth;

  /// False until the native host reports real measurements.
  final bool measured;

  /// Whether the OS reports system occlusion regions (iOS 27.1
  /// `UIView.reservedRegions(kind: .occlusion)`), for example the hinge or
  /// camera areas of foldable devices.
  final bool occlusionSupported;

  /// Active system occlusion regions in Flutter view coordinates.
  final List<Rect> occlusionRegions;

  /// While the page's top bar is `hidden` (iOS host only): where a trailing
  /// action would sit if the bar were shown, measured by the host. Apps use it
  /// to place their own Flutter control in the system position (for example a
  /// settings button on a full-bleed page, including foldable rails).
  final Rect? hiddenActionSlot;

  /// Rect of the top bar (including the status area it paints) in Flutter
  /// coordinates, for apps that paint their own mask over native bars.
  Rect topBarRect(Size viewSize) =>
      Rect.fromLTWH(0, 0, viewSize.width, topInset + topBarHeight);

  Rect tabBarRect(Size viewSize) => Rect.fromLTWH(
    0,
    viewSize.height - tabBarHeight,
    viewSize.width,
    tabBarHeight,
  );

  @override
  bool operator ==(Object other) =>
      other is NativeChromeGeometry &&
      other.topInset == topInset &&
      other.topBarHeight == topBarHeight &&
      other.topBarVisible == topBarVisible &&
      other.tabBarHeight == tabBarHeight &&
      other.tabBarVisible == tabBarVisible &&
      other.tabRailWidth == tabRailWidth &&
      other.measured == measured &&
      other.occlusionSupported == occlusionSupported &&
      other.hiddenActionSlot == hiddenActionSlot &&
      listEquals(other.occlusionRegions, occlusionRegions);

  @override
  int get hashCode => Object.hash(
    topInset,
    topBarHeight,
    topBarVisible,
    tabBarHeight,
    tabBarVisible,
    tabRailWidth,
    measured,
    occlusionSupported,
    Object.hashAll(occlusionRegions),
    hiddenActionSlot,
  );

  @override
  String toString() =>
      'NativeChromeGeometry(top: $topInset+$topBarHeight '
      '${topBarVisible ? 'shown' : 'hidden'}, tab: $tabBarHeight '
      '${tabBarVisible ? 'shown' : 'hidden'}, measured: $measured)';
}

/// Why an incoming native event was rejected.
enum NativeChromeRejection {
  noActiveOwner,
  ownerMismatch,
  sessionMismatch,
  notNative,
  suspended,
  transition,
  unknownId,
  disabled,
  busy,
  malformed,

  /// Event produced under another connection (an earlier controller/attach).
  leaseMismatch,

  /// The same request (same lease and requestId) was already handled.
  duplicateRequest,
}

/// Observable record of accepted and rejected native events.
class NativeChromeDiagnostics extends ChangeNotifier {
  NativeChromeDiagnostics({this.logToConsole = kDebugMode});

  /// Print every decision with `debugPrint` (tag `[native_chrome]`).
  bool logToConsole;

  int _accepted = 0;
  final Map<NativeChromeRejection, int> _rejected =
      <NativeChromeRejection, int>{};
  final ListQueue<String> _recent = ListQueue<String>();

  int get accepted => _accepted;
  Map<NativeChromeRejection, int> get rejected =>
      UnmodifiableMapView<NativeChromeRejection, int>(_rejected);
  int get rejectedTotal => _rejected.values.fold(0, (a, b) => a + b);
  List<String> get recent => List<String>.unmodifiable(_recent);

  /// Latest host problem (for example the iOS host was not installed).
  String? hostIssue;

  void recordAccepted(String what) {
    _accepted++;
    _push('accepted $what');
  }

  void recordRejected(NativeChromeRejection reason, String what) {
    _rejected[reason] = (_rejected[reason] ?? 0) + 1;
    _push('rejected(${reason.name}) $what');
  }

  void recordInfo(String what) => _push(what);

  void _push(String line) {
    _recent.addFirst(line);
    while (_recent.length > 30) {
      _recent.removeLast();
    }
    if (logToConsole) debugPrint('[native_chrome] $line');
    notifyListeners();
  }
}

/// Bridge to the native host. The default implementation uses a
/// [MethodChannel]; tests can substitute their own.
abstract class NativeChromeTransport {
  /// Called for every message from the native host. Messages are delivered to
  /// the transport that attached most recently (see [attach]).
  set onMessage(void Function(String method, Map<Object?, Object?> args)? fn);

  /// Called when the host rejects a Dart → native message (for example an
  /// unsupported protocol). Errors are never left as unhandled async errors.
  set onError(void Function(String method, PlatformException error)? fn);

  /// Takes over receiving native messages, opens connection [lease] (the host
  /// drops any earlier connection's state) and returns the host reply, or
  /// null when no native host exists. Throws [PlatformException] when the
  /// host rejects the negotiation.
  Future<Map<Object?, Object?>?> attach(String lease);

  /// Closes connection [lease]. The host ignores it if a newer lease exists.
  Future<void> detach(String lease);
  Future<void> update(Map<String, Object?> state);
  Future<void> registerIcons(Map<String, Object?> icons);
  Future<void> transition(Map<String, Object?> transition);
  void dispose();
}

class MethodChannelNativeChromeTransport implements NativeChromeTransport {
  MethodChannelNativeChromeTransport({
    MethodChannel channel = const MethodChannel(nativeChromeChannelName),
  }) : _channel = channel;

  /// The transport currently receiving native messages, per channel. Creating
  /// a transport does not take the channel; [attach] does, and [dispose] only
  /// releases it if this transport still owns it.
  static final Map<String, MethodChannelNativeChromeTransport> _receivers =
      <String, MethodChannelNativeChromeTransport>{};
  final MethodChannel _channel;
  void Function(String method, Map<Object?, Object?> args)? _onMessage;
  void Function(String method, PlatformException error)? _onError;

  @override
  set onMessage(void Function(String method, Map<Object?, Object?> args)? fn) =>
      _onMessage = fn;

  @override
  set onError(void Function(String method, PlatformException error)? fn) =>
      _onError = fn;

  /// Whether this transport currently receives native messages.
  @visibleForTesting
  bool get isReceiver => identical(_receivers[_channel.name], this);

  void _acquire() {
    _channel.setMethodCallHandler(_handle);
    _receivers[_channel.name] = this;
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments is Map
        ? Map<Object?, Object?>.from(call.arguments as Map)
        : <Object?, Object?>{};
    _onMessage?.call(call.method, args);
    return null;
  }

  @override
  Future<Map<Object?, Object?>?> attach(String lease) async {
    _acquire();
    try {
      final reply = await _channel.invokeMethod<Object?>('attach', {
        'protocol': nativeChromeProtocolVersion,
        'lease': lease,
      });
      return reply is Map ? Map<Object?, Object?>.from(reply) : null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _send(String method, Object? args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // No host: the Flutter renderer is used.
    } on PlatformException catch (error) {
      _onError?.call(method, error);
    }
  }

  @override
  Future<void> detach(String lease) =>
      _send('detach', <String, Object?>{'lease': lease});

  @override
  Future<void> update(Map<String, Object?> state) => _send('update', state);

  @override
  Future<void> registerIcons(Map<String, Object?> icons) =>
      _send('icons', icons);

  @override
  Future<void> transition(Map<String, Object?> transition) =>
      _send('transition', transition);

  @override
  void dispose() {
    // Only release the channel if this transport still receives on it; a
    // later attach by another transport is never undone.
    if (isReceiver) {
      _channel.setMethodCallHandler(null);
      _receivers.remove(_channel.name);
    }
    _onMessage = null;
    _onError = null;
  }
}

/// Rasterises icon glyphs to PNG template images for the native hosts.
abstract class NativeChromeIconRasterizer {
  Future<Map<String, Object?>?> rasterize(
    IconData icon, {
    required double logicalSize,
    required double devicePixelRatio,
  });
}

class GlyphNativeChromeIconRasterizer implements NativeChromeIconRasterizer {
  const GlyphNativeChromeIconRasterizer();

  @override
  Future<Map<String, Object?>?> rasterize(
    IconData icon, {
    required double logicalSize,
    required double devicePixelRatio,
  }) async {
    final px = (logicalSize * devicePixelRatio).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          inherit: false,
          fontSize: px.toDouble(),
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: const Color(0xFFFFFFFF),
          height: 1,
        ),
      ),
    )..layout();
    painter.paint(
      canvas,
      Offset((px - painter.width) / 2, (px - painter.height) / 2),
    );
    painter.dispose();
    final picture = recorder.endRecording();
    final image = await picture.toImage(px, px);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) return null;
    return <String, Object?>{
      'png': Uint8List.view(data.buffer),
      'scale': devicePixelRatio,
      'size': logicalSize,
    };
  }
}
