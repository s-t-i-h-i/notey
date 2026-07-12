import UIKit
import PencilKit
@available(iOS 18.0, *)
func check() {
    let picker = PKToolPicker()
    picker.toolItems = [PKToolPickerEraserItem(type: .bitmap)]
}
