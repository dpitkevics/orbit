import Foundation

/// Actor-based registry managing multiple MCP server connections.
///
/// Tracks server state (status, tools, errors) and provides
/// tool definitions to the ToolPool with proper name prefixing.
public actor MCPRegistry {
    private var servers: [String: MCPServerState] = [:]

    public init() {}

    /// Register a server with its current state.
    public func register(
        serverName: String,
        status: MCPConnectionStatus,
        tools: [MCPToolInfo],
        errorMessage: String? = nil
    ) {
        servers[serverName] = MCPServerState(
            serverName: serverName,
            status: status,
            tools: tools,
            errorMessage: errorMessage
        )
    }

    /// Get a specific server's state.
    public func getServer(named name: String) -> MCPServerState? {
        servers[name]
    }

    /// List all tracked servers.
    public func listServers() -> [MCPServerState] {
        servers.values.sorted { $0.serverName < $1.serverName }
    }

    /// Update a server's connection status.
    public func updateStatus(serverName: String, status: MCPConnectionStatus, errorMessage: String? = nil) {
        servers[serverName]?.status = status
        servers[serverName]?.errorMessage = errorMessage
    }

    /// Update a server's available tools.
    public func updateTools(serverName: String, tools: [MCPToolInfo]) {
        servers[serverName]?.tools = tools
    }

    /// Remove a server from the registry.
    public func remove(serverName: String) {
        servers.removeValue(forKey: serverName)
    }

    /// Generate ToolDefinitions for all connected servers' tools.
    /// Names are prefixed with `mcp__{server}__`.
    public func toolDefinitions() -> [ToolDefinition] {
        var defs: [ToolDefinition] = []

        for (serverName, state) in servers {
            guard state.status == .connected else { continue }

            for tool in state.tools {
                let prefixedName = MCPNaming.toolName(server: serverName, tool: tool.name)
                defs.append(ToolDefinition(
                    name: prefixedName,
                    description: tool.description,
                    inputSchema: tool.inputSchema ?? .object(["type": "object"])
                ))
            }
        }

        return defs.sorted { $0.name < $1.name }
    }

    /// Count of connected servers.
    public var connectedCount: Int {
        servers.values.filter { $0.status == .connected }.count
    }

    /// Total count of available tools across all connected servers.
    public var totalToolCount: Int {
        servers.values
            .filter { $0.status == .connected }
            .reduce(0) { $0 + $1.tools.count }
    }
}
