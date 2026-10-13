import AppKit
import SwiftUI
import CacheCueCore

/// The app's palette and surfaces. Every colour follows light and dark appearance.
enum Palette {
    /// `strong` is what "Increase contrast" in the system's settings gets: nil keeps the usual pair.
    private static func adaptive(dark: NSColor, light: NSColor, strong: (dark: NSColor, light: NSColor)? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if let strong, isHighContrast(appearance) {
                return isDark ? strong.dark : strong.light
            }
            return isDark ? dark : light
        }
    }

    /// Set by the off-screen render, to draw what "Increase contrast" gets.
    static var forcesStrong = false

    /// The appearance says so when it is the system's own; one the person chose in the
    /// app's settings is plain light or dark, and then the system's setting is asked.
    private static func isHighContrast(_ appearance: NSAppearance) -> Bool {
        if forcesStrong { return true }
        let named = appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        return named == .accessibilityHighContrastAqua || named == .accessibilityHighContrastDarkAqua
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }

    // The three levels, each in two strengths. Measured against the lightest and the
    // darkest the popover's translucent surface gets, in both appearances (WCAG 2.2 AA):
    //
    // - `tone`, for words and icons: at least 4.5:1 (1.4.3).
    // - `fill`, for bars, gauges and dots: at least 3:1 (1.4.11), and told apart by someone
    //   who does not see red and green as different. "Good" is a teal, so it stands off from
    //   red on the blue-yellow axis that stays; amber is kept yellow and light, red dark.
    //
    // The words cannot be made that distinct: dark enough to read on a light surface, amber
    // and red draw close. They say what they mean in letters and figures; the colour helps.
    //
    // With "Increase contrast" on, the words go a step further: at least 7:1 (1.4.6).
    static let okTone = adaptive(dark: rgb(0x3FD6C0), light: rgb(0x05665E), strong: (rgb(0x8AF0DF), rgb(0x03483F)))
    static let warnTone = adaptive(dark: rgb(0xF2C037), light: rgb(0x7A5200), strong: (rgb(0xFFD96B), rgb(0x573A00)))
    static let critTone = adaptive(dark: rgb(0xFF9486), light: rgb(0xA31B14), strong: (rgb(0xFFCCC4), rgb(0x7A0F0A)))
    static let okFill = adaptive(dark: rgb(0x2CC7B0), light: rgb(0x0C8A7D))
    static let warnFill = adaptive(dark: rgb(0xF0B429), light: rgb(0xB06C00))
    static let critFill = adaptive(dark: rgb(0xFF6B5E), light: rgb(0xA31B14))

    // The brand: a terracotta crescent, lit on a dark tile and deeper on a light one.
    static let terracottaLight = NSColor(red: 0.906, green: 0.612, blue: 0.459, alpha: 1)
    static let terracottaDark = NSColor(red: 0.80, green: 0.42, blue: 0.30, alpha: 1)

    // The accent for text and icons. The system's blue goes dull on a dark popover, most of
    // all on a tint of itself, so the dark appearance gets a lighter, brighter blue.
    static let accent = adaptive(dark: rgb(0x92C1FF), light: rgb(0x0054C2), strong: (rgb(0xBFDBFF), rgb(0x003A8C)))
    /// Behind white text: deep enough in both appearances for the white to read (4.5:1).
    static let accentFill = adaptive(dark: rgb(0x1F6FE0), light: rgb(0x0054C2))
    /// Behind white text where something calls for attention: support has answered.
    static let beacon = rgb(0xC2410C)

    /// Words that are not the main thing. The system's secondary label falls short of
    /// 4.5:1 on this surface at the sizes used here, so this one is a little stronger.
    static let secondaryText = adaptive(
        dark: NSColor.white.withAlphaComponent(0.62), light: NSColor.black.withAlphaComponent(0.62),
        strong: (NSColor.white.withAlphaComponent(0.80), NSColor.black.withAlphaComponent(0.80)))

    static let segmentBg = adaptive(
        dark: NSColor.white.withAlphaComponent(0.12), light: NSColor.black.withAlphaComponent(0.10),
        strong: (NSColor.white.withAlphaComponent(0.26), NSColor.black.withAlphaComponent(0.22)))
    // A card sits a shade above the surface it is on, and has an edge that can be seen.
    static let cardBg = adaptive(
        dark: NSColor.white.withAlphaComponent(0.05), light: NSColor.white.withAlphaComponent(0.55))
    static let cardBorder = adaptive(
        dark: NSColor.white.withAlphaComponent(0.10), light: NSColor.black.withAlphaComponent(0.08),
        strong: (NSColor.white.withAlphaComponent(0.45), NSColor.black.withAlphaComponent(0.40)))

    /// The colour of a level for words and icons; `plain` has none and takes the caller's default.
    static func tone(_ level: Level) -> NSColor? {
        switch level {
        case .plain: return nil
        case .ok: return okTone
        case .warn: return warnTone
        case .crit: return critTone
        }
    }

    /// The colour of a level for bars, gauges and dots.
    static func fill(_ level: Level) -> NSColor? {
        switch level {
        case .plain: return nil
        case .ok: return okFill
        case .warn: return warnFill
        case .crit: return critFill
        }
    }
}

extension Color {
    static let brandAccent = Color(nsColor: Palette.accent)
    static let brandAccentFill = Color(nsColor: Palette.accentFill)
    static let segmentBg = Color(nsColor: Palette.segmentBg)
    static let cardBg = Color(nsColor: Palette.cardBg)
    static let cardBorder = Color(nsColor: Palette.cardBorder)

    static let secondaryText = Color(nsColor: Palette.secondaryText)
    static let beacon = Color(nsColor: Palette.beacon)

    static func tone(_ level: Level, default fallback: Color = .primary) -> Color {
        Palette.tone(level).map { Color(nsColor: $0) } ?? fallback
    }

    static func toneFill(_ level: Level, default fallback: Color = .primary) -> Color {
        Palette.fill(level).map { Color(nsColor: $0) } ?? fallback
    }
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The crescent, as a path for any size: a disc with a second disc bitten out of its
/// upper right, in a square of side `size` whose origin is top-left.
enum Crescent {
    /// The moon and the bite, in the proportions of the app icon (drawn on a 512 grid).
    static func rects(in size: CGFloat) -> (moon: CGRect, bite: CGRect) {
        let unit = size / 512
        let center = size / 2
        let moon = CGRect(x: center - 135 * unit, y: center - 135 * unit, width: 270 * unit, height: 270 * unit)
        let bite = CGRect(
            x: center - 130 * unit + 32 * unit, y: center - 130 * unit - 32 * unit, width: 260 * unit, height: 260 * unit)
        return (moon, bite)
    }
}

/// The app's mark for the popover's header: the icon in small, on a tile that contrasts
/// with whichever appearance is showing.
struct BrandMark: View {
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isLight = colorScheme == .light
        let moon = Color(nsColor: isLight ? Palette.terracottaLight : Palette.terracottaDark)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(isLight ? Color(white: 0.08) : Color(red: 0.96, green: 0.96, blue: 0.98))
            Circle().stroke(moon.opacity(isLight ? 0.22 : 0.28), lineWidth: max(0.7, size * 0.03))
                .frame(width: size * 0.76, height: size * 0.76)
            Canvas { context, canvas in
                let rects = Crescent.rects(in: canvas.width)
                context.drawLayer { layer in
                    layer.fill(Path(ellipseIn: rects.moon), with: .color(moon))
                    layer.blendMode = .destinationOut
                    layer.fill(Path(ellipseIn: rects.bite), with: .color(.black))
                }
            }
        }
        .frame(width: size, height: size)
        // The name is written beside it wherever it appears.
        .accessibilityHidden(true)
    }
}
