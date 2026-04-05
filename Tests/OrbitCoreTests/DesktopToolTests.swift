import Foundation
import Testing
@testable import OrbitCore

@Suite("Desktop Tools")
struct DesktopToolTests {
    @Test("BrowserTool metadata")
    func browserMetadata() {
        let tool = BrowserTool()
        #expect(tool.name == "browser")
        #expect(tool.category == .desktop)
        #expect(tool.requiredPermission == .dangerFullAccess)
    }

    @Test("BrowserTool missing action returns error")
    func browserMissingAction() async throws {
        let tool = BrowserTool()
        let ctx = ToolContext(
            workspaceRoot: FileManager.default.temporaryDirectory,
            project: "test",
            enforcer: PermissionEnforcer(policy: PermissionPolicy(activeMode: .dangerFullAccess))
        )
        let result = try await tool.execute(input: .object([:]), context: ctx)
        #expect(result.isError)
    }

    @Test("BrowserTool unknown action returns error")
    func browserUnknownAction() async throws {
        let tool = BrowserTool()
        let ctx = ToolContext(
            workspaceRoot: FileManager.default.temporaryDirectory,
            project: "test",
            enforcer: PermissionEnforcer(policy: PermissionPolicy(activeMode: .dangerFullAccess))
        )
        let result = try await tool.execute(input: .object(["action": "unknown"]), context: ctx)
        #expect(result.isError)
    }

    @Test("ComputerUseTool metadata")
    func computerUseMetadata() {
        let tool = ComputerUseTool()
        #expect(tool.name == "computer_use")
        #expect(tool.category == .desktop)
        #expect(tool.requiredPermission == .dangerFullAccess)
    }

    @Test("ComputerUseTool missing action returns error")
    func computerUseMissingAction() async throws {
        let tool = ComputerUseTool()
        let ctx = ToolContext(
            workspaceRoot: FileManager.default.temporaryDirectory,
            project: "test",
            enforcer: PermissionEnforcer(policy: PermissionPolicy(activeMode: .dangerFullAccess))
        )
        let result = try await tool.execute(input: .object([:]), context: ctx)
        #expect(result.isError)
    }

    @Test("ComputerUseTool unknown action returns error")
    func computerUseUnknownAction() async throws {
        let tool = ComputerUseTool()
        let ctx = ToolContext(
            workspaceRoot: FileManager.default.temporaryDirectory,
            project: "test",
            enforcer: PermissionEnforcer(policy: PermissionPolicy(activeMode: .dangerFullAccess))
        )
        let result = try await tool.execute(input: .object(["action": "unknown"]), context: ctx)
        #expect(result.isError)
    }
}

@Suite("Plugin System")
struct PluginSystemTests {
    @Test("PluginManager registers and lists plugins")
    func pluginManagerBasic() async throws {
        let manager = PluginManager()

        let plugin = TestPlugin(id: "test", name: "Test Plugin", version: "1.0")
        try await manager.register(plugin)

        let all = await manager.allPlugins()
        #expect(all.count == 1)
        #expect(all[0].id == "test")
    }

    @Test("PluginManager rejects duplicate IDs")
    func pluginManagerDuplicate() async throws {
        let manager = PluginManager()
        let plugin = TestPlugin(id: "test", name: "Test", version: "1.0")
        try await manager.register(plugin)

        do {
            try await manager.register(plugin)
            #expect(Bool(false), "Should have thrown")
        } catch {
            #expect(error is PluginError)
        }
    }

    @Test("PluginManager unregister removes plugin")
    func pluginManagerUnregister() async throws {
        let manager = PluginManager()
        let plugin = TestPlugin(id: "test", name: "Test", version: "1.0")
        try await manager.register(plugin)
        try await manager.unregister(id: "test")

        let all = await manager.allPlugins()
        #expect(all.isEmpty)
    }

    @Test("PluginManager collects tools from plugins")
    func pluginManagerTools() async throws {
        let manager = PluginManager()
        let plugin = ToolPlugin(id: "tp", name: "Tool Plugin", version: "1.0")
        try await manager.register(plugin)

        let tools = await manager.allTools()
        #expect(tools.count == 1)
        #expect(tools[0].name == "plugin_tool")
    }

    @Test("PluginError descriptions")
    func pluginErrors() {
        let err1 = PluginError.alreadyRegistered("test")
        #expect(err1.errorDescription?.contains("test") == true)

        let err2 = PluginError.notFound("missing")
        #expect(err2.errorDescription?.contains("missing") == true)
    }
}

// Test helpers
private struct TestPlugin: OrbitPlugin {
    let id: String
    let name: String
    let version: String
}

private struct ToolPlugin: OrbitPlugin {
    let id: String
    let name: String
    let version: String

    func tools() -> [any Tool] {
        [MockTool(name: "plugin_tool")]
    }
}
