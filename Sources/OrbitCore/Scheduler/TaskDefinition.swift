import Foundation
import TOMLKit

/// A scheduled task definition loaded from TOML.
public struct TaskDefinition: Codable, Sendable {
    public let name: String
    public let slug: String
    public let project: String
    public let cron: String
    public let provider: String?
    public let model: String?
    public let promptFile: String?
    public let promptText: String?
    public let mcpServers: [String]
    public let skills: [String]
    public let enabled: Bool

    public init(
        name: String,
        slug: String,
        project: String,
        cron: String,
        provider: String? = nil,
        model: String? = nil,
        promptFile: String? = nil,
        promptText: String? = nil,
        mcpServers: [String] = [],
        skills: [String] = [],
        enabled: Bool = true
    ) {
        self.name = name
        self.slug = slug
        self.project = project
        self.cron = cron
        self.provider = provider
        self.model = model
        self.promptFile = promptFile
        self.promptText = promptText
        self.mcpServers = mcpServers
        self.skills = skills
        self.enabled = enabled
    }
}

/// Execution log entry for a completed scheduled task run.
public struct TaskExecutionLog: Codable, Sendable {
    public let taskSlug: String
    public let project: String
    public let startedAt: Date
    public let finishedAt: Date
    public let duration: TimeInterval
    public let usage: TokenUsage
    public let output: String
    public let success: Bool
    public let errorMessage: String?

    public init(
        taskSlug: String,
        project: String,
        startedAt: Date,
        finishedAt: Date,
        duration: TimeInterval,
        usage: TokenUsage,
        output: String,
        success: Bool,
        errorMessage: String? = nil
    ) {
        self.taskSlug = taskSlug
        self.project = project
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.duration = duration
        self.usage = usage
        self.output = output
        self.success = success
        self.errorMessage = errorMessage
    }
}

/// Parser for task definition TOML files.
public enum TaskDefinitionParser {
    public static func parse(_ toml: String, path: String) throws -> TaskDefinition {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: toml)
        } catch {
            throw ConfigError.parseError(path, underlying: error)
        }

        let task = table["task"]?.table
        guard let name = task?["name"]?.string else {
            throw ConfigError.missingField("task.name")
        }
        guard let slug = task?["slug"]?.string else {
            throw ConfigError.missingField("task.slug")
        }
        guard let project = task?["project"]?.string else {
            throw ConfigError.missingField("task.project")
        }
        guard let cron = task?["cron"]?.string else {
            throw ConfigError.missingField("task.cron")
        }

        let enabled = task?["enabled"]?.bool ?? true
        let provider = task?["provider"]?.string
        let model = task?["model"]?.string

        let prompt = task?["prompt"]?.table
        let promptFile = prompt?["file"]?.string
        let promptText = prompt?["text"]?.string

        var mcpServers: [String] = []
        if let mcps = task?["mcps"]?.table,
           let include = mcps["include"]?.array {
            for i in 0..<include.count {
                if let s = include[i]?.string {
                    mcpServers.append(s)
                }
            }
        }

        var skills: [String] = []
        if let skillsArr = task?["skills"]?.array {
            for i in 0..<skillsArr.count {
                if let s = skillsArr[i]?.string {
                    skills.append(s)
                }
            }
        }

        return TaskDefinition(
            name: name,
            slug: slug,
            project: project,
            cron: cron,
            provider: provider,
            model: model,
            promptFile: promptFile,
            promptText: promptText,
            mcpServers: mcpServers,
            skills: skills,
            enabled: enabled
        )
    }

    /// Load all task definitions from ~/.orbit/schedules/.
    public static func loadAll(schedulesDir: URL? = nil) -> [TaskDefinition] {
        let dir = schedulesDir ?? ConfigLoader.orbitHome.appendingPathComponent("schedules")
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        let files: [String]
        do {
            files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasSuffix(".toml") }
                .sorted()
        } catch {
            return []
        }

        return files.compactMap { filename in
            let path = dir.appendingPathComponent(filename)
            guard let data = FileManager.default.contents(atPath: path.path),
                  let content = String(data: data, encoding: .utf8) else {
                return nil
            }
            return try? parse(content, path: path.path)
        }
    }
}
