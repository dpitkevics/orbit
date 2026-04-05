import Foundation
import Testing
@testable import OrbitCore

@Suite("MCP Name Normalization")
struct MCPNormalizationTests {
    @Test("Normalizes alphanumeric and underscore/dash characters")
    func normalizeBasic() {
        #expect(MCPNaming.normalize("my_server") == "my_server")
        #expect(MCPNaming.normalize("my-server") == "my-server")
        #expect(MCPNaming.normalize("server123") == "server123")
    }

    @Test("Replaces special characters with underscore")
    func normalizeSpecialChars() {
        #expect(MCPNaming.normalize("my server") == "my_server")
        #expect(MCPNaming.normalize("my.server") == "my_server")
        #expect(MCPNaming.normalize("my@server!") == "my_server_")
    }

    @Test("Collapses underscores for claude.ai prefixed servers")
    func normalizeClaudeAI() {
        let result = MCPNaming.normalize("claude.ai My Server")
        #expect(!result.contains("__"))
        #expect(!result.hasPrefix("_"))
        #expect(!result.hasSuffix("_"))
    }

    @Test("Generates correct tool name prefix")
    func toolPrefix() {
        #expect(MCPNaming.toolPrefix(server: "analytics") == "mcp__analytics__")
    }

    @Test("Generates full tool name")
    func toolName() {
        let name = MCPNaming.toolName(server: "analytics", tool: "get_metrics")
        #expect(name == "mcp__analytics__get_metrics")
    }

    @Test("Tool name with special chars in server and tool")
    func toolNameSpecialChars() {
        let name = MCPNaming.toolName(server: "my server", tool: "get data")
        #expect(name == "mcp__my_server__get_data")
    }
}

@Suite("MCP Config Hashing")
struct MCPConfigHashingTests {
    @Test("Same config produces same hash")
    func deterministicHash() {
        let config = MCPServerConfig(
            name: "test",
            transport: .stdio,
            command: "/usr/bin/server",
            args: ["--port", "8080"]
        )
        let hash1 = MCPConfigHash.hash(config: config)
        let hash2 = MCPConfigHash.hash(config: config)
        #expect(hash1 == hash2)
    }

    @Test("Different configs produce different hashes")
    func differentHashes() {
        let config1 = MCPServerConfig(name: "a", transport: .stdio, command: "/usr/bin/a")
        let config2 = MCPServerConfig(name: "b", transport: .stdio, command: "/usr/bin/b")
        #expect(MCPConfigHash.hash(config: config1) != MCPConfigHash.hash(config: config2))
    }

    @Test("Hash is a hex string")
    func hashFormat() {
        let config = MCPServerConfig(name: "test", transport: .http, url: "https://example.com/mcp")
        let hash = MCPConfigHash.hash(config: config)
        #expect(hash.allSatisfy { $0.isHexDigit })
        #expect(!hash.isEmpty)
    }
}

@Suite("MCP Connection Status")
struct MCPConnectionStatusTests {
    @Test("All status values are representable")
    func statusValues() {
        let statuses: [MCPConnectionStatus] = [
            .disconnected, .connecting, .connected, .error,
        ]
        #expect(statuses.count == 4)
    }

    @Test("Status Codable roundtrip")
    func statusCodable() throws {
        let status = MCPConnectionStatus.connected
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(MCPConnectionStatus.self, from: data)
        #expect(decoded == .connected)
    }
}

@Suite("MCP Server State")
struct MCPServerStateTests {
    @Test("Server state tracks tools and status")
    func serverState() {
        let state = MCPServerState(
            serverName: "analytics",
            status: .connected,
            tools: [
                MCPToolInfo(name: "get_metrics", description: "Get metrics", inputSchema: nil),
                MCPToolInfo(name: "get_events", description: "Get events", inputSchema: nil),
            ]
        )
        #expect(state.serverName == "analytics")
        #expect(state.status == .connected)
        #expect(state.tools.count == 2)
    }
}

@Suite("MCP Registry")
struct MCPRegistryTests {
    @Test("Register and list servers")
    func registerServer() async {
        let registry = MCPRegistry()
        await registry.register(
            serverName: "analytics",
            status: .connected,
            tools: [MCPToolInfo(name: "get_data", description: nil, inputSchema: nil)]
        )

        let servers = await registry.listServers()
        #expect(servers.count == 1)
        #expect(servers[0].serverName == "analytics")
    }

    @Test("Get server by name")
    func getServer() async {
        let registry = MCPRegistry()
        await registry.register(serverName: "test", status: .connected, tools: [])

        let server = await registry.getServer(named: "test")
        #expect(server?.status == .connected)

        let missing = await registry.getServer(named: "missing")
        #expect(missing == nil)
    }

    @Test("Update server status")
    func updateStatus() async {
        let registry = MCPRegistry()
        await registry.register(serverName: "test", status: .connecting, tools: [])
        await registry.updateStatus(serverName: "test", status: .connected)

        let server = await registry.getServer(named: "test")
        #expect(server?.status == .connected)
    }

    @Test("Remove server")
    func removeServer() async {
        let registry = MCPRegistry()
        await registry.register(serverName: "test", status: .connected, tools: [])
        await registry.remove(serverName: "test")

        let servers = await registry.listServers()
        #expect(servers.isEmpty)
    }

    @Test("Generate tool definitions with prefixed names")
    func toolDefinitions() async {
        let registry = MCPRegistry()
        await registry.register(
            serverName: "analytics",
            status: .connected,
            tools: [
                MCPToolInfo(
                    name: "get_metrics",
                    description: "Fetch metrics",
                    inputSchema: .object(["type": "object"])
                ),
            ]
        )

        let defs = await registry.toolDefinitions()
        #expect(defs.count == 1)
        #expect(defs[0].name == "mcp__analytics__get_metrics")
        #expect(defs[0].description == "Fetch metrics")
    }

    @Test("Only connected servers contribute tools")
    func onlyConnectedServers() async {
        let registry = MCPRegistry()
        await registry.register(
            serverName: "good",
            status: .connected,
            tools: [MCPToolInfo(name: "a", description: nil, inputSchema: nil)]
        )
        await registry.register(
            serverName: "bad",
            status: .error,
            tools: [MCPToolInfo(name: "b", description: nil, inputSchema: nil)]
        )

        let defs = await registry.toolDefinitions()
        #expect(defs.count == 1)
        #expect(defs[0].name == "mcp__good__a")
    }

    @Test("Parse server name from prefixed tool name")
    func parseServerFromToolName() {
        let (server, tool) = MCPNaming.parse(prefixedName: "mcp__analytics__get_metrics")
        #expect(server == "analytics")
        #expect(tool == "get_metrics")
    }

    @Test("Parse returns nil for non-MCP tool name")
    func parseNonMCP() {
        let (server, tool) = MCPNaming.parse(prefixedName: "bash")
        #expect(server == nil)
        #expect(tool == nil)
    }
}
