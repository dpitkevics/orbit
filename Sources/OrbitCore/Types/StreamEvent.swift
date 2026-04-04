import Foundation

/// Events emitted during LLM streaming, consumed by the query engine and CLI renderer.
public enum StreamEvent: Sendable {
    /// Stream has started, provides message ID and model.
    case messageStart(id: String, model: String)

    /// Incremental text output from the assistant.
    case textDelta(String)

    /// Assistant is requesting a tool call.
    case toolUse(id: String, name: String, input: JSONValue)

    /// Token usage update from the provider.
    case usage(TokenUsage)

    /// A content block has finished streaming.
    case contentBlockStop(index: Int)

    /// The full message is complete.
    case messageStop(stopReason: StopReason)
}

/// Why the LLM stopped generating.
public enum StopReason: String, Codable, Sendable {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
    case unknown
}
