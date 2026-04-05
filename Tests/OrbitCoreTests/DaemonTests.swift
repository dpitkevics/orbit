import Foundation
import Testing
@testable import OrbitCore

@Suite("Daemon")
struct DaemonTests {
    @Test("DaemonConfig defaults")
    func daemonConfigDefaults() {
        let config = DaemonConfig()
        #expect(config.tickInterval == 300)
        #expect(config.maxBlockingBudget == 15)
        #expect(config.dreamThreshold == 1800)
        #expect(config.briefMode)
    }

    @Test("OrbitDaemon initial state is stopped")
    func daemonInitialState() async {
        let daemon = OrbitDaemon()
        let status = await daemon.getStatus()
        #expect(status == .stopped)
        let ticks = await daemon.getTickCount()
        #expect(ticks == 0)
    }

    @Test("OrbitDaemon start and stop")
    func daemonStartStop() async throws {
        let config = DaemonConfig(tickInterval: 0.1)
        let daemon = OrbitDaemon(config: config)

        await daemon.start { _ in }

        let running = await daemon.getStatus()
        #expect(running == .running)

        // Let it tick once
        try await Task.sleep(nanoseconds: 200_000_000)

        await daemon.stop()
        let stopped = await daemon.getStatus()
        #expect(stopped == .stopped)

        let ticks = await daemon.getTickCount()
        #expect(ticks >= 1)
    }

    @Test("OrbitDaemon tick handler receives context")
    func daemonTickContext() async throws {
        let config = DaemonConfig(tickInterval: 0.05)
        let task = TaskDefinition(
            name: "Test Task",
            slug: "test",
            project: "test",
            cron: "* * * * *",
            enabled: true
        )
        let daemon = OrbitDaemon(config: config, tasks: [task])

        let box = ContextBox()
        await daemon.start { ctx in
            await box.set(ctx)
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        await daemon.stop()

        let receivedContext = await box.get()
        #expect(receivedContext != nil)
        #expect(receivedContext?.tasks.count == 1)
        #expect(receivedContext?.config.briefMode == true)
    }

    @Test("Daily log append creates file")
    func dailyLogAppend() throws {
        let testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-daemon-test-\(UUID().uuidString.prefix(8))")

        try OrbitDaemon.appendDailyLog(
            project: "test",
            entry: "Observed: all metrics nominal",
            logsDir: testDir
        )

        // Check the file was created
        let projectDir = testDir.appendingPathComponent("test")
        let files = try FileManager.default.contentsOfDirectory(atPath: projectDir.path)
        #expect(files.count == 1)
        #expect(files[0].hasSuffix(".md"))

        let content = try String(contentsOf: projectDir.appendingPathComponent(files[0]), encoding: .utf8)
        #expect(content.contains("all metrics nominal"))
    }

    @Test("Daily log append appends to existing file")
    func dailyLogAppendMultiple() throws {
        let testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-daemon-test-\(UUID().uuidString.prefix(8))")

        try OrbitDaemon.appendDailyLog(project: "test", entry: "First entry", logsDir: testDir)
        try OrbitDaemon.appendDailyLog(project: "test", entry: "Second entry", logsDir: testDir)

        let projectDir = testDir.appendingPathComponent("test")
        let files = try FileManager.default.contentsOfDirectory(atPath: projectDir.path)
        let content = try String(contentsOf: projectDir.appendingPathComponent(files[0]), encoding: .utf8)
        #expect(content.contains("First entry"))
        #expect(content.contains("Second entry"))
    }
}

/// Thread-safe box for passing values out of Sendable closures.
private actor ContextBox {
    private var value: DaemonTickContext?
    func set(_ ctx: DaemonTickContext) { value = ctx }
    func get() -> DaemonTickContext? { value }
}
