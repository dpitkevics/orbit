import Foundation

/// Configuration for the Orbit daemon.
public struct DaemonConfig: Codable, Sendable {
    /// Check interval in seconds.
    public var tickInterval: TimeInterval
    /// Maximum time for a proactive action.
    public var maxBlockingBudget: TimeInterval
    /// Idle time before triggering autoDream.
    public var dreamThreshold: TimeInterval
    /// Use brief output for daemon actions.
    public var briefMode: Bool

    public init(
        tickInterval: TimeInterval = 300,
        maxBlockingBudget: TimeInterval = 15,
        dreamThreshold: TimeInterval = 1800,
        briefMode: Bool = true
    ) {
        self.tickInterval = tickInterval
        self.maxBlockingBudget = maxBlockingBudget
        self.dreamThreshold = dreamThreshold
        self.briefMode = briefMode
    }
}

/// Status of the daemon.
public enum DaemonStatus: String, Codable, Sendable {
    case stopped
    case running
    case stopping
}

/// The Orbit daemon — background agent that monitors projects and runs scheduled tasks.
public actor OrbitDaemon {
    private let config: DaemonConfig
    private let tasks: [TaskDefinition]
    private var status: DaemonStatus = .stopped
    private var lastTickTime: Date?
    private var tickCount: UInt64 = 0
    private var runLoop: Task<Void, Never>?

    public init(config: DaemonConfig = DaemonConfig(), tasks: [TaskDefinition] = []) {
        self.config = config
        self.tasks = tasks
    }

    public func getStatus() -> DaemonStatus { status }
    public func getTickCount() -> UInt64 { tickCount }
    public func getLastTickTime() -> Date? { lastTickTime }

    /// Start the daemon tick loop.
    public func start(onTick: @escaping @Sendable (DaemonTickContext) async -> Void) {
        guard status == .stopped else { return }
        status = .running

        runLoop = Task { [config, tasks] in
            while !Task.isCancelled {
                let tickNum = self.performTick()
                let enabledTasks = tasks.filter { $0.enabled }

                // Check which tasks are due based on cron expressions
                let now = Calendar.current.dateComponents(
                    [.minute, .hour, .day, .month, .weekday], from: Date()
                )
                let dueTasks = enabledTasks.filter { task in
                    (try? CronExpression(task.cron).matches(now)) ?? false
                }

                let context = DaemonTickContext(
                    tickNumber: tickNum,
                    config: config,
                    tasks: enabledTasks,
                    dueTasks: dueTasks
                )

                await onTick(context)

                try? await Task.sleep(nanoseconds: UInt64(config.tickInterval * 1_000_000_000))
            }
        }
    }

    /// Stop the daemon.
    public func stop() {
        status = .stopping
        runLoop?.cancel()
        runLoop = nil
        status = .stopped
    }

    private func performTick() -> UInt64 {
        tickCount += 1
        lastTickTime = Date()
        return tickCount
    }

    /// Append to the daily log for a project.
    public static func appendDailyLog(
        project: String,
        entry: String,
        logsDir: URL? = nil
    ) throws {
        let dir = (logsDir ?? ConfigLoader.orbitHome.appendingPathComponent("logs/daily"))
            .appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "\(formatter.string(from: Date())).md"
        let path = dir.appendingPathComponent(filename)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "- [\(timestamp)] \(entry)\n"

        if FileManager.default.fileExists(atPath: path.path) {
            let handle = try FileHandle(forWritingTo: path)
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try line.write(to: path, atomically: true, encoding: .utf8)
        }
    }
}

/// Context passed to the daemon's tick handler.
public struct DaemonTickContext: Sendable {
    public let tickNumber: UInt64
    public let config: DaemonConfig
    public let tasks: [TaskDefinition]
    /// Tasks whose cron expression matches the current time.
    public let dueTasks: [TaskDefinition]

    public init(
        tickNumber: UInt64,
        config: DaemonConfig,
        tasks: [TaskDefinition],
        dueTasks: [TaskDefinition] = []
    ) {
        self.tickNumber = tickNumber
        self.config = config
        self.tasks = tasks
        self.dueTasks = dueTasks
    }
}
