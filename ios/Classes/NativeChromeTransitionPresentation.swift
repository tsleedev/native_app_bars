import UIKit

/// Draws one transition frame using the host's resting coordinate space.
/// The host still owns lease validation, snapshot lifetime, and input policy.
@MainActor
enum NativeChromeTransitionPresentation {
  static func render(
    progress: CGFloat,
    direction: String?,
    style: String,
    rtl: Bool,
    container: UIView,
    chromeContainer: UIView,
    strip: UIView?,
    rail: UIView?,
    tabBar: UITabBar,
    tabSnapshot: UIView?,
    tabWasVisible: Bool,
    setTransitionChromeAlpha: (CGFloat) -> Void
  ) {
    let width = container.bounds.width
    let sign: CGFloat = rtl ? -1 : 1
    let p = min(max(progress, 0), 1)
    let outgoing = [strip, rail].compactMap { $0 }
    if style == "fade" {
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
      if let tabView = tabSnapshot { tabView.alpha = tabBar.isHidden ? 1 - p : 0 }
      tabBar.alpha = !tabWasVisible && !tabBar.isHidden ? p : 1
      return
    }
    setTransitionChromeAlpha(1)
    if direction == "push" {
      chromeContainer.transform = CGAffineTransform(translationX: sign * (1 - p) * width, y: 0)
      chromeContainer.layer.mask = nil
      // the outgoing bar (a strip of the outgoing page) stays
      // only where the outgoing page still shows, left of the incoming page
      // edge, and fades like a UINavigationController push. Before, it stayed
      // whole and opaque under the incoming glass bar until the end.
      let edge = sign > 0 ? (1 - p) * width : p * width
      let visible = sign > 0
        ? CGRect(x: 0, y: 0, width: max(0, edge), height: container.bounds.height)
        : CGRect(x: edge, y: 0, width: max(0, width - edge), height: container.bounds.height)
      for snapshot in outgoing {
        snapshot.transform = CGAffineTransform(translationX: -sign * 0.3 * p * width, y: 0)
        snapshot.alpha = 1 - p
        clip(snapshot, to: visible, in: container)
      }
    } else {
      for snapshot in outgoing {
        snapshot.transform = CGAffineTransform(translationX: sign * p * width, y: 0)
        snapshot.alpha = 1
        snapshot.layer.mask = nil
      }
      chromeContainer.transform = CGAffineTransform(translationX: -sign * 0.3 * (1 - p) * width, y: 0)
      if strip == nil {
        // no outgoing bar covers the incoming one; show it only
        // where the outgoing (bar-less) page has uncovered the page below.
        let edge = sign > 0 ? p * width : (1 - p) * width
        let visible = sign > 0
          ? CGRect(x: 0, y: 0, width: max(0, edge), height: container.bounds.height)
          : CGRect(x: edge, y: 0, width: max(0, width - edge), height: container.bounds.height)
        clip(chromeContainer, to: visible, in: container)
      } else {
        chromeContainer.layer.mask = nil
      }
    }
  }

  /// Masks [target] to [rect] (Host view coordinates, transform included).
  private static func clip(_ target: UIView, to rect: CGRect, in container: UIView) {
    let mask = (target.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mask.frame = target.bounds
    let local = target.convert(rect, from: container).intersection(target.bounds)
    mask.path = UIBezierPath(rect: local.isNull ? .zero : local).cgPath
    target.layer.mask = mask
    CATransaction.commit()
  }
}
