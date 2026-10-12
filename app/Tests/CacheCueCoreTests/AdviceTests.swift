import XCTest

@testable import CacheCueCore

final class AdviceTests: XCTestCase {
    func advice(_ tokens: Double, percent: Double? = nil, _ cache: CacheState) -> CompactAdvice {
        CompactAdvice(contextTokens: tokens, contextPercent: percent, cache: cache)
    }

    func testRulesInPriorityOrder() {
        // A running turn silences everything, even a full window.
        XCTAssertEqual(advice(900_000, percent: 95, .active).kind, .running)
        // A nearly full window outranks the cache, warm or cold.
        XCTAssertEqual(advice(170_000, percent: 85, .expires(in: 3000)).kind, .nearFull)
        XCTAssertEqual(advice(170_000, percent: 85, .expired).kind, .nearFull)
        // A small context is never worth compacting, whatever the cache is doing.
        XCTAssertEqual(advice(49_999, .expired).kind, .notNeeded)
        XCTAssertEqual(advice(20_000, .expires(in: 30)).kind, .notNeeded)
        // From here the cache decides.
        XCTAssertEqual(advice(50_000, .expired).kind, .cold)
        XCTAssertEqual(advice(60_000, .expires(in: 600)).kind, .beforeExpiry)
        XCTAssertEqual(advice(60_000, .expires(in: 601)).kind, .optional)
        XCTAssertEqual(advice(99_999, .expires(in: 3000)).kind, .optional)
        XCTAssertEqual(advice(100_000, .expires(in: 3000)).kind, .worthIt)
        // With no word on the cache yet, size alone decides.
        XCTAssertEqual(advice(207_000, percent: 21, .unknown).kind, .worthIt)
        XCTAssertEqual(advice(70_000, .unknown).kind, .optional)
        // 80% of a small window can still be few tokens; the window is what auto-compact goes by.
        XCTAssertEqual(advice(40_000, percent: 80, .expires(in: 3000)).kind, .nearFull)
    }

    func testWhatIsActionableAndHowLoud() {
        XCTAssertTrue(advice(170_000, percent: 85, .unknown).isActionable)
        XCTAssertTrue(advice(120_000, .expired).isActionable)
        XCTAssertTrue(advice(120_000, .expires(in: 300)).isActionable)
        XCTAssertFalse(advice(120_000, .expires(in: 3000)).isActionable)
        XCTAssertFalse(advice(10_000, .expired).isActionable)
        XCTAssertFalse(advice(500_000, .active).isActionable)

        XCTAssertEqual(advice(120_000, .expires(in: 300)).level, .warn)
        XCTAssertEqual(advice(120_000, .expires(in: 120)).level, .crit)
        XCTAssertEqual(advice(120_000, .expired).level, .crit)
        XCTAssertEqual(advice(120_000, .expires(in: 3000)).level, .warn)
        XCTAssertEqual(advice(10_000, .unknown).level, .ok)
        XCTAssertEqual(advice(70_000, .unknown).level, .plain)
    }

    func testWording() {
        let en = Strings.of(.en)
        let leaving = advice(120_000, .expires(in: 492))
        XCTAssertEqual(leaving.headline(en), "Stepping away? Compact now")
        XCTAssertTrue(leaving.detail(en).hasPrefix("Cache expires in 08:12."))
        XCTAssertEqual(
            advice(38_200, .unknown).detail(en), "Context is only 38.2k. Compacting would cost more than it saves.")
        XCTAssertEqual(
            advice(170_000, percent: 84.6, .unknown).detail(en),
            "Context is 85% full. Auto-compact will soon pick its own moment, possibly mid-task.")
        XCTAssertTrue(advice(207_000, .expired).detail(en).contains("all 207.0k"))
        XCTAssertEqual(advice(207_000, .expired).headline(.of(.zhHans)), "缓存已过期:继续之前先决定")
        // Every language fills in every situation without a stray placeholder.
        for language in Language.allCases {
            let strings = Strings.of(language)
            for one in [
                advice(900_000, .active), advice(170_000, percent: 85, .unknown), advice(10_000, .unknown),
                advice(120_000, .expired), leaving, advice(120_000, .unknown), advice(70_000, .unknown),
            ] {
                XCTAssertFalse(one.headline(strings).isEmpty)
                XCTAssertFalse(one.detail(strings).contains("%@"), "\(language.rawValue) \(one.kind)")
                XCTAssertFalse(one.detail(strings).contains("%d"), "\(language.rawValue) \(one.kind)")
            }
        }
    }
}
