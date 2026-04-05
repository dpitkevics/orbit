import Foundation
import Testing
@testable import OrbitCore

@Suite("OpenAI Provider")
struct OpenAIProviderTests {
    @Test("OpenAIProvider initializes with correct properties")
    func openAIProviderInit() {
        let provider = OpenAIProvider(apiKey: "test-key", model: "gpt-4o")
        #expect(provider.name == "openai")
        #expect(provider.model == "gpt-4o")
    }

    @Test("OpenAIProvider cost estimation for GPT-4o")
    func openAIProviderCostGPT4o() {
        let provider = OpenAIProvider(apiKey: "test-key", model: "gpt-4o")
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000)
        let cost = provider.estimateCost(usage: usage)
        #expect(cost.inputCost == 2.5)
        #expect(cost.outputCost == 5.0)
    }

    @Test("OpenAIProvider cost estimation for GPT-4o-mini")
    func openAIProviderCostMini() {
        let provider = OpenAIProvider(apiKey: "test-key", model: "gpt-4o-mini")
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        let cost = provider.estimateCost(usage: usage)
        #expect(cost.inputCost == 0.15)
        #expect(cost.outputCost == 0.60)
    }

    @Test("OpenAIProvider cost estimation for o3")
    func openAIProviderCostO3() {
        let provider = OpenAIProvider(apiKey: "test-key", model: "o3")
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000)
        let cost = provider.estimateCost(usage: usage)
        #expect(cost.inputCost == 10.0)
        #expect(cost.outputCost == 20.0)
    }
}
