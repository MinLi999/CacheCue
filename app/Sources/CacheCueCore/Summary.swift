import Foundation

public enum Level: Equatable {
    case plain, ok, warn, crit
}

public enum Format {
    public static let barCells = 8

    public static func tokens(_ count: Double) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", count / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", count / 1_000) }
        return String(Int(count.rounded()))
    }

    /// `4d2h`, `4h36m`, `38m`.
    public static func reset(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let days = seconds / 86400
        let hours = seconds % 86400 / 3600
        let minutes = seconds % 3600 / 60
        if days > 0 { return "\(days)d\(hours)h" }
        if hours > 0 { return "\(hours)h" + String(format: "%02dm", minutes) }
        return "\(minutes)m"
    }

    /// `47:36`.
    public static func countdown(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    public static func filledCells(_ percent: Double) -> Int {
        let filled = min(barCells, max(0, Int((percent * Double(barCells) / 100).rounded())))
        return percent > 0 && filled == 0 ? 1 : filled
    }

    public static func bar(_ percent: Double) -> String {
        let filled = filledCells(percent)
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: barCells - filled)
    }

    public static func level(_ percent: Double, warn: Double, crit: Double) -> Level {
        percent >= crit ? .crit : percent >= warn ? .warn : .ok
    }

    public static func hitLevel(_ percent: Int) -> Level {
        percent < 50 ? .crit : percent < 80 ? .warn : .ok
    }
}

/// An account-wide rate-limit window, ready to draw.
public struct LimitView: Equatable {
    public var label: String
    public var percent: Int
    /// 0 to 100, unrounded.
    public var used: Double
    public var bar: String
    public var reset: String?
    /// Seconds until the window resets.
    public var resetsIn: TimeInterval?
    public var level: Level
}

/// Where a session's prompt cache stands.
public enum CacheState: Equatable {
    case unknown
    case active
    case expires(in: TimeInterval)
    case expired

    /// How long a cache entry lives; the bar in the popover is drawn against it.
    public static let lifetime: TimeInterval = 3600

    /// What is left of the hour, 0 to 1.
    public var remainingFraction: Double {
        switch self {
        case .unknown, .expired: return 0
        case .active: return 1
        case .expires(let left): return min(1, max(0, left / CacheState.lifetime))
        }
    }

    /// The menu bar's short form: `47:36`, `live`, `exp`, `--:--`.
    public var shortText: String {
        switch self {
        case .unknown: return "--:--"
        case .active: return "live"
        case .expires(let left): return Format.countdown(left)
        case .expired: return "exp"
        }
    }

    public var text: String {
        switch self {
        case .unknown: return "--:--"
        case .active: return "active"
        case .expires(let left): return Format.countdown(left)
        case .expired: return "expired"
        }
    }

    public var level: Level {
        switch self {
        case .unknown, .active: return .plain
        case .expires(let left): return left <= 120 ? .crit : left <= 600 ? .warn : .plain
        case .expired: return .crit
        }
    }
}

public struct SessionView: Equatable {
    /// The session's id, which pinning goes by.
    public var id: String
    public var name: String
    /// `terminal`, `desktop`, ...
    public var source: String
    public var turnHit: Int?
    public var avgHit: Int?
    public var cache: CacheState
    public var contextTokens: Double
    public var contextWindow: Double
    public var contextPercent: Double?
    public var output: Double
    public var costUSD: Double?
}

public struct TitlePart: Equatable {
    public var text: String
    public var level: Level

    public init(_ text: String, _ level: Level = .plain) {
        self.text = text
        self.level = level
    }
}

public struct Summary: Equatable {
    /// A session silent for longer than this is not listed.
    public static let sessionWindow: TimeInterval = 24 * 3600
    public static let maxOthers = 5
    /// A session that said a turn was running and then went silent this long has died.
    public static let activeGrace: TimeInterval = 6 * 3600

    public var fiveHour: LimitView?
    public var sevenDay: LimitView?
    /// The session shown in full: the pinned one, or else the one that last did something.
    public var current: SessionView?
    public var others: [SessionView]
    /// `current` was chosen by the person, not by recency.
    public var isPinned = false
    /// Some session has rate-limit readings, which only a subscription (or a gateway
    /// spend limit) gives. The dollar figure is then a value at API list prices, not a bill.
    public var isSubscription = false

    /// `pinned` is a session id the person chose to keep in view; it stands for as long as
    /// that session is still listed.
    public init(snapshots: [Snapshot], now: Date, pinned: String? = nil) {
        let at = now.timeIntervalSince1970
        let newestFirst = snapshots.sorted { $0.updatedAt > $1.updatedAt }

        // The limits are the account's, but each session only knows what its own last
        // API response said, so the readings disagree. The one received last stands; a
        // reading of unknown age ranks below any dated one, then by its session's
        // activity. A window already past its reset says nothing.
        func limit(_ kind: String, label: String) -> LimitView? {
            let readings = newestFirst.compactMap { snapshot -> (limit: Snapshot.Limit, at: Double)? in
                guard let found = snapshot.limits[kind] else { return nil }
                if let resetsAt = found.resetsAt, resetsAt <= at { return nil }
                return (found, snapshot.limitsAt ?? 0)
            }
            // `max` keeps the first of equals, and the readings are newest session first.
            guard let freshest = readings.max(by: { $0.at < $1.at })?.limit else { return nil }
            return LimitView(
                label: label,
                percent: Int(freshest.used.rounded()),
                used: freshest.used,
                bar: Format.bar(freshest.used),
                reset: freshest.resetsAt.map { Format.reset($0 - at) },
                resetsIn: freshest.resetsAt.map { $0 - at },
                level: Format.level(freshest.used, warn: 70, crit: 90))
        }
        fiveHour = limit("five_hour", label: "5h")
        sevenDay = limit("seven_day", label: "7d")

        let live = newestFirst
            .filter { at - $0.updatedAt <= Summary.sessionWindow }
            .map { Summary.view(of: $0, at: at) }
        if let pinned, let index = live.firstIndex(where: { $0.id == pinned }) {
            var rest = live
            current = rest.remove(at: index)
            others = Array(rest.prefix(Summary.maxOthers))
            isPinned = true
        } else {
            current = live.first
            others = Array(live.dropFirst().prefix(Summary.maxOthers))
        }
        isSubscription = snapshots.contains { !$0.limits.isEmpty }
    }

    static func view(of snapshot: Snapshot, at: TimeInterval) -> SessionView {
        let cache: CacheState
        if snapshot.cache.active, at - snapshot.updatedAt <= activeGrace {
            cache = .active
        } else if let expiresAt = snapshot.cache.expiresAt {
            cache = expiresAt > at ? .expires(in: expiresAt - at) : .expired
        } else {
            cache = .unknown
        }
        let folder = snapshot.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return SessionView(
            id: snapshot.sessionID,
            name: folder.isEmpty ? String(snapshot.sessionID.prefix(8)) : folder,
            source: snapshot.source,
            turnHit: snapshot.cache.turnHit,
            avgHit: snapshot.cache.avgHit,
            cache: cache,
            contextTokens: snapshot.context.tokens,
            contextWindow: snapshot.context.window,
            contextPercent: snapshot.context.percent,
            output: snapshot.context.output,
            costUSD: snapshot.costUSD)
    }

    /// The menu bar's own text: `5h 20%  7d 3%  ◷47:36`.
    public var title: [TitlePart] {
        var parts: [TitlePart] = []
        func add(_ part: TitlePart) {
            if !parts.isEmpty { parts.append(TitlePart("  ")) }
            parts.append(part)
        }
        for limit in [fiveHour, sevenDay].compactMap({ $0 }) {
            add(TitlePart("\(limit.label) \(limit.percent)%", limit.level == .ok ? .plain : limit.level))
        }
        if let current {
            add(TitlePart("◷\(current.cache.text)", current.cache.level))
        }
        return parts.isEmpty ? [TitlePart("◷--")] : parts
    }

    public var titleText: String { title.map(\.text).joined() }

    // MARK: As text

    /// Everything the popover shows, as lines of text, top to bottom; `nil` is a rule.
    /// What `--dump` prints.
    public func rows(_ strings: Strings) -> [String?] {
        func limitRow(_ limit: LimitView?, title: String) -> String {
            guard let limit else { return "\(title)  \(strings.noReading)" }
            let reset = limit.resetsIn.map { "  ·  " + strings.reset(in: $0) } ?? ""
            return "\(title)  \(limit.bar)  \(limit.percent)% \(strings.used)\(reset)"
        }
        func cacheText(_ cache: CacheState) -> String {
            switch cache {
            case .unknown: return strings.cacheUnknown
            case .active: return strings.cacheActive
            case .expires(let left): return "\(Format.countdown(left)) \(strings.cacheExpiresCaption)"
            case .expired: return strings.cacheExpired
            }
        }
        func hit(_ value: Int?) -> String { value.map { "\($0)%" } ?? "--" }
        func cost(_ value: Double?) -> String { value.map { String(format: "$%.2f", $0) } ?? "--" }

        var rows: [String?] = [
            limitRow(fiveHour, title: strings.fiveHourTitle), limitRow(sevenDay, title: strings.sevenDayTitle), nil,
        ]
        if let current {
            var contextRow = "\(strings.context)  \(Format.tokens(current.contextTokens)) / \(Format.tokens(current.contextWindow))"
            if let percent = current.contextPercent { contextRow += " (\(Int(percent.rounded()))%)" }
            let advice = current.advice
            rows += [
                "\(strings.adviceTitle): \(advice.headline(strings))", advice.detail(strings), nil,
                "\(current.name)  ·  \(strings.source(current.source))  ·  \(strings.currentSession)",
                cacheText(current.cache),
                "\(strings.turnHit) \(hit(current.turnHit))  ·  \(strings.avgHit) \(hit(current.avgHit))  ·  \(isSubscription ? strings.costEquivalent : strings.cost) \(cost(current.costUSD))",
                contextRow,
            ]
        } else {
            rows.append(strings.emptyTitle)
        }
        if !others.isEmpty {
            rows.append(nil)
            rows.append(strings.otherSessions)
            rows += others.map { session in
                "\(session.name)  ·  \(strings.source(session.source))   \(hit(session.turnHit))   ◷\(session.cache.shortText)   \(cost(session.costUSD))"
            }
        }
        return rows
    }
}
