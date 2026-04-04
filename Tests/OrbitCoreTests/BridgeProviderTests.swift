import Foundation
import Testing
@testable import OrbitCore

@Suite("Bridge Provider")
struct BridgeProviderTests {
    @Test("BridgeProvider initializes with correct properties")
    func bridgeProviderInit() {
        let provider = BridgeProvider(
            name: "anthropic",
            cliPath: "/usr/local/bin/claude",
            model: "claude-sonnet-4-6"
        )
        #expect(provider.name == "anthropic")
        #expect(provider.model == "claude-sonnet-4-6")
    }

    @Test("BridgeProvider cost estimation uses model pricing")
    func bridgeProviderCost() {
        let provider = BridgeProvider(
            name: "anthropic",
            cliPath: "/usr/local/bin/claude",
            model: "claude-haiku-4-5"
        )
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000)
        let cost = provider.estimateCost(usage: usage)
        #expect(cost.inputCost == 1.0)
        #expect(cost.outputCost == 2.5)
    }

    @Test("BridgeProvider detectClaudeCLI finds installed claude")
    func detectClaudeCLI() {
        // This test verifies the detection mechanism works.
        // On a machine with claude installed, it should find it.
        let path = BridgeProvider.detectClaudeCLI()
        // We don't assert it's found because CI may not have claude installed,
        // but if found, it should be a valid path.
        if let path {
            #expect(FileManager.default.isExecutableFile(atPath: path))
            #expect(path.hasSuffix("claude"))
        }
    }

    @Test("BridgeProvider stream fails gracefully with invalid CLI path")
    func bridgeProviderInvalidPath() async {
        let provider = BridgeProvider(
            name: "anthropic",
            cliPath: "/nonexistent/path/to/claude",
            model: "claude-sonnet-4-6"
        )

        let stream = provider.stream(
            messages: [.userText("hello")],
            systemPrompt: "test",
            tools: []
        )

        var caughtError = false
        do {
            for try await _ in stream {
                // Should not get here
            }
        } catch {
            caughtError = true
        }
        #expect(caughtError)
    }
}
