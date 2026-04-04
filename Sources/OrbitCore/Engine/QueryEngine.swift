import Foundation

/// Configuration for the query engine.
public struct QueryEngineConfig: Sendable {
    /// Maximum LLM round-trips per query.
    public var maxTurns: Int
    /// Token budget cap per session.
    public var maxBudgetTokens: Int

    public init(maxTurns: Int = 8, maxBudgetTokens: Int = 50_000) {
        self.maxTurns = maxTurns
        self.maxBudgetTokens = maxBudgetTokens
    }
}

/// Events emitted by the query engine during a turn.
public enum TurnEvent: Sendable {
    /// Streaming text from the assistant.
    case textDelta(String)
    /// Assistant is requesting a tool call.
    case toolCallStart(id: String, name: String)
    /// Tool call completed.
    case toolCallEnd(id: String, name: String, result: ToolResult)
    /// A tool was denied by permissions.
    case toolDenied(name: String, reason: String)
    /// Token usage update.
    case usageUpdate(TokenUsage)
    /// The turn is complete.
    case turnComplete(TurnSummary)
}

/// Summary of a completed turn.
public struct TurnSummary: Sendable {
    public let iterations: Int
    public let usage: TokenUsage
    public let toolCallCount: Int
    public let stopReason: StopReason
}

/// Central orchestration engine managing the conversation loop.
///
/// For each user query:
/// 1. Send messages + tools to LLM via streaming
/// 2. If response contains tool calls → execute tools (checking permissions) → feed results back
/// 3. Repeat until text-only response or max turns
public struct QueryEngine: Sendable {
    private let provider: any LLMProvider
    private let toolPool: ToolPool
    private let policy: PermissionPolicy
    private let config: QueryEngineConfig
    private let prompter: (any PermissionPrompter)?

    public init(
        provider: any LLMProvider,
        toolPool: ToolPool,
        policy: PermissionPolicy,
        config: QueryEngineConfig = QueryEngineConfig(),
        prompter: (any PermissionPrompter)? = nil
    ) {
        self.provider = provider
        self.toolPool = toolPool
        self.policy = policy
        self.config = config
        self.prompter = prompter
    }

    /// Execute a conversation turn, yielding events as they occur.
    public func run(
        messages: inout [ChatMessage],
        systemPrompt: String
    ) -> AsyncThrowingStream<TurnEvent, Error> {
        // Capture mutable state
        let capturedMessages = messages
        let provider = self.provider
        let toolPool = self.toolPool
        let policy = self.policy
        let config = self.config
        let prompter = self.prompter

        return AsyncThrowingStream { continuation in
            let task = Task {
                var currentMessages = capturedMessages
                var totalUsage = TokenUsage.zero
                var iterations = 0
                var totalToolCalls = 0
                var lastStopReason = StopReason.endTurn

                let toolDefs = toolPool.definitions(mode: .full, policy: policy)
                let context = ToolContext(
                    workspaceRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                    project: "default",
                    enforcer: PermissionEnforcer(policy: policy)
                )

                while iterations < config.maxTurns {
                    iterations += 1

                    // Collect the full response from one LLM call
                    var pendingToolCalls: [(id: String, name: String, input: JSONValue)] = []
                    var assistantBlocks: [ContentBlock] = []
                    var turnUsage = TokenUsage.zero

                    let stream = provider.stream(
                        messages: currentMessages,
                        systemPrompt: systemPrompt,
                        tools: toolDefs
                    )

                    for try await event in stream {
                        switch event {
                        case .textDelta(let text):
                            continuation.yield(.textDelta(text))
                            assistantBlocks.append(.text(text))

                        case .toolUse(let id, let name, let input):
                            pendingToolCalls.append((id, name, input))
                            assistantBlocks.append(.toolUse(id: id, name: name, input: input))
                            continuation.yield(.toolCallStart(id: id, name: name))

                        case .usage(let usage):
                            turnUsage += usage
                            continuation.yield(.usageUpdate(usage))

                        case .messageStop(let reason):
                            lastStopReason = reason

                        case .messageStart, .contentBlockStop:
                            break
                        }
                    }

                    totalUsage += turnUsage

                    // Add assistant message to conversation
                    let assistantMsg = ChatMessage(
                        role: .assistant,
                        blocks: consolidateTextBlocks(assistantBlocks),
                        usage: turnUsage
                    )
                    currentMessages.append(assistantMsg)

                    // If no tool calls, we're done
                    if pendingToolCalls.isEmpty {
                        break
                    }

                    // Execute tool calls
                    for (toolId, toolName, toolInput) in pendingToolCalls {
                        totalToolCalls += 1

                        // Check permissions
                        guard let tool = toolPool.tool(named: toolName) else {
                            let result = ToolResult.error("Unknown tool: \(toolName)")
                            continuation.yield(.toolCallEnd(id: toolId, name: toolName, result: result))
                            let msg = ChatMessage.toolResult(
                                toolUseId: toolId,
                                toolName: toolName,
                                output: result.output,
                                isError: true
                            )
                            currentMessages.append(msg)
                            continue
                        }

                        let permResult = policy.authorize(
                            toolName: toolName,
                            requiredMode: tool.requiredPermission
                        )

                        if !permResult.isAllowed {
                            let reason: String
                            if case .deny(let r) = permResult { reason = r } else { reason = "Denied" }

                            // Ask prompter if available
                            var allowed = false
                            if let prompter {
                                allowed = await prompter.prompt(
                                    toolName: toolName,
                                    input: "\(toolInput)",
                                    reason: reason
                                )
                            }

                            if !allowed {
                                continuation.yield(.toolDenied(name: toolName, reason: reason))
                                let msg = ChatMessage.toolResult(
                                    toolUseId: toolId,
                                    toolName: toolName,
                                    output: "Permission denied: \(reason)",
                                    isError: true
                                )
                                currentMessages.append(msg)
                                continue
                            }
                        }

                        // Execute tool
                        let result: ToolResult
                        do {
                            result = try await tool.execute(input: toolInput, context: context)
                        } catch {
                            result = .error("Tool execution failed: \(error.localizedDescription)")
                        }

                        continuation.yield(.toolCallEnd(id: toolId, name: toolName, result: result))

                        let msg = ChatMessage.toolResult(
                            toolUseId: toolId,
                            toolName: toolName,
                            output: result.output,
                            isError: result.isError
                        )
                        currentMessages.append(msg)
                    }

                    // Check budget
                    if totalUsage.totalTokens > UInt32(config.maxBudgetTokens) {
                        lastStopReason = .maxTokens
                        break
                    }
                }

                let summary = TurnSummary(
                    iterations: iterations,
                    usage: totalUsage,
                    toolCallCount: totalToolCalls,
                    stopReason: lastStopReason
                )
                continuation.yield(.turnComplete(summary))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// Merge adjacent text blocks into single blocks to keep messages clean.
private func consolidateTextBlocks(_ blocks: [ContentBlock]) -> [ContentBlock] {
    var result: [ContentBlock] = []
    var pendingText = ""

    for block in blocks {
        switch block {
        case .text(let text):
            pendingText += text
        default:
            if !pendingText.isEmpty {
                result.append(.text(pendingText))
                pendingText = ""
            }
            result.append(block)
        }
    }

    if !pendingText.isEmpty {
        result.append(.text(pendingText))
    }

    return result
}
