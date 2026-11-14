import UIKit

/// Synchronizes UIKit tab items while the host retains its view controllers,
/// delegate, navigation stacks, and popup policy.
@MainActor
public final class NativeChromeManagedTabs {
  private weak var controller: UITabBarController?
  private var confirmedIndex: Int?

  public init(controller: UITabBarController) {
    self.controller = controller
  }

  public static func makeItem(title: String?, image: UIImage?, tag: Int) -> UITabBarItem {
    UITabBarItem(title: title, image: image, tag: tag)
  }

  public static func updateItem(
    _ item: UITabBarItem, title: String?, enabled: Bool,
    updatesBadge: Bool, badge: String?, accessibilityValue: String?
  ) {
    if item.title != title { item.title = title }
    if item.isEnabled != enabled { item.isEnabled = enabled }
    if updatesBadge {
      if item.badgeValue != badge { item.badgeValue = badge }
      if item.accessibilityValue != accessibilityValue { item.accessibilityValue = accessibilityValue }
    }
  }

  public func install(_ children: [UIViewController], selectedIndex: Int) {
    guard let controller else { return }
    controller.viewControllers = children
    if children.indices.contains(selectedIndex) {
      confirmedIndex = selectedIndex
      controller.selectedIndex = selectedIndex
    } else {
      confirmedIndex = nil
    }
  }

  /// Calls the host before UIKit confirms selection, for existing content handoff.
  public func confirm(_ index: Int, prepare: () -> Void) {
    guard let controller, let children = controller.viewControllers,
      children.indices.contains(index) else { return }
    if confirmedIndex != index {
      prepare()
      confirmedIndex = index
    }
    if controller.selectedIndex != index { controller.selectedIndex = index }
  }

  public func index(of controller: UIViewController) -> Int? {
    self.controller?.viewControllers?.firstIndex { $0 === controller }
  }

  public func updateAvailability(isVisible: Bool, enabled: Bool) {
    guard let tabBar = controller?.tabBar else { return }
    tabBar.isUserInteractionEnabled = isVisible && enabled
    tabBar.accessibilityElementsHidden = !isVisible || !enabled
  }
}
