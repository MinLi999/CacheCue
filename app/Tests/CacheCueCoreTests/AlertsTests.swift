import XCTest

@testable import CacheCueCore

final class AlertsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_750_000)
    var at: Double { now.timeIntervalSince1970 }

    func session(
        _ id: String = "a", expiresIn: Double? = 500, tokens: Double = 180_000, active: Bool = false, ttl: Double? = nil
    ) -> SessionView {
        let snapshot = Snapshot(
            v: 1, source: "terminal", sessionID: id, cwd: "/Users/t/Code/\(id)-app",
            cache: .init(turnHit: 90, avgHit: 90, expiresAt: expiresIn.map { at + $0 }, active: active, ttl: ttl),
            limits: [:], limitsAt: nil,
            context: .init(tokens: tokens, output: 0, window: 1_000_000, percent: nil),
            costUSD: nil, updatedAt: at - 5)
        return Summary.view(of: snapshot, at: at)
    }

    func limit(_ used: Double, resetsIn: Double = 3600) -> LimitView {
        LimitView(
            label: "5h", percent: Int(used.rounded()), used: used, bar: "", reset: nil, resetsIn: resetsIn,
            level: .ok, resetsAt: at + resetsIn)
    }

    func due(
        _ sessions: [SessionView] = [], limits: [String: LimitView] = [:], at moment: Date? = nil, lead: TimeInterval = 600,
        cache: Bool = true, quota: Bool = true, ledger: inout AlertLedger
    ) -> [Alert] {
        Alerts.due(
            sessions: sessions, limits: limits, now: moment ?? now, lead: lead, cache: cache, quota: quota, ledger: &ledger)
    }

    func testACacheIsAnnouncedOncePerExpiry() {
        var ledger = AlertLedger()
        let first = due([session()], ledger: &ledger)
        XCTAssertEqual(first.count, 1)
        guard case .cacheExpiring(let id, let name, let left, let cold) = first[0] else { return XCTFail("\(first)") }
        XCTAssertEqual(id, "a")
        XCTAssertEqual(name, "a-app")
        XCTAssertEqual(left, 500)
        XCTAssertEqual(cold.tokens, 180_000)
        // The same expiry is not said twice.
        XCTAssertEqual(due([session()], ledger: &ledger), [])
        // The session carries on, the cache gets a new expiry, and that one nears in its turn.
        XCTAssertEqual(due([session(expiresIn: 3500)], ledger: &ledger), [])
        XCTAssertEqual(due([session(expiresIn: 400)], ledger: &ledger).count, 1)
    }

    func testWhatIsLeftAlone() {
        var ledger = AlertLedger()
        // Plenty of time left, a context too small to matter, a turn in flight, a cache already gone.
        XCTAssertEqual(due([session(expiresIn: 601)], ledger: &ledger), [])
        XCTAssertEqual(due([session(tokens: 49_000)], ledger: &ledger), [])
        XCTAssertEqual(due([session(active: true)], ledger: &ledger), [])
        XCTAssertEqual(due([session(expiresIn: -5)], ledger: &ledger), [])
        XCTAssertEqual(due([session(expiresIn: nil)], ledger: &ledger), [])
        // And everything, while the person has the alert turned off.
        XCTAssertEqual(due([session()], cache: false, ledger: &ledger), [])
        XCTAssertEqual(ledger.cache, [:])
    }

    func testTheLeadIsThePersonsForAnHourAndFixedForFiveMinutes() {
        var ledger = AlertLedger()
        XCTAssertEqual(due([session(expiresIn: 500)], lead: 300, ledger: &ledger), [])
        XCTAssertEqual(due([session(expiresIn: 300)], lead: 300, ledger: &ledger).count, 1)
        XCTAssertEqual(due([session("b", expiresIn: 850)], lead: 900, ledger: &ledger).count, 1)
        // Fifteen minutes of notice would cover a five-minute cache three times over.
        XCTAssertEqual(due([session("c", expiresIn: 200, ttl: 300)], lead: 900, ledger: &ledger), [])
        XCTAssertEqual(due([session("c", expiresIn: 90, ttl: 300)], lead: 900, ledger: &ledger).count, 1)
    }

    func testASessionThatIsGoneIsForgotten() {
        var ledger = AlertLedger()
        _ = due([session("a"), session("b")], ledger: &ledger)
        XCTAssertEqual(Set(ledger.cache.keys), ["a", "b"])
        _ = due([session("b")], ledger: &ledger)
        XCTAssertEqual(Set(ledger.cache.keys), ["b"])
    }

    func testALimitIsAnnouncedAsItPassesEachMark() {
        var ledger = AlertLedger()
        XCTAssertEqual(due(limits: ["five_hour": limit(79.9)], ledger: &ledger), [])
        XCTAssertEqual(
            due(limits: ["five_hour": limit(81)], ledger: &ledger), [.quota(kind: "five_hour", percent: 81, resetsIn: 3600)])
        XCTAssertEqual(due(limits: ["five_hour": limit(88)], ledger: &ledger), [])
        XCTAssertEqual(due(limits: ["five_hour": limit(96)], ledger: &ledger).count, 1)
        XCTAssertEqual(due(limits: ["five_hour": limit(99)], ledger: &ledger), [])
        // Found already past both marks, it is said once, not twice.
        var fresh = AlertLedger()
        XCTAssertEqual(due(limits: ["seven_day": limit(97)], ledger: &fresh).count, 1)
        XCTAssertEqual(due(limits: ["seven_day": limit(97)], ledger: &fresh), [])
    }

    func testAWindowStartingOverIsAnnouncedAndItsMarksCountAgain() {
        var ledger = AlertLedger()
        _ = due(limits: ["five_hour": limit(96, resetsIn: 600)], ledger: &ledger)
        // The reset time comes; Claude Code has dropped the reading by then.
        let later = now.addingTimeInterval(601)
        XCTAssertEqual(due(at: later, ledger: &ledger), [.windowReset(kind: "five_hour")])
        XCTAssertEqual(due(at: later, ledger: &ledger), [])
        // The new window fills up in its turn.
        let next = LimitView(
            label: "5h", percent: 85, used: 85, bar: "", reset: nil, resetsIn: 18_000, level: .ok, resetsAt: at + 18_601)
        XCTAssertEqual(due(limits: ["five_hour": next], at: later, ledger: &ledger).count, 1)
        // Turned off, nothing is said and no window is watched.
        var off = AlertLedger()
        XCTAssertEqual(due(limits: ["five_hour": limit(96)], quota: false, ledger: &off), [])
        XCTAssertEqual(off.windows, [:])
    }

    func testWhatANotificationSays() {
        let en = Strings.of(.en)
        var ledger = AlertLedger()
        let cache = due([session()], ledger: &ledger)[0]
        XCTAssertEqual(cache.title(en), "a-app: cache goes cold in 8m")
        XCTAssertEqual(cache.body(en), "That rewrites ~180.0k tokens. Stepping away? Run /compact first.")
        XCTAssertEqual(cache.sessionID, "a")
        let short = due([session("b", expiresIn: 85, ttl: 300)], ledger: &ledger)[0]
        XCTAssertEqual(short.title(en), "b-app: cache goes cold in 01:25")

        let quota = Alert.quota(kind: "seven_day", percent: 81, resetsIn: 4 * 3600)
        XCTAssertEqual(quota.title(en), "7-Day Limit: 81% used")
        XCTAssertEqual(quota.body(en), "Resets in 4h00m")
        XCTAssertNil(quota.sessionID)
        XCTAssertEqual(Alert.windowReset(kind: "five_hour").title(en), "5-Hour Limit has reset")
        XCTAssertEqual(Alert.quota(kind: "spend_limit", percent: 95, resetsIn: nil).title(.of(.zhHans)), "消费上限：已用 95%")
    }

    func testTheLedgerSurvivesBeingStored() throws {
        var ledger = AlertLedger()
        _ = due([session()], limits: ["five_hour": limit(85)], ledger: &ledger)
        let stored = try JSONDecoder().decode(AlertLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(stored, ledger)
        var again = stored
        XCTAssertEqual(due([session()], limits: ["five_hour": limit(85)], ledger: &again), [])
    }
}
