import Foundation
import Crypto

/// Connection status of a managed MCP server.
public enum MCPConnectionStatus: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case error
}

/// Metadata about an MCP tool exposed by a server.
public struct MCPToolInfo: Codable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: JSONValue?

    public init(name: String, description: String?, inputSchema: JSONValue?) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Tracked state of an MCP server connection.
public struct MCPServerState: Sendable {
    public let serverName: String
    public var status: MCPConnectionStatus
    public var tools: [MCPToolInfo]
    public var errorMessage: String?

    public init(
        serverName: String,
        status: MCPConnectionStatus,
        tools: [MCPToolInfo] = [],
        errorMessage: String? = nil
    ) {
        self.serverName = serverName
        self.status = status
        self.tools = tools
        self.errorMessage = errorMessage
    }
}

/// Transport type for MCP server connections.
public enum MCPTransportType: String, Codable, Sendable {
    case stdio
    case http
    case sse
}

/// Configuration for an MCP server from TOML config.
public struct MCPServerConfig: Codable, Sendable {
    public let name: String
    public let transport: MCPTransportType
    public let command: String?
    public let args: [String]?
    public let url: String?
    public let headers: [String: String]?
    public let env: [String: String]?

    public init(
        name: String,
        transport: MCPTransportType,
        command: String? = nil,
        args: [String]? = nil,
        url: String? = nil,
        headers: [String: String]? = nil,
        env: [String: String]? = nil
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.headers = headers
        self.env = env
    }
}

// MARK: - Name Normalization (from Claw Code mcp.rs)

/// MCP naming conventions for tool name normalization and prefixing.
public enum MCPNaming {
    private static let claudeAIPrefix = "claude.ai "

    /// Normalize a server or tool name for the MCP naming convention.
    /// Replaces non-alphanumeric characters (except `_` and `-`) with `_`.
    /// For `claude.ai` prefixed servers, collapses underscores and trims.
    public static func normalize(_ name: String) -> String {
        var normalized = String(name.map { ch in
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                return ch
            }
            return "_" as Character
        })

        if name.hasPrefix(claudeAIPrefix) {
            normalized = collapseUnderscores(normalized)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }

        return normalized
    }

    /// Generate the tool name prefix for a server: `mcp__{server}__`
    public static func toolPrefix(server: String) -> String {
        "mcp__\(normalize(server))__"
    }

    /// Generate a fully qualified tool name: `mcp__{server}__{tool}`
    public static func toolName(server: String, tool: String) -> String {
        "\(toolPrefix(server: server))\(normalize(tool))"
    }

    /// Parse a prefixed tool name back into server and tool components.
    /// Returns `(nil, nil)` for non-MCP tool names.
    public static func parse(prefixedName: String) -> (server: String?, tool: String?) {
        guard prefixedName.hasPrefix("mcp__") else {
            return (nil, nil)
        }

        let withoutPrefix = String(prefixedName.dropFirst(5)) // drop "mcp__"
        guard let separatorRange = withoutPrefix.range(of: "__") else {
            return (nil, nil)
        }

        let server = String(withoutPrefix[..<separatorRange.lowerBound])
        let tool = String(withoutPrefix[separatorRange.upperBound...])

        return (server, tool)
    }

    private static func collapseUnderscores(_ s: String) -> String {
        var result = ""
        var prevWasUnderscore = false
        for ch in s {
            if ch == "_" {
                if !prevWasUnderscore {
                    result.append(ch)
                }
                prevWasUnderscore = true
            } else {
                result.append(ch)
                prevWasUnderscore = false
            }
        }
        return result
    }
}

// MARK: - Config Hashing (from Claw Code mcp.rs)

/// Deterministic hashing of MCP server configs for identity comparison.
public enum MCPConfigHash {
    /// Generate a hex hash of an MCP server config.
    /// Used to detect when a config has changed and needs reconnection.
    public static func hash(config: MCPServerConfig) -> String {
        let rendered: String
        switch config.transport {
        case .stdio:
            rendered = "stdio|\(config.command ?? "")|\(renderArgs(config.args))|\(renderEnv(config.env))"
        case .http:
            rendered = "http|\(config.url ?? "")|\(renderHeaders(config.headers))"
        case .sse:
            rendered = "sse|\(config.url ?? "")|\(renderHeaders(config.headers))"
        }

        let digest = SHA256.hash(data: Data(rendered.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func renderArgs(_ args: [String]?) -> String {
        guard let args else { return "[]" }
        return "[\(args.joined(separator: "|"))]"
    }

    private static func renderEnv(_ env: [String: String]?) -> String {
        guard let env else { return "" }
        return env.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    private static func renderHeaders(_ headers: [String: String]?) -> String {
        guard let headers else { return "" }
        return headers.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }
}
