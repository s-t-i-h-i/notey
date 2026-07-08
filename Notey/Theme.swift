import SwiftUI
import UIKit

// notey. — beige & navy theme with single delicate pink accents.
enum Theme {
    // Backgrounds
    static let bg = Color(hex: 0xF6F1E7)        // warm beige app background
    static let card = Color(hex: 0xFDFBF5)      // cream cards / canvas page
    static let bgDeep = Color(hex: 0xEFE7D8)    // deeper beige (tab strip, wells)

    // Lines & text
    static let border = Color(hex: 0xE4DAC6)
    static let navy = Color(hex: 0x1F2A44)      // primary: text, buttons, active ink
    static let navySoft = Color(hex: 0x54628A)
    static let textSecondary = Color(hex: 0x8A8271)

    // The single accent — used sparingly (active tool, "today", save dot)
    static let pink = Color(hex: 0xD98BA3)
    static let pinkSoft = Color(hex: 0xF6E7EC)

    static let cardUI = UIColor(red: 0.992, green: 0.984, blue: 0.961, alpha: 1)
    static let patternUI = UIColor(red: 0.87, green: 0.83, blue: 0.74, alpha: 1)

    // Ink palette (navy-first)
    static let inkColors: [UIColor] = [
        UIColor(red: 0.122, green: 0.165, blue: 0.267, alpha: 1), // navy
        UIColor(red: 0.55, green: 0.30, blue: 0.36, alpha: 1),    // plum
        UIColor(red: 0.24, green: 0.42, blue: 0.36, alpha: 1),    // forest
        UIColor(red: 0.68, green: 0.48, blue: 0.22, alpha: 1),    // ochre
        UIColor(red: 0.85, green: 0.55, blue: 0.64, alpha: 1),    // pink (accent)
    ]

    // Paper tints for custom note backgrounds (note settings sheet).
    static let paperColors: [String] = [
        "#FDFBF5", // cream (default)
        "#FFFFFF", // white
        "#F3EDE2", // beige
        "#F6E9C8", // sand
        "#E9EFF6", // blue mist
        "#EAF1EA", // sage
        "#F9ECEF", // rose
        "#EFEBF4", // lilac
        "#F0EEE9", // stone
    ]

    static let folderColors: [String] = [
        "#2E3D5C", // navy
        "#C9B98F", // sand
        "#7C8DAA", // steel blue
        "#8FA98F", // sage
        "#B98F9C", // dusty rose
        "#A08F6E", // olive
        "#6E7FA0", // slate
        "#C4A5AE", // pink-beige
    ]
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .alphanumerics.inverted)
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0x2E3D5C
        self.init(hex: v)
    }
}

extension UIColor {
    convenience init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .alphanumerics.inverted)
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0x2E3D5C
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
