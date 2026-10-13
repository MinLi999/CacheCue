import Foundation

/// What the command behind Claude Code's `statusLine` setting does with the session JSON it
/// is piped: it makes the snapshot the menu bar app reads, and prints nothing. The terminal
/// shows no line of ours; the figures live in the menu bar.
public enum StatusLine {
    private static func number(_ value: Any?) -> Double? {
        // A JSON true is an NSNumber too; it is not a figure.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func object(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    /// The session's figures as a snapshot; `previous` is the one written last, which
    /// carries forward the two timestamps a re-run with nothing new must not move.
    public static func snapshot(from input: [String: Any], now: Date, previous: Snapshot?) -> Snapshot? {
        guard let sessionID = input["session_id"] as? String, !sessionID.isEmpty else { return nil }
        let at = now.timeIntervalSince1970
        let context = object(input["context_window"])
        let usage = object(context["current_usage"])
        let cache = object(input["prompt_cache"])

        let read = number(usage["cache_read_input_tokens"]) ?? 0
        let total = read + (number(usage["cache_creation_input_tokens"]) ?? 0) + (number(usage["input_tokens"]) ?? 0)

        var limits: [String: Snapshot.Limit] = [:]
        for kind in ["five_hour", "seven_day", "spend_limit"] {
            let window = object(object(input["rate_limits"])[kind])
            if let used = number(window["used_percentage"]) {
                limits[kind] = .init(
                    used: used, resetsAt: number(window["resets_at"]),
                    usedUSD: number(window["used_usd"]), limitUSD: number(window["limit_usd"]),
                    period: window["period"] as? String)
            }
        }
        let model = object(input["model"])
        // `5m` or `1h`, as Claude Code names the two lifetimes.
        let ttl: Double? = (cache["ttl"] as? String).flatMap { $0 == "1h" ? 3600 : $0 == "5m" ? 300 : nil }
        func text(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        // Each session holds only its own last reading of the account's limits, so the app
        // needs each reading's age. The command is never told it: the run where a reading
        // first differs is the nearest thing, and with nothing to compare, it is unknown.
        let limitsAt: Double? = previous.flatMap { previous in
            !limits.isEmpty && previous.limits != limits ? at.rounded() : previous.limitsAt
        }

        var snapshot = Snapshot(
            v: Snapshot.version,
            source: "terminal",
            sessionID: sessionID,
            cwd: object(input["workspace"])["project_dir"] as? String ?? input["cwd"] as? String,
            cache: .init(
                turnHit: total > 0 ? Int((read * 100 / total).rounded()) : nil,
                avgHit: number(cache["hit_ratio"]).map { Int(($0 * 100).rounded()) },
                expiresAt: number(cache["expires_at"]),
                active: false,
                ttl: ttl,
                recacheTokens: number(cache["recache_tokens_if_cold"]),
                misses: number(cache["misses"]).map { Int($0) },
                missRecacheTokens: number(cache["miss_recache_tokens"]),
                lastMissCauses: object(cache["last_miss_cause"])["causes"] as? [String]),
            limits: limits,
            limitsAt: limitsAt,
            context: .init(
                tokens: number(context["total_input_tokens"]) ?? 0,
                output: number(context["total_output_tokens"]) ?? 0,
                window: number(context["context_window_size"]) ?? 0,
                percent: number(context["used_percentage"])),
            costUSD: number(object(input["cost"])["total_cost_usd"]),
            updatedAt: previous?.updatedAt ?? at.rounded(),
            name: text(input["session_name"]),
            model: text(model["display_name"]),
            modelID: text(model["id"]),
            effort: text(object(input["effort"])["level"]),
            fast: input["fast_mode"] as? Bool,
            worktree: text(object(input["worktree"])["name"]) ?? text(object(input["workspace"])["git_worktree"]))
        // Stamped anew only when a figure moved, so `updatedAt` reads "this session last
        // did something" and the app can tell which session is the live one.
        if snapshot != previous {
            snapshot.updatedAt = at.rounded()
        }
        return snapshot
    }

    /// The snapshot for whatever arrived on stdin; nil when it is not JSON or names no session.
    public static func snapshot(input data: Data, now: Date, previous: Snapshot?) -> Snapshot? {
        snapshot(from: object(try? JSONSerialization.jsonObject(with: data)), now: now, previous: previous)
    }
}

extension SnapshotStore {
    public static func url(for sessionID: String, in directory: URL) -> URL {
        let safe = sessionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent((safe.isEmpty ? "unknown" : safe) + ".json")
    }

    public static func read(_ sessionID: String, in directory: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url(for: sessionID, in: directory)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Writes whole or not at all: the status line command can be cancelled mid-run.
    public static func write(_ snapshot: Snapshot, in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(snapshot).write(to: url(for: snapshot.sessionID, in: directory), options: .atomic)
    }
}
