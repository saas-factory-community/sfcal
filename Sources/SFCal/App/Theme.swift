import SwiftUI

// Paleta: núcleo de marca → business-os/.claude/skills/diseno-de-marca/references/nucleo.md §2.
// Morado #8C27F1 y oro #ff9101 como ACENTOS; fondos titanium neutros; semáforo solo para estado real.

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
        } else {
            r = 0.5; g = 0.5; b = 0.5
        }
        self.init(red: r, green: g, blue: b)
    }

    static func fromCalendarHex(_ hex: String) -> Color { Color(hex: hex) }

    /// Color de TÍTULO de evento: el color del calendario ajustado para contraste
    /// (hacia blanco en dark, hacia negro en light). Doble codificación estilo
    /// Notion: barra + tipografía, sin fill gritón.
    static func eventTitle(hex: String, dark: Bool) -> Color {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        guard s.count == 6 else { return dark ? Color(hex: "#f7f8f8") : Color(hex: "#1c1c22") }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        if dark {
            let t = 0.55   // mezcla hacia blanco
            return Color(red: r + (1 - r) * t, green: g + (1 - g) * t, blue: b + (1 - b) * t)
        } else {
            let t = 0.42   // mezcla hacia negro
            return Color(red: r * (1 - t), green: g * (1 - t), blue: b * (1 - t))
        }
    }
}

struct Palette {
    let bg: Color
    let surface: Color
    let card: Color
    let border: Color
    let borderTop: Color
    let grid: Color
    let textPrimary: Color
    let textSecondary: Color
    let textMuted: Color
    let accent: Color        // morado de marca
    let gold: Color          // oro de marca
    let ok: Color
    let bad: Color
    let isDark: Bool

    static let dark = Palette(
        bg: Color(hex: "#09090b"),
        surface: Color(hex: "#0d0d12"),
        card: Color(hex: "#1a1a1e"),
        border: Color(hex: "#2c2c34"),
        borderTop: Color(hex: "#42424c"),
        grid: Color(hex: "#1c1c22"),
        textPrimary: Color(hex: "#f7f8f8"),
        textSecondary: Color(hex: "#d4d4d8"),
        textMuted: Color(hex: "#a1a1aa"),
        accent: Color(hex: "#8C27F1"),
        gold: Color(hex: "#ff9101"),
        ok: Color(hex: "#3fb27f"),
        bad: Color(hex: "#e0484d"),
        isDark: true
    )

    // Modo claro: cream cálido de la casa (delta declarado del canvas), mismos acentos.
    static let light = Palette(
        bg: Color(hex: "#faf6ef"),
        surface: Color(hex: "#ffffff"),
        card: Color(hex: "#ffffff"),
        border: Color(hex: "#e2dccf"),
        borderTop: Color(hex: "#efe9dd"),
        grid: Color(hex: "#ebe5d8"),
        textPrimary: Color(hex: "#1c1c22"),
        textSecondary: Color(hex: "#45454d"),
        textMuted: Color(hex: "#8a8a92"),
        accent: Color(hex: "#8C27F1"),
        gold: Color(hex: "#cc7301"),
        ok: Color(hex: "#2f9268"),
        bad: Color(hex: "#c53a3f"),
        isDark: false
    )
}

@MainActor
final class ThemeManager: ObservableObject {
    @Published var isDark: Bool {
        didSet { UserDefaults.standard.set(isDark, forKey: "sfcal.dark") }
    }

    init() {
        isDark = UserDefaults.standard.object(forKey: "sfcal.dark") as? Bool ?? true
    }

    var palette: Palette { isDark ? .dark : .light }

    func toggle() {
        withAnimation(.easeInOut(duration: 0.18)) { isDark.toggle() }
    }
}
