import Foundation

/// Spawn a sub-agent to handle a specific task.
public struct AgentTool: Tool, Sendable {
    public let name = "agent"
    public let description = "Launch a sub-agent to handle a complex sub-task. The agent gets its own conversation with the LLM and can use tools."
    public let category: ToolCategory = .agent
    public let requiredPermission: PermissionMode = .dangerFullAccess

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "task": .object([
                "type": "string",
                "description": "Description of what the sub-agent should do.",
            ]),
            "prompt": .object([
                "type": "string",
                "description": "The detailed prompt for the sub-agent.",
            ]),
        ]),
        "required": .array(["task", "prompt"]),
        "additionalProperties": false,
    ])

    private let provider: any LLMProvider
    private let toolPool: ToolPool
    private let policy: PermissionPolicy

    public init(provider: any LLMProvider, toolPool: ToolPool, policy: PermissionPolicy) {
        self.provider = provider
        self.toolPool = toolPool
        self.policy = policy
    }

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let task = input["task"]?.stringValue else {
            return .error("Missing required parameter: 'task'")
        }
        guard let prompt = input["prompt"]?.stringValue else {
            return .error("Missing required parameter: 'prompt'")
        }

        let systemPrompt = """
        You are a sub-agent of Orbit handling a specific task. Be focused and concise.
        Task: \(task)
        """

        let engine = QueryEngine(
            provider: provider,
            toolPool: toolPool,
            policy: policy,
            config: QueryEngineConfig(maxTurns: 5)
        )

        var messages = [ChatMessage.userText(prompt)]
        let stream = engine.run(messages: &messages, systemPrompt: systemPrompt)

        var output = ""
        for try await event in stream {
            if case .textDelta(let text) = event {
                output += text
            }
        }

        if output.isEmpty {
            return .error("Sub-agent produced no output.")
        }

        return .success(output)
    }
}
