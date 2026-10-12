import Foundation

/// Whether now is a good moment to run `/compact`, and why.
///
/// What it rests on (Claude Code's prompt caching docs): while the cache is warm, the
/// summarising request reads the conversation from it and costs a fraction of the
/// context's size; once the cache has expired, the same request reprocesses the whole
/// history uncached. Compacting throws detail away, so mid-task is the worst moment, and
/// on a small context it costs more than it saves. `/clear` costs nothing.
public struct CompactAdvice: Equatable {
    public enum Kind: Equatable {
        /// A turn is in flight; nothing can be compacted until it ends.
        case running
        /// The window is nearly full: auto-compact is about to choose the moment itself.
        case nearFull
        /// Too little context for compacting to pay.
        case notNeeded
        /// The cache has expired: the next message reprocesses everything either way.
        case cold
        /// The cache is about to expire: compact now if stepping away.
        case beforeExpiry
        /// Enough context that compacting pays, at the next break between tasks.
        case worthIt
        /// In between: only worth it when changing tasks.
        case optional
    }

    // Rules of thumb, not figures from Anthropic.
    /// Below this many tokens, compacting is not worth its own cost.
    public static let smallContext: Double = 50_000
    /// From this many tokens, every request re-reads enough for compacting to pay soon.
    public static let largeContext: Double = 100_000
    /// From this share of the window, auto-compact is close.
    public static let nearFullPercent: Double = 80
    /// With this little time left on the cache, stepping away means losing it.
    public static let expiryWindow: TimeInterval = 600

    public var kind: Kind
    public var contextTokens: Double
    public var contextPercent: Double?
    /// Seconds left on the cache, when it is counting down.
    public var expiresIn: TimeInterval?

    public init(contextTokens: Double, contextPercent: Double?, cache: CacheState) {
        self.contextTokens = contextTokens
        self.contextPercent = contextPercent
        if case .expires(let left) = cache { expiresIn = left }

        if cache == .active {
            kind = .running
        } else if let contextPercent, contextPercent >= CompactAdvice.nearFullPercent {
            kind = .nearFull
        } else if contextTokens < CompactAdvice.smallContext {
            kind = .notNeeded
        } else if cache == .expired {
            kind = .cold
        } else if let expiresIn, expiresIn <= CompactAdvice.expiryWindow {
            kind = .beforeExpiry
        } else {
            kind = contextTokens >= CompactAdvice.largeContext ? .worthIt : .optional
        }
    }

    /// Something to do now, as against something to keep in mind.
    public var isActionable: Bool {
        kind == .nearFull || kind == .cold || kind == .beforeExpiry
    }

    public var level: Level {
        switch kind {
        case .running, .optional: return .plain
        case .notNeeded: return .ok
        case .worthIt: return .warn
        case .beforeExpiry: return (expiresIn ?? 0) <= 120 ? .crit : .warn
        case .cold, .nearFull: return .crit
        }
    }

    public func headline(_ strings: Strings) -> String {
        switch kind {
        case .running: return strings.adviceRunning
        case .nearFull: return strings.adviceNearFull
        case .notNeeded: return strings.adviceNotNeeded
        case .cold: return strings.adviceCold
        case .beforeExpiry: return strings.adviceBeforeExpiry
        case .worthIt: return strings.adviceWorthIt
        case .optional: return strings.adviceOptional
        }
    }

    public func detail(_ strings: Strings) -> String {
        let size = Format.tokens(contextTokens)
        switch kind {
        case .running: return strings.adviceRunningDetail
        case .nearFull: return String(format: strings.adviceNearFullDetail, Int((contextPercent ?? 0).rounded()))
        case .notNeeded: return String(format: strings.adviceNotNeededDetail, size)
        case .cold: return String(format: strings.adviceColdDetail, size)
        case .beforeExpiry: return String(format: strings.adviceBeforeExpiryDetail, Format.countdown(expiresIn ?? 0))
        case .worthIt: return String(format: strings.adviceWorthItDetail, size)
        case .optional: return String(format: strings.adviceOptionalDetail, size)
        }
    }
}

extension SessionView {
    public var advice: CompactAdvice {
        CompactAdvice(contextTokens: contextTokens, contextPercent: contextPercent, cache: cache)
    }
}
