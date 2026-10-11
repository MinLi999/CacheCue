import XCTest

@testable import CacheCueCore

final class StatusLineSetupTests: XCTestCase {
    var settings: URL!
    let executable = "/Users/t/Applications/CacheCue.app/Contents/MacOS/CacheCue"

    override func setUpWithError() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cachecue-setup-\(UUID().uuidString)")
        settings = folder.appendingPathComponent(".claude/settings.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: settings, atomically: true, encoding: .utf8)
    }

    func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    var backup: URL { settings.appendingPathExtension("cachecue-backup") }

    func testCommandIsQuotedForTheShell() {
        XCTAssertEqual(
            StatusLineSetup.command(executable: "/Applications/My Apps/CacheCue.app/Contents/MacOS/CacheCue"),
            "'/Applications/My Apps/CacheCue.app/Contents/MacOS/CacheCue' statusline")
        XCTAssertEqual(StatusLineSetup.command(executable: "/a/it's/CacheCue"), "'/a/it'\\''s/CacheCue' statusline")
    }

    func testCreatesSettingsWhereThereAreNone() throws {
        XCTAssertEqual(StatusLineSetup.state(settings: settings), .notConfigured)
        try StatusLineSetup.install(executable: executable, settings: settings)
        XCTAssertEqual(StatusLineSetup.state(settings: settings), .ours)
        let line = try XCTUnwrap(try read()["statusLine"] as? [String: Any])
        XCTAssertEqual(line["type"] as? String, "command")
        XCTAssertEqual(line["command"] as? String, "'\(executable)' statusline")
        XCTAssertEqual(line["refreshInterval"] as? Int, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testKeepsEveryOtherSettingAndBacksUpTheOriginal() throws {
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]},"statusLine":{"type":"command","command":"~/.claude/statusline.py","padding":0}}"#
        try write(original)
        XCTAssertEqual(StatusLineSetup.state(settings: settings), .other(command: "~/.claude/statusline.py"))

        try StatusLineSetup.install(executable: executable, settings: settings)
        let after = try read()
        XCTAssertEqual(after["model"] as? String, "opus")
        XCTAssertNotNil((after["hooks"] as? [String: Any])?["Stop"])
        XCTAssertEqual(StatusLineSetup.state(settings: settings), .ours)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)

        // Setting up again must not replace the backup of the original with our own edit.
        try StatusLineSetup.install(executable: executable, settings: settings)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
    }

    func testLeavesAFileItCannotReadAlone() throws {
        try write("{ not json")
        XCTAssertEqual(StatusLineSetup.state(settings: settings), .notConfigured)
        XCTAssertThrowsError(try StatusLineSetup.install(executable: executable, settings: settings)) { error in
            XCTAssertEqual(error as? StatusLineSetup.Failure, .unreadableSettings)
        }
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }
}
