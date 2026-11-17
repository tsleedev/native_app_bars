import Flutter
import UIKit

/// Wire model for the `update` message (protocol 1). Parsing is isolated so it
/// can be unit tested without a running engine.
public struct NativeChromeIconSpec: Equatable {
  public let key: String
  public let iosSymbol: String?

  init?(_ value: Any?) {
    guard let map = value as? [String: Any], let key = map["key"] as? String else { return nil }
    self.key = key
    self.iosSymbol = map["iosSymbol"] as? String
  }
}

public struct NativeChromeActionSpec: Equatable {
  public let id: String
  public let label: String
  public let icon: NativeChromeIconSpec?
  public let enabled: Bool
  public let loading: Bool
  /// icon | text | done
  public let style: String

  let iosBadge: String?
  let iosBadgeAccessibilityValue: String?
  let iosAvatarPNG: Data?
  let iosSystemItem: UIBarButtonItem.SystemItem?

  func hasSameControl(as other: NativeChromeActionSpec) -> Bool {
    id == other.id && label == other.label && icon == other.icon &&
      enabled == other.enabled && loading == other.loading && style == other.style &&
      iosSystemItem == other.iosSystemItem
  }

  init?(_ value: Any?, allowsAvatar: Bool = false) {
    guard let map = value as? [String: Any], let id = map["id"] as? String else { return nil }
    self.id = id
    self.label = map["label"] as? String ?? id
    self.icon = NativeChromeIconSpec(map["icon"])
    self.enabled = map["enabled"] as? Bool ?? false
    self.loading = map["loading"] as? Bool ?? false
    self.style = map["style"] as? String ?? "icon"
    if style == "icon", !loading {
      switch map["iosSystemItem"] as? String {
      case "close": iosSystemItem = .close
      case "save": iosSystemItem = .save
      case "edit": iosSystemItem = .edit
      case "add": iosSystemItem = .add
      default: iosSystemItem = nil
      }
    } else {
      iosSystemItem = nil
    }
    let badge = map["badge"] as? String
    let value = map["iosBadgeAccessibilityValue"] as? String
    if style == "icon", !loading, let badge, badge.utf16.count <= 16,
      let value, !value.isEmpty, value.utf16.count <= 256 {
      iosBadge = badge
      iosBadgeAccessibilityValue = value
    } else {
      iosBadge = nil
      iosBadgeAccessibilityValue = nil
    }
    if allowsAvatar, style == "icon", !loading, iosSystemItem == nil,
      let data = map["iosAvatarPNG"] as? FlutterStandardTypedData,
      (1...65536).contains(data.data.count) {
      iosAvatarPNG = data.data
    } else {
      iosAvatarPNG = nil
    }
  }
}

/// Identity echoed back with every native event.
public struct NativeChromeOwnerStamp: Equatable {
  public let ownerToken: Int
  public let routeSession: Int
  public let semanticRevision: Int

  init?(_ map: [String: Any]) {
    guard let token = (map["ownerToken"] as? NSNumber)?.intValue,
      let session = (map["routeSession"] as? NSNumber)?.intValue
    else { return nil }
    ownerToken = token
    routeSession = session
    semanticRevision = (map["semanticRevision"] as? NSNumber)?.intValue ?? 0
  }

  var wire: [String: Any] {
    ["ownerToken": ownerToken, "routeSession": routeSession, "semanticRevision": semanticRevision]
  }
}

public struct NativeChromeTopSpec: Equatable {
  public let stamp: NativeChromeOwnerStamp
  public let title: String
  public let presentation: String
  /// platform | leading | expandedLeading
  public let titleAlignment: String
  public let titleAction: NativeChromeActionSpec?
  let iosLeadingTitleAccessory: String?
  let iosSubtitle: String?
  public let background: UIColor?
  public let foreground: UIColor?
  public let leading: NativeChromeActionSpec?
  public let actions: [NativeChromeActionSpec]
  /// Opt-in: the first action goes into `pinnedTrailingGroup`.
  public let pinFirstAction: Bool
  public let opacity: Double

  /// Opacity and semantic revision can change every drag frame without
  /// replacing controls under a finger. Owner/session changes still rebuild.
  func hasSameItems(as other: NativeChromeTopSpec) -> Bool {
    stamp.ownerToken == other.stamp.ownerToken && stamp.routeSession == other.stamp.routeSession
      && title == other.title && presentation == other.presentation
      && titleAlignment == other.titleAlignment && titleAction == other.titleAction
      && iosLeadingTitleAccessory == other.iosLeadingTitleAccessory && iosSubtitle == other.iosSubtitle
      && background == other.background && foreground == other.foreground
      && (leading.map { action in other.leading.map { action.hasSameControl(as: $0) } ?? false }
          ?? (other.leading == nil))
      && actions.count == other.actions.count
      && zip(actions, other.actions).allSatisfy { $0.hasSameControl(as: $1) }
      && pinFirstAction == other.pinFirstAction
  }

  init?(_ value: Any?) {
    guard let map = value as? [String: Any], let stamp = NativeChromeOwnerStamp(map) else { return nil }
    self.stamp = stamp
    title = map["title"] as? String ?? ""
    presentation = map["presentation"] as? String ?? "opaque"
    titleAlignment = map["titleAlignment"] as? String ?? "platform"
    titleAction = NativeChromeActionSpec(map["titleAction"])
    let accessory = map["iosLeadingTitleAccessory"] as? String
    iosLeadingTitleAccessory = accessory.flatMap { (1...64).contains($0.utf16.count) ? $0 : nil }
    iosSubtitle = (map["iosSubtitle"] as? String).flatMap { (1...512).contains($0.utf16.count) ? $0 : nil }
    background = NativeChromeAppearanceSpec.color(map["background"])
    foreground = NativeChromeAppearanceSpec.color(map["foreground"])
    leading = NativeChromeActionSpec(map["leading"], allowsAvatar: true)
    actions = (map["actions"] as? [Any] ?? []).compactMap { NativeChromeActionSpec($0) }
    pinFirstAction = map["pinFirstAction"] as? Bool ?? false
    let requested = (map["opacity"] as? NSNumber)?.doubleValue ?? 1
    opacity = requested.isFinite ? max(0, min(1, requested)) : 1
  }
}

public struct NativeChromeTabItemSpec: Equatable {
  public let id: String
  public let label: String
  public let icon: NativeChromeIconSpec?
  public let selectedIcon: NativeChromeIconSpec?
  public let badge: String?
  public let enabled: Bool
  /// Optional accessibility value (nil: UIKit default from the badge).
  public let accessibilityValue: String?

  init?(_ value: Any?) {
    guard let map = value as? [String: Any], let id = map["id"] as? String else { return nil }
    self.id = id
    label = map["label"] as? String ?? id
    icon = NativeChromeIconSpec(map["icon"])
    selectedIcon = NativeChromeIconSpec(map["selectedIcon"])
    badge = map["badge"] as? String
    enabled = map["enabled"] as? Bool ?? true
    accessibilityValue = map["accessibilityValue"] as? String
  }
}

public struct NativeChromeTabSpec: Equatable {
  public let stamp: NativeChromeOwnerStamp
  public let items: [NativeChromeTabItemSpec]
  public let selectedId: String
  public let hidden: Bool

  init?(_ value: Any?) {
    guard let map = value as? [String: Any], let stamp = NativeChromeOwnerStamp(map) else { return nil }
    self.stamp = stamp
    items = (map["items"] as? [Any] ?? []).compactMap { NativeChromeTabItemSpec($0) }
    selectedId = map["selectedId"] as? String ?? ""
    hidden = map["hidden"] as? Bool ?? false
  }
}

public struct NativeChromeAppearanceSpec: Equatable {
  public let dark: Bool
  public let background: UIColor?
  public let foreground: UIColor?
  public let tint: UIColor?
  public let unselected: UIColor?

  init(_ value: Any?) {
    let map = value as? [String: Any] ?? [:]
    dark = (map["brightness"] as? String) == "dark"
    background = NativeChromeAppearanceSpec.color(map["background"])
    foreground = NativeChromeAppearanceSpec.color(map["foreground"])
    tint = NativeChromeAppearanceSpec.color(map["tint"])
    unselected = NativeChromeAppearanceSpec.color(map["unselected"])
  }

  static func color(_ value: Any?) -> UIColor? {
    guard let number = value as? NSNumber else { return nil }
    let argb = number.uint32Value
    return UIColor(
      red: CGFloat((argb >> 16) & 0xff) / 255,
      green: CGFloat((argb >> 8) & 0xff) / 255,
      blue: CGFloat(argb & 0xff) / 255,
      alpha: CGFloat((argb >> 24) & 0xff) / 255)
  }
}

// Optional internal presentation, not a canonical tab owner or public API.
// Rectangles are from one Flutter post-frame read in logical view coordinates.
struct NativeChromeBottomPresentation: Equatable {
  let tab: NativeChromeTabSpec
  let viewport: CGSize
  let root: CGRect
  let cover: CGRect

  init?(_ value: Any?) {
    guard let map = value as? [String: Any],
      let tab = NativeChromeTabSpec(map["tab"]), !tab.hidden, !tab.items.isEmpty,
      let size = map["viewport"] as? [String: Any],
      let w = (size["width"] as? NSNumber)?.doubleValue,
      let h = (size["height"] as? NSNumber)?.doubleValue,
      w.isFinite, h.isFinite, w > 0, h > 0,
      let root = Self.rect(map["root"]), let cover = Self.rect(map["cover"]),
      abs(root.width - w) < 0.001, abs(cover.width - w) < 0.001,
      abs(root.height - h) < 0.001, abs(cover.height - h) < 0.001,
      abs(root.minY) < 0.001, abs(cover.minY) < 0.001
    else { return nil }
    self.tab = tab
    viewport = CGSize(width: w, height: h)
    self.root = root
    self.cover = cover
  }

  private static func rect(_ value: Any?) -> CGRect? {
    guard let m = value as? [String: Any],
      let x = (m["left"] as? NSNumber)?.doubleValue,
      let y = (m["top"] as? NSNumber)?.doubleValue,
      let w = (m["width"] as? NSNumber)?.doubleValue,
      let h = (m["height"] as? NSNumber)?.doubleValue,
      x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0
    else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
  }
}

struct NativeChromePopupForeground: Equatable {
  let viewport: CGSize
  let surfaces: [[CGFloat]]

  init?(_ value: Any?) {
    guard let map = value as? [String: Any],
      let width = (map["width"] as? NSNumber)?.doubleValue,
      let height = (map["height"] as? NSNumber)?.doubleValue,
      width.isFinite, height.isFinite, width > 0, height > 0,
      let raw = map["surfaces"] as? [[NSNumber]]
    else { return nil }
    viewport = CGSize(width: width, height: height)
    surfaces = raw.prefix(16).compactMap { values in
      let v = values.map { CGFloat($0.doubleValue) }
      guard v.count == 12, v.allSatisfy({ $0.isFinite }), v[2] > 0, v[3] > 0,
        (v[0] + v[2]).isFinite, (v[1] + v[3]).isFinite,
        v.dropFirst(4).allSatisfy({ $0 >= 0 }),
        v[4]+v[6] <= v[2]+0.01, v[8]+v[10] <= v[2]+0.01,
        v[5]+v[11] <= v[3]+0.01, v[7]+v[9] <= v[3]+0.01
      else { return nil }
      return v
    }
    if surfaces.isEmpty { return nil }
  }

  func visiblePath(in bounds: CGRect) -> CGPath? {
    guard abs(bounds.width - viewport.width) < 0.5,
      abs(bounds.height - viewport.height) < 0.5 else { return nil }
    var path = CGPath(rect: bounds, transform: nil)
    for v in surfaces {
      let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
      guard r.intersects(bounds) else { continue }
      let cutout = CGMutablePath()
      let k: CGFloat = 0.5522847498
      cutout.move(to: CGPoint(x: r.minX + v[4], y: r.minY))
      cutout.addLine(to: CGPoint(x: r.maxX - v[6], y: r.minY))
      cutout.addCurve(to: CGPoint(x: r.maxX, y: r.minY + v[7]),
        control1: CGPoint(x: r.maxX - v[6] * (1-k), y: r.minY),
        control2: CGPoint(x: r.maxX, y: r.minY + v[7] * (1-k)))
      cutout.addLine(to: CGPoint(x: r.maxX, y: r.maxY - v[9]))
      cutout.addCurve(to: CGPoint(x: r.maxX - v[8], y: r.maxY),
        control1: CGPoint(x: r.maxX, y: r.maxY - v[9] * (1-k)),
        control2: CGPoint(x: r.maxX - v[8] * (1-k), y: r.maxY))
      cutout.addLine(to: CGPoint(x: r.minX + v[10], y: r.maxY))
      cutout.addCurve(to: CGPoint(x: r.minX, y: r.maxY - v[11]),
        control1: CGPoint(x: r.minX + v[10] * (1-k), y: r.maxY),
        control2: CGPoint(x: r.minX, y: r.maxY - v[11] * (1-k)))
      cutout.addLine(to: CGPoint(x: r.minX, y: r.minY + v[5]))
      cutout.addCurve(to: CGPoint(x: r.minX + v[4], y: r.minY),
        control1: CGPoint(x: r.minX, y: r.minY + v[5] * (1-k)),
        control2: CGPoint(x: r.minX + v[4] * (1-k), y: r.minY))
      cutout.closeSubpath()
      path = path.subtracting(cutout)
    }
    return path
  }
}

public struct NativeChromeStateSpec: Equatable {
  /// Connection lease (protocol 2). Revisions are only compared within it.
  public let lease: String
  public let revision: Int
  public let top: NativeChromeTopSpec?
  public let tab: NativeChromeTabSpec?
  let bottomPresentation: NativeChromeBottomPresentation?
  // A malformed/temporarily unmeasurable optional presentation stays clipped
  // closed; it must not turn a partial root into a fully exposed native tab.
  let bottomPresentationRequested: Bool
  public let suspended: Bool
  let iosPopupForeground: NativeChromePopupForeground?
  public let dimColor: UIColor?
  public let dimDuration: TimeInterval
  public let rtl: Bool
  public let appearance: NativeChromeAppearanceSpec

  public init?(_ value: Any?) {
    guard let map = value as? [String: Any],
      (map["protocol"] as? NSNumber)?.intValue == 2,
      let lease = map["lease"] as? String
    else { return nil }
    self.lease = lease
    revision = (map["stateRevision"] as? NSNumber)?.intValue ?? 0
    top = NativeChromeTopSpec(map["top"])
    tab = NativeChromeTabSpec(map["tab"])
    bottomPresentation = NativeChromeBottomPresentation(map["bottomTransition"])
    bottomPresentationRequested = map["bottomTransition"] != nil && !(map["bottomTransition"] is NSNull)
    suspended = map["suspended"] as? Bool ?? false
    iosPopupForeground = suspended ? NativeChromePopupForeground(map["iosPopupForegrounds"]) : nil
    let dim = map["dim"] as? [String: Any]
    dimColor = NativeChromeAppearanceSpec.color(dim?["color"])
    dimDuration = Double((dim?["durationMs"] as? NSNumber)?.intValue ?? 0) / 1000
    rtl = map["rtl"] as? Bool ?? false
    appearance = NativeChromeAppearanceSpec(map["appearance"])
  }
}
