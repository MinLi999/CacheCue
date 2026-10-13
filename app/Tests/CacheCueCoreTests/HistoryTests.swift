import XCTest

@testable import CacheCueCore

final class HistoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_750_000)
    var at: Double { now.timeIntervalSince1970 }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func limit(_ used: Double, resetsIn: Double) -> LimitView {
        LimitView(
            label: "5h", percent: Int(used.rounded()), used: used, bar: "", reset: nil, resetsIn: resetsIn,
            level: .ok, resetsAt: at + resetsIn)
    }

    func snapshot(
        _ id: String = "s", cwd: String = "/Users/t/Code/api", updatedAgo: Double = 5, expiresIn: Double? = 3000,
        misses: Int? = nil, missTokens: Double? = nil, cost: Double? = nil, recache: Double? = 200_000, hit: Int? = 90,
        at moment: Double? = nil
    ) -> Snapshot {
        let base = moment ?? at
        return Snapshot(
            v: 1, source: "terminal", sessionID: id, cwd: cwd,
            cache: .init(
                turnHit: hit, avgHit: hit, expiresAt: expiresIn.map { base + $0 }, active: false, recacheTokens: recache,
                misses: misses, missRecacheTokens: missTokens),
            limits: [:], limitsAt: nil,
            context: .init(tokens: 210_000, output: 0, window: 1_000_000, percent: 21),
            costUSD: cost, updatedAt: base - updatedAgo)
    }

    func testThePaceIsWhereTheRecentRateLeads() {
        var history = History()
        // 40% twenty-five minutes ago, 62% now: 0.88 points a minute, so the rest goes in about 43 minutes.
        history.sample(limits: ["five_hour": limit(40, resetsIn: 5400)], now: now.addingTimeInterval(-1500))
        let current = limit(62, resetsIn: 5400)
        guard case .hits(let moment)? = history.pace("five_hour", limit: current, now: now) else { return XCTFail("no pace") }
        XCTAssertEqual(moment.timeIntervalSince(now), 38 / (22.0 / 1500), accuracy: 1)
        // With the reset nearer than that, what is left outlasts the window.
        var near = History()
        near.sample(limits: ["five_hour": limit(40, resetsIn: 1200)], now: now.addingTimeInterval(-1500))
        XCTAssertEqual(near.pace("five_hour", limit: limit(62, resetsIn: 1200), now: now), .lasts)
        var slow = History()
        slow.sample(limits: ["five_hour": limit(61, resetsIn: 3000)], now: now.addingTimeInterval(-1500))
        XCTAssertEqual(slow.pace("five_hour", limit: limit(62, resetsIn: 3000), now: now), .lasts)
    }

    func testTooLittleToGoBySaysNothing() {
        var history = History()
        XCTAssertNil(history.pace("five_hour", limit: limit(62, resetsIn: 5400), now: now))
        // Five minutes of readings is not a rate.
        history.sample(limits: ["five_hour": limit(60, resetsIn: 5400)], now: now.addingTimeInterval(-300))
        XCTAssertNil(history.pace("five_hour", limit: limit(62, resetsIn: 5400), now: now))
        // Nothing used in the time looked at.
        var flat = History()
        flat.sample(limits: ["five_hour": limit(62, resetsIn: 5400)], now: now.addingTimeInterval(-1200))
        XCTAssertNil(flat.pace("five_hour", limit: limit(62, resetsIn: 5400), now: now))
        // Readings older than the look back do not count; a spend limit has no pace.
        var old = History()
        old.sample(limits: ["five_hour": limit(10, resetsIn: 5400)], now: now.addingTimeInterval(-7200))
        XCTAssertNil(old.pace("five_hour", limit: limit(62, resetsIn: 5400), now: now))
        XCTAssertNil(history.pace("spend_limit", limit: limit(62, resetsIn: 5400), now: now))
    }

    func testReadingsOfAWindowThatHasResetGo() {
        var history = History()
        history.sample(limits: ["five_hour": limit(90, resetsIn: 600)], now: now)
        history.sample(limits: ["five_hour": limit(90, resetsIn: 540)], now: now.addingTimeInterval(60))
        // The same reading a minute on is not kept twice.
        XCTAssertEqual(history.samples["five_hour"]?.count, 1)
        history.sample(limits: ["five_hour": limit(91, resetsIn: 500)], now: now.addingTimeInterval(100))
        XCTAssertEqual(history.samples["five_hour"]?.count, 2)
        // A new window: the old one's readings would make nonsense of its pace.
        history.sample(limits: ["five_hour": limit(2, resetsIn: 18_000)], now: now.addingTimeInterval(700))
        XCTAssertEqual(history.samples["five_hour"]?.map(\.used), [2])
    }

    func testAColdStartIsACacheSeenColdAndThenInUseAgain() {
        var history = History()
        history.record(snapshots: [snapshot(expiresIn: 600)], now: now, calendar: calendar)
        XCTAssertEqual(history.week(now: now, calendar: calendar).coldStarts, 0)
        // Twenty minutes on the cache has run out, and nothing has been sent.
        let cold = now.addingTimeInterval(1200)
        history.record(snapshots: [snapshot(expiresIn: 600)], now: cold, calendar: calendar)
        XCTAssertEqual(history.week(now: cold, calendar: calendar).coldStarts, 0)
        // The next message rewrites what the cache held.
        let back = now.addingTimeInterval(1500)
        history.record(
            snapshots: [snapshot(expiresIn: 3600, recache: 205_000, at: back.timeIntervalSince1970)], now: back,
            calendar: calendar)
        let week = history.week(now: back, calendar: calendar)
        XCTAssertEqual(week.coldStarts, 1)
        XCTAssertEqual(week.coldTokens, 200_000)
        // Looked at again with nothing new, it is not counted again.
        history.record(
            snapshots: [snapshot(expiresIn: 3600, recache: 205_000, at: back.timeIntervalSince1970)], now: back,
            calendar: calendar)
        XCTAssertEqual(history.week(now: back, calendar: calendar).coldStarts, 1)
    }

    func testWhatASessionSpentBeforeTheFirstLookIsNotCounted() {
        var history = History()
        // The app is installed while a session is in full swing.
        history.record(snapshots: [snapshot(misses: 2, missTokens: 300_000, cost: 18)], now: now, calendar: calendar)
        XCTAssertTrue(history.week(now: now, calendar: calendar).projects.isEmpty)
        XCTAssertEqual(history.week(now: now, calendar: calendar).rebuilds, 0)
        history.record(
            snapshots: [snapshot(misses: 2, missTokens: 300_000, cost: 19), snapshot("new", cwd: "/Users/t/Code/web", cost: 3)],
            now: now, calendar: calendar)
        let week = history.week(now: now, calendar: calendar)
        XCTAssertEqual(week.rebuilds, 0)
        XCTAssertEqual(week.projectsLine, "web $3.00 · api $1.00")
    }

    func testRebuildsAndCostAreCountedAsTheyGrow() {
        var history = History()
        history.record(snapshots: [], now: now, calendar: calendar)
        history.record(snapshots: [snapshot(misses: 1, missTokens: 100_000, cost: 4)], now: now, calendar: calendar)
        history.record(snapshots: [snapshot(misses: 3, missTokens: 400_000, cost: 6.5)], now: now, calendar: calendar)
        history.record(snapshots: [snapshot(misses: 3, missTokens: 400_000, cost: 6.5)], now: now, calendar: calendar)
        let week = history.week(now: now, calendar: calendar)
        XCTAssertEqual(week.rebuilds, 3)
        XCTAssertEqual(week.rebuildTokens, 400_000)
        XCTAssertEqual(week.projects.map(\.name), ["api"])
        XCTAssertEqual(week.projects.first?.usd ?? 0, 6.5, accuracy: 0.0001)
        XCTAssertEqual(week.hit, 90)
        XCTAssertEqual(week.daily.last, 400_000)
        XCTAssertEqual(week.rebuildLine(.of(.en)), "Unexpected rebuilds 3 · 400.0k tokens rewritten")
        XCTAssertEqual(week.coldLine(.of(.en)), "Cold starts 0 · 0 tokens rewritten")
        XCTAssertEqual(week.projectsLine, "api $6.50")
    }

    func testASessionMetLongAfterItWentQuietIsCountedFromHereOn() {
        var history = History()
        // An old session's snapshot, found when the app is first installed.
        history.record(
            snapshots: [snapshot(updatedAgo: 3 * 86400, misses: 4, missTokens: 900_000, cost: 80)], now: now,
            calendar: calendar)
        XCTAssertTrue(history.week(now: now, calendar: calendar).projects.isEmpty)
        XCTAssertEqual(history.week(now: now, calendar: calendar).rebuilds, 0)
        history.record(snapshots: [snapshot(misses: 5, missTokens: 950_000, cost: 81)], now: now, calendar: calendar)
        let week = history.week(now: now, calendar: calendar)
        XCTAssertEqual(week.rebuilds, 1)
        XCTAssertEqual(week.rebuildTokens, 50_000)
        XCTAssertEqual(week.projects.first?.usd ?? 0, 1, accuracy: 0.0001)
    }

    func testTheWeekIsSevenDaysAndThirtyAreKept() {
        var history = History()
        history.record(snapshots: [], now: now.addingTimeInterval(-40 * 86400), calendar: calendar)
        for back in [0, 3, 6, 7, 29, 31] {
            let day = now.addingTimeInterval(-Double(back) * 86400)
            history.record(
                snapshots: [snapshot("d\(back)", misses: 1, missTokens: 1000, at: day.timeIntervalSince1970)], now: day,
                calendar: calendar)
        }
        // Recording again today drops what is past keeping, and sessions whose snapshot is gone.
        history.record(snapshots: [], now: now, calendar: calendar)
        XCTAssertEqual(history.days.count, 5)
        XCTAssertEqual(history.sessions, [:])
        let week = history.week(now: now, calendar: calendar)
        XCTAssertEqual(week.rebuilds, 3)
        XCTAssertEqual(week.daily, [1000, 0, 0, 1000, 0, 0, 1000])
        XCTAssertTrue(History().week(now: now, calendar: calendar).isEmpty)
        XCTAssertFalse(week.isEmpty)
    }

    func testHistoryGoesToDiskAndBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cachecue-history-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("CacheCue/history.json")
        XCTAssertEqual(HistoryStore.load(from: url), History())

        var history = History()
        history.sample(limits: ["five_hour": limit(40, resetsIn: 5400)], now: now)
        history.record(snapshots: [snapshot(misses: 2, missTokens: 5000, cost: 3)], now: now, calendar: calendar)
        try HistoryStore.save(history, to: url)
        XCTAssertEqual(HistoryStore.load(from: url), history)
        // Sums and counts, and nothing that could be read as what was said in a session.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("/Users/"))
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(HistoryStore.load(from: url), History())
    }

    func testTheMomentAsThePaceLineNamesIt() {
        let en = Strings.of(.en)
        XCTAssertEqual(Format.clock(now.addingTimeInterval(1800), now: now, calendar: calendar), "20:50")
        XCTAssertEqual(Format.clock(now.addingTimeInterval(2 * 86400), now: now, calendar: calendar), "10-13 20:20")
        var soon = limit(62, resetsIn: 5400)
        soon.pace = .hits(at: now.addingTimeInterval(1800))
        XCTAssertEqual(soon.paceLine(en, now: now, calendar: calendar), "At this pace it runs out at 20:50")
        soon.pace = .lasts
        XCTAssertEqual(soon.paceLine(en, now: now, calendar: calendar), "At this pace it lasts until the reset")
        soon.pace = nil
        XCTAssertNil(soon.paceLine(en, now: now, calendar: calendar))
    }
}
