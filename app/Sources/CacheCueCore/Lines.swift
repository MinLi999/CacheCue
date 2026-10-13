import Foundation

// What the popover says in words about a session's cache, a limit's pace and a
// notification: decided here, drawn by the views.

extension Format {
    /// A moment as the pace line names it: `14:32` today, `10-16 09:05` on another day.
    public static func clock(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        return String(format: "%02d-%02d ", parts.month ?? 0, parts.day ?? 0) + time
    }

    /// Time left on a cache, as a notification says it: `08:12` inside five minutes, `9m` beyond.
    public static func left(_ interval: TimeInterval) -> String {
        interval < 300 ? countdown(interval) : reset(interval)
    }
}

extension SessionView {
    /// The advice card's line on what letting the cache go cold costs; nil where there is
    /// no advice to weigh it against.
    public func coldLine(_ strings: Strings) -> String? {
        let kind = advice.kind
        guard kind != .running, kind != .notNeeded else { return nil }
        let cost = coldCost
        // A cache already cold is not "going" anywhere: taking the session up again is what rewrites.
        return String(format: cache == .expired ? strings.resumeRewrites : strings.coldRewrite, cost.tokensText) + " · "
            + String(format: strings.coldRatio, cost.ratioText)
    }

    /// Under a session whose cache has gone cold with enough context to matter: what taking
    /// it up again rewrites.
    public func resumeLine(_ strings: Strings) -> String? {
        guard cache == .expired, contextTokens >= CompactAdvice.smallContext else { return nil }
        return String(format: strings.resumeRewrites, coldCost.tokensText)
    }

    /// What a turn of this session has been taking of the 5-hour limit: `0.8` below ten
    /// percent, whole numbers from there.
    public func turnShareLine(_ strings: Strings) -> String? {
        guard let turnShare, turnShare > 0 else { return nil }
        let figure = turnShare < 10 ? String(format: "%.1f", turnShare) : String(format: "%.0f", turnShare)
        return String(format: strings.turnShare, figure)
    }

    /// The same in dollars, for an account the dollars are a bill for.
    public func coldPriceLine(_ strings: Strings, isSubscription: Bool) -> String? {
        guard !isSubscription, coldLine(strings) != nil, let cold = coldCost.coldUSD, let warm = coldCost.warmUSD
        else { return nil }
        return String(format: strings.coldPrice, ColdCost.dollars(cold), ColdCost.dollars(warm))
    }

    /// Cache misses Claude Code counted for this session; nil when it counted none.
    public func missLine(_ strings: Strings) -> String? {
        misses > 0 ? String(format: strings.missSummary, misses, Format.tokens(missTokens)) : nil
    }

    public func missCauseLine(_ strings: Strings) -> String? {
        guard misses > 0, !lastMissCauses.isEmpty else { return nil }
        return String(format: strings.missCause, lastMissCauses.map(strings.missCause(named:)).joined(separator: ", "))
    }

    /// Said under a five-minute cache on a subscription, where an hour is the rule.
    public func shortCacheLine(_ strings: Strings, isSubscription: Bool) -> String? {
        isSubscription && lifetime < 3600 ? strings.shortCacheNote : nil
    }
}

extension LimitView {
    public func paceLine(_ strings: Strings, now: Date, calendar: Calendar = .current) -> String? {
        switch pace {
        case .hits(let at): return String(format: strings.paceHits, Format.clock(at, now: now, calendar: calendar))
        case .lasts: return strings.paceLasts
        case nil: return nil
        }
    }

    /// `$314 / $500`, where a gateway's spend limit says both.
    public var dollarsText: String? {
        guard let usedUSD, let limitUSD else { return nil }
        return String(format: "$%.0f / $%.0f", usedUSD, limitUSD)
    }
}

extension Summary {
    /// The limits that have a reading, by kind.
    public var limits: [String: LimitView] {
        var limits: [String: LimitView] = [:]
        limits["five_hour"] = fiveHour
        limits["seven_day"] = sevenDay
        limits["spend_limit"] = spendLimit
        return limits
    }

    /// Every session listed, the one in view first.
    public var sessions: [SessionView] { (current.map { [$0] } ?? []) + others }

    /// Every session still alive, listed or not: what a notification or a compaction goes by.
    public var every: [SessionView] { sessions + unlisted }

    /// An account with a gateway's spend limit and neither of a subscription's windows.
    public var showsSpendLimit: Bool { fiveHour == nil && sevenDay == nil && spendLimit != nil }

    /// Gives each session what a turn of it has been taking of the 5-hour limit.
    public mutating func setTurnShares(from history: History) {
        if let id = current?.id { current?.turnShare = history.turnShare(of: id) }
        for index in others.indices {
            others[index].turnShare = history.turnShare(of: others[index].id)
        }
    }

    /// Works out where each window's rate of use leads, from the readings kept so far.
    public mutating func setPace(from history: History, now: Date) {
        if let limit = fiveHour { fiveHour?.pace = history.pace("five_hour", limit: limit, now: now) }
        if let limit = sevenDay { sevenDay?.pace = history.pace("seven_day", limit: limit, now: now) }
    }
}

extension Alert {
    public func title(_ strings: Strings) -> String {
        switch self {
        case .cacheExpiring(_, let name, let left, _):
            return String(format: strings.notifyCacheTitle, name, Format.left(left))
        case .quota(let kind, let percent, _):
            return String(format: strings.notifyQuotaTitle, strings.limitTitle(kind), percent)
        case .windowReset(let kind):
            return String(format: strings.notifyResetTitle, strings.limitTitle(kind))
        }
    }

    public func body(_ strings: Strings) -> String {
        switch self {
        case .cacheExpiring(_, _, _, let cold): return String(format: strings.notifyCacheBody, cold.tokensText)
        case .quota(_, _, let resetsIn): return resetsIn.map { strings.reset(in: $0) } ?? ""
        case .windowReset: return ""
        }
    }

    /// The session a press on the notification should bring into view.
    public var sessionID: String? {
        if case .cacheExpiring(let id, _, _, _) = self { return id }
        return nil
    }
}

extension Week {
    public func coldLine(_ strings: Strings) -> String {
        "\(strings.ledgerColdStarts) \(coldStarts) · " + String(format: strings.ledgerRewritten, Format.tokens(coldTokens))
    }

    public func rebuildLine(_ strings: Strings) -> String {
        "\(strings.ledgerRebuilds) \(rebuilds) · " + String(format: strings.ledgerRewritten, Format.tokens(rebuildTokens))
    }

    /// Nil in a week with no compaction on record.
    public func compactLine(_ strings: Strings) -> String? {
        compacts > 0
            ? "\(strings.ledgerCompacts) \(compacts) · " + String(format: strings.ledgerTrimmed, Format.tokens(compactSaved))
            : nil
    }

    public var projectsLine: String {
        projects.map { "\($0.name) \(ColdCost.dollars($0.usd))" }.joined(separator: " · ")
    }
}

extension Summary {
    /// The figures for a script, as `CacheCue status --json` prints them. Times are seconds
    /// from now; what has no reading is left out.
    public func json(now: Date) -> Data {
        func limit(_ limit: LimitView) -> [String: Any] {
            var object: [String: Any] = ["used_percent": limit.used]
            object["resets_in"] = limit.resetsIn.map { Int($0) }
            object["used_usd"] = limit.usedUSD
            object["limit_usd"] = limit.limitUSD
            if case .hits(let at) = limit.pace { object["runs_out_in"] = Int(at.timeIntervalSince(now)) }
            if limit.pace == .lasts { object["lasts_until_reset"] = true }
            return object
        }
        func session(_ session: SessionView) -> [String: Any] {
            let advice = session.advice
            var object: [String: Any] = [
                "id": session.id, "name": session.name, "source": session.source,
                "context_tokens": session.contextTokens, "cache_lifetime": Int(session.lifetime),
                "cold_tokens": session.coldCost.tokens, "cold_ratio": session.coldCost.ratio,
                "advice": String(describing: advice.kind), "actionable": advice.isActionable,
                "waiting": session.isWaiting,
            ]
            switch session.cache {
            case .unknown: object["cache"] = "unknown"
            case .active: object["cache"] = "active"
            case .expired: object["cache"] = "expired"
            case .expires(let left):
                object["cache"] = "warm"
                object["expires_in"] = Int(left)
            }
            object["context_percent"] = session.contextPercent
            object["cost_usd"] = session.costUSD
            object["model"] = session.modelID
            return object
        }
        var object: [String: Any] = ["limits": limits.mapValues(limit), "others": others.map(session)]
        object["current"] = current.map(session)
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
