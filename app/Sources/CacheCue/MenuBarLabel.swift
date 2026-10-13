import AppKit
import CacheCueCore

/// The menu bar item: a gauge for each rate-limit window, then the cache countdown.
///
///     ☾ 5h ▮  7d ▮  ◷ 47:36
///
/// The crescent is the app's mark, drawn in the menu bar's own text colour.
/// A dot before the clock says the popover has something to act on: compact now.
/// A dot in the crescent's hollow says some session is waiting on the person.
///
/// Drawn by a handler, not baked, so label colours follow the menu bar's own appearance
/// (which goes by the wallpaper, not by the system's light or dark mode).
enum MenuBarLabel {
    private static let height: CGFloat = 22
    private static let barSize = NSSize(width: 5.5, height: 12)

    private static func font(_ size: CGFloat, monospacedDigits: Bool = false) -> NSFont {
        let base = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            : NSFont.systemFont(ofSize: size, weight: .bold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }

    /// The same as the picture, in words, for someone who has the screen read to them.
    static func spoken(for summary: Summary, strings: Strings) -> String {
        var parts = ["CacheCue"]
        let limits: [(String, LimitView?)] = summary.showsSpendLimit
            ? [(strings.spendLimitTitle, summary.spendLimit)]
            : [(strings.fiveHourTitle, summary.fiveHour), (strings.sevenDayTitle, summary.sevenDay)]
        for (title, limit) in limits {
            if let limit { parts.append("\(title) \(limit.percent)%") }
        }
        if let current = summary.current {
            switch current.cache {
            case .unknown: break
            case .active: parts.append(strings.cacheActive)
            case .expires: parts.append("\(strings.cacheExpiresCaption) \(current.cache.shortText)")
            case .expired: parts.append(strings.cacheExpired)
            }
            if current.advice.isActionable { parts.append(current.advice.headline(strings)) }
        }
        if summary.isAnyWaiting { parts.append(strings.waitingForYou) }
        return parts.joined(separator: ", ")
    }

    static func image(for summary: Summary, marksWaiting: Bool = false) -> NSImage {
        let isWaiting = marksWaiting && summary.isAnyWaiting
        let labelFont = font(10.5)
        let timeFont = font(11, monospacedDigits: true)
        // An account with a gateway's spend limit and no windows gets one gauge for that.
        let gauges: [(text: String, limit: LimitView?)] = summary.showsSpendLimit
            ? [("$", summary.spendLimit)]
            : [("5h", summary.fiveHour), ("7d", summary.sevenDay)]
        let cache = summary.current?.cache ?? .unknown
        let cacheLevel = summary.current?.cacheLevel ?? .plain
        let timeText = cache.shortText

        func width(_ text: String, _ font: NSFont) -> CGFloat {
            ceil(NSString(string: text).size(withAttributes: [.font: font]).width)
        }
        let textToBar: CGFloat = 2.5
        let groupGap: CGFloat = 6
        let clockSize: CGFloat = 10
        let clockToTime: CGFloat = 3
        let markSize: CGFloat = 13
        let markGap: CGFloat = 5
        var total: CGFloat = markSize + markGap
        for gauge in gauges {
            total += width(gauge.text, labelFont) + textToBar + barSize.width + groupGap
        }
        // Room for the cue dot is always kept, so the item does not jump as it comes and goes.
        let cueSize: CGFloat = 5
        let cueGap: CGFloat = 3
        let advice = summary.current?.advice
        total += cueSize + cueGap + clockSize + clockToTime + width(timeText, timeFont)

        let image = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            let label = NSColor.labelColor
            var x: CGFloat = 0

            func draw(_ text: String, _ font: NSFont, _ color: NSColor) {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = NSString(string: text).size(withAttributes: attributes)
                NSString(string: text).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attributes)
                x += ceil(size.width)
            }

            // The mark: a disc with a bite out of its upper right. The bite is cleared inside
            // a layer of its own, so it cuts the disc and nothing behind it.
            if let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                let moon = NSRect(x: x, y: (height - markSize) / 2, width: markSize, height: markSize)
                label.setFill()
                NSBezierPath(ovalIn: moon).fill()
                context.compositingOperation = .clear
                NSBezierPath(ovalIn: moon.offsetBy(dx: markSize * 0.24, dy: markSize * 0.24).insetBy(dx: 0.3, dy: 0.3)).fill()
                context.cgContext.endTransparencyLayer()
                context.restoreGraphicsState()
                // It sits where the bite was taken, so the item keeps its width.
                if isWaiting {
                    let dot: CGFloat = 5.5
                    (Palette.fill(.warn) ?? label).setFill()
                    NSBezierPath(ovalIn: NSRect(x: moon.maxX - dot + 0.5, y: moon.maxY - dot + 0.5, width: dot, height: dot)).fill()
                }
            }
            x += markSize + markGap

            for gauge in gauges {
                draw(gauge.text, labelFont, gauge.limit == nil ? label.withAlphaComponent(0.45) : label)
                x += textToBar
                let track = NSRect(x: x, y: (height - barSize.height) / 2, width: barSize.width, height: barSize.height)
                let trackPath = NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5)
                label.withAlphaComponent(0.15).setFill()
                trackPath.fill()
                trackPath.lineWidth = 0.8
                label.withAlphaComponent(0.35).setStroke()
                trackPath.stroke()
                if let limit = gauge.limit, limit.used > 0 {
                    // Fills upward with what is used; never so thin it cannot be seen.
                    let filled = max(2, min(1, CGFloat(limit.used) / 100) * barSize.height)
                    (Palette.fill(limit.level) ?? label).setFill()
                    NSBezierPath(
                        roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width, height: filled),
                        xRadius: 1.5, yRadius: 1.5
                    ).fill()
                }
                x += barSize.width + groupGap
            }

            if let advice, advice.isActionable {
                (Palette.fill(advice.level) ?? label).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: (height - cueSize) / 2, width: cueSize, height: cueSize)).fill()
            }
            x += cueSize + cueGap

            // A small clock face, then the countdown.
            let tone = Palette.tone(cacheLevel) ?? label
            let muted = cache == .unknown ? label.withAlphaComponent(0.45) : tone
            let face = NSRect(x: x + 0.5, y: (height - clockSize) / 2 + 0.5, width: clockSize - 1, height: clockSize - 1)
            let clock = NSBezierPath(ovalIn: face)
            clock.lineWidth = 1.2
            muted.setStroke()
            clock.stroke()
            let hands = NSBezierPath()
            hands.move(to: NSPoint(x: face.midX, y: face.midY + 2.6))
            hands.line(to: NSPoint(x: face.midX, y: face.midY))
            hands.line(to: NSPoint(x: face.midX + 2.1, y: face.midY))
            hands.lineWidth = 1.2
            hands.lineCapStyle = .round
            hands.lineJoinStyle = .round
            hands.stroke()
            x += clockSize + clockToTime
            draw(timeText, timeFont, muted)
            return true
        }
        image.isTemplate = false
        return image
    }
}
