import Foundation

/// Tool definition sent to the LLM so it knows what tools are available.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: JSONValue

    public init(name: String, description: String? = nil, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Unified protocol for all LLM providers.
///
/// Each provider wraps a specific SDK (SwiftAnthropic, SwiftOpenAI, etc.)
/// and adapts it to Orbit's common types.
public protocol LLMProvider: Sendable {
    /// Provider name (e.g., "anthropic", "openai").
    var name: String { get }

    /// Active model identifier.
    var model: String { get }

    /// Stream a response from the LLM.
    ///
    /// The returned stream yields `StreamEvent` values as the model generates
    /// output. The stream completes with `.messageStop` or throws on error.
    func stream(
        messages: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamEvent, Error>

    /// Estimate cost for the given token usage.
    func estimateCost(usage: TokenUsage) -> CostEstimate
}

/// Errors from LLM providers.
public enum ProviderError: Error, LocalizedError {
    case authenticationFailed(String)
    case rateLimited(retryAfter: TimeInterval?)
    case modelNotFound(String)
    case serverError(statusCode: Int, message: String)
    case streamingError(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let detail):
            return "Authentication failed: \(detail)"
        case .rateLimited(let retry):
            if let retry {
                return "Rate limited. Retry after \(Int(retry))s."
            }
            return "Rate limited."
        case .modelNotFound(let model):
            return "Model not found: \(model)"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .streamingError(let detail):
            return "Streaming error: \(detail)"
        case .invalidResponse(let detail):
            return "Invalid response: \(detail)"
        }
    }
}
