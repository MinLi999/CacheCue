import XCTest

@testable import CacheCueCore

final class PricingTests: XCTestCase {
    func cost(_ model: String?, tokens: Double = 310_000, lifetime: TimeInterval = 3600) -> ColdCost {
        ColdCost(tokens: tokens, isEstimate: false, modelID: model, lifetime: lifetime)
    }

    func testTheMultipleIsTheWritePriceOverTheReadPrice() {
        // An hour's cache is written at twice the base price; reads cost a tenth, or less on newer models.
        XCTAssertEqual(cost("claude-opus-5").ratio, 20)
        XCTAssertEqual(cost("claude-opus-5-5").ratio, 40)
        XCTAssertEqual(cost("claude-sonnet-5-5").ratio, 40)
        XCTAssertEqual(cost("claude-fable-5-1").ratio, 80)
        XCTAssertEqual(cost("claude-fable-5").ratio, 20)
        // A five-minute cache is written at 1.25 times.
        XCTAssertEqual(cost("claude-opus-5-5", lifetime: 300).ratio, 25)
        XCTAssertEqual(cost("claude-opus-5", lifetime: 300).ratioText, "12.5")
        // However the provider spells the model.
        XCTAssertEqual(cost("us.anthropic.claude-opus-5-5-v1:0").ratio, 40)
        XCTAssertEqual(cost("claude-opus-5-5[1m]").ratio, 40)
    }

    func testAModelNotInTheTableIsGivenTheLeastItCanBe() {
        let unknown = cost("some-future-model")
        XCTAssertTrue(unknown.isFloor)
        XCTAssertEqual(unknown.ratioText, "≥20")
        XCTAssertNil(unknown.coldUSD)
        XCTAssertNil(unknown.warmUSD)
        XCTAssertTrue(cost(nil).isFloor)
        XCTAssertFalse(cost("claude-opus-5-5").isFloor)
    }

    func testDollarsAtListPrices() {
        // 310k tokens of Opus 5.5 ($4 per million): written at 2×, read at 0.05×.
        XCTAssertEqual(cost("claude-opus-5-5").coldUSD ?? 0, 2.48, accuracy: 0.0001)
        XCTAssertEqual(cost("claude-opus-5-5").warmUSD ?? 0, 0.062, accuracy: 0.0001)
        XCTAssertEqual(ColdCost.dollars(2.48), "$2.48")
        XCTAssertEqual(ColdCost.dollars(24.8), "$24.8")
        // Haiku 5.5 has one price up to 100k tokens of prompt and another above.
        XCTAssertEqual(Pricing.rate(modelID: "claude-haiku-5-5", promptTokens: 100_000).base, 0.1)
        XCTAssertEqual(Pricing.rate(modelID: "claude-haiku-5-5", promptTokens: 100_001).base, 0.5)
    }

    func testAnEstimateIsMarkedAsOne() {
        XCTAssertEqual(cost("claude-opus-5-5").tokensText, "310.0k")
        XCTAssertEqual(ColdCost(tokens: 96_000, isEstimate: true, modelID: nil, lifetime: 3600).tokensText, "~96.0k")
    }
}
