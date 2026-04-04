import Testing
@testable import OrbitCore

@Suite("Provider")
struct ProviderTests {
    @Test("ToolDefinition initialization")
    func toolDefinitionInit() {
        let tool = ToolDefinition(
            name: "web_search",
            description: "Search the web",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object(["type": "string"]),
                ]),
                "required": .array(["query"]),
            ])
        )
        #expect(tool.name == "web_search")
        #expect(tool.description == "Search the web")
    }

    @Test("ProviderError descriptions")
    func providerErrorDescriptions() {
        let err1 = ProviderError.authenticationFailed("invalid key")
        #expect(err1.errorDescription?.contains("invalid key") == true)

        let err2 = ProviderError.rateLimited(retryAfter: 30)
        #expect(err2.errorDescription?.contains("30") == true)

        let err3 = ProviderError.rateLimited(retryAfter: nil)
        #expect(err3.errorDescription?.contains("Rate limited") == true)

        let err4 = ProviderError.modelNotFound("gpt-99")
        #expect(err4.errorDescription?.contains("gpt-99") == true)

        let err5 = ProviderError.serverError(statusCode: 500, message: "internal")
        #expect(err5.errorDescription?.contains("500") == true)

        let err6 = ProviderError.streamingError("broken pipe")
        #expect(err6.errorDescription?.contains("broken pipe") == true)

        let err7 = ProviderError.invalidResponse("empty body")
        #expect(err7.errorDescription?.contains("empty body") == true)
    }

    @Test("AnthropicProvider initializes with correct properties")
    func anthropicProviderInit() {
        let provider = AnthropicProvider(apiKey: "test-key", model: "claude-sonnet-4-6")
        #expect(provider.name == "anthropic")
        #expect(provider.model == "claude-sonnet-4-6")
    }

    @Test("AnthropicProvider cost estimation uses model pricing")
    func anthropicProviderCost() {
        let provider = AnthropicProvider(apiKey: "test-key", model: "claude-haiku-4-5")
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000)
        let cost = provider.estimateCost(usage: usage)
        #expect(cost.inputCost == 1.0)
        #expect(cost.outputCost == 2.5)
    }
}
