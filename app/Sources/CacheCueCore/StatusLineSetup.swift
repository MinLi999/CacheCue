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

    /// What goes in `statusLine.command`: the executable, quoted for the shell, and its verb.
    public static func command(executable: String) -> String {
        "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' statusline"
    }

    private static func isOurs(_ command: String) -> Bool {
        command.contains("CacheCue") && command.hasSuffix(" statusline")
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

    /// Writes the setting, keeping every other key and a copy of the file as it was beside
    /// it (`settings.json.cachecue-backup`). Keys come back sorted: JSON has no order to keep.
    public static func install(executable: String, settings url: URL = defaultSettingsURL) throws {
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
        settings["statusLine"] = [
            "type": "command",
            "command": command(executable: executable),
            "padding": 0,
            // The countdown moves without any event to redraw it.
            "refreshInterval": 5,
        ] as [String: Any]
        var data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}
