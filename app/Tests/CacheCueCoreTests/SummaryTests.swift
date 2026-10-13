import XCTest

@testable import CacheCueCore

final class SummaryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_750_000)
    var at: Double { now.timeIntervalSince1970 }

    func snapshot(
        _ id: String,
        source: String = "desktop",
        cwd: String? = "/Users/t/Code/my-app",
        updatedAgo: Double = 10,
        turnHit: Int? = 97,
        avgHit: Int? = 94,
        expiresIn: Double? = 2856,
        active: Bool = false,
        limits: [String: Snapshot.Limit]? = nil,
        limitsAgo: Double? = nil,
        cost: Double? = 5.912
    ) -> Snapshot {
        Snapshot(
            v: 1, source: source, sessionID: id, cwd: cwd,
            cache: .init(turnHit: turnHit, avgHit: avgHit, expiresAt: expiresIn.map { at + $0 }, active: active),
            limits: limits ?? [
                "five_hour": .init(used: 20.4, resetsAt: at + 38 * 60),
                "seven_day": .init(used: 3, resetsAt: at + 4 * 86400 + 2 * 3600),
            ],
            limitsAt: limitsAgo.map { at - $0 },
            context: .init(tokens: 207_000, output: 908, window: 1_000_000, percent: 21),
            costUSD: cost, updatedAt: at - updatedAgo)
    }

    func testTitleAndMenuForOneSession() {
        let summary = Summary(snapshots: [snapshot("a")], now: now)
        XCTAssertEqual(summary.titleText, "5h 20%  7d 3%  ◷47:36")
        XCTAssertEqual(summary.rows(.of(.en)), [
            "5-Hour Limit  ▰▰▱▱▱▱▱▱  20% Used  ·  Resets in 38m",
            "7-Day Limit  ▰▱▱▱▱▱▱▱  3% Used  ·  Resets in 4d2h",
            nil,
            "When to /compact: Compact at the next stopping point",
            "Every request re-reads 207.0k. Do it between tasks, not mid-task, while the cache is warm.",
            // The fixture names no model and gives no count of its own, so both are hedged.
            "Going cold rewrites ~207.0k tokens · ≥20× the price of reading them warm",
            nil,
            "my-app  ·  Desktop  ·  Current session",
            // A desktop session's cache lifetime is the plugin's guess.
            "47:36 until cache expires  ·  ~1h",
            // The fixture has rate limits, so this is a subscription and the dollars are not a bill.
            "Turn cache hit 97%  ·  Avg cache hit 94%  ·  API-rate value $5.91",
            "Context  207.0k / 1.0M (21%)",
        ])
        XCTAssertEqual(summary.rows(.of(.zhHans))[0], "5 小时额度  ▰▰▱▱▱▱▱▱  20% 已用  ·  38m 后重置")
    }

    func testNoSnapshots() {
        let summary = Summary(snapshots: [], now: now)
        XCTAssertEqual(summary.titleText, "◷--")
        XCTAssertEqual(summary.rows(.of(.en)), [
            "5-Hour Limit  No reading yet", "7-Day Limit  No reading yet", nil,
            "No active sessions in the last 24 hours",
        ])
    }

    func testCurrentIsTheSessionThatLastDidSomething() {
        let summary = Summary(snapshots: [
            snapshot("old", source: "terminal", cwd: "/x/DraftPipe AI", updatedAgo: 600, turnHit: 90, expiresIn: 723, cost: 3.2),
            snapshot("new", updatedAgo: 5),
            snapshot("stale", cwd: "/x/Gone", updatedAgo: 25 * 3600),
        ], now: now)
        XCTAssertEqual(summary.current?.name, "my-app")
        XCTAssertEqual(summary.others.map(\.name), ["DraftPipe AI"])
        XCTAssertEqual(Array(summary.rows(.of(.en)).suffix(3)), [
            nil, "Other sessions", "DraftPipe AI  ·  Terminal   ❄~207.0k   ◷12:03   $3.20",
        ])
    }

    func testLimitsFallBackToAnotherSessionsReading() {
        // The newest session has no reading yet; an older one does.
        let summary = Summary(snapshots: [
            snapshot("fresh", updatedAgo: 5, limits: [:]),
            snapshot("older", updatedAgo: 300, limits: ["five_hour": .init(used: 95, resetsAt: at + 1500)]),
        ], now: now)
        XCTAssertEqual(summary.fiveHour?.percent, 95)
        XCTAssertEqual(summary.fiveHour?.level, .crit)
        XCTAssertNil(summary.sevenDay)
        XCTAssertEqual(summary.title.first, TitlePart("5h 95%", .crit))
    }

    func testTheReadingReceivedLastWinsNotTheSessionTouchedLast() {
        func five(_ used: Double) -> [String: Snapshot.Limit] {
            ["five_hour": .init(used: used, resetsAt: at + 1800)]
        }
        // As seen for real: sessions in one window reporting 17, 20 and 37.
        let summary = Summary(snapshots: [
            // Just started a turn, so it is the live session, but its reading is hours old.
            snapshot("live", updatedAgo: 2, limits: five(17), limitsAgo: 9000),
            snapshot("recent", updatedAgo: 400, limits: five(37), limitsAgo: 400),
            snapshot("middle", updatedAgo: 900, limits: five(20), limitsAgo: 900),
            // Touched after "recent", but it cannot say how old its reading is.
            snapshot("undated", updatedAgo: 100, limits: five(5)),
        ], now: now)
        XCTAssertEqual(summary.current?.name, "my-app")
        XCTAssertEqual(summary.fiveHour?.percent, 37)

        // With no dated reading at all, the most recently active session's stands.
        let undated = Summary(snapshots: [
            snapshot("a", updatedAgo: 500, limits: five(9)),
            snapshot("b", updatedAgo: 50, limits: five(13)),
        ], now: now)
        XCTAssertEqual(undated.fiveHour?.percent, 13)
    }

    func testAWindowPastItsResetIsDropped() {
        let summary = Summary(snapshots: [
            snapshot("a", limits: ["five_hour": .init(used: 80, resetsAt: at - 1)]),
        ], now: now)
        XCTAssertNil(summary.fiveHour)
        XCTAssertEqual(summary.titleText, "◷47:36")
    }

    func testASessionAboutToLoseItsCacheComesFirstWhenAskedTo() {
        var quiet = snapshot("big", cwd: "/x/Big", updatedAgo: 900, expiresIn: 400)
        quiet.cache.recacheTokens = 310_000
        var smaller = snapshot("smaller", cwd: "/x/Smaller", updatedAgo: 700, expiresIn: 200)
        smaller.cache.recacheTokens = 120_000
        let snapshots = [snapshot("latest", cwd: "/x/Latest", updatedAgo: 5), quiet, smaller]

        // Left alone, the session that last did something is the one in view.
        XCTAssertEqual(Summary(snapshots: snapshots, now: now).current?.id, "latest")
        // Asked to, the one with the most to rewrite of those about to go cold.
        let urgent = Summary(snapshots: snapshots, now: now, followsUrgent: true)
        XCTAssertEqual(urgent.current?.id, "big")
        XCTAssertTrue(urgent.isUrgent)
        XCTAssertEqual(urgent.others.map(\.id), ["latest", "smaller"])
        // The person's own choice still wins.
        let pinned = Summary(snapshots: snapshots, now: now, pinned: "smaller", followsUrgent: true)
        XCTAssertEqual(pinned.current?.id, "smaller")
        XCTAssertFalse(pinned.isUrgent)
        // With nothing about to go cold, it is the latest again.
        let calm = Summary(snapshots: [snapshot("latest", updatedAgo: 5)], now: now, followsUrgent: true)
        XCTAssertEqual(calm.current?.id, "latest")
        XCTAssertFalse(calm.isUrgent)
    }

    func testAFiveMinuteCacheIsMeasuredAgainstFiveMinutes() {
        var short = snapshot("a", expiresIn: 150)
        short.cache.ttl = 300
        let session = try! XCTUnwrap(Summary(snapshots: [short], now: now).current)
        XCTAssertEqual(session.lifetime, 300)
        XCTAssertEqual(session.lifetimeLabel, "~5m")
        XCTAssertEqual(session.cacheFraction, 0.5)
        // Half of five minutes left is no cause for alarm; a minute and a half is.
        XCTAssertEqual(session.cacheLevel, .plain)
        XCTAssertEqual(session.advice.kind, .worthIt)
        short.cache.expiresAt = at + 90
        let late = try! XCTUnwrap(Summary(snapshots: [short], now: now).current)
        XCTAssertEqual(late.cacheLevel, .warn)
        XCTAssertEqual(late.advice.kind, .beforeExpiry)
        short.cache.expiresAt = at + 30
        XCTAssertEqual(Summary(snapshots: [short], now: now).current?.cacheLevel, .crit)
        // A session that does not say is taken to have the hour.
        XCTAssertEqual(Summary(snapshots: [snapshot("b")], now: now).current?.lifetimeLabel, "~1h")
        // Only the status line command is told the lifetime outright.
        var told = snapshot("c", source: "terminal")
        told.cache.ttl = 300
        XCTAssertEqual(Summary(snapshots: [told], now: now).current?.lifetimeLabel, "5m")
    }

    func testASessionIsNamedAndDescribedByWhatClaudeCodeSaysOfIt() {
        var named = snapshot("a")
        named.name = "auth refactor"
        named.model = "Opus"
        named.effort = "high"
        named.fast = true
        named.worktree = "auth-fix"
        let session = try! XCTUnwrap(Summary(snapshots: [named], now: now).current)
        XCTAssertEqual(session.name, "auth refactor")
        XCTAssertEqual(session.folder, "my-app")
        XCTAssertEqual(session.subtitle, "my-app · Opus ⚡ · high · ⎇ auth-fix")
        // Without a name of its own the folder is the name, and is not said twice.
        let plain = try! XCTUnwrap(Summary(snapshots: [snapshot("b")], now: now).current)
        XCTAssertEqual(plain.name, "my-app")
        XCTAssertEqual(plain.subtitle, "")
    }

    func testThePluginsNoteSaysWhenATurnIsRunningOrThePersonIsWaitedOn() {
        let terminal = snapshot("a", source: "terminal", updatedAgo: 30, expiresIn: 3000)
        func view(_ state: String, ago: Double) -> SessionView? {
            Summary(
                snapshots: [terminal], now: now,
                states: ["a": SessionState(sessionID: "a", state: state, at: at - ago)]).current
        }
        XCTAssertEqual(view(SessionState.running, ago: 60)?.cache, .active)
        XCTAssertEqual(view(SessionState.idle, ago: 20)?.cache, .expires(in: 3000))
        // A waiting session's clock keeps running: nothing is being sent.
        XCTAssertEqual(view(SessionState.waiting, ago: 20)?.cache, .expires(in: 3000))
        XCTAssertEqual(view(SessionState.waiting, ago: 20)?.isWaiting, true)
        // The session has moved on since it was said to be waiting.
        XCTAssertEqual(view(SessionState.waiting, ago: 300)?.isWaiting, false)
        // A turn said to be running, with nothing moving for ten minutes, was interrupted.
        let quiet = snapshot("a", source: "terminal", updatedAgo: 1200, expiresIn: 2000)
        let stale = Summary(
            snapshots: [quiet], now: now,
            states: ["a": SessionState(sessionID: "a", state: SessionState.running, at: at - 1300)]).current
        XCTAssertEqual(stale?.cache, .expires(in: 2000))
    }

    func testAGatewaysSpendLimitStandsInForTheWindows() {
        let gateway = snapshot("a", limits: ["spend_limit": .init(
            used: 62.8, resetsAt: at + 86_400, usedUSD: 314.12, limitUSD: 500, period: "monthly")])
        let summary = Summary(snapshots: [gateway], now: now)
        XCTAssertTrue(summary.showsSpendLimit)
        XCTAssertEqual(summary.spendLimit?.percent, 63)
        XCTAssertEqual(summary.spendLimit?.dollarsText, "$314 / $500")
        // Only a subscription's two windows make the dollars a value and not a bill.
        XCTAssertFalse(summary.isSubscription)
        XCTAssertEqual(summary.rows(.of(.en))[0], "Spend Limit  ▰▰▰▰▰▱▱▱  63% Used  ·  Resets in 1d0h  ·  $314 / $500")
        XCTAssertFalse(Summary(snapshots: [snapshot("b")], now: now).showsSpendLimit)
        // A week used evenly would stand where the bar's mark is.
        let week = Summary(snapshots: [snapshot("b")], now: now).sevenDay
        let left: Double = 4 * 86400 + 2 * 3600
        let expected: Double = 1 - left / (7 * 86400)
        XCTAssertEqual(week?.evenMark ?? 0, expected, accuracy: 0.0001)
    }

    func testWhatASessionSaysAboutItsCache() throws {
        let en = Strings.of(.en)
        var billed = snapshot("a", limits: [:])
        billed.modelID = "claude-opus-5-5"
        billed.cache.recacheTokens = 310_000
        billed.cache.misses = 2
        billed.cache.missRecacheTokens = 412_000
        billed.cache.lastMissCauses = ["tools_changed", "something_new"]
        let session = try XCTUnwrap(Summary(snapshots: [billed], now: now).current)
        XCTAssertEqual(session.coldLine(en), "Going cold rewrites 310.0k tokens · 40× the price of reading them warm")
        XCTAssertEqual(session.coldPriceLine(en, isSubscription: false), "At API prices: $2.48 cold, $0.06 warm")
        // On a subscription the dollars are nobody's bill, so they are not shown.
        XCTAssertNil(session.coldPriceLine(en, isSubscription: true))
        XCTAssertEqual(session.missLine(en), "Cache rebuilt 2× unexpectedly · 412.0k tokens rewritten")
        // A cause Claude Code names that this build does not know is shown as it came.
        XCTAssertEqual(session.missCauseLine(en), "Last cause: tool definitions changed, something new")
        XCTAssertNil(session.shortCacheLine(en, isSubscription: true))

        // A session with no misses on record says nothing of them; a small one nothing of cold costs.
        let quiet = try XCTUnwrap(Summary(snapshots: [snapshot("b")], now: now).current)
        XCTAssertNil(quiet.missLine(en))
        XCTAssertNil(quiet.missCauseLine(en))
        var small = snapshot("c")
        small.context.tokens = 20_000
        XCTAssertNil(Summary(snapshots: [small], now: now).current?.coldLine(en))
        var short = snapshot("d")
        short.cache.ttl = 300
        XCTAssertEqual(Summary(snapshots: [short], now: now).current?.shortCacheLine(en, isSubscription: true), en.shortCacheNote)
    }

    func testTheFiguresAsAScriptReadsThem() throws {
        var first = snapshot("a")
        first.modelID = "claude-sonnet-5-5"
        let data = Summary(snapshots: [first, snapshot("b", updatedAgo: 90, expiresIn: -5)], now: now).json(now: now)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let current = try XCTUnwrap(object["current"] as? [String: Any])
        XCTAssertEqual(current["cache"] as? String, "warm")
        XCTAssertEqual(current["expires_in"] as? Int, 2856)
        XCTAssertEqual(current["advice"] as? String, "worthIt")
        XCTAssertEqual(current["cold_ratio"] as? Double, 40)
        XCTAssertEqual(current["model"] as? String, "claude-sonnet-5-5")
        let others = try XCTUnwrap(object["others"] as? [[String: Any]])
        XCTAssertEqual(others.first?["cache"] as? String, "expired")
        XCTAssertEqual(others.first?["actionable"] as? Bool, true)
        let limits = try XCTUnwrap(object["limits"] as? [String: [String: Any]])
        XCTAssertEqual(limits["five_hour"]?["resets_in"] as? Int, 38 * 60)
        // With no session there is still an object to read.
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: Summary(snapshots: [], now: now).json(now: now)) as? [String: Any])
        XCTAssertNil(empty["current"])
    }

    func testCacheStates() {
        func state(expiresIn: Double?, active: Bool = false) -> CacheState? {
            Summary(snapshots: [snapshot("a", expiresIn: expiresIn, active: active)], now: now).current?.cache
        }
        XCTAssertEqual(state(expiresIn: nil), .unknown)
        XCTAssertEqual(state(expiresIn: -5), .expired)
        XCTAssertEqual(state(expiresIn: 300, active: true), .active)
        // A session that died mid-turn stops claiming to be active.
        let dead = Summary(snapshots: [snapshot("a", updatedAgo: 7 * 3600, expiresIn: -100, active: true)], now: now)
        XCTAssertEqual(dead.current?.cache, .expired)
        XCTAssertEqual(state(expiresIn: 300)?.level, .warn)
        XCTAssertEqual(state(expiresIn: 90)?.level, .crit)
        XCTAssertEqual(state(expiresIn: 3000)?.level, .plain)
        XCTAssertEqual(CacheState.expired.text, "expired")
        XCTAssertEqual(CacheState.expired.shortText, "exp")
        XCTAssertEqual(CacheState.active.shortText, "live")
        XCTAssertEqual(CacheState.expires(in: 2856).shortText, "47:36")
        XCTAssertEqual(CacheState.expires(in: 900).remainingFraction, 0.25)
        XCTAssertEqual(CacheState.expires(in: 9000).remainingFraction, 1)
        XCTAssertEqual(CacheState.active.remainingFraction, 1)
        XCTAssertEqual(CacheState.unknown.remainingFraction, 0)
    }

    func testFormats() {
        XCTAssertEqual(Format.tokens(908), "908")
        XCTAssertEqual(Format.tokens(68_600), "68.6k")
        XCTAssertEqual(Format.tokens(1_000_000), "1.0M")
        XCTAssertEqual(Format.reset(4 * 3600 + 36 * 60 + 59), "4h36m")
        XCTAssertEqual(Format.reset(4 * 3600 + 5 * 60), "4h05m")
        XCTAssertEqual(Format.reset(59), "0m")
        XCTAssertEqual(Format.bar(0), "▱▱▱▱▱▱▱▱")
        XCTAssertEqual(Format.bar(2), "▰▱▱▱▱▱▱▱")
        XCTAssertEqual(Format.bar(100), "▰▰▰▰▰▰▰▰")
        XCTAssertEqual(Format.level(69.9, warn: 70, crit: 90), .ok)
        XCTAssertEqual(Format.level(70, warn: 70, crit: 90), .warn)
        XCTAssertEqual(Format.hitLevel(49), .crit)
    }

    // MARK: Files, as the two writers leave them

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-bar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLoadsBothWritersAndSkipsWhatDoesNotDecode() throws {
        let directory = try temporaryDirectory()
        // The status line command's spelling.
        let terminal = """
        {"v":1,"source":"terminal","session_id":"t1","cwd":"/x/App","cache":{"turn_hit":94,"avg_hit":96,\
        "expires_at":1791758026,"active":false},"limits":{"five_hour":{"used":2.3,"resets_at":1791771012}},"limits_at":1791754452,\
        "context":{"tokens":68600,"output":9600,"window":1000000,"percent":7},"cost_usd":206.512,"updated_at":1791754452}
        """
        // The mod's, before its first turn: nulls where it has no figure yet.
        let desktop = """
        {"v":1,"source":"desktop","session_id":"d1","cwd":"/x/Other","cache":{"turn_hit":null,"avg_hit":null,\
        "expires_at":null,"active":true},"limits":{},"limits_at":null,"context":{"tokens":0,"output":0,"window":200000,\
        "percent":null},"cost_usd":null,"updated_at":1791754460}
        """
        try terminal.write(to: directory.appendingPathComponent("t1.json"), atomically: true, encoding: .utf8)
        try desktop.write(to: directory.appendingPathComponent("d1.json"), atomically: true, encoding: .utf8)
        try "{\"v\":1,\"sou".write(to: directory.appendingPathComponent("half.json"), atomically: true, encoding: .utf8)
        try terminal.replacingOccurrences(of: "\"v\":1", with: "\"v\":9")
            .write(to: directory.appendingPathComponent("future.json"), atomically: true, encoding: .utf8)
        // The plugin's note on what a session is doing sits in the same folder and is not a snapshot.
        try "{\"session_id\":\"t1\",\"state\":\"waiting\",\"at\":1791754460}"
            .write(to: directory.appendingPathComponent("t1.state.json"), atomically: true, encoding: .utf8)
        try "not a snapshot".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let loaded = SnapshotStore.load(from: directory).sorted { $0.sessionID < $1.sessionID }
        XCTAssertEqual(loaded.map(\.sessionID), ["d1", "t1"])
        XCTAssertEqual(loaded[0].cache.active, true)
        XCTAssertNil(loaded[0].costUSD)
        XCTAssertEqual(loaded[1].limits["five_hour"]?.used, 2.3)
        XCTAssertEqual(loaded[1].limitsAt, 1_791_754_452)
        XCTAssertNil(loaded[0].limitsAt)
        XCTAssertEqual(loaded[1].cache.expiresAt, 1_791_758_026)
        XCTAssertEqual(SnapshotStore.load(from: directory.appendingPathComponent("missing")), [])
        XCTAssertEqual(
            SnapshotStore.loadStates(from: directory),
            ["t1": SessionState(sessionID: "t1", state: SessionState.waiting, at: 1_791_754_460)])
    }

    func testPruneRemovesOnlyOldSnapshots() throws {
        let directory = try temporaryDirectory()
        let old = directory.appendingPathComponent("old.json")
        let recent = directory.appendingPathComponent("recent.json")
        let other = directory.appendingPathComponent("keep.txt")
        for url in [old, recent, other] {
            try "{}".write(to: url, atomically: true, encoding: .utf8)
        }
        let eightDaysAgo = now.addingTimeInterval(-8 * 86400)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: other.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: recent.path)

        XCTAssertEqual(SnapshotStore.prune(in: directory, now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: Languages

    func testEveryLanguageHasEveryStringWithItsPlaceholders() {
        let reference = Mirror(reflecting: Strings.of(.en)).children.map { ($0.label!, $0.value as! String) }
        func placeholders(_ text: String) -> [String] {
            ["%@", "%d"].flatMap { mark in Array(repeating: mark, count: text.components(separatedBy: mark).count - 1) }
        }
        XCTAssertEqual(Language.allCases.count, 20)
        for language in Language.allCases {
            let fields = Mirror(reflecting: Strings.of(language)).children.map { ($0.label!, $0.value as! String) }
            XCTAssertEqual(fields.count, reference.count)
            for (field, expected) in zip(fields, reference) {
                XCTAssertFalse(field.1.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.rawValue).\(field.0) is empty")
                XCTAssertEqual(
                    placeholders(field.1), placeholders(expected.1),
                    "\(language.rawValue).\(field.0) must carry the same placeholders as English")
            }
            XCTAssertFalse(language.nativeName.isEmpty)
        }
        // A wrong copy-paste would leave one language reading as another.
        XCTAssertEqual(Set(Language.allCases.map { Strings.of($0).emptyHint }).count, 20)
    }

    func testFormattedStrings() {
        XCTAssertEqual(Strings.of(.en).reset(in: 4 * 3600 + 36 * 60), "Resets in 4h36m")
        XCTAssertEqual(Strings.of(.zhHans).reset(in: 38 * 60 + 10), "38m 后重置")
        XCTAssertEqual(Strings.of(.ja).reset(in: 20), "まもなくリセット")
        XCTAssertEqual(String(format: Strings.of(.en).activeCount, 3), "3 active")
        XCTAssertEqual(Strings.of(.de).source("terminal"), "Terminal")
        XCTAssertEqual(Strings.of(.zhHans).source("desktop"), "桌面")
        XCTAssertEqual(Strings.of(.en).source("vscode"), "vscode")
    }

    func testLanguageResolution() {
        XCTAssertEqual(Language.resolve(choice: "ja", preferred: ["en-US"]), .ja)
        XCTAssertEqual(Language.resolve(choice: "system", preferred: ["de-DE", "en-US"]), .de)
        XCTAssertEqual(Language.resolve(choice: nil, preferred: ["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(Language.resolve(choice: "klingon", preferred: ["fr-CA"]), .fr)
        XCTAssertEqual(Language.resolve(preferred: ["zh-Hant-HK"]), .zhHant)
        XCTAssertEqual(Language.resolve(preferred: ["zh-TW"]), .zhHant)
        XCTAssertEqual(Language.resolve(preferred: ["zh-CN"]), .zhHans)
        XCTAssertEqual(Language.resolve(preferred: ["zh"]), .zhHans)
        XCTAssertEqual(Language.resolve(preferred: ["pt-BR"]), .pt)
        // Not one of the twenty: the next preference stands, then English.
        XCTAssertEqual(Language.resolve(preferred: ["fi-FI", "sv-SE"]), .sv)
        XCTAssertEqual(Language.resolve(preferred: ["fi-FI"]), .en)
        XCTAssertEqual(Language.resolve(preferred: []), .en)
        XCTAssertTrue(Language.ar.isRightToLeft)
        XCTAssertFalse(Language.zhHans.isRightToLeft)
    }

    // MARK: Pinning, and what the dollar figure means

    func testAPinnedSessionStaysInViewUntilItGoesQuiet() {
        let snapshots = [
            snapshot("new", updatedAgo: 5),
            snapshot("mine", source: "terminal", cwd: "/x/DraftPipe AI", updatedAgo: 600, turnHit: 90, expiresIn: 723),
            snapshot("third", cwd: "/x/Other", updatedAgo: 900),
        ]
        let automatic = Summary(snapshots: snapshots, now: now)
        XCTAssertEqual(automatic.current?.id, "new")
        XCTAssertFalse(automatic.isPinned)

        let pinned = Summary(snapshots: snapshots, now: now, pinned: "mine")
        XCTAssertEqual(pinned.current?.name, "DraftPipe AI")
        XCTAssertTrue(pinned.isPinned)
        // The rest keep their order, newest first.
        XCTAssertEqual(pinned.others.map(\.id), ["new", "third"])
        // The menu bar's clock follows the session in view.
        XCTAssertEqual(pinned.titleText, "5h 20%  7d 3%  ◷12:03")

        // A pin on a session that is no longer listed falls back to the newest.
        let gone = Summary(snapshots: snapshots, now: now, pinned: "closed-long-ago")
        XCTAssertEqual(gone.current?.id, "new")
        XCTAssertFalse(gone.isPinned)
        let stale = Summary(
            snapshots: [snapshot("new", updatedAgo: 5), snapshot("mine", updatedAgo: 25 * 3600)], now: now, pinned: "mine")
        XCTAssertEqual(stale.current?.id, "new")
        XCTAssertFalse(stale.isPinned)
    }

    func testDollarsAreABillOnlyWithoutASubscription() {
        XCTAssertTrue(Summary(snapshots: [snapshot("a")], now: now).isSubscription)
        // Rate limits come from any session of the account, not only the one in view.
        XCTAssertTrue(Summary(snapshots: [snapshot("a", limits: [:]), snapshot("b", updatedAgo: 900)], now: now).isSubscription)
        let api = Summary(snapshots: [snapshot("a", limits: [:])], now: now)
        XCTAssertFalse(api.isSubscription)
        XCTAssertTrue(api.rows(.of(.en)).contains { $0?.contains("Session cost $5.91") == true })
    }
}
