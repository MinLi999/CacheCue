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

    func snapshot(_ data: Data, previous: Snapshot? = nil) -> Snapshot? {
        StatusLine.snapshot(input: data, now: now, previous: previous)
    }

    func testInputThatNamesNoSessionMakesNoSnapshot() {
        for data in [Data(), Data("{}".utf8), Data("not json".utf8), Data("[1,2]".utf8), Data("null".utf8)] {
            XCTAssertNil(snapshot(data))
        }
        // A session before its first response: nulls where figures will be.
        let fresh = Data("""
            {"session_id":"s2","context_window":{"current_usage":null,"used_percentage":null,\
            "context_window_size":200000,"total_input_tokens":0,"total_output_tokens":0},"cost":{"total_cost_usd":0}}
            """.utf8)
        let made = snapshot(fresh)
        XCTAssertEqual(made?.sessionID, "s2")
        XCTAssertNil(made?.cache.turnHit)
        XCTAssertEqual(made?.limits, [:])
        XCTAssertEqual(made?.context.window, 200_000)
    }

    func testAnAccountWithoutLimitsAndAnOlderClaudeCode() throws {
        // Only Pro and Max plans are told their limits; an older Claude Code sends no prompt_cache.
        let made = try XCTUnwrap(snapshot(input { $0["rate_limits"] = nil; $0["prompt_cache"] = nil }))
        XCTAssertEqual(made.limits, [:])
        XCTAssertNil(made.cache.expiresAt)
        XCTAssertNil(made.cache.avgHit)
        XCTAssertEqual(made.cache.turnHit, 94)
    }

    func testWhatClaudeCodeSaysAboutTheCacheTheModelAndTheSessionIsKept() throws {
        let made = try XCTUnwrap(snapshot(input {
            $0["prompt_cache"] = [
                "warm": true, "ttl": "5m", "expires_at": self.at + 240, "hit_ratio": 0.91, "misses": 2,
                "miss_recache_tokens": 310_200, "recache_tokens_if_cold": 45_000,
                "last_miss_cause": ["causes": ["tools_changed"], "tools_added": 2, "tools_removed": 0],
            ] as [String: Any]
            $0["rate_limits"] = ["spend_limit": [
                "used_percentage": 62.8, "resets_at": self.at + 86_400, "used_usd": 314.12, "limit_usd": 500,
                "period": "monthly",
            ] as [String: Any]]
            $0["model"] = ["id": "claude-opus-5-5", "display_name": "Opus"]
            $0["session_name"] = "auth refactor"
            $0["effort"] = ["level": "high"]
            $0["fast_mode"] = true
            $0["worktree"] = ["name": "auth-fix"]
        }))
        XCTAssertEqual(made.cache.ttl, 300)
        XCTAssertEqual(made.cache.recacheTokens, 45_000)
        XCTAssertEqual(made.cache.misses, 2)
        XCTAssertEqual(made.cache.missRecacheTokens, 310_200)
        XCTAssertEqual(made.cache.lastMissCauses, ["tools_changed"])
        XCTAssertEqual(made.limits, ["spend_limit": .init(
            used: 62.8, resetsAt: at + 86_400, usedUSD: 314.12, limitUSD: 500, period: "monthly")])
        XCTAssertEqual(made.name, "auth refactor")
        XCTAssertEqual(made.model, "Opus")
        XCTAssertEqual(made.modelID, "claude-opus-5-5")
        XCTAssertEqual(made.effort, "high")
        XCTAssertEqual(made.fast, true)
        XCTAssertEqual(made.worktree, "auth-fix")

        // Right after a compaction Claude Code has no count of what a cold cache rewrites.
        let compacted = try XCTUnwrap(snapshot(input {
            $0["prompt_cache"] = ["ttl": "1h", "recache_tokens_if_cold": NSNull(), "last_miss_cause": NSNull()] as [String: Any]
        }))
        XCTAssertNil(compacted.cache.recacheTokens)
        XCTAssertNil(compacted.cache.lastMissCauses)
        XCTAssertNil(compacted.name)
    }

    func testSnapshot() throws {
        let snapshot = try XCTUnwrap(snapshot(input()))
        XCTAssertEqual(snapshot, Snapshot(
            v: 1, source: "terminal", sessionID: "s1", cwd: "/Users/t/Code/my-app",
            cache: .init(turnHit: 94, avgHit: 96, expiresAt: at + 2_856, active: false, ttl: 3600),
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
        let first = try XCTUnwrap(snapshot(input()))
        let later = now.addingTimeInterval(30)
        func again(_ data: Data, after previous: Snapshot) throws -> Snapshot {
            try XCTUnwrap(StatusLine.snapshot(input: data, now: later, previous: previous))
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
        let snapshot = try XCTUnwrap(snapshot(input()))
        try SnapshotStore.write(snapshot, in: directory)
        XCTAssertEqual(SnapshotStore.read("s1", in: directory), snapshot)
        XCTAssertEqual(SnapshotStore.load(from: directory), [snapshot])
        XCTAssertNil(SnapshotStore.read("missing", in: directory))
        // A session id is never trusted as a path.
        XCTAssertEqual(SnapshotStore.url(for: "../../etc/x", in: directory).lastPathComponent, "etcx.json")
    }
}
