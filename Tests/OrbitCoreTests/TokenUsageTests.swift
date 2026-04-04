import Foundation
import Testing
@testable import OrbitCore

@Suite("Token Usage & Pricing")
struct TokenUsageTests {
    @Test("TokenUsage zero constant")
    func tokenUsageZero() {
        let zero = TokenUsage.zero
        #expect(zero.inputTokens == 0)
        #expect(zero.outputTokens == 0)
        #expect(zero.totalTokens == 0)
    }

    @Test("TokenUsage += operator")
    func tokenUsagePlusEquals() {
        var usage = TokenUsage(inputTokens: 10, outputTokens: 20)
        usage += TokenUsage(inputTokens: 5, outputTokens: 15)
        #expect(usage.inputTokens == 15)
        #expect(usage.outputTokens == 35)
    }

    @Test("TokenUsage total includes cache tokens")
    func tokenUsageTotalWithCache() {
        let usage = TokenUsage(
            inputTokens: 100,
            outputTokens: 50,
            cacheCreationInputTokens: 25,
            cacheReadInputTokens: 10
        )
        #expect(usage.totalTokens == 185)
    }

    @Test("TokenUsage codable roundtrip")
    func tokenUsageCodable() throws {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50, cacheCreationInputTokens: 25)
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        #expect(decoded == usage)
    }

    @Test("ModelPricing for model names")
    func modelPricingLookup() {
        let haiku = ModelPricing.forModel("claude-haiku-4-5")
        #expect(haiku.inputCostPerMillion == 1.0)

        let opus = ModelPricing.forModel("claude-opus-4-6")
        #expect(opus.inputCostPerMillion == 15.0)

        let sonnet = ModelPricing.forModel("claude-sonnet-4-6")
        #expect(sonnet.inputCostPerMillion == 3.0)

        let unknown = ModelPricing.forModel("some-unknown-model")
        #expect(unknown.inputCostPerMillion == 3.0) // defaults to sonnet
    }

    @Test("Cost estimate for haiku")
    func costEstimateHaiku() {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000)
        let cost = usage.estimateCost(pricing: .haiku)
        #expect(cost.inputCost == 1.0)
        #expect(cost.outputCost == 2.5)
        #expect(cost.totalCost == 3.5)
    }

    @Test("Cost estimate formatted USD")
    func costFormatted() {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50)
        let cost = usage.estimateCost(pricing: .sonnet)
        // Tiny cost should show 4 decimals
        #expect(cost.formattedUSD.hasPrefix("$"))
        #expect(cost.totalCost < 0.01)
    }

    @Test("UsageTracker accumulates")
    func usageTrackerAccumulates() {
        var tracker = UsageTracker(model: "claude-sonnet-4-6")
        tracker.record(TokenUsage(inputTokens: 100, outputTokens: 50))
        tracker.record(TokenUsage(inputTokens: 200, outputTokens: 75))

        #expect(tracker.turnCount == 2)
        #expect(tracker.cumulativeUsage.inputTokens == 300)
        #expect(tracker.cumulativeUsage.outputTokens == 125)
    }

    @Test("UsageTracker estimated cost uses model pricing")
    func usageTrackerCost() {
        var tracker = UsageTracker(model: "claude-haiku-4-5")
        tracker.record(TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000))
        let cost = tracker.estimatedCost
        #expect(cost.inputCost == 1.0)
    }
}
