import Foundation
import Testing
@testable import OrbitCore

/// Mock LLM provider for testing the query engine.
struct MockProvider: LLMProvider, Sendable {
    let name = "mock"
    let model = "mock-model"
    let responses: @Sendable () -> [[StreamEvent]]

    init(responses: @escaping @Sendable () -> [[StreamEvent]]) {
        self.responses = responses
    }

    /// Simple text-only response.
    static func textOnly(_ text: String) -> MockProvider {
        MockProvider {
            [[
                .messageStart(id: "msg_1", model: "mock"),
                .textDelta(text),
                .usage(TokenUsage(inputTokens: 10, outputTokens: 5)),
                .messageStop(stopReason: .endTurn),
            ]]
        }
    }

    /// Response that requests a tool call, then gets a text response.
    static func withToolCall(
        toolId: String = "tool_1",
        toolName: String,
        toolInput: JSONValue,
        finalText: String
    ) -> MockProvider {
        let callCount = Mutex(0)
        return MockProvider { [callCount] in
            let current = callCount.withLock { value -> Int in
                let c = value
                value += 1
                return c
            }

            if current == 0 {
                // First call: request tool use
                return [[
                    .messageStart(id: "msg_1", model: "mock"),
                    .toolUse(id: toolId, name: toolName, input: toolInput),
                    .usage(TokenUsage(inputTokens: 10, outputTokens: 5)),
                    .messageStop(stopReason: .toolUse),
                ]]
            } else {
                // Second call: text response after tool result
                return [[
                    .messageStart(id: "msg_2", model: "mock"),
                    .textDelta(finalText),
                    .usage(TokenUsage(inputTokens: 15, outputTokens: 10)),
                    .messageStop(stopReason: .endTurn),
                ]]
            }
        }
    }

    func stream(
        messages: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let allResponses = responses()
        let responseIndex = messages.count / 2 // rough heuristic
        let events = responseIndex < allResponses.count ? allResponses[responseIndex] : allResponses.last ?? []

        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func estimateCost(usage: TokenUsage) -> CostEstimate {
        usage.estimateCost(pricing: .sonnet)
    }
}

/// Simple thread-safe counter.
final class Mutex<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

@Suite("Query Engine")
struct QueryEngineTests {
    @Test("Text-only response passes through")
    func textOnlyResponse() async throws {
        let provider = MockProvider.textOnly("Hello from Orbit!")
        let pool = ToolPool(tools: [])
        let policy = PermissionPolicy(activeMode: .readOnly)
        let engine = QueryEngine(provider: provider, toolPool: pool, policy: policy)

        var messages = [ChatMessage.userText("Hi")]
        let stream = engine.run(messages: &messages, systemPrompt: "Test")

        var text = ""
        var completed = false

        for try await event in stream {
            switch event {
            case .textDelta(let t):
                text += t
            case .turnComplete(let summary):
                completed = true
                #expect(summary.iterations == 1)
                #expect(summary.toolCallCount == 0)
                #expect(summary.stopReason == .endTurn)
            default:
                break
            }
        }

        #expect(text == "Hello from Orbit!")
        #expect(completed)
    }

    @Test("Tool call executes and feeds back")
    func toolCallExecution() async throws {
        let echoTool = MockTool(
            name: "echo",
            requiredPermission: .readOnly,
            handler: { input, _ in
                let text = input["text"]?.stringValue ?? "empty"
                return .success("Echo: \(text)")
            }
        )

        let provider = MockProvider.withToolCall(
            toolName: "echo",
            toolInput: .object(["text": "test"]),
            finalText: "Done!"
        )

        let pool = ToolPool(tools: [echoTool])
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)
        let engine = QueryEngine(provider: provider, toolPool: pool, policy: policy)

        var messages = [ChatMessage.userText("Echo something")]
        let stream = engine.run(messages: &messages, systemPrompt: "Test")

        var toolCalls: [(String, ToolResult)] = []
        var text = ""

        for try await event in stream {
            switch event {
            case .textDelta(let t):
                text += t
            case .toolCallEnd(_, let name, let result):
                toolCalls.append((name, result))
            default:
                break
            }
        }

        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].0 == "echo")
        #expect(toolCalls[0].1.output == "Echo: test")
    }

    @Test("Unknown tool returns error result")
    func unknownToolError() async throws {
        let provider = MockProvider.withToolCall(
            toolName: "nonexistent_tool",
            toolInput: .object([:]),
            finalText: "Handled"
        )

        let pool = ToolPool(tools: [])
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)
        let engine = QueryEngine(provider: provider, toolPool: pool, policy: policy)

        var messages = [ChatMessage.userText("Try unknown tool")]
        let stream = engine.run(messages: &messages, systemPrompt: "Test")

        var toolResults: [ToolResult] = []

        for try await event in stream {
            if case .toolCallEnd(_, _, let result) = event {
                toolResults.append(result)
            }
        }

        #expect(toolResults.count == 1)
        #expect(toolResults[0].isError)
        #expect(toolResults[0].output.contains("Unknown tool"))
    }

    @Test("Permission denied blocks tool execution")
    func permissionDenied() async throws {
        let tool = MockTool(name: "bash", requiredPermission: .dangerFullAccess)

        let provider = MockProvider.withToolCall(
            toolName: "bash",
            toolInput: .object(["command": "rm -rf /"]),
            finalText: "Blocked"
        )

        let pool = ToolPool(tools: [tool])
        let policy = PermissionPolicy(activeMode: .readOnly) // Too restrictive for bash
        let engine = QueryEngine(provider: provider, toolPool: pool, policy: policy)

        var messages = [ChatMessage.userText("Run something")]
        let stream = engine.run(messages: &messages, systemPrompt: "Test")

        var denied = false

        for try await event in stream {
            if case .toolDenied = event {
                denied = true
            }
        }

        #expect(denied)
    }

    @Test("QueryEngineConfig defaults")
    func queryEngineConfigDefaults() {
        let config = QueryEngineConfig()
        #expect(config.maxTurns == 8)
        #expect(config.maxBudgetTokens == 50_000)
    }
}
