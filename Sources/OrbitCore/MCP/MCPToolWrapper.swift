import Foundation

/// Wraps an MCP server tool as an Orbit Tool, enabling the LLM to execute it.
///
/// When the LLM calls a tool with name `mcp__{server}__{tool}`, this wrapper
/// routes the call to the appropriate MCP server via MCPConnector.
public struct MCPToolWrapper: Tool, @unchecked Sendable {
    public let name: String
    public let description: String
    public let category: ToolCategory = .mcp
    public let inputSchema: JSONValue
    public let requiredPermission: PermissionMode = .readOnly

    private let serverName: String
    private let originalToolName: String
    private let connector: MCPConnector

    public init(
        serverName: String,
        toolInfo: MCPToolInfo,
        connector: MCPConnector
    ) {
        self.serverName = serverName
        self.originalToolName = toolInfo.name
        self.name = MCPNaming.toolName(server: serverName, tool: toolInfo.name)
        self.description = toolInfo.description ?? "MCP tool from \(serverName)"
        self.inputSchema = toolInfo.inputSchema ?? .object(["type": "object"])
        self.connector = connector
    }

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        // Convert JSONValue input to [String: JSONValue] for MCP call
        var arguments: [String: JSONValue] = [:]
        if case .object(let dict) = input {
            arguments = dict
        }

        return try await connector.callTool(
            serverName: serverName,
            toolName: originalToolName,
            arguments: arguments
        )
    }
}

/// Create Tool wrappers for all connected MCP server tools.
public func mcpToolWrappers(registry: MCPRegistry, connector: MCPConnector) async -> [any Tool] {
    let servers = await registry.listServers()
    var tools: [any Tool] = []

    for server in servers where server.status == .connected {
        for toolInfo in server.tools {
            tools.append(MCPToolWrapper(
                serverName: server.serverName,
                toolInfo: toolInfo,
                connector: connector
            ))
        }
    }

    return tools
}
