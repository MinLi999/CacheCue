import AppKit
import SwiftUI
import CacheCueCore

/// The app's palette and surfaces. Every colour follows light and dark appearance.
enum Palette {
    private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let mintGreen = adaptive(
        dark: NSColor(red: 0.35, green: 0.82, blue: 0.58, alpha: 1),
        light: NSColor(red: 0.18, green: 0.62, blue: 0.40, alpha: 1))
    static let amberOrange = adaptive(
        dark: NSColor(red: 0.95, green: 0.70, blue: 0.38, alpha: 1),
        light: NSColor(red: 0.82, green: 0.48, blue: 0.15, alpha: 1))
    static let roseRed = adaptive(
        dark: NSColor(red: 0.95, green: 0.45, blue: 0.52, alpha: 1),
        light: NSColor(red: 0.80, green: 0.22, blue: 0.28, alpha: 1))

    static let segmentBg = adaptive(
        dark: NSColor.white.withAlphaComponent(0.06), light: NSColor.black.withAlphaComponent(0.04))
    static let cardBg = adaptive(
        dark: NSColor.white.withAlphaComponent(0.02), light: NSColor.black.withAlphaComponent(0.015))
    static let cardBorder = adaptive(
        dark: NSColor.white.withAlphaComponent(0.04), light: NSColor.black.withAlphaComponent(0.03))

    /// The tone of a level; `plain` has none and takes the caller's default.
    static func tone(_ level: Level) -> NSColor? {
        switch level {
        case .plain: return nil
        case .ok: return mintGreen
        case .warn: return amberOrange
        case .crit: return roseRed
        }
    }
}

extension Color {
    static let segmentBg = Color(nsColor: Palette.segmentBg)
    static let cardBg = Color(nsColor: Palette.cardBg)
    static let cardBorder = Color(nsColor: Palette.cardBorder)

    static func tone(_ level: Level, default fallback: Color = .primary) -> Color {
        Palette.tone(level).map { Color(nsColor: $0) } ?? fallback
    }
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
