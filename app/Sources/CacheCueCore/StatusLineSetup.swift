import Foundation

/// Pointing Claude Code's `statusLine` setting at this app's own command.
public enum StatusLineSetup {
    public enum State: Equatable {
        case notConfigured
        /// Already this app's command.
        case ours
        /// Someone else's command, which setting up would replace.
        case other(command: String)
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// The settings file exists but is not a JSON object; it is left untouched.
        case unreadableSettings

        public var errorDescription: String? { "settings.json is not valid JSON" }
    }

    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    private static let chainMarker = " statusline --then "

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What goes in `statusLine.command`: the executable, quoted for the shell, and its verb.
    /// With `original`, the status line that was there before is handed the same input
    /// afterwards, and what it prints is what the terminal shows.
    public static func command(executable: String, then original: String? = nil) -> String {
        let own = quoted(executable) + " statusline"
        guard let original, !original.isEmpty else { return own }
        return own + " --then " + quoted(original)
    }

    private static func isOurs(_ command: String) -> Bool {
        command.contains("CacheCue") && (command.hasSuffix(" statusline") || command.contains(chainMarker))
    }

    /// The status line this app's command hands on to; nil when it is not chained to one.
    public static func chained(in command: String) -> String? {
        guard isOurs(command), let marker = command.range(of: chainMarker) else { return nil }
        let rest = command[marker.upperBound...]
        guard rest.count >= 2, rest.hasPrefix("'"), rest.hasSuffix("'") else { return nil }
        return rest.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "'")
    }

    /// The status line kept behind this app's command, as the settings file has it.
    public static func chained(settings url: URL = defaultSettingsURL) -> String? {
        guard let settings = try? load(url), let line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String
        else { return nil }
        return chained(in: command)
    }

    private static func load(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadableSettings
        }
        return settings
    }

    public static func state(settings url: URL = defaultSettingsURL) -> State {
        guard let settings = try? load(url), let line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String, !command.isEmpty
        else { return .notConfigured }
        return isOurs(command) ? .ours : .other(command: command)
    }

    private static func write(_ settings: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    /// Takes this app's command out again: back to the status line it was chained to, or to
    /// no status line at all. Someone else's status line is left alone.
    public static func remove(settings url: URL = defaultSettingsURL) throws {
        var settings = try load(url)
        guard var line = settings["statusLine"] as? [String: Any], let command = line["command"] as? String,
              isOurs(command)
        else { return }
        if let original = chained(in: command) {
            line["command"] = original
            settings["statusLine"] = line
        } else {
            settings["statusLine"] = nil
        }
        try write(settings, to: url)
    }

    /// Writes the setting, keeping every other key and a copy of the file as it was beside
    /// it (`settings.json.cachecue-backup`). Keys come back sorted: JSON has no order to keep.
    /// `original` is a status line to keep running behind this app's command.
    public static func install(
        executable: String, keeping original: String? = nil, settings url: URL = defaultSettingsURL
    ) throws {
        var settings = try load(url)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            // Kept from the first run only: a second run would back up our own edit.
            let backup = url.appendingPathExtension("cachecue-backup")
            if state(settings: url) != .ours || !fileManager.fileExists(atPath: backup.path) {
                try? fileManager.removeItem(at: backup)
                try fileManager.copyItem(at: url, to: backup)
            }
        } else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if let original, !original.isEmpty {
            // The other status line keeps its own padding and refresh; only the command changes hands.
            var line = settings["statusLine"] as? [String: Any] ?? ["type": "command"]
            line["command"] = command(executable: executable, then: original)
            settings["statusLine"] = line
        } else {
            settings["statusLine"] = [
                "type": "command",
                "command": command(executable: executable),
                "padding": 0,
                // The countdown moves without any event to redraw it.
                "refreshInterval": 5,
            ] as [String: Any]
        }
        try write(settings, to: url)
    }
}

/// Running the status line this app's command is chained to: it gets the same input, and
/// whatever it prints goes where this command's own output would.
public enum StatusLineChain {
    /// Longer than this and the other status line is given up on, so Claude Code never waits on it.
    public static let timeout: TimeInterval = 5

    /// Runs `command` through the shell with `input` on its stdin. Returns its exit status;
    /// 0 when it could not be started or ran out of time.
    @discardableResult
    public static func run(
        _ command: String, input: Data, timeout: TimeInterval = timeout, output: FileHandle = .standardOutput
    ) -> Int32 {
        // A command that exits without reading its input must not take this one down with it.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return 0
        }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return 0
        }
        return process.terminationStatus
    }
}
