import Foundation

/// Status of a deep analysis task.
public enum DeepTaskStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case reviewPending
}

/// A long-running, asynchronous analysis task.
///
/// Deep tasks can span multiple projects and use a configurable
/// (typically more powerful) model for thorough analysis.
public struct DeepTask: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let prompt: String
    public let projects: [String]
    public let provider: String?
    public let model: String?
    public let maxDuration: TimeInterval
    public var status: DeepTaskStatus
    public var result: String?
    public var startedAt: Date?
    public var completedAt: Date?
    public var usage: TokenUsage?

    public init(
        name: String,
        prompt: String,
        projects: [String],
        provider: String? = nil,
        model: String? = nil,
        maxDuration: TimeInterval = 1800
    ) {
        self.id = UUID()
        self.name = name
        self.prompt = prompt
        self.projects = projects
        self.provider = provider
        self.model = model
        self.maxDuration = maxDuration
        self.status = .pending
        self.result = nil
        self.startedAt = nil
        self.completedAt = nil
        self.usage = nil
    }
}

/// Runs deep analysis tasks in the background.
public struct DeepTaskRunner: Sendable {
    private let provider: any LLMProvider

    public init(provider: any LLMProvider) {
        self.provider = provider
    }

    /// Execute a deep task synchronously (caller manages background dispatch).
    public func run(_ task: DeepTask) async throws -> DeepTask {
        var result = task
        result.status = .running
        result.startedAt = Date()

        let systemPrompt = """
        You are Orbit performing a deep analysis task. Be thorough, analytical, \
        and provide actionable insights. This is a long-running background task, \
        so take time to be comprehensive.

        Task: \(task.name)
        Projects: \(task.projects.joined(separator: ", "))
        """

        let messages = [ChatMessage.userText(task.prompt)]
        let stream = provider.stream(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: []
        )

        var output = ""
        var totalUsage = TokenUsage.zero

        do {
            for try await event in stream {
                switch event {
                case .textDelta(let text):
                    output += text
                case .usage(let usage):
                    totalUsage += usage
                default:
                    break
                }
            }

            result.result = output
            result.usage = totalUsage
            result.status = .completed
        } catch {
            result.result = "Error: \(error.localizedDescription)"
            result.status = .failed
        }

        result.completedAt = Date()
        return result
    }

    /// Save a deep task result to disk.
    public static func save(_ task: DeepTask, baseDir: URL? = nil) throws {
        let dir = (baseDir ?? ConfigLoader.orbitHome.appendingPathComponent("deep-tasks"))
            .appendingPathComponent(task.id.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Save result as markdown
        if let result = task.result {
            let resultPath = dir.appendingPathComponent("result.md")
            try result.write(to: resultPath, atomically: true, encoding: .utf8)
        }

        // Save metadata as JSON
        let metaPath = dir.appendingPathComponent("task.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(task)
        try data.write(to: metaPath)
    }
}
