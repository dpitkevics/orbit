import Foundation
import Testing
@testable import OrbitCore

@Suite("Cron Expression")
struct CronExpressionTests {
    @Test("Parse simple cron expression")
    func parseSimple() throws {
        let cron = try CronExpression("0 9 * * *") // 9 AM daily
        #expect(cron.minute == .value(0))
        #expect(cron.hour == .value(9))
        #expect(cron.dayOfMonth == .any)
        #expect(cron.month == .any)
        #expect(cron.dayOfWeek == .any)
    }

    @Test("Parse wildcard cron")
    func parseWildcard() throws {
        let cron = try CronExpression("* * * * *") // every minute
        #expect(cron.minute == .any)
        #expect(cron.hour == .any)
    }

    @Test("Parse cron with step")
    func parseStep() throws {
        let cron = try CronExpression("*/15 * * * *") // every 15 minutes
        #expect(cron.minute == .step(15))
    }

    @Test("Parse cron with range")
    func parseRange() throws {
        let cron = try CronExpression("0 9-17 * * *") // 9 AM to 5 PM
        #expect(cron.hour == .range(9, 17))
    }

    @Test("Parse cron with list")
    func parseList() throws {
        let cron = try CronExpression("0 9 * * 1,3,5") // Mon, Wed, Fri
        #expect(cron.dayOfWeek == .list([1, 3, 5]))
    }

    @Test("Invalid cron throws")
    func invalidCron() {
        #expect(throws: CronParseError.self) {
            try CronExpression("invalid")
        }
        #expect(throws: CronParseError.self) {
            try CronExpression("0 9 * *") // only 4 fields
        }
    }

    @Test("Cron matches specific time")
    func cronMatches() throws {
        let cron = try CronExpression("30 14 * * *") // 2:30 PM daily

        var components = DateComponents()
        components.minute = 30
        components.hour = 14
        components.day = 15
        components.month = 4
        components.weekday = 3 // Tuesday (1=Sunday in Calendar)

        #expect(cron.matches(components))
    }

    @Test("Cron does not match wrong time")
    func cronDoesNotMatch() throws {
        let cron = try CronExpression("30 14 * * *")

        var components = DateComponents()
        components.minute = 0
        components.hour = 9
        components.day = 15
        components.month = 4
        components.weekday = 3

        #expect(!cron.matches(components))
    }

    @Test("Cron step matches correctly")
    func cronStepMatches() throws {
        let cron = try CronExpression("*/15 * * * *")

        var c0 = DateComponents()
        c0.minute = 0; c0.hour = 10; c0.day = 1; c0.month = 1; c0.weekday = 1
        #expect(cron.matches(c0))

        var c15 = DateComponents()
        c15.minute = 15; c15.hour = 10; c15.day = 1; c15.month = 1; c15.weekday = 1
        #expect(cron.matches(c15))

        var c7 = DateComponents()
        c7.minute = 7; c7.hour = 10; c7.day = 1; c7.month = 1; c7.weekday = 1
        #expect(!cron.matches(c7))
    }

    @Test("Cron day-of-week matches (Sunday=0 or 7)")
    func cronDayOfWeek() throws {
        let cron = try CronExpression("0 9 * * 1") // Monday

        var mon = DateComponents()
        mon.minute = 0; mon.hour = 9; mon.day = 1; mon.month = 1; mon.weekday = 2 // Calendar: Monday=2
        #expect(cron.matches(mon))

        var tue = DateComponents()
        tue.minute = 0; tue.hour = 9; tue.day = 1; tue.month = 1; tue.weekday = 3
        #expect(!cron.matches(tue))
    }
}

@Suite("Task Definition")
struct TaskDefinitionTests {
    @Test("TaskDefinition initialization")
    func taskDefInit() {
        let task = TaskDefinition(
            name: "Daily Brief",
            slug: "daily-brief",
            project: "myproject",
            cron: "0 9 * * *",
            promptText: "Summarize today's metrics.",
            enabled: true
        )
        #expect(task.name == "Daily Brief")
        #expect(task.slug == "daily-brief")
        #expect(task.enabled)
    }

    @Test("TaskDefinition disabled by default is false")
    func taskDefDisabled() {
        let task = TaskDefinition(
            name: "Test",
            slug: "test",
            project: "p",
            cron: "* * * * *",
            enabled: false
        )
        #expect(!task.enabled)
    }
}

@Suite("Task Execution Log")
struct TaskExecutionLogTests {
    @Test("TaskExecutionLog records results")
    func logRecords() {
        let log = TaskExecutionLog(
            taskSlug: "daily-brief",
            project: "myproject",
            startedAt: Date(),
            finishedAt: Date(),
            duration: 5.2,
            usage: TokenUsage(inputTokens: 1000, outputTokens: 500),
            output: "Summary: all good",
            success: true
        )
        #expect(log.success)
        #expect(log.output == "Summary: all good")
        #expect(log.duration == 5.2)
    }
}

@Suite("Task Store")
struct TaskStoreTests {
    let testDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbit-sched-test-\(UUID().uuidString.prefix(8))")

    @Test("Save and load task definition from TOML")
    func taskDefinitionTOMLRoundtrip() throws {
        let toml = """
        [task]
        name = "Daily Brief"
        slug = "daily-brief"
        project = "myproject"
        cron = "0 9 * * *"
        enabled = true

        [task.prompt]
        text = "Summarize today."
        """

        let task = try TaskDefinitionParser.parse(toml, path: "test.toml")
        #expect(task.name == "Daily Brief")
        #expect(task.slug == "daily-brief")
        #expect(task.cron == "0 9 * * *")
        #expect(task.promptText == "Summarize today.")
        #expect(task.enabled)
    }

    @Test("Parse task with prompt file reference")
    func taskWithPromptFile() throws {
        let toml = """
        [task]
        name = "Weekly Report"
        slug = "weekly-report"
        project = "myproject"
        cron = "0 9 * * 1"
        enabled = true

        [task.prompt]
        file = "prompts/weekly.md"
        """

        let task = try TaskDefinitionParser.parse(toml, path: "test.toml")
        #expect(task.promptFile == "prompts/weekly.md")
        #expect(task.promptText == nil)
    }
}
