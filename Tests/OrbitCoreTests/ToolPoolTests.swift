import Foundation
import Testing
@testable import OrbitCore

/// Minimal test tool for unit testing.
struct MockTool: Tool, Sendable {
    let name: String
    let description: String
    let category: ToolCategory
    let inputSchema: JSONValue = .object(["type": "object"])
    let requiredPermission: PermissionMode
    let handler: @Sendable (JSONValue, ToolContext) async throws -> ToolResult

    init(
        name: String,
        description: String = "Mock tool",
        category: ToolCategory = .fileIO,
        requiredPermission: PermissionMode = .readOnly,
        handler: @escaping @Sendable (JSONValue, ToolContext) async throws -> ToolResult = { _, _ in .success("ok") }
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.requiredPermission = requiredPermission
        self.handler = handler
    }

    func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await handler(input, context)
    }
}

@Suite("Tool Pool")
struct ToolPoolTests {
    @Test("ToolPool basic operations")
    func toolPoolBasics() {
        let tools: [any Tool] = [
            MockTool(name: "alpha"),
            MockTool(name: "beta"),
            MockTool(name: "gamma"),
        ]
        let pool = ToolPool(tools: tools)
        #expect(pool.count == 3)
        #expect(pool.allNames == ["alpha", "beta", "gamma"])
        #expect(pool.tool(named: "beta")?.name == "beta")
        #expect(pool.tool(named: "missing") == nil)
    }

    @Test("ToolPool respects maxVisible cap")
    func toolPoolMaxVisible() {
        let tools: [any Tool] = (0..<20).map { MockTool(name: "tool_\($0)") }
        let pool = ToolPool(tools: tools, maxVisible: 5)

        let policy = PermissionPolicy(activeMode: .dangerFullAccess)
        let available = pool.availableTools(mode: .full, policy: policy)
        #expect(available.count == 5)
    }

    @Test("ToolPool simple mode filters to core tools")
    func toolPoolSimpleMode() {
        let tools: [any Tool] = [
            MockTool(name: "bash", requiredPermission: .dangerFullAccess),
            MockTool(name: "file_read"),
            MockTool(name: "file_edit", requiredPermission: .workspaceWrite),
            MockTool(name: "web_search"),
            MockTool(name: "glob_search"),
        ]
        let pool = ToolPool(tools: tools)
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)

        let available = pool.availableTools(mode: .simple, policy: policy)
        let names = available.map { $0.name }
        #expect(names.contains("bash"))
        #expect(names.contains("file_read"))
        #expect(names.contains("file_edit"))
        #expect(!names.contains("web_search"))
        #expect(!names.contains("glob_search"))
    }

    @Test("ToolPool restricted mode filters to specific tools")
    func toolPoolRestrictedMode() {
        let tools: [any Tool] = [
            MockTool(name: "alpha"),
            MockTool(name: "beta"),
            MockTool(name: "gamma"),
        ]
        let pool = ToolPool(tools: tools)
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)

        let available = pool.availableTools(
            mode: .restricted(allowed: ["alpha", "gamma"]),
            policy: policy
        )
        let names = available.map { $0.name }
        #expect(names == ["alpha", "gamma"])
    }

    @Test("ToolPool permission filtering excludes denied tools")
    func toolPoolPermissionFilter() {
        let tools: [any Tool] = [
            MockTool(name: "bash", requiredPermission: .dangerFullAccess),
            MockTool(name: "file_read", requiredPermission: .readOnly),
        ]
        let pool = ToolPool(tools: tools)
        let policy = PermissionPolicy(activeMode: .readOnly)

        let available = pool.availableTools(mode: .full, policy: policy)
        let names = available.map { $0.name }
        #expect(names == ["file_read"])
    }

    @Test("ToolPool definitions converts to ToolDefinition")
    func toolPoolDefinitions() {
        let tools: [any Tool] = [MockTool(name: "test_tool", description: "A test")]
        let pool = ToolPool(tools: tools)
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)

        let defs = pool.definitions(mode: .full, policy: policy)
        #expect(defs.count == 1)
        #expect(defs[0].name == "test_tool")
        #expect(defs[0].description == "A test")
    }

    @Test("ToolRegistry rejects duplicate names")
    func toolRegistryDuplicate() {
        var registry = ToolRegistry()
        try! registry.register(MockTool(name: "alpha"))
        #expect(throws: ToolRegistryError.self) {
            try registry.register(MockTool(name: "alpha"))
        }
    }

    @Test("ToolRegistry builds pool")
    func toolRegistryBuildPool() throws {
        var registry = ToolRegistry()
        try registry.register(MockTool(name: "alpha"))
        try registry.register(MockTool(name: "beta"))
        let pool = registry.buildPool()
        #expect(pool.count == 2)
    }

    @Test("ToolResult convenience constructors")
    func toolResultConvenience() {
        let success = ToolResult.success("data")
        #expect(!success.isError)
        #expect(success.output == "data")

        let error = ToolResult.error("bad")
        #expect(error.isError)
        #expect(error.output == "bad")
    }

    @Test("Tool toDefinition extension")
    func toolToDefinition() {
        let tool = MockTool(name: "my_tool", description: "Does things")
        let def = tool.toDefinition()
        #expect(def.name == "my_tool")
        #expect(def.description == "Does things")
    }
}
