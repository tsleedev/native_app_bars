import UIKit

/// Applies content to the existing navigation item and its host-owned bar.
@MainActor
public enum NativeChromeNavigationPresentation {
  public enum TrailingPlacement { case standard, pinned }

  public static func update(
    item: UINavigationItem, bar: UINavigationBar,
    title: String?, titleView: UIView?, leading: UIBarButtonItem?,
    trailing: [UIBarButtonItem], enabled: Bool,
    back: UIAction? = nil, trailingPlacement: TrailingPlacement = .pinned,
    hidesAccessibilityWhenDisabled: Bool = true
  ) {
    item.title = title
    item.titleView = titleView
    item.leadingItemGroups = []
    item.trailingItemGroups = []
    item.pinnedTrailingGroup = nil
    item.backAction = nil
    item.leftBarButtonItems = nil
    item.rightBarButtonItems = nil
    switch trailingPlacement {
    case .pinned:
      item.leftBarButtonItem = leading
      item.pinnedTrailingGroup = trailing.isEmpty
        ? nil : UIBarButtonItemGroup(barButtonItems: trailing, representativeItem: nil)
      if #available(iOS 27.1, *) { item.verticalBarCompressionBehavior = .prefersBarItems }
    case .standard:
      item.leftBarButtonItems = leading.map { [$0] }
      item.backAction = back
      item.rightBarButtonItems = trailing
      if #available(iOS 27.1, *) { item.verticalBarCompressionBehavior = .automatic }
    }
    bar.isUserInteractionEnabled = enabled
    bar.accessibilityElementsHidden = hidesAccessibilityWhenDisabled && !enabled
  }
}
