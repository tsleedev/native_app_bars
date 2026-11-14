import Flutter
import UIKit

/// Installs the native chrome host once at launch.
///
/// Call from `AppDelegate.application(_:didFinishLaunchingWithOptions:)` after
/// `super`, or from `SceneDelegate.scene(_:willConnectTo:options:)` after the
/// window is set up:
///
/// ```swift
/// NativeChromeHost.install(in: window)
/// ```
@objc public final class NativeChromeHost: NSObject {
  /// Wraps the window's FlutterViewController in a host container exactly once.
  /// Returns false when the window has no FlutterViewController root (the Dart
  /// side then falls back to the Flutter renderer and reports the reason).
  @discardableResult
  @objc public static func install(in window: UIWindow?) -> Bool {
    guard let window else { return false }
    if window.rootViewController is NativeChromeHostViewController { return true }
    guard let flutter = window.rootViewController as? FlutterViewController else { return false }
    let host = NativeChromeHostViewController(flutterViewController: flutter)
    window.rootViewController = host
    return true
  }
}

/// Container that owns the Flutter view controller as a child for its whole
/// lifetime. The top bar belongs to a `UINavigationController` in a sibling
/// chrome layer; the tab bar is a standalone `UITabBar` sibling (it does not
/// join a Duo system rail). Tab changes only change bar content; the Flutter
/// view controller is never re-parented.
public final class NativeChromeHostViewController: UIViewController, UINavigationBarDelegate,
  UITabBarDelegate
{
  /// The hosted content (the app's FlutterViewController in production).
  public let contentViewController: UIViewController
  public var flutterViewController: FlutterViewController? {
    contentViewController as? FlutterViewController
  }
  /// The top bar. It belongs to a real `UINavigationController` in a chrome
  /// layer that is a sibling of the content, so UIKit lays it out like any
  /// navigation bar (safe area, Duo system rail, vertical bar items) while
  /// the content view controller stays attached once and is never moved.
  public var navigationBar: UINavigationBar { chromeNavigationController.navigationBar }
  public let chromeNavigationController: UINavigationController
  private let chromeContainer = NativeChromePassThroughView()
  public let tabBar = UITabBar()
  private let topDim = UIView()
  private let bottomDim = UIView()

  private var state: NativeChromeStateSpec?
  private var appliedTop: NativeChromeTopSpec?
  private var appliedTopKey: (NativeChromeAppearanceSpec, Int)?
  private var appliedTabItems: [NativeChromeTabItemSpec]?
  private var appliedTabIconVersion = -1
  private var tabIds: [String] = []
  private var confirmedTabId: String?
  private var lastGeometry: [String: AnyHashable]?
  private var transitionSnapshot: UIView?
  /// Outgoing top bar items that UIKit placed outside the bar (Duo system
  /// rail), captured from the chrome layer only. Nil on iPhone layouts.
  private var transitionRailSnapshot: UIView?
  /// Diagnostics: how often rail items were snapshotted / dimmed.
  private(set) var railSnapshotCount = 0
  private(set) var railDimCount = 0

  /// App hook: called synchronously whenever the native top bar becomes
  /// hidden (`true`) or shown (`false`), in the same run loop turn, so an app
  /// can cover the frame gap with its own view (for example a proxy button at
  /// `hiddenActionSlotRect` until its Flutter overlay has painted).
  public var onTopBarHiddenChange: ((Bool) -> Void)?
  private var lastTopBarHidden = true

  /// Where a trailing action would sit if the hidden top bar were shown
  /// (measured with a probe item; Flutter view coordinates). Nil unless the
  /// current page's bar is hidden.
  public private(set) var hiddenActionSlotRect: CGRect?
  private var slotKey: String?
  private var slotMeasureScheduled = false
  private var transitionDirection: String?
  private var transitionRTL = false
  private var transitionId: Int?
  // `slide` (Cupertino page) or `fade` (other routes).
  private var transitionStyle = "slide"
  private var transitionProgress: CGFloat = 0
  /// Fade style only: the tab bar as it looked when the transition began,
  /// shown fading out if the tab bar hides during the transition.
  private var transitionTabSnapshot: UIView?
  private var transitionTabWasVisible = false
  /// Fade style only: multiplies the bar's own opacity (`top.opacity`).
  private var transitionChromeAlpha: CGFloat = 1
  private var baseChromeOpacity: Float = 1

  /// Counts native-side filtering, for tests and diagnostics.
  public private(set) var nativeFiltered = 0

  private let registerWithHub: Bool

  /// `registerWithHub: false` creates a detached host (unit tests) that does
  /// not replace the app's connection to Dart.
  public convenience init(flutterViewController: FlutterViewController) {
    self.init(content: flutterViewController, registerWithHub: true)
  }

  public init(content: UIViewController, registerWithHub: Bool) {
    self.contentViewController = content
    self.registerWithHub = registerWithHub
    self.chromeNavigationController = UINavigationController(rootViewController: NativeChromeBarRootViewController())
    super.init(nibName: nil, bundle: nil)
  }

  /// The navigation item the top bar shows.
  private var topNavigationItem: UINavigationItem {
    chromeNavigationController.viewControllers.first!.navigationItem
  }

  private func setTopBarHidden(_ hidden: Bool) {
    if chromeNavigationController.isNavigationBarHidden != hidden {
      chromeNavigationController.setNavigationBarHidden(hidden, animated: false)
    }
  }

  /// Top bar input (bar and any items UIKit moved into a system rail).
  private func setTopInteraction(_ enabled: Bool) {
    navigationBar.isUserInteractionEnabled = enabled
    chromeContainer.isUserInteractionEnabled = enabled
  }

  /// While a popup suspends the bars they leave the accessibility tree (the
  /// modal owns VoiceOver focus), including items in a Duo system rail.
  private var accessibilitySuspended = false
  private func setAccessibilitySuspended(_ hidden: Bool) {
    accessibilitySuspended = hidden
    navigationBar.accessibilityElementsHidden = hidden
    chromeContainer.accessibilityElementsHidden = hidden
    tabBar.accessibilityElementsHidden = hidden || bottomPresentationActive
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  public override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    addChild(contentViewController)
    contentViewController.view.frame = view.bounds
    view.addSubview(contentViewController.view)
    contentViewController.didMove(toParent: self)

    addChild(chromeNavigationController)
    chromeContainer.frame = view.bounds
    chromeContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    chromeNavigationController.view.frame = chromeContainer.bounds
    chromeNavigationController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    chromeNavigationController.view.backgroundColor = .clear
    chromeContainer.addSubview(chromeNavigationController.view)
    chromeContainer.navigationBar = navigationBar
    chromeContainer.transparentViews = [chromeNavigationController.view]
    chromeNavigationController.setNavigationBarHidden(true, animated: false)
    chromeNavigationController.interactivePopGestureRecognizer?.isEnabled = false
    navigationBar.accessibilityIdentifier = "native_chrome.topBar"
    tabBar.delegate = self
    tabBar.isHidden = true
    tabBar.accessibilityIdentifier = "native_chrome.tabBar"
    for dim in [topDim, bottomDim] {
      dim.isUserInteractionEnabled = false
      dim.alpha = 0
      dim.isAccessibilityElement = false
    }
    view.addSubview(chromeContainer)
    chromeNavigationController.didMove(toParent: self)
    view.addSubview(tabBar)
    // Compose solid chrome + its popup dim, then apply chromeContainer's
    // opacity once. A sibling dim would also repaint Flutter underneath.
    chromeContainer.layer.allowsGroupOpacity = true
    chromeContainer.addSubview(topDim)
    view.addSubview(bottomDim)
    if registerWithHub { NativeChromeHub.shared.hostDidInstall(self) }
  }

  // Let Flutter keep control of system UI.
  public override var childForStatusBarStyle: UIViewController? { contentViewController }
  public override var childForStatusBarHidden: UIViewController? { contentViewController }
  public override var childForHomeIndicatorAutoHidden: UIViewController? { contentViewController }
  public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    contentViewController.supportedInterfaceOrientations
  }

  public func position(for bar: UIBarPositioning) -> UIBarPosition { .topAttached }

  // MARK: Layout and geometry

  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let bounds = view.bounds
    let safe = view.safeAreaInsets
    contentViewController.view.frame = bounds
    // Keep the neutral layout independent of transition translation. Setting
    // frame here would compensate center and move transformed chrome back in.
    chromeContainer.bounds = CGRect(origin: .zero, size: bounds.size)
    chromeContainer.center = CGPoint(x: bounds.midX, y: bounds.midY)

    // Place the bar at the bottom first so its own safe area is known, then
    // ask for its fitting height (which includes the home indicator area).
    var tabHeight = max(49 + safe.bottom, 1)
    tabBar.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: tabHeight)
    tabBar.center = CGPoint(x: bounds.midX, y: bounds.maxY - tabHeight / 2)
    tabBar.layoutIfNeeded()
    let fitted = tabBar.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
    if fitted > 0 { tabHeight = fitted < safe.bottom + 1 ? fitted + safe.bottom : fitted }
    tabBar.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: tabHeight)
    tabBar.center = CGPoint(x: bounds.midX, y: bounds.maxY - tabHeight / 2)

    topDim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topBarBottom())
    bottomDim.bounds = tabBar.bounds
    bottomDim.center = tabBar.center
    applyBottomPresentation()
    if let snapshot = transitionSnapshot {
      snapshot.frame.size.width = bounds.width
    }
    // The probe layout below shows the bar invisibly; it must not publish a
    // visible bar or schedule another measurement.
    if measuringSlot { return }
    scheduleSlotMeasurement()
    publishGeometry()
  }

  private var measuringSlot = false

  private func notifyTopBarHidden() {
    let hidden = navigationBar.isHidden
    guard hidden != lastTopBarHidden else { return }
    lastTopBarHidden = hidden
    onTopBarHiddenChange?(hidden)
  }

  private func scheduleSlotMeasurement() {
    guard !slotMeasureScheduled else { return }
    slotMeasureScheduled = true
    // Measure after the current layout pass (the probe needs its own layout).
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.slotMeasureScheduled = false
      self.measureHiddenActionSlot()
    }
  }

  /// Measures the trailing action slot of the hidden bar by laying out an
  /// invisible probe item, then restores the hidden state.
  private func measureHiddenActionSlot() {
    guard let top = state?.top, top.presentation == "hidden", transitionId == nil else {
      if hiddenActionSlotRect != nil {
        hiddenActionSlotRect = nil
        slotKey = nil
        publishGeometry()
      }
      return
    }
    let content = contentViewController.view!
    let key = "\(view.bounds)|\(view.safeAreaInsets)|\(view.effectiveUserInterfaceLayoutDirection.rawValue)|"
      + "\((occlusionGeometry()["regions"] as? [[String: Double]]) ?? [])"
    if key == slotKey { return }
    let item = topNavigationItem
    let probe = UIView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    probe.translatesAutoresizingMaskIntoConstraints = false
    probe.isUserInteractionEnabled = false
    probe.isAccessibilityElement = false
    NSLayoutConstraint.activate([
      probe.widthAnchor.constraint(equalToConstant: 48),
      probe.heightAnchor.constraint(equalToConstant: 48),
    ])
    let probeItem = UIBarButtonItem(customView: probe)
    if #available(iOS 27.1, *) { probeItem.axisBehavior = .verticalPreferred }
    let savedLeading = item.leadingItemGroups
    let savedTrailing = item.trailingItemGroups
    let savedPinned = item.pinnedTrailingGroup
    let savedTitle = item.title
    let savedTitleView = item.titleView
    item.leadingItemGroups = []
    item.title = nil
    item.titleView = nil
    // The slot a pinned trailing action would take (available since iOS 16).
    item.trailingItemGroups = []
    item.pinnedTrailingGroup = UIBarButtonItemGroup(barButtonItems: [probeItem], representativeItem: nil)
    if #available(iOS 27.1, *) { item.verticalBarCompressionBehavior = .prefersBarItems }
    // Everything below runs in one main-thread turn: no touch or VoiceOver
    // query can reach the bar in between. It is still made inert and silent.
    let opacity = chromeContainer.layer.opacity
    let interaction = chromeContainer.isUserInteractionEnabled
    measuringSlot = true
    chromeContainer.layer.opacity = 0
    setTopInteraction(false)
    let savedBarAccessibilityHidden = navigationBar.accessibilityElementsHidden
    navigationBar.accessibilityElementsHidden = true
    setTopBarHidden(false)
    view.setNeedsLayout()
    view.layoutIfNeeded()
    navigationBar.layoutIfNeeded()
    probe.superview?.layoutIfNeeded()
    let measured = probe.window == nil ? nil : probe.convert(probe.bounds, to: content)
    item.pinnedTrailingGroup = savedPinned
    item.trailingItemGroups = savedTrailing
    item.leadingItemGroups = savedLeading
    item.title = savedTitle
    item.titleView = savedTitleView
    setTopBarHidden(true)
    navigationBar.accessibilityElementsHidden = savedBarAccessibilityHidden
    setTopInteraction(interaction)
    chromeContainer.layer.opacity = opacity
    measuringSlot = false
    let rect = measured?.standardized.intersection(content.bounds)
    let valid = rect.flatMap { r -> CGRect? in
      r.isNull || r.isEmpty || !r.minX.isFinite || !r.minY.isFinite ? nil : r
    }
    // Not attached to a window yet: measure again on the next layout even if
    // the key is unchanged.
    slotKey = measured == nil ? nil : key
    if valid != hiddenActionSlotRect {
      hiddenActionSlotRect = valid
      publishGeometry()
    }
    debugLog("hidden action slot \(String(describing: valid))")
  }

  /// Bottom of the top bar in this view (UIKit places the bar; in a Duo
  /// system rail layout the bar is lower than the safe area top).
  private func topBarBottom() -> CGFloat {
    let barBottom = navigationBar.convert(navigationBar.bounds, to: view).maxY
    if !navigationBar.isHidden { lastTopBarBottom = barBottom }
    return navigationBar.isHidden ? lastTopBarBottom : barBottom
  }

  private var lastTopBarBottom: CGFloat = 0

  /// Top bar controls that UIKit laid out entirely below the bar (iOS 27.1
  /// Duo system rail: they live in the navigation controller's floating bar
  /// container, outside `navigationBar`). Empty when every item is in the bar
  /// (iPhone), so rail handling never runs there.
  private func railControls() -> [UIView] {
    guard !navigationBar.isHidden else { return [] }
    let barBottom = topBarBottom()
    var found: [UIView] = []
    func visible(_ v: UIView) -> Bool {
      var current: UIView? = v
      while let c = current, c !== chromeContainer {
        if c.isHidden || c.alpha <= 0.01 { return false }
        current = c.superview
      }
      return current === chromeContainer
    }
    func walk(_ v: UIView) {
      if v === navigationBar { return }
      if v is UIControl {
        let frame = v.convert(v.bounds, to: view)
        if frame.width > 0, frame.height > 0, frame.minY >= barBottom - 0.5, visible(v) {
          found.append(v)
          return
        }
      }
      v.subviews.forEach(walk)
    }
    walk(chromeNavigationController.view)
    return found
  }

  public func geometry() -> [String: Any] {
    let safe = view.safeAreaInsets
    return [
      "hostInstalled": true,
      "topInset": Double(safe.top),
      "topBarHeight": Double(max(0, topBarBottom() - safe.top)),
      "topBarVisible": !navigationBar.isHidden,
      "tabBarHeight": Double(tabBar.bounds.height),
      // Presentation clips/transforms do not change logical geometry/slots.
      "tabBarVisible": (state?.tab).map { !$0.hidden && !$0.items.isEmpty } ?? false,
      "occlusion": occlusionGeometry(),
      "hiddenActionSlot": hiddenActionSlotRect.map {
        ["left": Double($0.minX), "top": Double($0.minY), "width": Double($0.width), "height": Double($0.height)]
          as Any
      } ?? NSNull(),
    ]
  }

  /// System occlusion regions (iOS 27.1 `reservedRegions(kind: .occlusion)`,
  /// for example foldable hinge/camera areas) in Flutter view coordinates.
  private func occlusionGeometry() -> [String: Any] {
    let content = contentViewController.view!
    if #available(iOS 27.1, *) {
      let regions: [[String: Double]] = content.reservedRegions(kind: .occlusion)
        .filter(\.isActive)
        .compactMap { region in
          let frame = region.frame.standardized.intersection(content.bounds)
          guard !frame.isNull, !frame.isEmpty, frame.minX.isFinite, frame.minY.isFinite else { return nil }
          return ["left": Double(frame.minX), "top": Double(frame.minY),
                  "width": Double(frame.width), "height": Double(frame.height)]
        }
      return ["supported": true, "regions": regions]
    }
    return ["supported": false, "regions": [] as [[String: Double]]]
  }

  private func publishGeometry() {
    let current = geometry()
    let hashable = current.mapValues { value -> AnyHashable in
      (value as? AnyHashable) ?? AnyHashable(String(describing: value))
    }
    guard hashable != lastGeometry else { return }
    lastGeometry = hashable
    NativeChromeHub.shared.send("geometry", current)
  }

  // MARK: State

  func reapply() {
    if let state { apply(state) }
  }

  /// Drops the current connection's state: hides both bars, ends any
  /// transition and suspension dim, and lets touches reach Flutter.
  public func clear() {
    loadViewIfNeeded()
    endTransition()
    restoreForegroundDim()
    state = nil
    applyBottomPresentation()
    appliedTop = nil
    appliedTopKey = nil
    appliedTabItems = nil
    confirmedTabId = nil
    setTopBarHidden(true)
    tabBar.isHidden = true
    hiddenActionSlotRect = nil
    slotKey = nil
    notifyTopBarHidden()
    topDim.alpha = 0
    bottomDim.alpha = 0
    chromeContainer.layer.opacity = 1
    setTopInteraction(true)
    tabBar.isUserInteractionEnabled = true
    setAccessibilitySuspended(false)
    view.setNeedsLayout()
    view.layoutIfNeeded()
    publishGeometry()
    debugLog("cleared")
  }

  public func apply(_ next: NativeChromeStateSpec) {
    loadViewIfNeeded()
    debugLog(
      "apply rev=\(next.revision) top=\(next.top?.title ?? "-") tabs=\(next.tab?.items.map(\.label) ?? []) "
        + "selected=\(next.tab?.selectedId ?? "-") suspended=\(next.suspended)")
    let previous = state
    let atomicBottom = bottomPresentationActive || next.bottomPresentationRequested
    if atomicBottom {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
    }
    defer { if atomicBottom { CATransaction.commit() } }
    state = next
    let appearance = next.appearance
    let style: UIUserInterfaceStyle = appearance.dark ? .dark : .light
    // The top bar's style is per bar (applyTop).
    tabBar.overrideUserInterfaceStyle = style
    // The top bar's tint is per bar (foreground ?? appearance tint) and is
    // owned by applyTop, also when its items are reused.
    if let tint = appearance.tint { tabBar.tintColor = tint }
    if let unselected = appearance.unselected { tabBar.unselectedItemTintColor = unselected }
    view.semanticContentAttribute = next.rtl ? .forceRightToLeft : .forceLeftToRight

    // Layer opacity preserves UIKit hit testing and AX at alpha zero.
    // Snapshots already bake this alpha; never multiply the snapshot again.
    baseChromeOpacity = Float(next.top?.opacity ?? 1)
    chromeContainer.layer.opacity = baseChromeOpacity * Float(transitionChromeAlpha)
    applyTop(next.top, appearance: appearance)
    notifyTopBarHidden()
    scheduleSlotMeasurement()
    // One synchronous state update selects canonical ownership and its clip.
    // Borrow outgoing root contents only while its native presentation lives.
    applyTab(next.bottomPresentation?.tab ?? next.tab, appearance: appearance)
    applySuspension(next, previous: previous)
    view.setNeedsLayout()
    view.layoutIfNeeded()
    applyBottomPresentation()
    // the state that arrives after `transition begin` (the
    // incoming bar, a tab bar hiding or showing) joins the running transition.
    if transitionId != nil { setTransitionProgress(transitionProgress) }
    publishGeometry()
  }

  private func applyTop(_ top: NativeChromeTopSpec?, appearance: NativeChromeAppearanceSpec) {
    guard let top, top.presentation != "hidden" else {
      navigationBar.overrideUserInterfaceStyle = appearance.dark ? .dark : .light
      setTopBarHidden(true)
      return
    }
    setTopBarHidden(false)
    // Replacing bar button items while a finger is down loses the tap; only
    // rebuild when this bar's content, appearance or icons changed.
    let iconVersion = NativeChromeHub.shared.iconVersion
    let effectiveTint = top.foreground ?? appearance.foreground ?? appearance.tint
    // A per-bar background decides the bar's light/dark style, so system
    // materials (iOS 26+ glass platters) match that background.
    let barStyle: UIUserInterfaceStyle = top.background.map { Self.isDark($0) ? .dark : .light }
      ?? (appearance.dark ? .dark : .light)
    if navigationBar.overrideUserInterfaceStyle != barStyle { navigationBar.overrideUserInterfaceStyle = barStyle }
    if let appliedTop, top.hasSameItems(as: appliedTop), let key = appliedTopKey,
      key.0 == appearance, key.1 == iconVersion {
      // Items are reused; only restore the bar's own tint (cheap, no rebuild).
      if navigationBar.tintColor != effectiveTint { navigationBar.tintColor = effectiveTint }
      setTopInteraction(!(state?.suspended ?? false) && transitionId == nil)
      return
    }
    appliedTop = top
    appliedTopKey = (appearance, iconVersion)
    let background = top.background ?? appearance.background
    let foreground = top.foreground ?? appearance.foreground
    let bar = UINavigationBarAppearance()
    if top.presentation == "transparent" {
      bar.configureWithTransparentBackground()
    } else if let background {
      bar.configureWithOpaqueBackground()
      bar.backgroundColor = background
      bar.shadowColor = .clear
    } else {
      bar.configureWithDefaultBackground()
    }
    if let foreground {
      bar.titleTextAttributes = [.foregroundColor: foreground]
    }
    navigationBar.standardAppearance = bar
    navigationBar.compactAppearance = bar
    navigationBar.scrollEdgeAppearance = bar
    navigationBar.tintColor = effectiveTint

    let item = topNavigationItem
    let leadingTitle = top.titleAlignment != "platform"
    var leadingGroups: [UIBarButtonItemGroup] = []
    if let leading = top.leading {
      leadingGroups.append(UIBarButtonItemGroup(barButtonItems: [barButton(leading, top: top, foreground: foreground)], representativeItem: nil))
    }
    if leadingTitle {
      item.title = nil
      item.titleView = nil
      leadingGroups.append(
        UIBarButtonItemGroup(barButtonItems: [titleItem(top, foreground: foreground)], representativeItem: nil))
    } else if top.titleAction != nil {
      item.title = nil
      item.titleView = titleButton(top, foreground: foreground, expanded: false)
    } else {
      item.titleView = nil
      item.title = top.title
    }
    item.leftItemsSupplementBackButton = false
    item.leftBarButtonItems = nil
    item.leadingItemGroups = leadingGroups
    let trailing = top.actions.map { barButton($0, top: top, foreground: foreground) }
    // Default: actions keep their order (rightBarButtonItems lists from the
    // trailing edge, hence reversed). Opt-in: the first action is pinned; the
    // pinned group sits at the trailing edge and stays in compact bars.
    if top.pinFirstAction, let first = trailing.first {
      item.pinnedTrailingGroup = UIBarButtonItemGroup(barButtonItems: [first], representativeItem: nil)
      item.rightBarButtonItems = Array(trailing.dropFirst().reversed())
    } else {
      item.pinnedTrailingGroup = nil
      item.rightBarButtonItems = Array(trailing.reversed())
    }
    if #available(iOS 27.1, *) {
      item.verticalBarCompressionBehavior = .prefersBarItems
    }
    setTopInteraction(!(state?.suspended ?? false) && transitionId == nil)
  }

  private func titleButton(_ top: NativeChromeTopSpec, foreground: UIColor?, expanded: Bool) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.title = top.title
    configuration.image = NativeChromeHub.shared.icon(for: top.titleAction?.icon)
    // Leading titles read like a back affordance (icon first); centred titles
    // read like a picker (icon after the text).
    configuration.imagePlacement = top.titleAlignment == "platform" ? .trailing : .leading
    configuration.imagePadding = 6
    configuration.contentInsets = .zero
    configuration.baseForegroundColor = foreground ?? .label
    // A loading title action shows a spinner in place of its icon.
    configuration.showsActivityIndicator = top.titleAction?.loading ?? false
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = .preferredFont(forTextStyle: expanded ? .title2 : .headline)
      return outgoing
    }
    let stamp = top.stamp
    let action = top.titleAction
    let button = UIButton(
      configuration: configuration,
      primaryAction: UIAction { [weak self] _ in
        if let action { self?.emitTop(action, stamp: stamp) }
      })
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.isEnabled = action?.enabled ?? false
    button.isUserInteractionEnabled = action != nil
    button.accessibilityLabel = action?.label ?? top.title
    button.accessibilityIdentifier = "native_chrome.top.\(action?.id ?? "title")"
    if action == nil { button.accessibilityTraits = .header }
    return button
  }

  private func titleItem(_ top: NativeChromeTopSpec, foreground: UIColor?) -> UIBarButtonItem {
    let button = titleButton(top, foreground: foreground, expanded: top.titleAlignment == "expandedLeading")
    let item = UIBarButtonItem(customView: button)
    item.isEnabled = top.titleAction?.enabled ?? true
    if #available(iOS 26.0, *) { item.hidesSharedBackground = true }
    if #available(iOS 27.1, *) { item.axisBehavior = .horizontalOnly }
    return item
  }

  /// `foreground` (per bar, else appearance) is applied to the item itself:
  /// on iOS 26+ glass, `UINavigationBar.tintColor` does not colour bar item
  /// content (measured on iOS 27.0; `item.tintColor` does).
  static func isDark(_ color: UIColor) -> Bool {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
    return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5
  }

  private func barButton(
    _ action: NativeChromeActionSpec, top: NativeChromeTopSpec, foreground: UIColor?
  ) -> UIBarButtonItem {
    let identifier = "native_chrome.top.\(action.id)"
    if action.loading {
      let indicator = UIActivityIndicatorView(style: .medium)
      if let foreground { indicator.color = foreground }
      indicator.startAnimating()
      indicator.accessibilityLabel = action.label
      indicator.accessibilityIdentifier = identifier
      let item = UIBarButtonItem(customView: indicator)
      item.isEnabled = false
      item.accessibilityIdentifier = identifier
      if #available(iOS 27.1, *) { item.axisBehavior = action.style == "icon" ? .verticalPreferred : .horizontalOnly }
      return item
    }
    let stamp = top.stamp
    let image = action.style == "icon" ? NativeChromeHub.shared.icon(for: action.icon) : nil
    return NativeChromeBarButton.button(
      label: action.label, image: image, identifier: identifier, enabled: action.enabled,
      done: action.style == "done", tint: foreground
    ) { [weak self] in self?.emitTop(action, stamp: stamp) }
  }

  private func emitTop(_ action: NativeChromeActionSpec, stamp: NativeChromeOwnerStamp) {
    // First-line filter; Dart remains the final authority.
    guard action.enabled, !(state?.suspended ?? false), transitionId == nil,
      state?.top?.stamp.ownerToken == stamp.ownerToken
    else {
      nativeFiltered += 1
      debugLog("filtered topAction \(action.id)")
      return
    }
    debugLog("emit topAction \(action.id)")
    guard let lease = state?.lease else { return }
    var args = stamp.wire
    args["type"] = "topAction"
    args["actionId"] = action.id
    args["lease"] = lease
    args["requestId"] = NativeChromeHub.shared.nextRequestId()
    NativeChromeHub.shared.send("event", args)
  }

  private func applyTab(_ tab: NativeChromeTabSpec?, appearance: NativeChromeAppearanceSpec) {
    guard let tab, !tab.hidden, !tab.items.isEmpty else {
      tabBar.isHidden = true
      return
    }
    tabBar.isHidden = false
    let bar = UITabBarAppearance()
    if let background = appearance.background {
      bar.configureWithOpaqueBackground()
      bar.backgroundColor = background
    } else {
      bar.configureWithDefaultBackground()
    }
    tabBar.standardAppearance = bar
    tabBar.scrollEdgeAppearance = bar

    let ids = tab.items.map(\.id)
    if ids != tabIds || tabBar.items?.count != ids.count {
      tabIds = ids
      let items = tab.items.enumerated().map { index, _ in UITabBarItem(title: nil, image: nil, tag: index) }
      tabBar.setItems(items, animated: false)
    }
    let items = tabBar.items ?? []
    let iconVersion = NativeChromeHub.shared.iconVersion
    let previousItems = appliedTabIconVersion == iconVersion ? appliedTabItems : nil
    appliedTabItems = tab.items
    appliedTabIconVersion = iconVersion
    for (index, spec) in tab.items.enumerated() where index < items.count {
      let item = items[index]
      let previous = previousItems.flatMap { index < $0.count ? $0[index] : nil }
      if previous?.badge != spec.badge || previous == nil { item.badgeValue = spec.badge }
      if previous?.accessibilityValue != spec.accessibilityValue || previous == nil {
        item.accessibilityValue = spec.accessibilityValue
      }
      if let previous, previous.id == spec.id, previous.label == spec.label, previous.icon == spec.icon,
        previous.selectedIcon == spec.selectedIcon, previous.enabled == spec.enabled
      {
        continue
      }
      item.title = spec.label
      item.image = NativeChromeHub.shared.icon(for: spec.icon)
      item.selectedImage = NativeChromeHub.shared.icon(for: spec.selectedIcon ?? spec.icon)
      item.isEnabled = spec.enabled
      item.accessibilityLabel = spec.label
      item.accessibilityIdentifier = "native_chrome.tab.\(spec.id)"
    }
    confirmedTabId = tab.selectedId
    if let index = ids.firstIndex(of: tab.selectedId), index < items.count {
      tabBar.selectedItem = items[index]
    } else {
      tabBar.selectedItem = nil
    }
    tabBar.isUserInteractionEnabled = !(state?.suspended ?? false) && !bottomPresentationActive
  }

  public func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    // Request only: show the Dart-confirmed selection until Dart answers with
    // a new state. This mirrors Android, where the listener returns false.
    restoreConfirmedSelection()
    // UIKit (iOS 26+ glass bars) can re-apply the touched item after this
    // delegate returns; restore again on the next run loop turn. Dart answers
    // with a new state if it accepts the request.
    DispatchQueue.main.async { [weak self] in
      self?.restoreConfirmedSelection()
      self?.debugLog("after request selected=\(self?.tabBar.selectedItem.map { self?.tabIds[$0.tag] ?? "" } ?? "-")")
    }
    guard let tab = state?.tab, item.tag >= 0, item.tag < tabIds.count, item.isEnabled,
      !(state?.suspended ?? false), !bottomPresentationActive
    else {
      nativeFiltered += 1
      debugLog("filtered tabRequest tag=\(item.tag)")
      return
    }
    debugLog("emit tabRequest \(tabIds[item.tag])")
    var args = tab.stamp.wire
    args["type"] = "tabRequest"
    args["tabId"] = tabIds[item.tag]
    args["lease"] = state?.lease ?? ""
    args["requestId"] = NativeChromeHub.shared.nextRequestId()
    NativeChromeHub.shared.send("event", args)
  }

  private func restoreConfirmedSelection() {
    let items = tabBar.items ?? []
    if let confirmed = confirmedTabId, let index = tabIds.firstIndex(of: confirmed), index < items.count {
      if tabBar.selectedItem !== items[index] { tabBar.selectedItem = items[index] }
    }
  }

  private func applySuspension(_ next: NativeChromeStateSpec, previous: NativeChromeStateSpec?) {
    let wasDimmed = previous?.dimColor != nil && (previous?.suspended ?? false)
    let dimmed = next.suspended && next.dimColor != nil
    // Only a bar with a solid background colour hides the Flutter content
    // behind it. Transparent bars and the default (translucent system
    // material) bar show Flutter content, which the popup barrier already
    // dims: dim only their foreground (exactly once). A solid bar gets the
    // dim layer.
    // Before iOS 26 the default bar background is a nearly opaque system
    // material (measured on iOS 18.6: 247 → 234 under a 54 % barrier), so it
    // takes the dim layer like a solid bar; from iOS 26 it is glass.
    func showsFlutterBehind(_ spec: NativeChromeStateSpec?) -> Bool {
      guard let top = spec?.top else { return false }
      if top.presentation == "transparent" { return true }
      guard (top.background ?? spec?.appearance.background) == nil else { return false }
      if #available(iOS 26.0, *) { return true }
      return false
    }
    let transparentTop = showsFlutterBehind(next)
    let wasTransparentTop = showsFlutterBehind(previous)
    if let color = next.dimColor {
      topDim.backgroundColor = color
      bottomDim.backgroundColor = color
    }
    let topDimWasHidden = topDim.isHidden
    let bottomDimWasHidden = bottomDim.isHidden
    topDim.isHidden = navigationBar.isHidden || transparentTop
    bottomDim.isHidden = tabBar.isHidden
    if dimmed != wasDimmed || transparentTop != wasTransparentTop {
      let duration = dimmed ? next.dimDuration : (previous?.dimDuration ?? 0.2)
      let topTarget: CGFloat = dimmed && !transparentTop ? 1 : 0
      let bottomTarget: CGFloat = dimmed ? 1 : 0
      // a dim layer that was hidden was never seen, so it
      // takes its value at once. Fading it would show a stale dim on a bar
      // that just appeared (for example a solid bar pushed over a sheet that
      // suspended a hidden bar: measured 0.97 -> 0 over ~300 ms).
      if topDimWasHidden {
        topDim.layer.removeAllAnimations()
        topDim.alpha = topTarget
      }
      if bottomDimWasHidden {
        bottomDim.layer.removeAllAnimations()
        bottomDim.alpha = bottomTarget
      }
      UIView.animate(withDuration: max(0, duration)) {
        if !topDimWasHidden { self.topDim.alpha = topTarget }
        if !bottomDimWasHidden { self.bottomDim.alpha = bottomTarget }
      }
    }
    restoreForegroundDim()
    if dimmed, transparentTop, !navigationBar.isHidden, let color = next.dimColor {
      var alpha: CGFloat = 0
      color.getWhite(nil, alpha: &alpha)
      applyForegroundDim(factor: max(0, 1 - alpha))
    } else if dimmed, !navigationBar.isHidden, let color = next.dimColor {
      // Solid bar: the dim layer covers the bar strip only. Items UIKit moved
      // into a system rail (Duo) sit outside it; fade just those, once.
      let rail = railControls()
      if !rail.isEmpty {
        var alpha: CGFloat = 0
        color.getWhite(nil, alpha: &alpha)
        let factor = max(0, 1 - alpha)
        for control in rail {
          dimmedViewAlphas.append((control, control.alpha))
          control.alpha *= factor
        }
        railDimCount += 1
      }
    }
    setTopInteraction(!next.suspended && transitionId == nil)
    tabBar.isUserInteractionEnabled = !next.suspended && !bottomPresentationActive
    tabBar.accessibilityElementsHidden = next.suspended || bottomPresentationActive
    if accessibilitySuspended != next.suspended { setAccessibilitySuspended(next.suspended) }
  }

  // MARK: Foreground dim (transparent top bar under a popup barrier)

  private var dimmedItemTints: [(UIBarButtonItem, UIColor?)] = []
  private var dimmedButtonConfigs: [(UIButton, UIButton.Configuration?)] = []
  private var dimmedViewAlphas: [(UIView, CGFloat)] = []
  private var dimmedAppearance: (item: UINavigationBarAppearance, original: UINavigationBarAppearance)?

  private func currentBarItems() -> [UIBarButtonItem] {
    guard let item = navigationBar.topItem else { return [] }
    var items = item.leadingItemGroups.flatMap(\.barButtonItems)
    items += item.rightBarButtonItems ?? []
    items += item.pinnedTrailingGroup?.barButtonItems ?? []
    var seen = Set<ObjectIdentifier>()
    return items.filter { seen.insert(ObjectIdentifier($0)).inserted }
  }

  private func applyForegroundDim(factor: CGFloat) {
    let barTint = navigationBar.tintColor ?? .label
    for barItem in currentBarItems() {
      dimmedItemTints.append((barItem, barItem.tintColor))
      let base = barItem.tintColor ?? barTint
      barItem.tintColor = base.withAlphaComponent(base.cgColor.alpha * factor)
      if let custom = barItem.customView { dimForeground(of: custom, factor: factor) }
    }
    if let titleView = navigationBar.topItem?.titleView { dimForeground(of: titleView, factor: factor) }
    let original = navigationBar.standardAppearance
    let dimmed = original.copy() as! UINavigationBarAppearance
    var attributes = dimmed.titleTextAttributes
    let color = (attributes[.foregroundColor] as? UIColor) ?? .label
    attributes[.foregroundColor] = color.withAlphaComponent(color.cgColor.alpha * factor)
    dimmed.titleTextAttributes = attributes
    navigationBar.standardAppearance = dimmed
    navigationBar.compactAppearance = dimmed
    navigationBar.scrollEdgeAppearance = dimmed
    // The property copies on set; remember the instance the bar now holds.
    dimmedAppearance = (navigationBar.standardAppearance, original)
  }

  /// UIKit manages the alpha of title views and item custom views itself, so
  /// a title button is dimmed through its configuration colour instead.
  private func dimForeground(of view: UIView, factor: CGFloat) {
    if let button = view as? UIButton, var configuration = button.configuration {
      dimmedButtonConfigs.append((button, button.configuration))
      let base = configuration.baseForegroundColor ?? navigationBar.tintColor ?? .label
      configuration.baseForegroundColor = base.withAlphaComponent(base.cgColor.alpha * factor)
      button.configuration = configuration
    } else {
      dimmedViewAlphas.append((view, view.alpha))
      view.alpha *= factor
    }
  }

  private func restoreForegroundDim() {
    for (button, configuration) in dimmedButtonConfigs { button.configuration = configuration }
    dimmedButtonConfigs.removeAll()
    for (item, tint) in dimmedItemTints { item.tintColor = tint }
    for (view, alpha) in dimmedViewAlphas { view.alpha = alpha }
    dimmedItemTints.removeAll()
    dimmedViewAlphas.removeAll()
    // Restore the title colour only if the bar still uses our dimmed copy
    // (a rebuild while dimmed already installed a fresh appearance).
    if let saved = dimmedAppearance, navigationBar.standardAppearance === saved.item {
      navigationBar.standardAppearance = saved.original
      navigationBar.compactAppearance = saved.original
      navigationBar.scrollEdgeAppearance = saved.original
    }
    dimmedAppearance = nil
  }

  // MARK: Root tab presentation (independent of top snapshots)

  private var bottomPresentationActive: Bool { state?.bottomPresentationRequested ?? false }

  private func applyBottomPresentation() {
    let active = bottomPresentationActive
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    tabBar.transform = .identity
    bottomDim.transform = .identity
    tabBar.isUserInteractionEnabled = !(state?.suspended ?? false) && !active
    tabBar.accessibilityElementsHidden = (state?.suspended ?? false) || active
    guard active else {
      tabBar.layer.mask = nil
      bottomDim.layer.mask = nil
      return
    }
    var visible = CGRect.zero
    if let presentation = state?.bottomPresentation,
      abs(presentation.viewport.width - contentViewController.view.bounds.width) < 0.001,
      abs(presentation.viewport.height - contentViewController.view.bounds.height) < 0.001
    {
      // Flutter logical view coordinates -> content -> Host. Full-page,
      // axis-aligned horizontal footprints were admitted by both endpoints.
      let content = contentViewController.view!
      let root = content.convert(presentation.root, to: view)
      let cover = content.convert(presentation.cover, to: view)
      let viewport = content.convert(content.bounds, to: view).intersection(view.bounds)
      let dx = root.minX - viewport.minX
      tabBar.transform = CGAffineTransform(translationX: dx, y: 0)
      bottomDim.transform = tabBar.transform
      let edge = (state?.rtl ?? false) ? cover.maxX : cover.minX
      let gap: CGRect
      if state?.rtl ?? false {
        gap = CGRect(x: max(viewport.minX, min(viewport.maxX, edge)), y: viewport.minY,
          width: max(0, viewport.maxX - max(viewport.minX, edge)), height: viewport.height)
      } else {
        gap = CGRect(x: viewport.minX, y: viewport.minY,
          width: max(0, min(viewport.maxX, edge) - viewport.minX), height: viewport.height)
      }
      visible = gap.intersection(root).intersection(viewport)
    }
    // Invalid or stale-size measurements never reuse the prior frame's clip.
    // The actual full-width tab remains measured at its neutral bounds/center.
    for layerView in [tabBar, bottomDim] {
      let mask = (layerView.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
      mask.frame = layerView.bounds
      let local = visible.isNull || visible.isEmpty ? CGRect.zero :
        layerView.convert(visible, from: view).intersection(layerView.bounds)
      mask.path = UIBezierPath(rect: local.isNull ? .zero : local).cgPath
      layerView.layer.mask = mask
    }
  }

  // MARK: Transitions

  func transition(_ map: [String: Any]) {
    let phase = map["phase"] as? String
    let id = (map["id"] as? NSNumber)?.intValue
    let progress = CGFloat((map["progress"] as? NSNumber)?.doubleValue ?? 0)
    switch phase {
    case "begin":
      endTransition()
      let direction = map["direction"] as? String ?? "push"
      // older Dart sends no style; it always slid.
      let style = map["style"] as? String ?? "slide"
      // a hidden outgoing bar has nothing to snapshot, but the
      // incoming bar still moves with its page (bar-less page -> bar page).
      var snapshot: UIView?
      var railSnapshot: UIView?
      if !navigationBar.isHidden {
        let height = topBarBottom()
        if let strip = view.resizableSnapshotView(
          from: CGRect(x: 0, y: 0, width: view.bounds.width, height: height),
          afterScreenUpdates: false, withCapInsets: .zero)
        {
          strip.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
          strip.isUserInteractionEnabled = false
          snapshot = strip
        }
        // Rail items (Duo) are outside the strip above: capture them from the
        // chrome layer alone (no Flutter content) so they leave with the bar.
        let rail = railControls()
        if snapshot != nil, !rail.isEmpty {
          let rect = rail.map { $0.convert($0.bounds, to: view) }.reduce(CGRect.null) { $0.union($1) }
            .insetBy(dx: -8, dy: -8).intersection(view.bounds)
          if !rect.isNull, !rect.isEmpty,
            let railView = chromeContainer.resizableSnapshotView(
              from: chromeContainer.convert(rect, from: view), afterScreenUpdates: false, withCapInsets: .zero)
          {
            railView.frame = rect
            railView.isUserInteractionEnabled = false
            railSnapshot = railView
            railSnapshotCount += 1
          }
        }
      }
      for outgoing in [snapshot, railSnapshot].compactMap({ $0 }) {
        if direction == "push" && style == "slide" {
          view.insertSubview(outgoing, belowSubview: chromeContainer)
        } else {
          view.insertSubview(outgoing, aboveSubview: chromeContainer)
        }
      }
      // A fade route can hide (or reveal) the tab bar: keep its look so it
      // fades with the page instead of vanishing in one frame.
      transitionTabWasVisible = !tabBar.isHidden
      if style == "fade", !tabBar.isHidden,
        let tabView = tabBar.snapshotView(afterScreenUpdates: false)
      {
        tabView.frame = tabBar.frame
        tabView.isUserInteractionEnabled = false
        tabView.accessibilityElementsHidden = true
        tabView.alpha = 0
        view.insertSubview(tabView, aboveSubview: tabBar)
        transitionTabSnapshot = tabView
      }
      transitionSnapshot = snapshot
      transitionRailSnapshot = railSnapshot
      transitionDirection = direction
      transitionStyle = style
      transitionRTL = map["rtl"] as? Bool ?? false
      transitionId = id
      setTopInteraction(false)
      setTransitionProgress(progress)
    case "update":
      guard id == transitionId else { return }
      setTransitionProgress(progress)
    case "end":
      guard id == transitionId else { return }
      endTransition()
    default:
      break
    }
  }

  private func setTransitionProgress(_ progress: CGFloat) {
    guard transitionId != nil else { return }
    let width = view.bounds.width
    let sign: CGFloat = transitionRTL ? -1 : 1
    let p = min(max(progress, 0), 1)
    transitionProgress = p
    let outgoing = [transitionSnapshot, transitionRailSnapshot].compactMap { $0 }
    if transitionStyle == "fade" {
      // a route that does not slide (for example a fade) cross-fades
      // the bars in place instead of sliding them across a still page.
      chromeContainer.transform = .identity
      chromeContainer.layer.mask = nil
      setTransitionChromeAlpha(p)
      for snapshot in outgoing {
        snapshot.transform = .identity
        snapshot.layer.mask = nil
        snapshot.alpha = 1 - p
      }
      if let tabView = transitionTabSnapshot { tabView.alpha = tabBar.isHidden ? 1 - p : 0 }
      tabBar.alpha = !transitionTabWasVisible && !tabBar.isHidden ? p : 1
      return
    }
    setTransitionChromeAlpha(1)
    if transitionDirection == "push" {
      chromeContainer.transform = CGAffineTransform(translationX: sign * (1 - p) * width, y: 0)
      chromeContainer.layer.mask = nil
      // the outgoing bar (a strip of the outgoing page) stays
      // only where the outgoing page still shows, left of the incoming page
      // edge, and fades like a UINavigationController push. Before, it stayed
      // whole and opaque under the incoming glass bar until the end.
      let edge = sign > 0 ? (1 - p) * width : p * width
      let visible = sign > 0
        ? CGRect(x: 0, y: 0, width: max(0, edge), height: view.bounds.height)
        : CGRect(x: edge, y: 0, width: max(0, width - edge), height: view.bounds.height)
      for snapshot in outgoing {
        snapshot.transform = CGAffineTransform(translationX: -sign * 0.3 * p * width, y: 0)
        snapshot.alpha = 1 - p
        clip(snapshot, to: visible)
      }
    } else {
      for snapshot in outgoing {
        snapshot.transform = CGAffineTransform(translationX: sign * p * width, y: 0)
        snapshot.alpha = 1
        snapshot.layer.mask = nil
      }
      chromeContainer.transform = CGAffineTransform(translationX: -sign * 0.3 * (1 - p) * width, y: 0)
      if transitionSnapshot == nil {
        // no outgoing bar covers the incoming one; show it only
        // where the outgoing (bar-less) page has uncovered the page below.
        let edge = sign > 0 ? p * width : (1 - p) * width
        let visible = sign > 0
          ? CGRect(x: 0, y: 0, width: max(0, edge), height: view.bounds.height)
          : CGRect(x: edge, y: 0, width: max(0, width - edge), height: view.bounds.height)
        clip(chromeContainer, to: visible)
      } else {
        chromeContainer.layer.mask = nil
      }
    }
  }

  /// Masks [target] to [rect] (Host view coordinates, transform included).
  private func clip(_ target: UIView, to rect: CGRect) {
    let mask = (target.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mask.frame = target.bounds
    let local = target.convert(rect, from: view).intersection(target.bounds)
    mask.path = UIBezierPath(rect: local.isNull ? .zero : local).cgPath
    target.layer.mask = mask
    CATransaction.commit()
  }

  private func setTransitionChromeAlpha(_ alpha: CGFloat) {
    guard transitionChromeAlpha != alpha else { return }
    transitionChromeAlpha = alpha
    if !measuringSlot { chromeContainer.layer.opacity = baseChromeOpacity * Float(alpha) }
  }

  private func endTransition() {
    transitionSnapshot?.removeFromSuperview()
    transitionSnapshot = nil
    transitionRailSnapshot?.removeFromSuperview()
    transitionRailSnapshot = nil
    transitionTabSnapshot?.removeFromSuperview()
    transitionTabSnapshot = nil
    transitionTabWasVisible = false
    tabBar.alpha = 1
    transitionDirection = nil
    transitionStyle = "slide"
    transitionProgress = 0
    transitionId = nil
    chromeContainer.transform = .identity
    chromeContainer.layer.mask = nil
    setTransitionChromeAlpha(1)
    setTopInteraction(!(state?.suspended ?? false))
    if state?.top?.presentation == "hidden" { scheduleSlotMeasurement() }
  }

  private func debugLog(_ message: String) {
    #if DEBUG
      NSLog("[NativeChrome] %@", message)
    #endif
  }

  // MARK: Test support

  /// Debug description of the native state (tests and diagnostics).
  public func debugSnapshot() -> [String: Any] {
    [
      "flutterParentIsHost": contentViewController.parent === self,
      "topVisible": !navigationBar.isHidden,
      "title": navigationBar.topItem?.title ?? "",
      "rightItems": navigationBar.topItem?.rightBarButtonItems?.count ?? 0,
      "tabVisible": !tabBar.isHidden,
      "selectedTab": tabBar.selectedItem.map { tabIds[$0.tag] } ?? "",
      "tabIds": tabIds,
      "nativeFiltered": nativeFiltered,
      "railSnapshotCount": railSnapshotCount,
      "railDimCount": railDimCount,
      "accessibilitySuspended": accessibilitySuspended,
    ]
  }
}

/// Root of the chrome navigation controller: shows no content of its own.
final class NativeChromeBarRootViewController: UIViewController {
  override func loadView() {
    view = UIView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
  }
}

/// Holds the chrome navigation controller over the content. Touches reach
/// only bar controls (in the bar or moved by UIKit into a system rail); the
/// transparent rest passes through to the content.
final class NativeChromePassThroughView: UIView {
  weak var navigationBar: UINavigationBar?
  var transparentViews: [UIView] = []

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard let hit = super.hitTest(point, with: event) else { return nil }
    if hit === self || transparentViews.contains(where: { $0 === hit }) { return nil }
    if let bar = navigationBar, hit.isDescendant(of: bar) { return hit }
    // Climb to the controller's own view (its edge-pop recognizer must not
    // capture content touches); only real controls keep the touch.
    var current: UIView? = hit
    while let candidate = current, candidate !== self,
      !transparentViews.contains(where: { $0 === candidate })
    {
      if candidate is UIControl || !(candidate.gestureRecognizers ?? []).isEmpty { return hit }
      current = candidate.superview
    }
    return nil
  }
}
