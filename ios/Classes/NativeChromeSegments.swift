import UIKit

/// Synchronizes an existing UIKit segment strip without remounting its host.
@MainActor
public enum NativeChromeSegments {
  public static func update(_ control: UISegmentedControl, labels: [String], selectedIndex: Int, enabled: Bool) {
    if control.numberOfSegments != labels.count {
      control.removeAllSegments()
      for (index, label) in labels.enumerated() {
        control.insertSegment(withTitle: label, at: index, animated: false)
      }
    } else {
      for (index, label) in labels.enumerated() where control.titleForSegment(at: index) != label {
        control.setTitle(label, forSegmentAt: index)
      }
    }
    let selection = labels.indices.contains(selectedIndex) ? selectedIndex : UISegmentedControl.noSegment
    if control.selectedSegmentIndex != selection { control.selectedSegmentIndex = selection }
    control.isEnabled = enabled
  }
}
