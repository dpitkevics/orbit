import Foundation

/// LLM provider that shells out to an installed CLI tool (e.g., `claude`, `codex`).
///
/// Uses the user's existing subscription — no separate API key needed.
/// For Anthropic: wraps `claude --print --output-format stream-json --verbose`.
public struct BridgeProvider: LLMProvider, Sendable {
    public let name: String
    public let model: String
    private let cliPath: String

    public init(name: String = "anthropic", cliPath: String, model: String = "claude-sonnet-4-6") {
        self.name = name
        self.cliPath = cliPath
        self.model = model
    }

    /// Auto-detect the claude CLI path.
    public static func detectClaudeCLI() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.local/bin/claude" },
            Optional("/usr/local/bin/claude"),
            Optional("/opt/homebrew/bin/claude"),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // Try `which`
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public func stream(
        messages: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Build full prompt with conversation history
                    let prompt = Self.buildPromptWithHistory(messages)

                    // Write system prompt to temp file (avoids CLI arg length limits)
                    let tempDir = FileManager.default.temporaryDirectory
                    let promptFile = tempDir.appendingPathComponent("orbit_system_prompt_\(ProcessInfo.processInfo.processIdentifier).txt")
                    try systemPrompt.write(to: promptFile, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(at: promptFile) }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: cliPath)

                    var args = [
                        "--print",
                        "--output-format", "stream-json",
                        "--verbose",
                        "--model", model,
                        "--system-prompt-file", promptFile.path,
                        "--no-session-persistence",
                    ]

                    // Add workspace directory for file access
                    let cwd = FileManager.default.currentDirectoryPath
                    args.append(contentsOf: ["--add-dir", cwd])

                    args.append(prompt)
                    process.arguments = args

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()

                    let handle = stdoutPipe.fileHandleForReading
                    var buffer = Data()
                    var hadAssistantMessage = false

                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }

                        buffer.append(chunk)

                        // Process complete lines
                        while let newlineRange = buffer.range(of: Data("\n".utf8)) {
                            let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
                            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                            guard !lineData.isEmpty else { continue }
                            let wasAssistant = processStreamLine(
                                lineData,
                                hadAssistantMessage: hadAssistantMessage,
                                continuation: continuation
                            )
                            if wasAssistant { hadAssistantMessage = true }
                        }
                    }

                    // Process any remaining data
                    if !buffer.isEmpty {
                        _ = processStreamLine(
                            buffer,
                            hadAssistantMessage: hadAssistantMessage,
                            continuation: continuation
                        )
                    }

                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderrStr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                        continuation.finish(throwing: ProviderError.streamingError(
                            "claude CLI exited with code \(process.terminationStatus): \(stderrStr)"
                        ))
                    } else {
                        continuation.finish()
                    }
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
        // Bridge uses subscription, but we still track for awareness
        usage.estimateCost(pricing: ModelPricing.forModel(model))
    }

    // MARK: - Conversation History

    /// Build a prompt that includes conversation history context for the CLI.
    /// The claude CLI doesn't support multi-turn, so we embed history in the prompt.
    private static func buildPromptWithHistory(_ messages: [ChatMessage]) -> String {
        guard messages.count > 1 else {
            return messages.last?.textContent ?? ""
        }

        var parts: [String] = []

        // Include conversation history as context
        let historyMessages = messages.dropLast()
        if !historyMessages.isEmpty {
            parts.append("Previous conversation context:")
            for msg in historyMessages {
                let role = msg.role.rawValue.capitalized
                let text = msg.textContent
                if !text.isEmpty {
                    parts.append("[\(role)] \(text)")
                }
            }
            parts.append("\nCurrent request:")
        }

        // Current message
        parts.append(messages.last?.textContent ?? "")

        return parts.joined(separator: "\n")
    }

    // MARK: - Stream Processing

    /// Process one line of stream-json output.
    /// Returns `true` if this was an assistant message (to track dedup).
    @discardableResult
    private func processStreamLine(
        _ data: Data,
        hadAssistantMessage: Bool,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) -> Bool {
        guard let json = try? JSONDecoder().decode(BridgeStreamEvent.self, from: data) else {
            return false
        }

        switch json.type {
        case "assistant":
            if let msg = json.message {
                continuation.yield(.messageStart(
                    id: msg.id ?? "bridge",
                    model: msg.model ?? model
                ))

                // Extract text content
                if let content = msg.content {
                    for block in content {
                        if block.type == "text", let text = block.text {
                            continuation.yield(.textDelta(text))
                        }
                    }
                }

                // Extract usage from assistant message
                if let usage = msg.usage {
                    continuation.yield(.usage(TokenUsage(
                        inputTokens: UInt32(usage.inputTokens ?? 0),
                        outputTokens: UInt32(usage.outputTokens ?? 0),
                        cacheCreationInputTokens: UInt32(usage.cacheCreationInputTokens ?? 0),
                        cacheReadInputTokens: UInt32(usage.cacheReadInputTokens ?? 0)
                    )))
                }
            }
            return true

        case "result":
            // Only yield usage from result (not from assistant, to avoid double-counting)
            if !hadAssistantMessage, let usage = json.usage {
                continuation.yield(.usage(TokenUsage(
                    inputTokens: UInt32(usage.inputTokens ?? 0),
                    outputTokens: UInt32(usage.outputTokens ?? 0),
                    cacheCreationInputTokens: UInt32(usage.cacheCreationInputTokens ?? 0),
                    cacheReadInputTokens: UInt32(usage.cacheReadInputTokens ?? 0)
                )))
            }

            // Only yield result text if we didn't already get it from the assistant message
            if !hadAssistantMessage, let resultText = json.result {
                continuation.yield(.textDelta(resultText))
            }

            let reason: StopReason = switch json.stopReason {
            case "end_turn": .endTurn
            case "tool_use": .toolUse
            case "max_tokens": .maxTokens
            default: .endTurn
            }
            continuation.yield(.messageStop(stopReason: reason))
            return false

        default:
            return false
        }
    }
}

// MARK: - Bridge JSON Types

private struct BridgeStreamEvent: Decodable {
    let type: String
    let subtype: String?
    let message: BridgeMessage?
    let result: String?
    let stopReason: String?
    let usage: BridgeUsage?
    let totalCostUsd: Double?

    enum CodingKeys: String, CodingKey {
        case type, subtype, message, result
        case stopReason = "stop_reason"
        case usage
        case totalCostUsd = "total_cost_usd"
    }
}

private struct BridgeMessage: Decodable {
    let id: String?
    let model: String?
    let role: String?
    let content: [BridgeContentBlock]?
    let stopReason: String?
    let usage: BridgeUsage?

    enum CodingKeys: String, CodingKey {
        case id, model, role, content
        case stopReason = "stop_reason"
        case usage
    }
}

private struct BridgeContentBlock: Decodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
}

private struct BridgeUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}
