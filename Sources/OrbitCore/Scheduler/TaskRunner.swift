import Foundation

/// Runs a scheduled task by wiring project config, prompt, and provider into a query.
public struct TaskRunner: Sendable {
    private let provider: any LLMProvider
    private let toolPool: ToolPool
    private let policy: PermissionPolicy

    public init(
        provider: any LLMProvider,
        toolPool: ToolPool = ToolPool(tools: builtinTools()),
        policy: PermissionPolicy = PermissionPolicy(activeMode: .workspaceWrite)
    ) {
        self.provider = provider
        self.toolPool = toolPool
        self.policy = policy
    }

    /// Execute a task and return the log entry.
    public func run(task: TaskDefinition) async throws -> TaskExecutionLog {
        let startedAt = Date()

        // Resolve prompt
        let prompt: String
        if let text = task.promptText {
            prompt = text
        } else if let file = task.promptFile {
            let path = (file as NSString).expandingTildeInPath
            prompt = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "Run task: \(task.name)"
        } else {
            prompt = "Run task: \(task.name)"
        }

        let systemPrompt = """
        You are Orbit running a scheduled task. Be concise and output-focused.
        Task: \(task.name)
        Project: \(task.project)
        """

        let engine = QueryEngine(
            provider: provider,
            toolPool: toolPool,
            policy: policy,
            config: QueryEngineConfig(maxTurns: 8)
        )

        var messages = [ChatMessage.userText(prompt)]
        let stream = engine.run(messages: &messages, systemPrompt: systemPrompt)

        var output = ""
        var totalUsage = TokenUsage.zero
        var success = true

        do {
            for try await event in stream {
                switch event {
                case .textDelta(let text):
                    output += text
                case .usageUpdate(let usage):
                    totalUsage += usage
                default:
                    break
                }
            }
        } catch {
            output = "Error: \(error.localizedDescription)"
            success = false
        }

        let finishedAt = Date()
        return TaskExecutionLog(
            taskSlug: task.slug,
            project: task.project,
            startedAt: startedAt,
            finishedAt: finishedAt,
            duration: finishedAt.timeIntervalSince(startedAt),
            usage: totalUsage,
            output: output,
            success: success,
            errorMessage: success ? nil : output
        )
    }

    /// Save an execution log to disk.
    public static func saveLog(_ log: TaskExecutionLog, logsDir: URL? = nil) throws {
        let dir = (logsDir ?? ConfigLoader.orbitHome.appendingPathComponent("logs/tasks"))
            .appendingPathComponent(log.taskSlug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        let filename = "\(formatter.string(from: log.startedAt)).json"
        let path = dir.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(log)
        try data.write(to: path)
    }
}
