import XCTest

@testable import CacheCueCore

final class StatusLineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_750_000)
    var at: Double { now.timeIntervalSince1970 }

    func input(_ edit: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var json: [String: Any] = [
            "session_id": "s1",
            "cwd": "/tmp/elsewhere",
            "workspace": ["project_dir": "/Users/t/Code/my-app"],
            "cost": ["total_cost_usd": 206.512],
            "context_window": [
                "total_input_tokens": 68_600, "total_output_tokens": 9_600, "context_window_size": 1_000_000,
                "used_percentage": 7,
                "current_usage": [
                    "input_tokens": 2, "output_tokens": 773, "cache_creation_input_tokens": 4_100,
                    "cache_read_input_tokens": 64_498,
                ],
            ],
            "rate_limits": [
                "five_hour": ["used_percentage": 2.3, "resets_at": at + 16_560],
                "seven_day": ["used_percentage": 76.4, "resets_at": at + 50_160],
            ],
            "prompt_cache": ["warm": true, "ttl": "1h", "expires_at": at + 2_856, "hit_ratio": 0.955],
        ]
        edit(&json)
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func render(_ data: Data, previous: Snapshot? = nil, color: Bool = false) -> StatusLine.Output {
        StatusLine.render(input: data, now: now, previous: previous, color: color)
    }

    func testTheWholeLine() {
        XCTAssertEqual(
            render(input()).line,
            "cache 94% avg 96% ◷47:36 | 5h ▰▱▱▱▱▱▱▱ 2% ↻4h36m | 7d ▰▰▰▰▰▰▱▱ 76% ↻13h56m | ↑68.6k ↓9.6k ◆1.0M | $206.51")
    }

    func testEveryInputAnswersWithALine() {
        let empty = "cache -- ◷--:-- | 5h -- | 7d -- | ↑0 ↓0 ◆0 | $0.00"
        for data in [Data(), Data("{}".utf8), Data("not json".utf8), Data("[1,2]".utf8), Data("null".utf8)] {
            let output = render(data)
            XCTAssertEqual(output.line, empty)
            XCTAssertNil(output.snapshot)
        }
        // A session before its first response: nulls where figures will be.
        let fresh = Data("""
            {"session_id":"s2","context_window":{"current_usage":null,"used_percentage":null,\
            "context_window_size":200000,"total_input_tokens":0,"total_output_tokens":0},"cost":{"total_cost_usd":0}}
            """.utf8)
        XCTAssertEqual(render(fresh).line, "cache -- ◷--:-- | 5h -- | 7d -- | ↑0 ↓0 ◆200.0k | $0.00")
        XCTAssertEqual(render(fresh).snapshot?.sessionID, "s2")
    }

    func testCacheStatesAndTheCompactCue() {
        // An older Claude Code sends no prompt_cache: no average, no countdown.
        XCTAssertTrue(render(input { $0["prompt_cache"] = nil }).line.hasPrefix("cache 94% ◷--:-- |"))
        // Expired at 68.6k: the next message reprocesses it all, so there is a choice to make.
        let expired = render(input { $0["prompt_cache"] = ["expires_at": self.at - 5, "hit_ratio": 0.9] }).line
        XCTAssertTrue(expired.hasPrefix("cache 94% avg 90% ◷expired |"))
        XCTAssertTrue(expired.hasSuffix("| ⇲ compact or clear"))
        // Expired on a small context: said, but nothing worth doing about it.
        let small = render(input {
            var context = $0["context_window"] as! [String: Any]
            context["total_input_tokens"] = 20_000
            $0["context_window"] = context
            $0["prompt_cache"] = ["expires_at": self.at - 5]
        }).line
        XCTAssertTrue(small.contains("◷expired"))
        XCTAssertFalse(small.contains("⇲"))

        func large(_ cache: [String: Any], percent: Double = 20) -> String {
            render(input {
                var context = $0["context_window"] as! [String: Any]
                context["total_input_tokens"] = 200_000
                context["used_percentage"] = percent
                $0["context_window"] = context
                $0["prompt_cache"] = cache
            }).line
        }
        XCTAssertTrue(large(["expires_at": at + 3000]).hasSuffix("| ⇲ compact at next break"))
        XCTAssertTrue(large(["expires_at": at + 300]).hasSuffix("| ⇲ compact now"))
        XCTAssertTrue(large(["expires_at": at - 1]).hasSuffix("| ⇲ compact or clear"))
        XCTAssertTrue(large(["expires_at": at + 3000], percent: 90).hasSuffix("| ⇲ compact now"))
    }

    func testColorIsOptIn() {
        XCTAssertFalse(render(input()).line.contains("\u{1B}"))
        let colored = render(input(), color: true).line
        XCTAssertTrue(colored.contains("\u{1B}[1;36m94%\u{1B}[0m"))
        XCTAssertTrue(colored.contains("\u{1B}[33m76%\u{1B}[0m"))
    }

    func testSnapshot() throws {
        let snapshot = try XCTUnwrap(render(input()).snapshot)
        XCTAssertEqual(snapshot, Snapshot(
            v: 1, source: "terminal", sessionID: "s1", cwd: "/Users/t/Code/my-app",
            cache: .init(turnHit: 94, avgHit: 96, expiresAt: at + 2_856, active: false),
            limits: [
                "five_hour": .init(used: 2.3, resetsAt: at + 16_560),
                "seven_day": .init(used: 76.4, resetsAt: at + 50_160),
            ],
            // Nothing to compare the reading against yet, so its age is unknown.
            limitsAt: nil,
            context: .init(tokens: 68_600, output: 9_600, window: 1_000_000, percent: 7),
            costUSD: 206.512, updatedAt: at))
    }

    func testTimestampsMoveOnlyWithTheFigures() throws {
        let first = try XCTUnwrap(render(input()).snapshot)
        let later = now.addingTimeInterval(30)
        func again(_ data: Data, after previous: Snapshot) throws -> Snapshot {
            try XCTUnwrap(StatusLine.render(input: data, now: later, previous: previous, color: false).snapshot)
        }
        // The timer firing with nothing new leaves the snapshot exactly as it was.
        XCTAssertEqual(try again(input(), after: first), first)
        // The cost moved: the session did something, but the limits reading is the old one.
        let spent = try again(input { $0["cost"] = ["total_cost_usd": 207.0] }, after: first)
        XCTAssertEqual(spent.updatedAt, at + 30)
        XCTAssertNil(spent.limitsAt)
        // A new reading is dated by the run that first saw it.
        let moved = try again(input {
            $0["rate_limits"] = ["five_hour": ["used_percentage": 3.0, "resets_at": self.at + 16_560]]
        }, after: first)
        XCTAssertEqual(moved.limitsAt, at + 30)
        XCTAssertEqual(moved.updatedAt, at + 30)
    }

    func testSnapshotsRoundTripThroughTheStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cachecue-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try XCTUnwrap(render(input()).snapshot)
        try SnapshotStore.write(snapshot, in: directory)
        XCTAssertEqual(SnapshotStore.read("s1", in: directory), snapshot)
        XCTAssertEqual(SnapshotStore.load(from: directory), [snapshot])
        XCTAssertNil(SnapshotStore.read("missing", in: directory))
        // A session id is never trusted as a path.
        XCTAssertEqual(SnapshotStore.url(for: "../../etc/x", in: directory).lastPathComponent, "etcx.json")
    }
}
