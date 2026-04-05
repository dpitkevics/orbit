import Foundation
@preconcurrency import SwiftOpenAI

/// LLM provider implementation for OpenAI models (GPT-4o, o3, etc.).
public struct OpenAIProvider: LLMProvider, @unchecked Sendable {
    public let name = "openai"
    public let model: String
    private let service: OpenAIService

    public init(apiKey: String, model: String = "gpt-4o") {
        self.model = model
        self.service = OpenAIServiceFactory.service(apiKey: apiKey)
    }

    public func stream(
        messages: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var openAIMessages: [ChatCompletionParameters.Message] = [
                        .init(role: .system, content: .text(systemPrompt)),
                    ]
                    openAIMessages.append(contentsOf: messages.compactMap { convertMessage($0) })

                    let openAITools: [ChatCompletionParameters.Tool]? = tools.isEmpty ? nil : tools.map { convertTool($0) }

                    let parameters = ChatCompletionParameters(
                        messages: openAIMessages,
                        model: .custom(model),
                        tools: openAITools,
                        streamOptions: .init(includeUsage: true)
                    )

                    let stream = try await service.startStreamedChat(parameters: parameters)

                    var currentToolCallID: String?
                    var currentToolName: String?
                    var currentToolArgs: String = ""
                    var messageID: String?

                    for try await chunk in stream {
                        if messageID == nil, let id = chunk.id {
                            messageID = id
                            continuation.yield(.messageStart(id: id, model: chunk.model ?? model))
                        }

                        if let usage = chunk.usage {
                            continuation.yield(.usage(TokenUsage(
                                inputTokens: UInt32(usage.promptTokens ?? 0),
                                outputTokens: UInt32(usage.completionTokens ?? 0)
                            )))
                        }

                        guard let choice = chunk.choices?.first else { continue }

                        if let content = choice.delta?.content {
                            continuation.yield(.textDelta(content))
                        }

                        if let toolCalls = choice.delta?.toolCalls {
                            for tc in toolCalls {
                                if let id = tc.id {
                                    if let prevID = currentToolCallID, let prevName = currentToolName {
                                        let input = parseJSONValueFromString(currentToolArgs)
                                        continuation.yield(.toolUse(id: prevID, name: prevName, input: input))
                                    }
                                    currentToolCallID = id
                                    currentToolName = tc.function.name
                                    currentToolArgs = tc.function.arguments
                                } else {
                                    currentToolArgs += tc.function.arguments
                                }
                            }
                        }

                        if let finishReasonValue = choice.finishReason,
                           case .string(let finishReason) = finishReasonValue {
                            if let toolID = currentToolCallID, let toolName = currentToolName {
                                let input = parseJSONValueFromString(currentToolArgs)
                                continuation.yield(.toolUse(id: toolID, name: toolName, input: input))
                                currentToolCallID = nil
                                currentToolName = nil
                                currentToolArgs = ""
                            }

                            let reason: StopReason = switch finishReason {
                            case "stop": .endTurn
                            case "tool_calls": .toolUse
                            case "length": .maxTokens
                            default: .unknown
                            }
                            continuation.yield(.messageStop(stopReason: reason))
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func estimateCost(usage: TokenUsage) -> CostEstimate {
        usage.estimateCost(pricing: openAIPricing())
    }

    // MARK: - Type Conversion

    private func convertMessage(_ message: ChatMessage) -> ChatCompletionParameters.Message? {
        switch message.role {
        case .user:
            let text = message.textContent
            guard !text.isEmpty else { return nil }
            return .init(role: .user, content: .text(text))

        case .tool:
            for block in message.blocks {
                if case .toolResult(let toolUseId, _, let output, _) = block {
                    return .init(role: .tool, content: .text(output), toolCallID: toolUseId)
                }
            }
            return nil

        case .assistant:
            let text = message.textContent
            let toolCalls: [ToolCall]? = {
                let uses = message.toolUses
                guard !uses.isEmpty else { return nil }
                return uses.map { use in
                    ToolCall(
                        id: use.id,
                        function: FunctionCall(
                            arguments: jsonValueToString(use.input),
                            name: use.name
                        )
                    )
                }
            }()
            return .init(role: .assistant, content: .text(text), toolCalls: toolCalls)

        case .system:
            return .init(role: .system, content: .text(message.textContent))
        }
    }

    private func convertTool(_ tool: ToolDefinition) -> ChatCompletionParameters.Tool {
        let schema = jsonValueToOpenAISchema(tool.inputSchema)
        return .init(function: .init(
            name: tool.name,
            strict: nil,
            description: tool.description,
            parameters: schema
        ))
    }

    private func jsonValueToOpenAISchema(_ value: JSONValue) -> JSONSchema? {
        guard case .object(let dict) = value else { return nil }

        let type: JSONSchemaType? = dict["type"]?.stringValue.flatMap { str in
            switch str {
            case "object": .object
            case "string": .string
            case "integer": .integer
            case "number": .number
            case "boolean": .boolean
            case "array": .array
            default: nil
            }
        }

        var properties: [String: JSONSchema]?
        if let propsDict = dict["properties"]?.objectValue {
            properties = [:]
            for (key, propValue) in propsDict {
                if let propSchema = jsonValueToOpenAISchema(propValue) {
                    properties?[key] = propSchema
                }
            }
        }

        let required = dict["required"]?.arrayValue?.compactMap { $0.stringValue }
        let description = dict["description"]?.stringValue

        return JSONSchema(
            type: type,
            description: description,
            properties: properties,
            required: required
        )
    }

    private func jsonValueToString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private func openAIPricing() -> ModelPricing {
        let lower = model.lowercased()
        if lower.contains("gpt-4o-mini") {
            return ModelPricing(inputCostPerMillion: 0.15, outputCostPerMillion: 0.60, cacheCreationCostPerMillion: 0, cacheReadCostPerMillion: 0)
        }
        if lower.contains("gpt-4o") {
            return ModelPricing(inputCostPerMillion: 2.5, outputCostPerMillion: 10.0, cacheCreationCostPerMillion: 0, cacheReadCostPerMillion: 0)
        }
        if lower.contains("o3") || lower.contains("o4") {
            return ModelPricing(inputCostPerMillion: 10.0, outputCostPerMillion: 40.0, cacheCreationCostPerMillion: 0, cacheReadCostPerMillion: 0)
        }
        return ModelPricing(inputCostPerMillion: 2.5, outputCostPerMillion: 10.0, cacheCreationCostPerMillion: 0, cacheReadCostPerMillion: 0)
    }
}

private func parseJSONValueFromString(_ json: String) -> JSONValue {
    guard !json.isEmpty,
          let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        return .object([:])
    }
    return decoded
}
