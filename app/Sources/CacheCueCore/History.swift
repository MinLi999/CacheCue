import Foundation

/// Where a limit's present rate of use leads.
public enum Pace: Equatable {
    /// The limit is reached at this moment, before the window resets.
    case hits(at: Date)
    /// What is left outlasts the window.
    case lasts
}

/// A week of what the cache cost, added up from the days the app saw.
public struct Week: Equatable {
    public var coldStarts = 0
    public var coldTokens: Double = 0
    public var rebuilds = 0
    public var rebuildTokens: Double = 0
    /// Compactions, and what they took off the contexts they ran on, in tokens.
    public var compacts = 0
    public var compactSaved: Double = 0
    /// The mean of the sessions' cache hit rates, 0 to 100; nil with none on record.
    public var hit: Int?
    /// Tokens written again on each of the seven days, oldest first, today last.
    public var daily: [Double] = Array(repeating: 0, count: 7)
    /// The projects that cost the most, at API list prices, dearest first.
    public var projects: [(name: String, usd: Double)] = []

    public init() {}

    public var isEmpty: Bool {
        coldStarts == 0 && rebuilds == 0 && compacts == 0 && hit == nil && projects.isEmpty
    }

    public static func == (left: Week, right: Week) -> Bool {
        left.coldStarts == right.coldStarts && left.coldTokens == right.coldTokens
            && left.rebuilds == right.rebuilds && left.rebuildTokens == right.rebuildTokens
            && left.compacts == right.compacts && left.compactSaved == right.compactSaved
            && left.hit == right.hit && left.daily == right.daily
            && left.projects.map(\.name) == right.projects.map(\.name)
            && left.projects.map(\.usd) == right.projects.map(\.usd)
    }
}

/// What the app keeps from one day to the next: readings of the limits, to tell the pace,
/// and each day's totals, for the weekly ledger. Sums and counts only; never what was said
/// in a session. It stays on this Mac, in `history.json`, for thirty days.
public struct History: Codable, Equatable {
    public struct Sample: Codable, Equatable {
        public var at: Double
        public var used: Double
        public var resetsAt: Double
    }

    public struct Day: Codable, Equatable {
        /// Times a session's cache was seen cold and then in use again, and what that rewrote.
        public var coldStarts = 0
        public var coldTokens: Double = 0
        /// Cache misses Claude Code counted, and what they wrote again.
        public var rebuilds = 0
        public var rebuildTokens: Double = 0
        /// Each session's average cache hit rate, as last seen that day.
        public var hits: [String: Int] = [:]
        /// Cost by project folder, in US dollars at API list prices.
        public var projects: [String: Double] = [:]
        /// Compactions seen, and the tokens they took off the context. Optional: a file
        /// written before these were kept has neither.
        public var compacts: Int? = nil
        public var compactSaved: Double? = nil
    }

    /// What a session's turns have taken of the 5-hour limit lately: percent, over turns.
    public struct Burn: Codable, Equatable {
        public var percent: Double = 0
        public var turns: Double = 0
    }

    /// A session's counters as last seen, to tell what a later look adds.
    public struct Seen: Codable, Equatable {
        public var misses: Int
        public var missTokens: Double
        public var cost: Double
        public var expiresAt: Double?
        public var coldTokens: Double
        public var wasCold: Bool
        /// When the session's last compaction counted was, and its turn count as last seen.
        public var compactAt: Double? = nil
        public var turns: Int? = nil
    }

    public static let retention: TimeInterval = 30 * 86400
    /// A reading is kept when it moved, or this long after the last one kept.
    public static let sampleEvery: TimeInterval = 300
    /// How far back the pace looks, by window.
    public static let lookback: [String: TimeInterval] = ["five_hour": 1800, "seven_day": 86400]
    /// Less than this much to go by says nothing about the pace.
    public static let minimumSpan: TimeInterval = 600
    /// A session first seen this long after it last did something is not counted from the start.
    static let freshness: TimeInterval = 300
    /// A turn's share of the 5-hour limit is said from this many turns on.
    public static let minimumTurns: Double = 3
    /// Past this many turns the tally is halved, so the figure follows the session as it grows.
    static let turnMemory: Double = 20

    public var v = 1
    public var samples: [String: [Sample]] = [:]
    public var days: [String: Day] = [:]
    public var sessions: [String: Seen] = [:]
    /// When the ledger began counting; nil until its first look at the sessions.
    public var since: Double?
    /// By session: what its turns have taken of the 5-hour limit.
    public var burn: [String: Burn]?
    /// The 5-hour reading as last looked at, to tell what was used since.
    public var lastFiveHour: Sample?

    public init() {}

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Pace

    /// Takes in the limits as they read now. Readings of a window that has since reset go.
    public mutating func sample(limits: [String: LimitView], now: Date) {
        let at = now.timeIntervalSince1970
        for (kind, limit) in limits {
            guard let resetsAt = limit.resetsAt else { continue }
            var kept = (samples[kind] ?? []).filter { abs($0.resetsAt - resetsAt) < 120 }
            if let last = kept.last, last.used == limit.used, at - last.at < History.sampleEvery {
                samples[kind] = kept
                continue
            }
            kept.append(Sample(at: at, used: limit.used, resetsAt: resetsAt))
            samples[kind] = Array(kept.suffix(600))
        }
    }

    /// Where the rate of use over the window's recent past leads; nil with too little to
    /// go by, or when nothing was used in that time.
    public func pace(_ kind: String, limit: LimitView, now: Date) -> Pace? {
        let at = now.timeIntervalSince1970
        guard let resetsAt = limit.resetsAt, let lookback = History.lookback[kind] else { return nil }
        let window = (samples[kind] ?? []).filter { abs($0.resetsAt - resetsAt) < 120 && at - $0.at <= lookback }
        guard let first = window.first, at - first.at >= History.minimumSpan else { return nil }
        let rate = (limit.used - first.used) / (at - first.at)
        guard rate > 0 else { return nil }
        let reachesAt = at + (100 - limit.used) / rate
        return reachesAt < resetsAt ? .hits(at: Date(timeIntervalSince1970: reachesAt)) : .lasts
    }

    // MARK: Ledger

    /// Adds what the sessions did since the last look to today's totals.
    ///
    /// `states` are the plugin's notes: they say when a session was compacted and how many
    /// turns it has finished. `fiveHour` is the 5-hour limit as it reads now; what it grew by
    /// since the last look goes to the one session that was at work in between, and to none
    /// when more than one was.
    public mutating func record(
        snapshots: [Snapshot], states: [String: SessionState] = [:], fiveHour: LimitView? = nil, now: Date,
        calendar: Calendar = .current
    ) {
        let at = now.timeIntervalSince1970
        let key = History.dayKey(now, calendar: calendar)
        var day = days[key] ?? Day()
        // On the first look every session was running before the count began.
        let isFirstRecord = since == nil
        since = since ?? at
        // What the 5-hour limit grew by since the last look, within one window.
        var used: Double = 0
        if let fiveHour, let resetsAt = fiveHour.resetsAt {
            if let last = lastFiveHour, abs(last.resetsAt - resetsAt) < 120 { used = max(0, fiveHour.used - last.used) }
            lastFiveHour = Sample(at: at, used: fiveHour.used, resetsAt: resetsAt)
        }
        var atWork: [String] = []
        var burn = self.burn ?? [:]

        for snapshot in snapshots {
            let id = snapshot.sessionID
            let state = states[id]
            let misses = snapshot.cache.misses ?? 0
            let missTokens = snapshot.cache.missRecacheTokens ?? 0
            let cost = snapshot.costUSD ?? 0
            let coldTokens = snapshot.cache.recacheTokens ?? snapshot.context.tokens
            let isCold = !snapshot.cache.active && (snapshot.cache.expiresAt.map { $0 <= at } ?? false)
            let folder = snapshot.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""

            // A session met for the first time long after it went quiet is history already
            // made: it is counted from here on, not from its start.
            let isFresh = !isFirstRecord && at - snapshot.updatedAt <= History.freshness
            let before = sessions[id] ?? Seen(
                misses: isFresh ? 0 : misses, missTokens: isFresh ? 0 : missTokens, cost: isFresh ? 0 : cost,
                expiresAt: snapshot.cache.expiresAt, coldTokens: coldTokens, wasCold: isCold,
                // A compaction from before the session was first seen is history already made.
                compactAt: state?.compact.flatMap { isFirstRecord || at - $0.at > History.freshness ? $0.at : nil },
                turns: state?.turns)

            // Counted once its size afterwards is known; until then it waits.
            var compactAt = before.compactAt
            if let compact = state?.compact, compact.at != before.compactAt, let after = compact.after {
                day.compacts = (day.compacts ?? 0) + 1
                day.compactSaved = (day.compactSaved ?? 0) + max(0, (compact.before ?? after) - after)
                compactAt = compact.at
            }
            // A count that went down is a plugin that loaded again: it starts over, uncounted.
            let finished = max(0, (state?.turns ?? 0) - (before.turns ?? state?.turns ?? 0))
            if finished > 0 { burn[id, default: Burn()].turns += Double(finished) }
            let isRunning = state?.state == SessionState.running
                && at - max(snapshot.updatedAt, state?.at ?? 0) <= Summary.runningGrace
            if isRunning || snapshot.cache.active && isFresh || finished > 0 || cost > before.cost { atWork.append(id) }

            if misses > before.misses {
                day.rebuilds += misses - before.misses
                day.rebuildTokens += max(0, missTokens - before.missTokens)
            }
            if cost > before.cost, !folder.isEmpty {
                day.projects[folder, default: 0] += cost - before.cost
            }
            // Cold when last looked at, and running on a later expiry now: it was started cold.
            if before.wasCold, let expiresAt = snapshot.cache.expiresAt, expiresAt > (before.expiresAt ?? 0), expiresAt > at {
                day.coldStarts += 1
                day.coldTokens += before.coldTokens
            }
            if let hit = snapshot.cache.avgHit, at - snapshot.updatedAt <= 86400 {
                day.hits[id] = hit
            }
            sessions[id] = Seen(
                misses: misses, missTokens: missTokens, cost: cost, expiresAt: snapshot.cache.expiresAt,
                coldTokens: coldTokens, wasCold: isCold, compactAt: compactAt, turns: state?.turns)
        }
        if day != Day() { days[key] = day }

        if used > 0, atWork.count == 1, !isFirstRecord { burn[atWork[0], default: Burn()].percent += used }
        for (id, tally) in burn where tally.turns >= History.turnMemory {
            burn[id] = Burn(percent: tally.percent / 2, turns: tally.turns / 2)
        }

        // Sessions whose snapshot is gone, and days past keeping.
        let listed = Set(snapshots.map(\.sessionID))
        sessions = sessions.filter { listed.contains($0.key) }
        burn = burn.filter { listed.contains($0.key) }
        self.burn = burn.isEmpty ? nil : burn
        let oldest = History.dayKey(now.addingTimeInterval(-History.retention), calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }

    /// The seven days ending today.
    public func week(now: Date, calendar: Calendar = .current) -> Week {
        var week = Week()
        var hits: [Int] = []
        var projects: [String: Double] = [:]
        for back in 0..<7 {
            let date = calendar.date(byAdding: .day, value: -back, to: now) ?? now
            guard let day = days[History.dayKey(date, calendar: calendar)] else { continue }
            week.coldStarts += day.coldStarts
            week.coldTokens += day.coldTokens
            week.rebuilds += day.rebuilds
            week.rebuildTokens += day.rebuildTokens
            week.compacts += day.compacts ?? 0
            week.compactSaved += day.compactSaved ?? 0
            week.daily[6 - back] = day.coldTokens + day.rebuildTokens
            hits += day.hits.values
            for (name, usd) in day.projects { projects[name, default: 0] += usd }
        }
        week.hit = hits.isEmpty ? nil : Int((Double(hits.reduce(0, +)) / Double(hits.count)).rounded())
        week.projects = projects.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3).map { (name: $0.key, usd: $0.value) }
        return week
    }
}

extension History {
    /// What a turn of this session has been taking of the 5-hour limit, in percent; nil
    /// until enough turns have been seen, or when none of the limit's growth was its own.
    public func turnShare(of sessionID: String) -> Double? {
        guard let tally = burn?[sessionID], tally.turns >= History.minimumTurns, tally.percent > 0 else { return nil }
        return tally.percent / tally.turns
    }
}

public enum HistoryStore {
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["CACHECUE_HISTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CacheCue/history.json")
    }

    /// The history on disk; an empty one when there is none, or it does not read.
    public static func load(from url: URL) -> History {
        guard let data = try? Data(contentsOf: url), let history = try? JSONDecoder().decode(History.self, from: data),
              history.v == 1
        else { return History() }
        return history
    }

    public static func save(_ history: History, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(history).write(to: url, options: .atomic)
    }
}
