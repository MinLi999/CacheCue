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
