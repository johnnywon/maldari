import SwiftUI

// MARK: - Design Constants matching translation-app.jsx

enum Theme {
    // Core colors
    static let lime = Color(hex: 0xBBFF00)
    static let cyan = Color(hex: 0x5CE0D8)
    static let text = Color(hex: 0xF4F5F7)
    static let glass = Color(red: 10/255, green: 10/255, blue: 18/255).opacity(0.76)
    static let glassHeader = Color(red: 14/255, green: 14/255, blue: 24/255).opacity(0.8)

    // NSColor variants for AppKit usage
    static let limeNS = NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 1)
    static let cyanNS = NSColor(red: 92/255, green: 224/255, blue: 216/255, alpha: 1)
    static let textNS = NSColor(red: 244/255, green: 245/255, blue: 247/255, alpha: 1)

    // Text opacity variants
    static let textMeta = Color(hex: 0xF4F5F7).opacity(0.62)
    static let textDim = Color(hex: 0xF4F5F7).opacity(0.38)

    // Border colors
    static let border = Color.white.opacity(0.05)
    static let borderHighlight = Color(hex: 0xBBFF00).opacity(0.14)

    // Fonts — use PostScript names to avoid SwiftUI weight descriptor warnings
    static let mono = Font.custom("SFMono-Medium", size: 11)
    static func mono(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        let name: String
        switch weight {
        case .bold: name = "SFMono-Bold"
        case .semibold: name = "SFMono-Semibold"
        case .light: name = "SFMono-Light"
        case .regular: name = "SFMono-Regular"
        default: name = "SFMono-Medium"
        }
        return Font.custom(name, size: size)
    }
    static let sans = Font.system(size: 16)
    static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return Font.system(size: size, weight: weight)
    }

    // Layout
    static let windowWidth: CGFloat = 560
    static let headerHeight: CGFloat = 46
    static let cornerRadius: CGFloat = 10
    static let contentHeight: CGFloat = 560

    // Gradient
    static let accentGradient = LinearGradient(
        colors: [lime, cyan],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Color Extension

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// Pack the sRGB components into a 0xRRGGBB value (alpha dropped) so a
    /// ColorPicker selection can be persisted in UserDefaults.
    var rgbHex: UInt {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = UInt((ns.redComponent * 255).rounded())
        let g = UInt((ns.greenComponent * 255).rounded())
        let b = UInt((ns.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}
