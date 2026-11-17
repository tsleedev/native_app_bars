import Flutter
import UIKit

/// Inline iOS segments and modal toolbar controls. A sheet keeps its
/// inline toolbar; it never becomes a second window chrome owner.
public final class NativeChromeInlineToolbarFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  private let channelNamespace: String
  private let accessibilityNamespace: String

  public init(messenger: FlutterBinaryMessenger,
    channelNamespace: String = "native_chrome/inline",
    accessibilityNamespace: String = "native_chrome.inline") {
    self.messenger = messenger
    self.channelNamespace = channelNamespace
    self.accessibilityNamespace = accessibilityNamespace
    super.init()
  }

  public func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
    arguments args: Any?) -> FlutterPlatformView {
    NativeChromeInlineToolbar(frame: frame, id: viewId, messenger: messenger,
      channelNamespace: channelNamespace, accessibilityNamespace: accessibilityNamespace)
  }
}

private final class NativeChromeInlineToolbar: NSObject, FlutterPlatformView {
  private let container: UIView
  private let accessibilityNamespace: String
  private let channel: FlutterMethodChannel
  private let segments = UISegmentedControl()
  private let modalBar = UINavigationBar()
  private var modalDescriptor = [String: Any]()
  private var generation = -1
  private var active = false
  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger,
    channelNamespace: String, accessibilityNamespace: String) {
    self.accessibilityNamespace = accessibilityNamespace
    container = UIView(frame: frame)
    channel = FlutterMethodChannel(name: "\(channelNamespace)/\(id)", binaryMessenger: messenger)
    super.init()
    container.isUserInteractionEnabled = false
    container.accessibilityElementsHidden = true
    segments.isHidden = true
    segments.isEnabled = false
    segments.accessibilityIdentifier = "\(accessibilityNamespace).segments"
    segments.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(segments)
    NSLayoutConstraint.activate([
      segments.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      segments.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      segments.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
      segments.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
    ])
    segments.addTarget(self, action: #selector(selected), for: .valueChanged)
    modalBar.translatesAutoresizingMaskIntoConstraints = false
    modalBar.isHidden = true
    modalBar.accessibilityIdentifier = "\(accessibilityNamespace).modalBar"
    container.addSubview(modalBar)
    NSLayoutConstraint.activate([
      modalBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      modalBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      modalBar.topAnchor.constraint(equalTo: container.topAnchor),
      modalBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      guard call.method == "update", let value = call.arguments as? [String: Any],
        let kind = value["kind"] as? String, ["segments", "modalBar"].contains(kind),
        let revision = value["generation"] as? Int else {
        return result(FlutterError(code: "invalid-segment-descriptor", message: nil, details: nil))
      }
      if revision >= self.generation {
        self.generation = revision
        self.active = value["active"] as? Bool ?? false
        self.container.isUserInteractionEnabled = self.active
        self.container.accessibilityElementsHidden = !self.active
        self.segments.isHidden = kind != "segments"
        self.modalBar.isHidden = kind != "modalBar"
        if kind == "modalBar" {
          self.updateModal(value)
          return result(nil)
        }
        let labels = value["labels"] as? [String] ?? []
        let selection = value["selected"] as? Int ?? -1
        MainActor.assumeIsolated {
          NativeChromeSegments.update(self.segments, labels: labels, selectedIndex: selection, enabled: self.active)
        }
        self.container.overrideUserInterfaceStyle = value["dark"] as? Bool == true ? .dark : .light
        let requestedScale = value["textScale"] as? Double ?? 1
        let scale = CGFloat(requestedScale.isFinite && requestedScale > 0
          ? min(requestedScale, 8) : 1)
        let font = UIFont.systemFont(ofSize: 14 * scale, weight: .medium)
        self.segments.setTitleTextAttributes([.font: font], for: .normal)
        let height = max(36, ceil(font.lineHeight + 20))
        self.channel.invokeMethod("height", arguments: ["generation": revision, "height": height])
      }
      result(nil)
    }
  }
  func view() -> UIView { container }
  private func updateModal(_ value: [String: Any]) {
    modalDescriptor = value
    container.overrideUserInterfaceStyle = value["dark"] as? Bool == true ? .dark : .light
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = .systemBackground
    modalBar.standardAppearance = appearance
    modalBar.scrollEdgeAppearance = appearance
    modalBar.compactAppearance = appearance
    let item = UINavigationItem(title: value["title"] as? String ?? "")
    let revision = generation
    item.rightBarButtonItems = (value["actions"] as? [[String: Any]] ?? []).map { action in
      let id = action["id"] as? String ?? ""
      let label = action["label"] as? String ?? ""
      let text = action["display"] as? String == "text"
      let button = UIBarButtonItem(title: text ? label : nil,
        image: text ? nil : UIImage(systemName: action["symbol"] as? String == "edit" ? "pencil" : "ellipsis"),
        primaryAction: UIAction(title: label) { [weak self] _ in self?.modalAction(id, revision: revision) }, menu: nil)
      button.accessibilityLabel = label
      button.accessibilityIdentifier = "\(accessibilityNamespace).modal.\(id)"
      button.isEnabled = active && action["enabled"] as? Bool == true && action["loading"] as? Bool != true
      return button
    }
    modalBar.setItems([item], animated: false)
    modalBar.isUserInteractionEnabled = active
    let height = max(44, modalBar.sizeThatFits(CGSize(width: container.bounds.width, height: 0)).height)
    channel.invokeMethod("height", arguments: ["generation": generation, "height": height])
  }
  private func modalAction(_ id: String, revision: Int) {
    guard active, generation == revision, !modalBar.isHidden, visibleInWindow(modalBar),
      UIApplication.shared.applicationState == .active,
      (modalDescriptor["actions"] as? [[String: Any]] ?? []).contains(where: {
        $0["id"] as? String == id && $0["enabled"] as? Bool == true && $0["loading"] as? Bool != true
      }) else { return }
    channel.invokeMethod("action", arguments: ["generation": revision, "id": id])
  }
  @objc private func selected() {
    let index = segments.selectedSegmentIndex
    guard active, !segments.isHidden, segments.isEnabled,
      (0..<segments.numberOfSegments).contains(index),
      visibleInWindow(segments), UIApplication.shared.applicationState == .active else { return }
    channel.invokeMethod("selected", arguments: ["generation": generation, "index": index])
  }
  private func visibleInWindow(_ view: UIView) -> Bool {
    guard let window = view.window, !window.isHidden,
      window.windowScene?.activationState == .foregroundActive else { return false }
    var ancestor: UIView? = view
    while let current = ancestor {
      if current.isHidden || current.alpha <= 0.01 { return false }
      ancestor = current.superview
    }
    return true
  }

  deinit { channel.setMethodCallHandler(nil) }
}
