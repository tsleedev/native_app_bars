import UIKit

/// A native toolbar for content already presented in a UIKit sheet. The
/// content controller owns its list, actions and presentation lifecycle.
/// UIKit drives the transition of this navigation controller with the sheet.
@MainActor
public final class NativeChromePresentedNavigationController: UINavigationController {
  public struct Action {
    public init(systemItem: UIBarButtonItem.SystemItem, enabled: Bool = true,
      handler: @escaping () -> Void) {
      self.systemItem = systemItem
      self.enabled = enabled
      self.handler = handler
    }

    public let systemItem: UIBarButtonItem.SystemItem
    public let enabled: Bool
    fileprivate let handler: () -> Void
  }

  private var toolbarGeneration: UInt64 = 0

  public override func viewDidLoad() {
    super.viewDidLoad()
    navigationBar.accessibilityIdentifier = "native_chrome.presentedToolbar"
  }

  /// Configures the current content's native toolbar. UIKit system items keep
  /// their current system styling and accessibility.
  public func updateToolbar(title: String?, prompt: String?,
    leading: Action?, trailing: Action?) {
    guard let item = topViewController?.navigationItem else { return }
    toolbarGeneration &+= 1
    item.title = title
    item.prompt = prompt
    item.leftBarButtonItem = leading.map { makeItem($0, item: item, generation: toolbarGeneration) }
    item.rightBarButtonItem = trailing.map { makeItem($0, item: item, generation: toolbarGeneration) }
  }

  private func makeItem(_ action: Action, item ownerItem: UINavigationItem, generation: UInt64) -> UIBarButtonItem {
    let item = UIBarButtonItem(systemItem: action.systemItem,
      primaryAction: UIAction { [weak self, weak ownerItem] _ in
        guard let self, let ownerItem, action.enabled, self.toolbarGeneration == generation,
          self.topViewController?.navigationItem === ownerItem,
          self.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        else { return }
        action.handler()
      })
    item.isEnabled = action.enabled
    return item
  }
}
