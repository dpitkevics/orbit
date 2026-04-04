import Foundation

/// Category grouping for tools.
public enum ToolCategory: String, Codable, Sendable {
    case fileIO
    case execution
    case search
    case network
    case desktop
    case agent
    case planning
    case mcp
    case plugin
}

/// Protocol for all tools in Orbit.
///
/// Each tool is a self-contained capability with a JSON Schema definition,
/// a required permission level, and an execute method.
public protocol Tool: Sendable {
    /// Unique tool name (used in LLM tool calls).
    var name: String { get }

    /// Human-readable description for the LLM.
    var description: String { get }

    /// Tool category for grouping and filtering.
    var category: ToolCategory { get }

    /// JSON Schema defining the tool's input parameters.
    var inputSchema: JSONValue { get }

    /// Minimum permission level required to execute this tool.
    var requiredPermission: PermissionMode { get }

    /// Execute the tool with the given input.
    func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult
}

/// Context provided to tools during execution.
public struct ToolContext: Sendable {
    /// Current working directory / workspace root.
    public let workspaceRoot: URL

    /// Active project slug.
    public let project: String

    /// Permission enforcer for nested checks (e.g., bash checking file writes).
    public let enforcer: PermissionEnforcer

    public init(workspaceRoot: URL, project: String, enforcer: PermissionEnforcer) {
        self.workspaceRoot = workspaceRoot
        self.project = project
        self.enforcer = enforcer
    }
}

/// Result from executing a tool.
public struct ToolResult: Sendable, Equatable {
    public let output: String
    public let isError: Bool

    public init(output: String, isError: Bool = false) {
        self.output = output
        self.isError = isError
    }

    public static func success(_ output: String) -> ToolResult {
        ToolResult(output: output)
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(output: message, isError: true)
    }
}

/// Convert a `Tool` to a `ToolDefinition` for sending to the LLM.
extension Tool {
    public func toDefinition() -> ToolDefinition {
        ToolDefinition(name: name, description: description, inputSchema: inputSchema)
    }
}
