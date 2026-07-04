import SwiftUI

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: return nil
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255)
    }

    /// Museum brand color that is guaranteed readable in dark mode.
    /// Dark hex colors (brightness < 0.65) are lightened automatically in Dark Aqua appearances.
    init?(adaptiveHex hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&int), trimmed.count == 6 else { return nil }
        let r = CGFloat(int >> 16) / 255
        let g = CGFloat(int >> 8 & 0xFF) / 255
        let b = CGFloat(int & 0xFF) / 255
        let base = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        let dynamic = NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                  let rgb = base.usingColorSpace(.deviceRGB) else { return base }
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
            guard br < 0.65 else { return base }
            return NSColor(hue: h, saturation: min(s, 0.75), brightness: 0.65, alpha: a)
        }
        self = Color(nsColor: dynamic)
    }
}
