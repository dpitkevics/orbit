import Foundation
import MCP
#if canImport(System)
import System
#endif

/// Connects to MCP servers using the official MCP Swift SDK
/// and registers their tools into the MCPRegistry.
public actor MCPConnector {
    private let registry: MCPRegistry
    private var clients: [String: Client] = [:]
    private var processes: [String: Process] = [:]

    public init(registry: MCPRegistry) {
        self.registry = registry
    }

    /// Connect to an MCP server based on its config.
    public func connect(config: MCPServerConfig) async throws {
        await registry.register(
            serverName: config.name,
            status: .connecting,
            tools: []
        )

        do {
            let client = Client(
                name: "orbit",
                version: "0.1.0"
            )

            let transport: any Transport
            switch config.transport {
            case .stdio:
                guard let command = config.command else {
                    throw MCPConnectorError.missingCommand(server: config.name)
                }
                transport = try launchStdioServer(
                    name: config.name,
                    command: command,
                    args: config.args ?? [],
                    env: config.env
                )
            case .http, .sse:
                guard let urlString = config.url,
                      let url = URL(string: urlString) else {
                    throw MCPConnectorError.missingURL(server: config.name)
                }
                transport = HTTPClientTransport(endpoint: url)
            }

            _ = try await client.connect(transport: transport)

            // Discover tools
            let (mcpTools, _) = try await client.listTools()
            let toolInfos = mcpTools.map { tool in
                MCPToolInfo(
                    name: tool.name,
                    description: tool.description,
                    inputSchema: convertMCPValue(tool.inputSchema)
                )
            }

            clients[config.name] = client
            await registry.register(
                serverName: config.name,
                status: .connected,
                tools: toolInfos
            )
        } catch {
            await registry.updateStatus(
                serverName: config.name,
                status: .error,
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }

    /// Call a tool on a connected MCP server.
    public func callTool(
        serverName: String,
        toolName: String,
        arguments: [String: JSONValue]
    ) async throws -> ToolResult {
        guard let client = clients[serverName] else {
            return .error("MCP server '\(serverName)' is not connected.")
        }

        let mcpArgs = arguments.mapValues { convertToMCPValue($0) }

        let (content, isError) = try await client.callTool(
            name: toolName,
            arguments: mcpArgs
        )

        let output = content.compactMap { block -> String? in
            if case .text(let text, _, _) = block {
                return text
            }
            return nil
        }.joined(separator: "\n")

        return ToolResult(output: output, isError: isError ?? false)
    }

    /// Disconnect from an MCP server.
    public func disconnect(serverName: String) async {
        if let client = clients.removeValue(forKey: serverName) {
            await client.disconnect()
        }
        if let process = processes.removeValue(forKey: serverName) {
            process.terminate()
        }
        await registry.updateStatus(serverName: serverName, status: .disconnected)
    }

    /// Disconnect from all servers.
    public func disconnectAll() async {
        for (name, client) in clients {
            await client.disconnect()
            await registry.updateStatus(serverName: name, status: .disconnected)
        }
        for (_, process) in processes {
            process.terminate()
        }
        clients.removeAll()
        processes.removeAll()
    }

    // MARK: - Stdio Server Launch

    /// Launch a subprocess MCP server and create a StdioTransport piped to it.
    private func launchStdioServer(
        name: String,
        command: String,
        args: [String],
        env: [String: String]?
    ) throws -> StdioTransport {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

        if let env {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in env {
                environment[key] = value
            }
            process.environment = environment
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        processes[name] = process

        // Create StdioTransport with the process's file descriptors
        let inputFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        let outputFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)

        return StdioTransport(input: inputFD, output: outputFD)
    }

    // MARK: - Value Conversion

    private func convertMCPValue(_ value: MCP.Value) -> JSONValue {
        switch value {
        case .object(let dict):
            return .object(dict.mapValues { convertMCPValue($0) })
        case .array(let arr):
            return .array(arr.map { convertMCPValue($0) })
        case .string(let s):
            return .string(s)
        case .int(let i):
            return .int(i)
        case .double(let d):
            return .double(d)
        case .bool(let b):
            return .bool(b)
        case .null:
            return .null
        case .data(_, let data):
            return .string(data.base64EncodedString())
        }
    }

    private func convertToMCPValue(_ value: JSONValue) -> MCP.Value {
        switch value {
        case .object(let dict):
            return .object(dict.mapValues { convertToMCPValue($0) })
        case .array(let arr):
            return .array(arr.map { convertToMCPValue($0) })
        case .string(let s):
            return .string(s)
        case .int(let i):
            return .int(i)
        case .double(let d):
            return .double(d)
        case .bool(let b):
            return .bool(b)
        case .null:
            return .null
        }
    }
}

public enum MCPConnectorError: Error, LocalizedError {
    case missingCommand(server: String)
    case missingURL(server: String)

    public var errorDescription: String? {
        switch self {
        case .missingCommand(let server):
            return "MCP server '\(server)' is configured as stdio but has no command."
        case .missingURL(let server):
            return "MCP server '\(server)' is configured as http/sse but has no URL."
        }
    }
}
