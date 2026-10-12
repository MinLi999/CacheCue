import Foundation

/// The terminal status line, from the session JSON Claude Code pipes to the command:
///
///     cache 94% avg 96% ◷47:36 | 5h ▰▱▱▱▱▱▱▱ 2% ↻4h36m | 7d ▰▰▰▰▰▰▱▱ 76% ↻13h56m | ↑68.6k ↓9.6k ◆1.0M | $206.51
///
/// It also makes the snapshot the menu bar app reads. Whatever the input, it answers with
/// a line: a command that fails leaves the whole status line blank.
public enum StatusLine {
    public struct Output: Equatable {
        public var line: String
        /// Nil when the input names no session.
        public var snapshot: Snapshot?
    }

    private enum Tone: String {
        // Bright blue, not 34: the plain one all but vanishes on a dark terminal.
        case dim = "2", ok = "36", warn = "33", crit = "1;31", blue = "94", plain = "0"

        init(_ level: Level) {
            switch level {
            case .plain: self = .plain
            case .ok: self = .ok
            case .warn: self = .warn
            case .crit: self = .crit
            }
        }
    }

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
        for kind in ["five_hour", "seven_day"] {
            let window = object(object(input["rate_limits"])[kind])
            if let used = number(window["used_percentage"]) {
                limits[kind] = .init(used: used, resetsAt: number(window["resets_at"]))
            }
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
                active: false),
            limits: limits,
            limitsAt: limitsAt,
            context: .init(
                tokens: number(context["total_input_tokens"]) ?? 0,
                output: number(context["total_output_tokens"]) ?? 0,
                window: number(context["context_window_size"]) ?? 0,
                percent: number(context["used_percentage"])),
            costUSD: number(object(input["cost"])["total_cost_usd"]),
            updatedAt: previous?.updatedAt ?? at.rounded())
        // Stamped anew only when a figure moved, so `updatedAt` reads "this session last
        // did something" and the app can tell which session is the live one.
        if snapshot != previous {
            snapshot.updatedAt = at.rounded()
        }
        return snapshot
    }

    public static func render(input data: Data, now: Date, previous: Snapshot?, color: Bool) -> Output {
        let input = object(try? JSONSerialization.jsonObject(with: data))
        let at = now.timeIntervalSince1970
        func paint(_ text: String, _ tone: Tone) -> String {
            color && !text.isEmpty ? "\u{1B}[\(tone.rawValue)m\(text)\u{1B}[0m" : text
        }

        // With no session named there is nothing to write, but the line is still drawn.
        let made = snapshot(from: input, now: now, previous: previous)
        let context = object(input["context_window"])
        let usage = object(context["current_usage"])
        let read = number(usage["cache_read_input_tokens"]) ?? 0
        let total = read + (number(usage["cache_creation_input_tokens"]) ?? 0) + (number(usage["input_tokens"]) ?? 0)
        let promptCache = object(input["prompt_cache"])

        // Cache: this turn's hit rate, the session's, and the time left.
        func hit(_ percent: Int?, bold: Bool = false) -> String {
            guard let percent else { return paint("--", .dim) }
            let level = Format.hitLevel(percent)
            return color && bold && level != .crit
                ? "\u{1B}[1;\(Tone(level).rawValue)m\(percent)%\u{1B}[0m" : paint("\(percent)%", Tone(level))
        }
        var cacheParts = [paint("cache", .dim), hit(total > 0 ? Int((read * 100 / total).rounded()) : nil, bold: true)]
        if let ratio = number(promptCache["hit_ratio"]) {
            cacheParts += [paint("avg", .dim), hit(Int((ratio * 100).rounded()))]
        }
        let state: CacheState
        if let expiresAt = number(promptCache["expires_at"]) {
            state = expiresAt > at ? .expires(in: expiresAt - at) : .expired
        } else {
            state = .unknown
        }
        switch state {
        case .unknown: cacheParts.append(paint("◷--:--", .dim))
        case .expired: cacheParts.append(paint("◷expired", .crit))
        case .expires(let left): cacheParts.append(paint("◷", .dim) + paint(Format.countdown(left), Tone(state.level)))
        case .active: break
        }

        func limit(_ label: String, _ kind: String) -> String {
            let window = object(object(input["rate_limits"])[kind])
            guard let used = number(window["used_percentage"]) else { return paint("\(label) --", .dim) }
            let tone = Tone(Format.level(used, warn: 70, crit: 90))
            let filled = Format.filledCells(used)
            var text = paint(label, .dim) + " " + paint(String(repeating: "▰", count: filled), tone)
                + paint(String(repeating: "▱", count: Format.barCells - filled), .dim)
                + " " + paint("\(Int(used.rounded()))%", tone)
            if let resetsAt = number(window["resets_at"]) {
                text += " " + paint("↻" + Format.reset(resetsAt - at), .dim)
            }
            return text
        }

        let tokens = number(context["total_input_tokens"]) ?? 0
        let percent = number(context["used_percentage"])
        let contextTone = percent.map { Tone(Format.level($0, warn: 60, crit: 85)) } ?? .plain
        let contextPart = [
            paint("↑" + Format.tokens(tokens), contextTone),
            paint("↓" + Format.tokens(number(context["total_output_tokens"]) ?? 0), .dim),
            paint("◆" + Format.tokens(number(context["context_window_size"]) ?? 0), .blue),
        ].joined(separator: " ")

        var segments = [
            cacheParts.joined(separator: " "), limit("5h", "five_hour"), limit("7d", "seven_day"), contextPart,
            String(format: "$%.2f", number(object(input["cost"])["total_cost_usd"]) ?? 0),
        ]
        // The cue to compact, when there is something to do or plan for.
        let advice = CompactAdvice(contextTokens: tokens, contextPercent: percent, cache: state)
        if let cue = advice.statusLineCue {
            segments.append(paint("⇲ " + cue, Tone(advice.level)))
        }
        return Output(line: segments.joined(separator: paint(" | ", .dim)), snapshot: made)
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
