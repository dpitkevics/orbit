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
        subcommands: [ScheduleList.self, ScheduleEnable.self, ScheduleDisable.self]
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

struct ScheduleEnable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a scheduled task."
    )

    @Argument(help: "Task slug.")
    var slug: String

    func run() {
        toggleTask(slug: slug, enable: true)
    }
}

struct ScheduleDisable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a scheduled task."
    )

    @Argument(help: "Task slug.")
    var slug: String

    func run() {
        toggleTask(slug: slug, enable: false)
    }
}

private func toggleTask(slug: String, enable: Bool) {
    let path = ConfigLoader.orbitHome.appendingPathComponent("schedules/\(slug).toml")
    guard FileManager.default.fileExists(atPath: path.path) else {
        print("Task '\(slug)' not found.")
        return
    }

    guard var content = try? String(contentsOf: path, encoding: .utf8) else {
        print("Cannot read task file.")
        return
    }

    // Simple toggle by replacing the enabled line
    if enable {
        content = content.replacingOccurrences(of: "enabled = false", with: "enabled = true")
    } else {
        content = content.replacingOccurrences(of: "enabled = true", with: "enabled = false")
    }

    try? content.write(to: path, atomically: true, encoding: .utf8)
    print("Task '\(slug)' \(enable ? "enabled" : "disabled").")
}

// MARK: - orbit daemon

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the Orbit background daemon.",
        subcommands: [DaemonStatus.self, DaemonStart.self, DaemonStop.self]
    )
}

struct DaemonStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show daemon status."
    )

    func run() {
        let plistPath = launchdPlistPath()
        let isLoaded = FileManager.default.fileExists(atPath: plistPath)

        if isLoaded {
            // Check if actually running via launchctl
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["list", "com.orbit.daemon"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                print("Daemon: running (launchd)")
            } else {
                print("Daemon: plist exists but not loaded")
            }
        } else {
            print("Daemon: not running")
        }
        print("Plist: \(plistPath)")
        print("Use `orbit daemon start` to start.")
    }
}

struct DaemonStart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the daemon via launchd."
    )

    func run() {
        let orbitBinary = ProcessInfo.processInfo.arguments[0]
        let plistPath = launchdPlistPath()

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.orbit.daemon</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(orbitBinary)</string>
                <string>run</string>
                <string>--daemon-mode</string>
            </array>
            <key>StartInterval</key>
            <integer>300</integer>
            <key>StandardOutPath</key>
            <string>\(ConfigLoader.orbitHome.appendingPathComponent("logs/daemon.log").path)</string>
            <key>StandardErrorPath</key>
            <string>\(ConfigLoader.orbitHome.appendingPathComponent("logs/daemon-error.log").path)</string>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """

        do {
            let logsDir = ConfigLoader.orbitHome.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", plistPath]
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                print("Daemon started via launchd.")
                print("Plist: \(plistPath)")
            } else {
                print("Failed to load launchd plist.")
            }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}

struct DaemonStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the daemon."
    )

    func run() {
        let plistPath = launchdPlistPath()

        guard FileManager.default.fileExists(atPath: plistPath) else {
            print("Daemon is not running (no plist found).")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", plistPath]
        try? process.run()
        process.waitUntilExit()

        try? FileManager.default.removeItem(atPath: plistPath)
        print("Daemon stopped.")
    }
}

private func launchdPlistPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/LaunchAgents/com.orbit.daemon.plist").path
}
