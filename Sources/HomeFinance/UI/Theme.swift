import SwiftUI
import HFCore

/// Kleuren en maten van de app. Gebruik deze in plaats van losse kleuren in schermen.
enum Theme {
    static let accent = Color(light: 0x1F7A5C, dark: 0x4CC79A)
    static let positive = Color(light: 0x1F8A4C, dark: 0x5BD08A)
    static let negative = Color(light: 0xC0392B, dark: 0xFF7A6B)
    static let warning = Color(light: 0xD98E04, dark: 0xF5B83D)
    static let info = Color(light: 0x2D6CDF, dark: 0x6EA2FF)
    static let muted = Color.secondary

    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    static let cardRadius: CGFloat = 14
    static let spacing: CGFloat = 16

    /// Kleuren voor reeksen in grafieken, in vaste volgorde.
    static let series: [Color] = [
        Color(light: 0x1F7A5C, dark: 0x4CC79A), Color(light: 0x2D6CDF, dark: 0x6EA2FF),
        Color(light: 0xD98E04, dark: 0xF5B83D), Color(light: 0xB0447F, dark: 0xE884B8),
        Color(light: 0x6B5BD2, dark: 0xA79BFF), Color(light: 0x3C9AA8, dark: 0x6FD0DD),
        Color(light: 0xC0562B, dark: 0xFF9A6B), Color(light: 0x7A8590, dark: 0xA9B4BF),
    ]
}

extension Color {
    /// Kleur die meeschakelt tussen lichte en donkere weergave.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// "#RRGGBB" (zoals in `Tag.color`); grijs als de tekst niet klopt.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        self.init(nsColor: NSColor(hex: UInt32(s, radix: 16) ?? 0x888888))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
