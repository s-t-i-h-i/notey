import UIKit
import PencilKit
@available(iOS 18.0, *)
func check() {
    let picker = PKToolPicker()
    print("Default items count: \(picker.toolItems.count)")
}
