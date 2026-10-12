import XCTest

@testable import CacheCueCore

final class PluginSetupTests: XCTestCase {
    var home: URL!
    let fileManager = FileManager.default

    override func setUpWithError() throws {
        home = fileManager.temporaryDirectory.appendingPathComponent("cachecue-plugin-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? self.fileManager.removeItem(at: self.home) }
    }

    func write(_ text: String, to path: String, executable: Bool = false) throws {
        let url = home.appendingPathComponent(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// A marketplace folder as a release build carries it.
    func makeBundle(version: String = "0.3.0") throws -> URL {
        try write(#"{"name":"cachecue","plugins":[{"name":"cachecue","source":"./plugin"}]}"#, to: "app/marketplace/.claude-plugin/marketplace.json")
        try write(#"{"name":"cachecue","version":"\#(version)"}"#, to: "app/marketplace/plugin/.claude-plugin/plugin.json")
        try write("export const register = () => {}", to: "app/marketplace/plugin/hooks/register.tsx")
        return home.appendingPathComponent("app")
    }

    // MARK: Is it installed

    func testInstalledOnlyWhenClaudeCodeHasItOnRecord() throws {
        XCTAssertFalse(PluginSetup.isInstalled(home: home))
        try write("not json", to: ".claude/plugins/installed_plugins.json")
        XCTAssertFalse(PluginSetup.isInstalled(home: home))
        try write(#"{"version":2,"plugins":{"other@market":[{"scope":"user"}]}}"#, to: ".claude/plugins/installed_plugins.json")
        XCTAssertFalse(PluginSetup.isInstalled(home: home))
        // An entry left empty by an uninstall is not an install.
        try write(#"{"version":2,"plugins":{"cachecue@cachecue":[]}}"#, to: ".claude/plugins/installed_plugins.json")
        XCTAssertFalse(PluginSetup.isInstalled(home: home))
        // Whichever marketplace it came from.
        try write(#"{"version":2,"plugins":{"cachecue@somewhere":[{"scope":"user"}]}}"#, to: ".claude/plugins/installed_plugins.json")
        XCTAssertTrue(PluginSetup.isInstalled(home: home))
    }

    // MARK: Which Claude Code

    func testFindsTheTerminalClaudeCodeBeforeTheDesktopAppsOwn() throws {
        XCTAssertNil(PluginSetup.claudeExecutable(home: home, system: []))
        let desktop = "Library/Application Support/Claude/claude-code"
        try write("", to: "\(desktop)/2.1.99/aaa/claude.app/Contents/MacOS/claude", executable: true)
        try write("", to: "\(desktop)/2.1.295/bbb/claude.app/Contents/MacOS/claude", executable: true)
        // Not executable: a download caught half-way.
        try write("", to: "\(desktop)/2.1.300/ccc/claude.app/Contents/MacOS/claude")
        // The newest by version, not by spelling.
        XCTAssertEqual(
            PluginSetup.claudeExecutable(home: home, system: [])?.path,
            home.appendingPathComponent("\(desktop)/2.1.295/bbb/claude.app/Contents/MacOS/claude").path)

        try write("", to: "sys/claude", executable: true)
        XCTAssertEqual(
            PluginSetup.claudeExecutable(home: home, system: [home.appendingPathComponent("sys/claude").path])?.path,
            home.appendingPathComponent("sys/claude").path)
        try write("", to: ".local/bin/claude", executable: true)
        XCTAssertEqual(
            PluginSetup.claudeExecutable(home: home, system: [home.appendingPathComponent("sys/claude").path])?.path,
            home.appendingPathComponent(".local/bin/claude").path)
    }

    // MARK: The copy

    func testBundledIsNilWithoutAMarketplaceFile() throws {
        XCTAssertNil(PluginSetup.bundled(resources: nil))
        XCTAssertNil(PluginSetup.bundled(resources: home))
        let app = try makeBundle()
        XCTAssertEqual(PluginSetup.bundled(resources: app)?.lastPathComponent, "marketplace")
    }

    func testRefreshOnlyTouchesACopyThisAppMade() throws {
        let bundled = try XCTUnwrap(PluginSetup.bundled(resources: makeBundle()))
        let folder = PluginSetup.installedFolder(home: home)
        // Never installed from here: nothing is written.
        XCTAssertFalse(PluginSetup.refresh(bundled: bundled, home: home))
        XCTAssertFalse(fileManager.fileExists(atPath: folder.path))

        try PluginSetup.copy(bundled: bundled, to: folder)
        XCTAssertEqual(PluginSetup.files(in: folder), PluginSetup.files(in: bundled))
        XCTAssertEqual(PluginSetup.files(in: folder).keys.sorted(), [
            ".claude-plugin/marketplace.json", "plugin/.claude-plugin/plugin.json", "plugin/hooks/register.tsx",
        ])
        // The same build again: left alone.
        XCTAssertFalse(PluginSetup.refresh(bundled: bundled, home: home))

        // The app was updated and carries a newer plugin; a stray file in the old copy goes too.
        let newer = try XCTUnwrap(PluginSetup.bundled(resources: makeBundle(version: "0.4.0")))
        try "old".write(to: folder.appendingPathComponent("plugin/stale.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(PluginSetup.refresh(bundled: newer, home: home))
        XCTAssertEqual(PluginSetup.files(in: folder), PluginSetup.files(in: newer))
        XCTAssertFalse(PluginSetup.refresh(bundled: nil, home: home))
    }

    // MARK: Installing

    func testInstallCopiesThenRunsClaudeCodeTwice() throws {
        let bundled = try XCTUnwrap(PluginSetup.bundled(resources: makeBundle()))
        let folder = PluginSetup.installedFolder(home: home)
        XCTAssertEqual(PluginSetup.commands(folder: folder), [
            ["plugin", "marketplace", "add", folder.path], ["plugin", "install", "cachecue@cachecue"],
        ])
        // A stand-in for Claude Code that writes down what it was asked.
        let log = home.appendingPathComponent("calls.txt").path
        try write("#!/bin/sh\necho \"$@\" >> '\(log)'\n", to: "bin/claude", executable: true)
        try PluginSetup.install(bundled: bundled, home: home, claude: home.appendingPathComponent("bin/claude"))
        XCTAssertEqual(
            try String(contentsOfFile: log, encoding: .utf8),
            "plugin marketplace add \(folder.path)\nplugin install cachecue@cachecue\n")
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent("plugin/hooks/register.tsx").path))
    }

    func testInstallReportsWhatClaudeCodeSaid() throws {
        let bundled = try XCTUnwrap(PluginSetup.bundled(resources: makeBundle()))
        try write("#!/bin/sh\necho 'no such plugin' >&2\nexit 3\n", to: "bin/claude", executable: true)
        XCTAssertThrowsError(try PluginSetup.install(bundled: bundled, home: home, claude: home.appendingPathComponent("bin/claude"))) {
            XCTAssertEqual($0 as? PluginSetup.Failure, .claude("no such plugin"))
        }
        XCTAssertThrowsError(try PluginSetup.install(bundled: nil, home: home, claude: home.appendingPathComponent("bin/claude"))) {
            XCTAssertEqual($0 as? PluginSetup.Failure, .notBundled)
        }
    }

    /// The whole path with a real Claude Code and the plugin a built app carries, in a
    /// throwaway config folder. Opt-in:
    ///   CACHECUE_PLUGIN_TEST_RESOURCES=build/CacheCue.app/Contents/Resources \
    ///   CACHECUE_PLUGIN_TEST_CLAUDE=~/.local/bin/claude swift test --filter PluginSetup
    func testInstallWithARealClaudeCode() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let resources = environment["CACHECUE_PLUGIN_TEST_RESOURCES"], let claude = environment["CACHECUE_PLUGIN_TEST_CLAUDE"] else {
            throw XCTSkip("set CACHECUE_PLUGIN_TEST_RESOURCES and CACHECUE_PLUGIN_TEST_CLAUDE to run")
        }
        let bundled = try XCTUnwrap(PluginSetup.bundled(resources: URL(fileURLWithPath: resources)))
        // Claude Code keeps its records where this says, which is where `isInstalled` looks.
        setenv("CLAUDE_CONFIG_DIR", home.appendingPathComponent(".claude").path, 1)
        defer { unsetenv("CLAUDE_CONFIG_DIR") }
        XCTAssertFalse(PluginSetup.isInstalled(home: home))
        try PluginSetup.install(bundled: bundled, home: home, claude: URL(fileURLWithPath: claude))
        XCTAssertTrue(PluginSetup.isInstalled(home: home))
        // A second press, with the marketplace already known, still ends installed.
        try PluginSetup.install(bundled: bundled, home: home, claude: URL(fileURLWithPath: claude))
        XCTAssertTrue(PluginSetup.isInstalled(home: home))
    }
}
