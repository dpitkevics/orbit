import Foundation

// MARK: - Message Role

public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

// MARK: - Content Block

/// Source for an image attachment.
public enum ImageSource: Sendable, Equatable, Codable {
    case base64(mediaType: String, data: String)
    case url(String)
}

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, toolName: String, output: String, isError: Bool)
    case thinking(content: String, signature: String?)
    case image(source: ImageSource)
    case document(name: String, mediaType: String, content: String)
}

// MARK: - Chat Message

public struct ChatMessage: Sendable {
    public let role: MessageRole
    public var blocks: [ContentBlock]
    public var usage: TokenUsage?

    public init(role: MessageRole, blocks: [ContentBlock], usage: TokenUsage? = nil) {
        self.role = role
        self.blocks = blocks
        self.usage = usage
    }

    // MARK: - Convenience Constructors

    public static func userText(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, blocks: [.text(text)])
    }

    public static func assistantText(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, blocks: [.text(text)])
    }

    public static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, blocks: [.text(text)])
    }

    public static func toolResult(
        toolUseId: String,
        toolName: String,
        output: String,
        isError: Bool = false
    ) -> ChatMessage {
        ChatMessage(
            role: .tool,
            blocks: [.toolResult(
                toolUseId: toolUseId,
                toolName: toolName,
                output: output,
                isError: isError
            )]
        )
    }

    // MARK: - Accessors

    /// Returns concatenated text content from all text blocks.
    public var textContent: String {
        blocks.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined()
    }

    /// Returns all tool use blocks.
    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        blocks.compactMap { block in
            if case .toolUse(let id, let name, let input) = block {
                return (id, name, input)
            }
            return nil
        }
    }

    /// Rough token estimate (~4 chars per token, from Claw Code heuristic).
    public var estimatedTokens: Int {
        let charCount = blocks.reduce(0) { sum, block in
            switch block {
            case .text(let t): return sum + t.count
            case .toolUse(_, let name, _): return sum + name.count + 100
            case .toolResult(_, _, let output, _): return sum + output.count
            case .thinking(let content, _): return sum + content.count
            case .image: return sum + 1000 // Images are ~1K tokens estimate
            case .document(_, _, let content): return sum + content.count
            }
        }
        return max(1, charCount / 4)
    }
}

// MARK: - Codable

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, toolUseId = "tool_use_id"
        case toolName = "tool_name", output, isError = "is_error"
        case content, signature, source, mediaType = "media_type", data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode(JSONValue.self, forKey: .input)
            self = .toolUse(id: id, name: name, input: input)
        case "tool_result":
            let toolUseId = try container.decode(String.self, forKey: .toolUseId)
            let toolName = try container.decodeIfPresent(String.self, forKey: .toolName) ?? ""
            let output = try container.decode(String.self, forKey: .output)
            let isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            self = .toolResult(toolUseId: toolUseId, toolName: toolName, output: output, isError: isError)
        case "thinking":
            let content = try container.decode(String.self, forKey: .content)
            let signature = try container.decodeIfPresent(String.self, forKey: .signature)
            self = .thinking(content: content, signature: signature)
        case "image":
            let source = try container.decode(ImageSource.self, forKey: .source)
            self = .image(source: source)
        case "document":
            let name = try container.decode(String.self, forKey: .name)
            let mediaType = try container.decode(String.self, forKey: .mediaType)
            let content = try container.decode(String.self, forKey: .content)
            self = .document(name: name, mediaType: mediaType, content: content)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content block type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let toolName, let output, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(output, forKey: .output)
            try container.encode(isError, forKey: .isError)
        case .thinking(let content, let signature):
            try container.encode("thinking", forKey: .type)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(signature, forKey: .signature)
        case .image(let source):
            try container.encode("image", forKey: .type)
            try container.encode(source, forKey: .source)
        case .document(let name, let mediaType, let content):
            try container.encode("document", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(mediaType, forKey: .mediaType)
            try container.encode(content, forKey: .content)
        }
    }
}

extension ChatMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case role, blocks, usage
    }
}
