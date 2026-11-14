import Flutter
import UIKit

/// Connects the Flutter channel with the (single) installed host.
///
/// v0 supports one Flutter engine with one host per process, which matches the
/// package architecture.
public final class NativeChromeHub {
  public static let shared = NativeChromeHub()

  weak var plugin: NativeChromePlugin?
  public internal(set) weak var host: NativeChromeHostViewController?
  public internal(set) var lastState: NativeChromeStateSpec?
  /// Current connection lease. Messages and events of other leases are
  /// ignored; a new lease drops the previous connection's state and input.
  public internal(set) var currentLease: String?
  private var requestCounter = 0
  var icons: [String: UIImage] = [:]
  /// Bumped when new icon images arrive so hosts rebuild affected items.
  public internal(set) var iconVersion = 0

  /// Test hook: receives every message sent to Dart.
  public var debugMessageObserver: ((String, [String: Any]) -> Void)?

  func send(_ method: String, _ args: [String: Any]) {
    debugMessageObserver?(method, args)
    plugin?.channel.invokeMethod(method, arguments: args)
  }

  /// Next request id of the current lease (top actions and tab requests).
  func nextRequestId() -> Int {
    requestCounter += 1
    return requestCounter
  }

  /// Opens [lease]. A different lease resets state, transitions, suspension,
  /// request ids and hides the bars until the new connection sends state.
  public func attach(lease: String) {
    guard lease != currentLease else { return }
    currentLease = lease
    lastState = nil
    requestCounter = 0
    host?.clear()
  }

  /// Closes [lease] if it is still current. Late detaches are ignored.
  @discardableResult
  public func detach(lease: String) -> Bool {
    guard lease == currentLease else { return false }
    currentLease = nil
    lastState = nil
    requestCounter = 0
    host?.clear()
    return true
  }

  func apply(_ state: NativeChromeStateSpec) {
    guard state.lease == currentLease else { return }
    if let current = lastState, current.lease == state.lease, state.revision < current.revision {
      return
    }
    lastState = state
    host?.apply(state)
  }

  public func icon(for spec: NativeChromeIconSpec?) -> UIImage? {
    guard let spec else { return nil }
    if let symbol = spec.iosSymbol, let image = UIImage(systemName: symbol) {
      return image
    }
    return icons[spec.key]
  }

  func hostDidInstall(_ host: NativeChromeHostViewController) {
    self.host = host
    if let state = lastState { host.apply(state) }
    var args: [String: Any] = ["hostInstalled": true, "geometry": host.geometry()]
    if let lease = currentLease { args["lease"] = lease }
    send("hostReady", args)
  }

  /// Applies a raw `update` payload (used by tests and the plugin).
  @discardableResult
  public func applyWire(_ value: Any?) -> Bool {
    guard let state = NativeChromeStateSpec(value) else { return false }
    apply(state)
    return true
  }
}

public class NativeChromePlugin: NSObject, FlutterPlugin {
  let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "native_chrome/host", binaryMessenger: registrar.messenger())
    let instance = NativeChromePlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    NativeChromeHub.shared.plugin = instance
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let hub = NativeChromeHub.shared
    switch call.method {
    case "attach":
      let args = call.arguments as? [String: Any]
      guard (args?["protocol"] as? NSNumber)?.intValue == 2, let lease = args?["lease"] as? String else {
        result(FlutterError(code: "bad-protocol", message: "native_chrome protocol 2 required", details: nil))
        return
      }
      hub.attach(lease: lease)
      var reply: [String: Any] = [
        "protocol": 2, "platform": "ios", "hostInstalled": hub.host != nil, "lease": lease,
      ]
      if let host = hub.host { reply["geometry"] = host.geometry() }
      result(reply)
    case "update":
      if hub.applyWire(call.arguments) {
        result(nil)
      } else {
        result(FlutterError(code: "bad-state", message: "Unsupported native_chrome state", details: nil))
      }
    case "icons":
      if let map = call.arguments as? [String: Any] {
        for (key, value) in map {
          guard let entry = value as? [String: Any],
            let data = entry["png"] as? FlutterStandardTypedData
          else { continue }
          let scale = (entry["scale"] as? NSNumber)?.doubleValue ?? Double(UIScreen.main.scale)
          if let image = UIImage(data: data.data, scale: CGFloat(scale)) {
            hub.icons[key] = image.withRenderingMode(.alwaysTemplate)
          }
        }
        hub.iconVersion += 1
        hub.host?.reapply()
      }
      result(nil)
    case "detach":
      if let lease = (call.arguments as? [String: Any])?["lease"] as? String {
        hub.detach(lease: lease)
      }
      result(nil)
    case "transition":
      if let map = call.arguments as? [String: Any], map["lease"] as? String == hub.currentLease {
        hub.host?.transition(map)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
