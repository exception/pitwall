import AppKit
import SwiftUI

/// Pitwall's visual tokens (direction C: glass & dispatch bar).
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: a)
    }

    // Surfaces
    static let canvas = dynamic(light: hex(0xE9ECEF), dark: hex(0x0F1012))
    static let canvasDot = dynamic(light: hex(0x000000, 0.10), dark: hex(0xFFFFFF, 0.07))
    static let tile = dynamic(light: hex(0xFFFFFF), dark: hex(0x1A1C20))
    static let terminalBG = dynamic(light: hex(0xFDFCFA), dark: hex(0x141518))
    static let hairline = dynamic(light: hex(0x000000, 0.07), dark: hex(0xFFFFFF, 0.08))
    static let tileShadow = dynamic(light: hex(0x141E32, 0.12), dark: hex(0x000000, 0.5))
    static let pill = dynamic(light: hex(0xEEF0F3), dark: hex(0x26282D))
    static let frameFill = dynamic(light: hex(0xFFFFFF, 0.35), dark: hex(0xFFFFFF, 0.03))

    // Text
    static let text = dynamic(light: hex(0x1B1C1F), dark: hex(0xECEDEF))
    static let text2 = dynamic(light: hex(0x585B63), dark: hex(0xA3A6AE))
    static let text3 = dynamic(light: hex(0x6E717A), dark: hex(0x8B8F98))

    // Status
    static let amber = hex(0xF5A524)
    static let amberText = dynamic(light: hex(0x8A5300), dark: hex(0xF7B54A))
    static let green = dynamic(light: hex(0x16874A), dark: hex(0x3DD68C))
    static let blue = dynamic(light: hex(0x2563EB), dark: hex(0x5B9CFF))
    static let red = dynamic(light: hex(0xC62828), dark: hex(0xFF6B61))
    static let idle = dynamic(light: hex(0xB9BCC3), dark: hex(0x5A5E68))

    static func color(for state: AgentState) -> NSColor {
        switch state {
        case .idle: return idle
        case .working: return green
        case .waiting: return amber
        case .done: return blue
        case .error: return red
        }
    }

    static let boardColors: [NSColor] = [hex(0xE08A00), hex(0x2563EB), hex(0x16874A), hex(0x7C4DDB), hex(0xD9467A), hex(0x0E7C86)]

    static let tileRadius: CGFloat = 18
    static let headerHeight: CGFloat = 44

    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension Color {
    init(ns: NSColor) { self.init(nsColor: ns) }
}

extension View {
    /// Liquid Glass on macOS 26+, material elsewhere.
    @ViewBuilder
    func pitwallGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07)))
                .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
        }
    }
}

extension Date {
    /// Compact elapsed time: "now", "12s", "4m", "2h", "3d".
    var elapsedShort: String {
        let s = Int(Date().timeIntervalSince(self))
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
