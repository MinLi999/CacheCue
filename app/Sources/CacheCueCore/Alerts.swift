import Foundation

/// Something worth a notification: a cache about to go cold, a limit filling up, a window
/// starting over.
public enum Alert: Equatable {
    case cacheExpiring(sessionID: String, name: String, left: TimeInterval, cold: ColdCost)
    /// `kind` is `five_hour`, `seven_day` or `spend_limit`.
    case quota(kind: String, percent: Int, resetsIn: TimeInterval?)
    case windowReset(kind: String)
}

/// What has been announced already, so nothing is announced twice.
public struct AlertLedger: Codable, Equatable {
    /// By session: the expiry the person was last warned of.
    public var cache: [String: Double] = [:]
    /// By `kind|threshold`: the reset time of the window it was announced for.
    public var quota: [String: Double] = [:]
    /// By kind: the reset time of the window last seen, to tell when it starts over.
    public var windows: [String: Double] = [:]

    public init() {}
}

public enum Alerts {
    /// A limit is announced as it passes each of these, in percent.
    public static let thresholds: [Double] = [80, 95]
    /// The lead times the person may pick for a one-hour cache, in seconds.
    public static let leads: [TimeInterval] = [300, 600, 900]
    public static let defaultLead: TimeInterval = 600

    /// How long before a cache runs out to say so: the person's choice for a one-hour
    /// cache; for a shorter one, the same window the advice goes by.
    public static func lead(chosen: TimeInterval, lifetime: TimeInterval) -> TimeInterval {
        lifetime >= 3600 ? chosen : CacheState.warnWindow(lifetime: lifetime)
    }

    /// What is due now. Each cache is announced once per expiry: a session that carries on
    /// gets a new expiry, and so a new warning when that one nears. A context too small to
    /// be worth compacting is left alone, and so is a session with a turn running.
    public static func due(
        sessions: [SessionView], limits: [String: LimitView], now: Date, lead: TimeInterval,
        cache isCacheOn: Bool, quota isQuotaOn: Bool, ledger: inout AlertLedger
    ) -> [Alert] {
        let at = now.timeIntervalSince1970
        var alerts: [Alert] = []

        if isCacheOn {
            for session in sessions {
                guard case .expires(let left) = session.cache, let expiresAt = session.expiresAt,
                      session.contextTokens >= CompactAdvice.smallContext,
                      left <= Alerts.lead(chosen: lead, lifetime: session.lifetime),
                      ledger.cache[session.id] != expiresAt
                else { continue }
                ledger.cache[session.id] = expiresAt
                alerts.append(.cacheExpiring(sessionID: session.id, name: session.name, left: left, cold: session.coldCost))
            }
        }
        let listed = Set(sessions.map(\.id))
        ledger.cache = ledger.cache.filter { listed.contains($0.key) }

        if isQuotaOn {
            // A window seen before whose reset time has come has started over.
            for (kind, resetsAt) in ledger.windows where resetsAt <= at {
                ledger.windows[kind] = nil
                alerts.append(.windowReset(kind: kind))
            }
            for (kind, limit) in limits.sorted(by: { $0.key < $1.key }) {
                guard let resetsAt = limit.resetsAt else { continue }
                ledger.windows[kind] = resetsAt
                // Only the highest mark passed is said; the lower ones are taken as said.
                let passed = thresholds.filter { limit.used >= $0 }
                let unsaid = passed.filter { ledger.quota["\(kind)|\(Int($0))"] != resetsAt }
                for threshold in passed { ledger.quota["\(kind)|\(Int(threshold))"] = resetsAt }
                if unsaid.max() != nil {
                    alerts.append(.quota(kind: kind, percent: limit.percent, resetsIn: limit.resetsIn))
                }
            }
        } else {
            ledger.windows = [:]
        }
        return alerts
    }
}
