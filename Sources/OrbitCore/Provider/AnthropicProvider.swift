import Foundation
@preconcurrency import SwiftAnthropic

/// LLM provider implementation for Anthropic Claude models.
///
/// Wraps the SwiftAnthropic SDK to conform to Orbit's `LLMProvider` protocol.
public struct AnthropicProvider: LLMProvider, @unchecked Sendable {
    public let name = "anthropic"
    public let model: String
    private let service: AnthropicService

    public init(apiKey: String, model: String = "claude-sonnet-4-6") {
        self.model = model
        self.service = AnthropicServiceFactory.service(
            apiKey: apiKey,
            betaHeaders: nil
        )
    }

    public func stream(
        messages: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let anthropicMessages = messages.compactMap { convertMessage($0) }
                    let anthropicTools = tools.map { convertTool($0) }

                    let parameters = MessageParameter(
                        model: .other(model),
                        messages: anthropicMessages,
                        maxTokens: 8192,
                        system: .text(systemPrompt),
                        tools: anthropicTools.isEmpty ? nil : anthropicTools
                    )

                    let stream = try await service.streamMessage(parameters)
                    var currentToolId: String?
                    var currentToolName: String?
                    var currentToolJSON: String = ""

                    for try await event in stream {
                        guard let streamEvent = event.streamEvent else { continue }

                        switch streamEvent {
                        case .messageStart:
                            if let msg = event.message {
                                continuation.yield(.messageStart(
                                    id: msg.id ?? "unknown",
                                    model: msg.model ?? model
                                ))
                                let usage = TokenUsage(
                                    inputTokens: UInt32(msg.usage.inputTokens ?? 0),
                                    outputTokens: UInt32(msg.usage.outputTokens),
                                    cacheCreationInputTokens: UInt32(msg.usage.cacheCreationInputTokens ?? 0),
                                    cacheReadInputTokens: UInt32(msg.usage.cacheReadInputTokens ?? 0)
                                )
                                continuation.yield(.usage(usage))
                            }

                        case .contentBlockStart:
                            if let block = event.contentBlock {
                                if block.type == "tool_use",
                                   let id = block.id,
                                   let name = block.name {
                                    currentToolId = id
                                    currentToolName = name
                                    currentToolJSON = ""
                                }
                            }

                        case .contentBlockDelta:
                            if let delta = event.delta {
                                switch delta.type {
                                case "text_delta":
                                    if let text = delta.text {
                                        continuation.yield(.textDelta(text))
                                    }
                                case "input_json_delta":
                                    if let json = delta.partialJson {
                                        currentToolJSON += json
                                    }
                                default:
                                    break
                                }
                            }

                        case .contentBlockStop:
                            if let toolId = currentToolId, let toolName = currentToolName {
                                let input = parseJSONValue(currentToolJSON)
                                continuation.yield(.toolUse(
                                    id: toolId,
                                    name: toolName,
                                    input: input
                                ))
                                currentToolId = nil
                                currentToolName = nil
                                currentToolJSON = ""
                            }

                        case .messageDelta:
                            if let usage = event.usage {
                                let tokenUsage = TokenUsage(
                                    inputTokens: 0,
                                    outputTokens: UInt32(usage.outputTokens)
                                )
                                continuation.yield(.usage(tokenUsage))
                            }

                            if let delta = event.delta {
                                let reason: StopReason = switch delta.stopReason {
                                case "end_turn": .endTurn
                                case "tool_use": .toolUse
                                case "max_tokens": .maxTokens
                                default: .unknown
                                }
                                continuation.yield(.messageStop(stopReason: reason))
                            }

                        case .messageStop:
                            break
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
        usage.estimateCost(pricing: ModelPricing.forModel(model))
    }

    // MARK: - Type Conversion

    private func convertMessage(_ message: ChatMessage) -> MessageParameter.Message? {
        switch message.role {
        case .user:
            let content = message.blocks.compactMap { block -> MessageParameter.Message.Content.ContentObject? in
                switch block {
                case .text(let text):
                    return .text(text)
                case .toolResult(let toolUseId, _, let output, let isError):
                    return .toolResult(toolUseId, output, isError ? true : nil, nil)
                default:
                    return nil
                }
            }
            guard !content.isEmpty else { return nil }
            return .init(role: .user, content: .list(content))

        case .assistant:
            let content = message.blocks.compactMap { block -> MessageParameter.Message.Content.ContentObject? in
                switch block {
                case .text(let text):
                    return .text(text)
                case .toolUse(let id, let name, let input):
                    let inputDict = jsonValueToDynamicContent(input)
                    return .toolUse(id, name, inputDict)
                default:
                    return nil
                }
            }
            guard !content.isEmpty else { return nil }
            return .init(role: .assistant, content: .list(content))

        case .system, .tool:
            return nil
        }
    }

    private func convertTool(_ tool: ToolDefinition) -> MessageParameter.Tool {
        let schema = jsonValueToJSONSchema(tool.inputSchema)
        return .function(
            name: tool.name,
            description: tool.description,
            inputSchema: schema
        )
    }

    private func jsonValueToJSONSchema(_ value: JSONValue) -> JSONSchema {
        guard case .object(let dict) = value else {
            return JSONSchema(type: .object)
        }

        let type = (dict["type"]?.stringValue).flatMap {
            JSONSchema.JSONType(rawValue: $0)
        } ?? .object

        var properties: [String: JSONSchema.Property]?
        if let propsDict = dict["properties"]?.objectValue {
            properties = [:]
            for (key, propValue) in propsDict {
                if let propDict = propValue.objectValue {
                    let propType = (propDict["type"]?.stringValue).flatMap {
                        JSONSchema.JSONType(rawValue: $0)
                    } ?? .string
                    let desc = propDict["description"]?.stringValue
                    properties?[key] = JSONSchema.Property(type: propType, description: desc)
                }
            }
        }

        let required = dict["required"]?.arrayValue?.compactMap { $0.stringValue }

        return JSONSchema(
            type: type,
            properties: properties,
            required: required
        )
    }

    private func jsonValueToDynamicContent(_ value: JSONValue) -> MessageResponse.Content.Input {
        guard case .object(let dict) = value else { return [:] }
        var result: MessageResponse.Content.Input = [:]
        for (key, val) in dict {
            result[key] = convertToDynamicContent(val)
        }
        return result
    }

    private func convertToDynamicContent(_ value: JSONValue) -> MessageResponse.Content.DynamicContent {
        switch value {
        case .string(let s): return .string(s)
        case .int(let i): return .integer(i)
        case .double(let d): return .double(d)
        case .bool(let b): return .bool(b)
        case .null: return .null
        case .array(let a): return .array(a.map { convertToDynamicContent($0) })
        case .object(let o):
            var dict: MessageResponse.Content.Input = [:]
            for (k, v) in o { dict[k] = convertToDynamicContent(v) }
            return .dictionary(dict)
        }
    }
}

// MARK: - JSON Parsing Helpers

private func parseJSONValue(_ json: String) -> JSONValue {
    guard !json.isEmpty,
          let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        return .object([:])
    }
    return decoded
}
