import Foundation

/// Connecting the Claude desktop app: installing the `cachecue` plugin that travels inside
/// this app, with the Claude Code already on this Mac. No terminal, no git, no network.
public enum PluginSetup {
    public static let pluginName = "cachecue"
    public static let marketplaceName = "cachecue"

    public enum Failure: Error, Equatable, LocalizedError {
        /// The plugin's files are not inside this build (a bare `swift build`).
        case notBundled
        /// Claude Code ran and said no; carries what it printed.
        case claude(String)

        public var errorDescription: String? {
            switch self {
            case .notBundled: return "this build carries no plugin"
            case .claude(let output): return output
            }
        }
    }

    // MARK: Where things are

    /// The marketplace folder a release build carries: `Contents/Resources/marketplace`.
    public static func bundled(resources: URL?) -> URL? {
        guard let folder = resources?.appendingPathComponent("marketplace", isDirectory: true),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(".claude-plugin/marketplace.json").path)
        else { return nil }
        return folder
    }

    /// Where the copy Claude Code reads is kept: it must not read from inside the signed app.
    public static func installedFolder(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/CacheCue/marketplace", isDirectory: true)
    }

    /// True once Claude Code has a `cachecue` plugin on record, whoever installed it and from where.
    public static func isInstalled(home: URL) -> Bool {
        let record = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: record),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any]
        else { return false }
        return plugins.contains { key, value in
            key.hasPrefix(pluginName + "@") && !((value as? [Any])?.isEmpty ?? true)
        }
    }

    /// The Claude Code to run: the terminal one where there is one, else the newest copy the
    /// Claude desktop app keeps for itself.
    public static func claudeExecutable(home: URL, system: [String] = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) -> URL? {
        let fileManager = FileManager.default
        let fixed = [home.appendingPathComponent(".local/bin/claude").path] + system
        if let found = fixed.first(where: fileManager.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: found)
        }
        // <version>/<build id>/claude.app/Contents/MacOS/claude
        let versions = home.appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: versions.path)) ?? []
        for name in names.sorted(by: isNewer) {
            let builds = (try? fileManager.contentsOfDirectory(atPath: versions.appendingPathComponent(name).path)) ?? []
            for build in builds.sorted() {
                let candidate = versions.appendingPathComponent("\(name)/\(build)/claude.app/Contents/MacOS/claude")
                if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// `2.1.295` before `2.1.99`; a folder that is not a version goes last.
    static func isNewer(_ left: String, _ right: String) -> Bool {
        switch (AppVersion(left), AppVersion(right)) {
        case (let a?, let b?): return a > b
        case (_?, nil): return true
        default: return false
        }
    }

    // MARK: The copy

    /// Every file under `folder`, by its path from there.
    static func files(in folder: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let base = folder.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return found }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url)
            else { continue }
            found[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = data
        }
        return found
    }

    /// Lays the bundled marketplace out at `destination`, replacing what was there.
    public static func copy(bundled: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: bundled, to: destination)
    }

    /// Brings a copy this app made earlier up to the build now running, so the plugin moves
    /// with the app. Leaves alone a Mac where it never made one. Returns whether it rewrote it.
    @discardableResult
    public static func refresh(bundled: URL?, home: URL) -> Bool {
        let destination = installedFolder(home: home)
        guard let bundled, FileManager.default.fileExists(atPath: destination.path),
              files(in: bundled) != files(in: destination)
        else { return false }
        return (try? copy(bundled: bundled, to: destination)) != nil
    }

    // MARK: Keeping the installed plugin current

    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The version of the plugin in a marketplace folder laid out as this app carries it.
    static func version(inMarketplace folder: URL) -> String? {
        json(folder.appendingPathComponent("plugin/.claude-plugin/plugin.json"))?["version"] as? String
    }

    /// The version Claude Code has on record as installed from this app's marketplace. That
    /// record points at a copy Claude Code keeps of its own, and the desktop app's sessions
    /// load that copy, not the marketplace folder.
    static func installedVersion(home: URL) -> String? {
        let record = json(home.appendingPathComponent(".claude/plugins/installed_plugins.json"))
        let entries = (record?["plugins"] as? [String: Any])?["\(pluginName)@\(marketplaceName)"] as? [[String: Any]]
        return entries?.first?["version"] as? String
    }

    /// True when the marketplace Claude Code knows as `cachecue` is the folder this app keeps:
    /// one a person added from GitHub, or from a folder of their own, is theirs to update.
    static func ownsMarketplace(home: URL) -> Bool {
        let known = json(home.appendingPathComponent(".claude/plugins/known_marketplaces.json"))
        let source = (known?[marketplaceName] as? [String: Any])?["source"] as? [String: Any]
        guard let path = source?["path"] as? String else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == installedFolder(home: home).standardizedFileURL.path
    }

    /// The app moved on and Claude Code's installed copy did not: the folder this app keeps
    /// holds a newer plugin than the one on record. `refresh` only brings the folder along.
    public static func needsUpdate(home: URL) -> Bool {
        guard ownsMarketplace(home: home),
              let offered = version(inMarketplace: installedFolder(home: home)).flatMap(AppVersion.init),
              let installed = installedVersion(home: home).flatMap(AppVersion.init)
        else { return false }
        return offered > installed
    }

    public static let updateCommand = ["plugin", "update", "\(pluginName)@\(marketplaceName)"]

    /// Has Claude Code bring its installed copy up to the plugin this app now carries, where
    /// it has fallen behind. Sessions already open keep the old one until they are reopened.
    /// Blocks while Claude Code runs: call it off the main thread. Returns whether it ran.
    @discardableResult
    public static func updateIfBehind(home: URL, claude: URL?) -> Bool {
        guard needsUpdate(home: home), let claude else { return false }
        return (try? run(claude, updateCommand))?.status == 0
    }

    // MARK: Installing

    /// The two commands that install it, as arguments to Claude Code.
    public static func commands(folder: URL) -> [[String]] {
        [
            ["plugin", "marketplace", "add", folder.path],
            ["plugin", "install", "\(pluginName)@\(marketplaceName)"],
        ]
    }

    /// Copies the plugin out of the app and has Claude Code install it from there. Blocks
    /// while Claude Code runs: call it off the main thread.
    public static func install(bundled: URL?, home: URL, claude: URL) throws {
        guard let bundled else { throw Failure.notBundled }
        let folder = installedFolder(home: home)
        try copy(bundled: bundled, to: folder)
        // A marketplace of that name may be known already; what counts is the install.
        var result: (status: Int32, output: String) = (0, "")
        for arguments in commands(folder: folder) {
            result = try run(claude, arguments)
        }
        guard result.status == 0 else {
            throw Failure.claude(result.output.isEmpty ? "exit \(result.status)" : String(result.output.suffix(200)))
        }
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: printed, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }
}
