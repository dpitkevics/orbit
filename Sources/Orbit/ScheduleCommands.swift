import ArgumentParser
import Foundation
import OrbitCore

// MARK: - orbit run <slug>

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manually run a scheduled task."
    )

    @Argument(help: "Task slug to run.")
    var slug: String

    @Option(name: .long, help: "Auth mode: 'apiKey' or 'bridge'.")
    var authMode: String?

    func run() async throws {
        let globalConfig = try ConfigLoader.loadGlobal()
        let allTasks = TaskDefinitionParser.loadAll()

        guard let taskDef = allTasks.first(where: { $0.slug == slug }) else {
            print("Task '\(slug)' not found.")
            print("Available tasks: \(allTasks.map(\.slug).joined(separator: ", "))")
            return
        }

        print("Running task: \(taskDef.name)...")

        let effectiveModel = taskDef.model ?? globalConfig.defaultModel
        let effectiveProvider = taskDef.provider ?? globalConfig.defaultProvider

        let provider = try resolveProviderForChat(
            providerName: effectiveProvider,
            model: effectiveModel,
            authModeOverride: authMode,
            globalConfig: globalConfig
        )

        let runner = TaskRunner(provider: provider)
        let log = try await runner.run(task: taskDef)

        print(log.output)
        print()
        print("--- Task Complete ---")
        print("Duration: \(String(format: "%.1f", log.duration))s")
        print("Tokens:   \(log.usage.totalTokens)")
        print("Success:  \(log.success)")

        try TaskRunner.saveLog(log)
    }
}

// MARK: - orbit schedule

struct Schedule: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage scheduled tasks.",
        subcommands: [ScheduleList.self]
    )
}

struct ScheduleList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all scheduled tasks."
    )

    func run() {
        let tasks = TaskDefinitionParser.loadAll()

        if tasks.isEmpty {
            print("No scheduled tasks found.")
            print("Add task TOML files to ~/.orbit/schedules/")
            return
        }

        print("Scheduled tasks:\n")
        for task in tasks {
            let status = task.enabled ? "enabled" : "disabled"
            print("  \(task.slug) — \(task.name)")
            print("    Project: \(task.project) | Cron: \(task.cron) | \(status)")
        }
    }
}

// MARK: - orbit daemon

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the Orbit background daemon.",
        subcommands: [DaemonStatus.self]
    )
}

struct DaemonStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show daemon status."
    )

    func run() {
        // For now, daemon is in-process only (launchd integration in Phase 9)
        print("Daemon: not running (in-process mode only)")
        print("Use orbit chat for interactive sessions.")
        print("Use orbit run <slug> to manually trigger tasks.")
    }
}
