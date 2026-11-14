import UIKit

/// Text items for a navigation bar owned and laid out by its host.
@MainActor
public enum NativeChromeBarButton {
  public static func text(
    label: String, identifier: String, enabled: Bool, action: @escaping () -> Void
  ) -> UIBarButtonItem {
    button(label: label, image: nil, identifier: identifier, enabled: enabled, done: false, tint: nil, action: action)
  }

  static func button(
    label: String, image: UIImage?, identifier: String, enabled: Bool,
    done: Bool, tint: UIColor?, action: @escaping () -> Void
  ) -> UIBarButtonItem {
    let handler = UIAction { _ in action() }
    let item = UIBarButtonItem(title: image == nil ? label : nil, image: image, primaryAction: handler, menu: nil)
    item.style = done ? .done : .plain
    if let tint { item.tintColor = tint }
    item.isEnabled = enabled
    item.accessibilityLabel = label
    item.accessibilityIdentifier = identifier
    if #available(iOS 27.1, *) { item.axisBehavior = image != nil ? .verticalPreferred : .horizontalOnly }
    return item
  }
}
