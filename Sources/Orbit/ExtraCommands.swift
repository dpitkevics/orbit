import ArgumentParser
import Foundation
import OrbitCore

// MARK: - orbit code

struct Code: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Coding awareness and delegation.",
        subcommands: [CodeActivity.self, CodeDelegate_.self]
    )
}

struct CodeActivity: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activity",
        abstract: "Show recent git activity for a project."
    )

    @Argument(help: "Project slug.")
    var project: String

    @Option(name: .long, help: "Number of days (default: 7).")
    var days: Int = 7

    func run() {
        let config = try? ConfigLoader.loadProject(slug: project)
        guard let repoPath = config?.repoPath else {
            print("No repository configured for project '\(project)'.")
            return
        }

        let repoURL = URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath)
        let commits = CodingAwareness.recentCommits(repo: repoURL, days: days)

        if commits.isEmpty {
            print("No commits in the last \(days) days.")
            return
        }

        print("Recent activity for \(project) (last \(days) days):\n")
        for commit in commits {
            print("  \(commit.hash.prefix(7)) \(commit.date) \(commit.author): \(commit.message)")
        }

        let structure = CodingAwareness.repoStructure(repo: repoURL)
        if structure.totalFiles > 0 {
            print("\nRepo: \(structure.totalFiles) files")
            let topLangs = structure.languages.sorted { $0.value > $1.value }.prefix(5)
            if !topLangs.isEmpty {
                print("Languages: \(topLangs.map { "\($0.key)(\($0.value))" }.joined(separator: ", "))")
            }
        }
    }
}

struct CodeDelegate_: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delegate",
        abstract: "Delegate a coding task to an external agent."
    )

    @Argument(help: "Project slug.")
    var project: String

    @Argument(help: "Task description.")
    var task: String

    @Option(name: .long, help: "Coding agent: 'claude-code' or 'codex-cli'.")
    var agent: String = "claude-code"

    @Option(name: .long, help: "Create and work on a branch.")
    var branch: String?

    func run() async throws {
        let config = try ConfigLoader.loadProject(slug: project)
        guard let repoPath = config.repoPath else {
            print("No repository configured for project '\(project)'.")
            return
        }

        guard let codingAgent = CodingAgent(rawValue: agent) else {
            print("Unknown agent '\(agent)'. Available: \(CodingAgent.allCases.map(\.rawValue).joined(separator: ", "))")
            return
        }

        let repoURL = URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath)

        print("Delegating to \(agent)...")
        if let branch {
            print("Branch: \(branch)")
        }

        let result = try await CodingDelegate.delegate(
            task: task,
            repo: repoURL,
            agent: codingAgent,
            branch: branch
        )

        print(result.output.prefix(2000))
        print("\n--- Delegation Complete ---")
        print("Agent:    \(result.agent.rawValue)")
        print("Success:  \(result.success)")
        print("Duration: \(String(format: "%.1f", result.duration))s")
    }
}

// MARK: - orbit skills

struct Skills: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage skills.",
        subcommands: [SkillsList.self, SkillsAdd.self]
    )
}

struct SkillsList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available skills."
    )

    @Argument(help: "Project slug (optional, shows global + project skills).")
    var project: String?

    func run() {
        let loader = SkillLoader()
        let skills = loader.loadSkills(project: project ?? "default")

        if skills.isEmpty {
            print("No skills found.")
            print("Add skill markdown files to ~/.orbit/skills/")
            return
        }

        print("Skills (\(skills.count)):\n")
        for skill in skills {
            print("  \(skill.name) — \(skill.description)")
            if !skill.triggerPatterns.isEmpty {
                print("    Triggers: \(skill.triggerPatterns.joined(separator: ", "))")
            }
        }
    }
}

struct SkillsAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a skill file to a project."
    )

    @Argument(help: "Project slug.")
    var project: String

    @Argument(help: "Path to the skill markdown file.")
    var file: String

    func run() {
        let sourcePath = (file as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            print("File not found: \(file)")
            return
        }

        let filename = (sourcePath as NSString).lastPathComponent
        let destDir = ConfigLoader.orbitHome.appendingPathComponent("skills/\(project)")
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destPath = destDir.appendingPathComponent(filename)

        do {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: destPath.path)
            print("Added skill '\(filename)' to project '\(project)'.")
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - orbit cost

struct Cost: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show cost summary."
    )

    func run() {
        // Cost tracking across sessions would require reading session files
        // For now, show how to use --show-cost flag
        print("Cost tracking:")
        print("  Use --show-cost flag with `orbit ask` for per-query costs.")
        print("  Use /cost in the REPL for session costs.")
        print("  Session costs are tracked in memory during each session.")
    }
}

// MARK: - orbit trace

struct Trace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show agent trace for a session."
    )

    @Argument(help: "Session ID (prefix is enough).")
    var sessionId: String?

    func run() {
        print("Agent trace visualization is available in the REPL via /trace.")
        print("Session traces are recorded in the AgentTree during execution.")
        if let id = sessionId {
            print("Looking for session: \(id)...")

            let store = FileSessionStore()
            let projects = ConfigLoader.listProjects()
            for project in projects {
                if let list = try? store.list(project: project, limit: 50) {
                    for session in list where session.sessionID.hasPrefix(id) {
                        print("  Found: \(session.sessionID) in project '\(project)' (\(session.messageCount) messages)")
                    }
                }
            }
        }
    }
}

// MARK: - orbit logs

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "View task execution logs."
    )

    @Argument(help: "Task slug.")
    var slug: String

    @Option(name: .long, help: "Number of recent logs (default: 5).")
    var last: Int = 5

    func run() {
        let logsDir = ConfigLoader.orbitHome
            .appendingPathComponent("logs/tasks")
            .appendingPathComponent(slug)

        guard FileManager.default.fileExists(atPath: logsDir.path) else {
            print("No logs found for task '\(slug)'.")
            return
        }

        let files: [String]
        do {
            files = try FileManager.default.contentsOfDirectory(atPath: logsDir.path)
                .filter { $0.hasSuffix(".json") }
                .sorted(by: >)
        } catch {
            print("Error reading logs: \(error.localizedDescription)")
            return
        }

        if files.isEmpty {
            print("No execution logs for '\(slug)'.")
            return
        }

        print("Recent logs for '\(slug)' (last \(last)):\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files.prefix(last) {
            let path = logsDir.appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path.path),
                  let log = try? decoder.decode(TaskExecutionLog.self, from: data) else {
                print("  \(file) (unreadable)")
                continue
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            let status = log.success ? "OK" : "FAIL"
            print("  [\(formatter.string(from: log.startedAt))] \(status) — \(String(format: "%.1f", log.duration))s, \(log.usage.totalTokens) tokens")
            if !log.success, let err = log.errorMessage {
                print("    Error: \(err.prefix(80))")
            }
        }
    }
}
