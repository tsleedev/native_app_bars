import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_chrome/native_chrome.dart';

/// Fake native host speaking the real MethodChannel protocol and mirroring the
/// native host rules (iOS NativeChromeHub / Android NativeChromeConnection):
/// a new lease drops previous state; updates of other leases or older
/// revisions within the lease are dropped; detach of a stale lease is ignored;
/// request ids are unique per lease.
class FakeHost {
  FakeHost({this.installed = true, this.geometry});

  bool installed;
  Map<String, Object?>? geometry;
  final List<MethodCall> calls = <MethodCall>[];

  /// Negotiation knobs for protocol-mismatch tests.
  int protocolReply = nativeChromeProtocolVersion;
  bool echoOtherLease = false;
  String? throwOnAttach; // PlatformException code
  String? rejectUpdatesWith; // PlatformException code for every update
  // Like a real host, a rejected update leaves the shown state untouched.

  String? currentLease;
  Map<Object?, Object?>? nativeState;
  int _requestId = 0;

  /// Leases of updates the host dropped (other lease or older revision).
  final List<Object?> droppedUpdateLeases = <Object?>[];

  static const channel = MethodChannel(nativeChromeChannelName);

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    _messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments is Map
          ? Map<Object?, Object?>.from(call.arguments as Map)
          : <Object?, Object?>{};
      switch (call.method) {
        case 'attach':
          expect(args['protocol'], nativeChromeProtocolVersion);
          if (throwOnAttach != null) {
            throw PlatformException(code: throwOnAttach!, message: 'fake');
          }
          final lease = args['lease'] as String;
          if (lease != currentLease) {
            currentLease = lease;
            nativeState = null;
            _requestId = 0;
          }
          return <String, Object?>{
            'protocol': protocolReply,
            'hostInstalled': installed,
            'lease': echoOtherLease ? 'someone-else' : lease,
            'geometry': ?geometry,
          };
        case 'update':
          if (rejectUpdatesWith != null) {
            throw PlatformException(code: rejectUpdatesWith!, message: 'fake');
          }
          if (args['lease'] != currentLease) {
            droppedUpdateLeases.add(args['lease']);
            return null;
          }
          final current = nativeState;
          if (current != null &&
              (args['stateRevision']! as int) <
                  (current['stateRevision']! as int)) {
            droppedUpdateLeases.add(args['lease']);
            return null;
          }
          nativeState = args;
        case 'detach':
          handleDetach(args['lease'] as String?);
      }
      return null;
    });
  }

  /// Native detach rule (also used to simulate a late detach).
  void handleDetach(String? lease) {
    if (lease == null || lease != currentLease) return;
    currentLease = null;
    nativeState = null;
    _requestId = 0;
  }

  /// Simulates the native side losing the connection (host recreated without
  /// the Dart isolate restarting).
  void resetConnection() {
    currentLease = null;
    nativeState = null;
    _requestId = 0;
  }

  /// Simulates a platform without the plugin (MissingPluginException).
  void simulateMissingPlugin() {
    _messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw MissingPluginException();
    });
  }

  int get updateCount => calls.where((c) => c.method == 'update').length;

  void uninstall() => _messenger.setMockMethodCallHandler(channel, null);

  List<Map<Object?, Object?>> get updates => <Map<Object?, Object?>>[
    for (final c in calls)
      if (c.method == 'update') Map<Object?, Object?>.from(c.arguments as Map),
  ];

  List<Map<Object?, Object?>> get transitions => <Map<Object?, Object?>>[
    for (final c in calls)
      if (c.method == 'transition')
        Map<Object?, Object?>.from(c.arguments as Map),
  ];

  /// State currently shown by the (fake) native host.
  Map<Object?, Object?> get state => nativeState!;
  Map<Object?, Object?>? get top =>
      nativeState?['top'] as Map<Object?, Object?>?;
  Map<Object?, Object?>? get tab =>
      nativeState?['tab'] as Map<Object?, Object?>?;

  int nextRequestId() => ++_requestId;

  /// Sends a message from "native" to Dart through the real channel.
  Future<void> send(String method, Map<String, Object?> args) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, args),
    );
    await _messenger.handlePlatformMessage(
      nativeChromeChannelName,
      data,
      (_) {},
    );
  }

  /// Simulates a native top bar tap using the stamp currently displayed.
  Future<void> tapTop(
    String actionId, {
    Map<Object?, Object?>? stamp,
    String? lease,
    int? requestId,
  }) {
    final s = stamp ?? top!;
    return send('event', <String, Object?>{
      'type': 'topAction',
      'actionId': actionId,
      'lease': lease ?? currentLease,
      'requestId': requestId ?? nextRequestId(),
      'ownerToken': s['ownerToken'],
      'routeSession': s['routeSession'],
      'semanticRevision': s['semanticRevision'],
    });
  }

  /// Simulates a native tab bar tap using the stamp currently displayed.
  Future<void> tapTab(
    String tabId, {
    Map<Object?, Object?>? stamp,
    String? lease,
    int? requestId,
  }) {
    final s = stamp ?? tab!;
    return send('event', <String, Object?>{
      'type': 'tabRequest',
      'tabId': tabId,
      'lease': lease ?? currentLease,
      'requestId': requestId ?? nextRequestId(),
      'ownerToken': s['ownerToken'],
      'routeSession': s['routeSession'],
      'semanticRevision': s['semanticRevision'],
    });
  }
}

/// Rasteriser that avoids image encoding in widget tests.
class FakeRasterizer implements NativeChromeIconRasterizer {
  @override
  Future<Map<String, Object?>?> rasterize(
    IconData icon, {
    required double logicalSize,
    required double devicePixelRatio,
  }) async => <String, Object?>{
    'png': Uint8List(0),
    'scale': devicePixelRatio,
    'size': logicalSize,
  };
}

NativeChromeController testController() => NativeChromeController(
  rasterizer: FakeRasterizer(),
  diagnostics: NativeChromeDiagnostics(logToConsole: false),
);
