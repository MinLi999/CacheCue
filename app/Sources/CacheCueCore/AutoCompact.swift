import Foundation

/// Compacting a session for the person, before its cache goes cold. Off unless they turned
/// it on for that session: compacting throws detail away and cannot be undone. The app
/// decides when and leaves a request; the plugin in the session carries it out.
public enum AutoCompact {
    /// How long before the cache runs out the request is made: late enough that the person
    /// has plainly stepped away, early enough for the summary to be written from a warm cache.
    public static let lead: TimeInterval = 300
    /// With less than this left, the summarising request would not reach the cache in time.
    public static let tooLate: TimeInterval = 45
    /// A request the plugin has not answered in this long is taken back.
    public static let requestLife: TimeInterval = 600

    /// A five-minute cache runs out during any pause: compacting at each would be absurd.
    public static func isOffered(for session: SessionView) -> Bool {
        session.lifetime >= 3600
    }

    /// The sessions to compact now. Each cache is asked about once: `ledger` holds, by
    /// session, the expiry a request was last made for.
    public static func due(sessions: [SessionView], enabled: Set<String>, ledger: inout [String: Double]) -> [SessionView] {
        var due: [SessionView] = []
        for session in sessions where enabled.contains(session.id) {
            guard isOffered(for: session), session.acceptsCompact, session.isIdle,
                  session.contextTokens >= CompactAdvice.smallContext,
                  case .expires(let left) = session.cache, left <= lead, left > tooLate,
                  let expiresAt = session.expiresAt, ledger[session.id] != expiresAt
            else { continue }
            ledger[session.id] = expiresAt
            due.append(session)
        }
        let listed = Set(sessions.map(\.id))
        ledger = ledger.filter { listed.contains($0.key) }
        return due
    }

    /// Where a session with the switch on stands.
    public enum Status: Equatable {
        /// The plugin in the session is too old to be asked, or the session has none.
        case needsPlugin
        /// Waiting for the moment.
        case armed
        /// Compacted on the app's request.
        case done(SessionState.Compaction)
        /// A request did not go through, and nothing has been compacted since.
        case failed
    }

    public static func status(of session: SessionView) -> Status {
        guard session.acceptsCompact else { return .needsPlugin }
        if let failed = session.compactFailed, failed.at >= (session.lastCompact?.at ?? 0) { return .failed }
        if let compact = session.lastCompact, compact.request != nil { return .done(compact) }
        return .armed
    }
}

extension SessionView {
    /// What to say under the switch for compacting this session automatically.
    public func autoCompactLine(_ strings: Strings, now: Date, calendar: Calendar = .current) -> String {
        switch AutoCompact.status(of: self) {
        case .needsPlugin: return strings.autoCompactNeedsPlugin
        case .armed: return String(format: strings.autoCompactNote, Int(AutoCompact.lead / 60))
        case .failed: return strings.autoCompactFailed
        case .done(let compact):
            let time = Format.clock(Date(timeIntervalSince1970: compact.at), now: now, calendar: calendar)
            var line = String(format: strings.autoCompactDone, time)
            if let before = compact.before, let after = compact.after {
                line += " · \(Format.tokens(before)) → \(Format.tokens(after))"
            }
            return line
        }
    }
}
