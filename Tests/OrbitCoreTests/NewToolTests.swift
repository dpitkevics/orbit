import Foundation
import Testing
@testable import OrbitCore

@Suite("New Tools")
struct NewToolTests {
    let testDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbit-newtools-test-\(UUID().uuidString.prefix(8))")

    var context: ToolContext {
        ToolContext(
            workspaceRoot: testDir,
            project: "test",
            enforcer: PermissionEnforcer(
                policy: PermissionPolicy(activeMode: .dangerFullAccess),
                workspaceRoot: testDir.path
            )
        )
    }

    init() throws {
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    // MARK: - WebFetchTool

    @Test("WebFetchTool metadata")
    func webFetchMetadata() {
        let tool = WebFetchTool()
        #expect(tool.name == "web_fetch")
        #expect(tool.category == .network)
        #expect(tool.requiredPermission == .readOnly)
    }

    @Test("WebFetchTool missing URL returns error")
    func webFetchMissingURL() async throws {
        let tool = WebFetchTool()
        let result = try await tool.execute(input: .object([:]), context: context)
        #expect(result.isError)
        #expect(result.output.contains("url"))
    }

    @Test("WebFetchTool invalid URL returns error")
    func webFetchInvalidURL() async throws {
        let tool = WebFetchTool()
        let result = try await tool.execute(
            input: .object(["url": "not a url"]),
            context: context
        )
        #expect(result.isError)
    }

    // MARK: - WebSearchTool

    @Test("WebSearchTool metadata")
    func webSearchMetadata() {
        let tool = WebSearchTool()
        #expect(tool.name == "web_search")
        #expect(tool.category == .network)
        #expect(tool.requiredPermission == .readOnly)
    }

    @Test("WebSearchTool missing query returns error")
    func webSearchMissingQuery() async throws {
        let tool = WebSearchTool()
        let result = try await tool.execute(input: .object([:]), context: context)
        #expect(result.isError)
        #expect(result.output.contains("query"))
    }

    // MARK: - GitLogTool

    @Test("GitLogTool metadata")
    func gitLogMetadata() {
        let tool = GitLogTool()
        #expect(tool.name == "git_log")
        #expect(tool.category == .fileIO)
        #expect(tool.requiredPermission == .readOnly)
    }

    @Test("GitLogTool returns commits from current repo")
    func gitLogCurrentRepo() async throws {
        let tool = GitLogTool()
        let repoContext = ToolContext(
            workspaceRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            project: "test",
            enforcer: PermissionEnforcer(policy: PermissionPolicy(activeMode: .readOnly))
        )
        let result = try await tool.execute(input: .object(["days": 30]), context: repoContext)
        // Should have commits from the Orbit repo itself
        #expect(!result.isError)
    }

    // MARK: - StructuredOutputTool

    @Test("StructuredOutputTool metadata")
    func structuredOutputMetadata() {
        let tool = StructuredOutputTool()
        #expect(tool.name == "structured_output")
        #expect(tool.category == .planning)
    }

    @Test("StructuredOutputTool returns JSON")
    func structuredOutputJSON() async throws {
        let tool = StructuredOutputTool()
        let result = try await tool.execute(
            input: .object(["data": .object(["name": "test", "count": 42])]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("test"))
        #expect(result.output.contains("42"))
    }

    @Test("StructuredOutputTool markdown table format")
    func structuredOutputTable() async throws {
        let tool = StructuredOutputTool()
        let result = try await tool.execute(
            input: .object([
                "data": .object(["name": "Alice", "role": "Engineer"]),
                "format": "markdown_table",
            ]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("|"))
        #expect(result.output.contains("Alice"))
    }

    // MARK: - SendNotificationTool

    @Test("SendNotificationTool metadata")
    func sendNotificationMetadata() {
        let tool = SendNotificationTool()
        #expect(tool.name == "send_notification")
        #expect(tool.category == .network)
    }

    @Test("SendNotificationTool stdout channel")
    func sendNotificationStdout() async throws {
        let tool = SendNotificationTool()
        let result = try await tool.execute(
            input: .object(["message": "Test alert"]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("Test alert"))
    }

    @Test("SendNotificationTool file channel")
    func sendNotificationFile() async throws {
        let tool = SendNotificationTool()
        let filePath = testDir.appendingPathComponent("notifications.log").path
        let result = try await tool.execute(
            input: .object([
                "message": "Alert: disk full",
                "channel": "file",
                "file_path": .string(filePath),
            ]),
            context: context
        )
        #expect(!result.isError)
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content.contains("Alert: disk full"))
    }

    @Test("SendNotificationTool file channel missing path")
    func sendNotificationFileMissingPath() async throws {
        let tool = SendNotificationTool()
        let result = try await tool.execute(
            input: .object(["message": "test", "channel": "file"]),
            context: context
        )
        #expect(result.isError)
    }

    // MARK: - AgentTool

    @Test("AgentTool metadata")
    func agentToolMetadata() {
        let provider = MockProvider.textOnly("response")
        let pool = ToolPool(tools: [])
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)
        let tool = AgentTool(provider: provider, toolPool: pool, policy: policy)
        #expect(tool.name == "agent")
        #expect(tool.category == .agent)
        #expect(tool.requiredPermission == .dangerFullAccess)
    }

    @Test("AgentTool missing parameters")
    func agentToolMissingParams() async throws {
        let provider = MockProvider.textOnly("response")
        let pool = ToolPool(tools: [])
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)
        let tool = AgentTool(provider: provider, toolPool: pool, policy: policy)

        let result = try await tool.execute(input: .object([:]), context: context)
        #expect(result.isError)
    }

    // MARK: - allTools factory

    @Test("allTools includes all 12 tools")
    func allToolsCount() {
        let provider = MockProvider.textOnly("test")
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)
        let tools = allTools(provider: provider, policy: policy)
        #expect(tools.count == 12)

        let names = Set(tools.map { $0.name })
        #expect(names.contains("bash"))
        #expect(names.contains("file_read"))
        #expect(names.contains("web_fetch"))
        #expect(names.contains("web_search"))
        #expect(names.contains("git_log"))
        #expect(names.contains("agent"))
        #expect(names.contains("structured_output"))
        #expect(names.contains("send_notification"))
    }

    @Test("builtinTools returns 11 tools (no agent)")
    func builtinToolsCount() {
        let tools = builtinTools()
        #expect(tools.count == 11)
        #expect(!tools.contains { $0.name == "agent" })
    }
}
