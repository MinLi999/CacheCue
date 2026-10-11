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

    // The brand: a terracotta crescent, lit on a dark tile and deeper on a light one.
    static let terracottaLight = NSColor(red: 0.906, green: 0.612, blue: 0.459, alpha: 1)
    static let terracottaDark = NSColor(red: 0.80, green: 0.42, blue: 0.30, alpha: 1)

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
    }
}
