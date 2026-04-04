import Foundation

/// Mode controlling which tools are visible to the LLM.
public enum ToolPoolMode: Sendable, Equatable {
    /// All registered tools (up to maxVisible cap).
    case full
    /// Restricted to bash, file_read, file_edit only.
    case simple
    /// Only the specified tool names.
    case restricted(allowed: Set<String>)
}

/// Manages the set of tools available to the LLM.
///
/// Filters tools based on mode, permissions, and a visibility cap
/// to prevent overwhelming the LLM's context window.
public struct ToolPool: Sendable {
    /// Maximum number of tools visible to the LLM at once.
    public static let defaultMaxVisible = 15

    private let tools: [String: any Tool]
    private let orderedNames: [String]
    public let maxVisible: Int

    public init(tools: [any Tool], maxVisible: Int = ToolPool.defaultMaxVisible) {
        var dict: [String: any Tool] = [:]
        var names: [String] = []
        for tool in tools {
            dict[tool.name] = tool
            names.append(tool.name)
        }
        self.tools = dict
        self.orderedNames = names
        self.maxVisible = maxVisible
    }

    /// Get a tool by name.
    public func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    /// All registered tool names.
    public var allNames: [String] { orderedNames }

    /// Total number of registered tools.
    public var count: Int { tools.count }

    /// Filter and return tools visible to the LLM based on mode and permissions.
    public func availableTools(
        mode: ToolPoolMode = .full,
        policy: PermissionPolicy
    ) -> [any Tool] {
        let filtered: [any Tool] = orderedNames.compactMap { name in
            guard let tool = tools[name] else { return nil }

            // Apply mode filter
            switch mode {
            case .full:
                break
            case .simple:
                let simpleTools: Set<String> = ["bash", "file_read", "file_edit"]
                guard simpleTools.contains(name) else { return nil }
            case .restricted(let allowed):
                guard allowed.contains(name) else { return nil }
            }

            // Apply permission filter — exclude tools that are denied by rules
            let outcome = policy.authorize(toolName: name, requiredMode: tool.requiredPermission)
            guard outcome.isAllowed else { return nil }

            return tool
        }

        // Cap at maxVisible
        return Array(filtered.prefix(maxVisible))
    }

    /// Get tool definitions suitable for sending to the LLM.
    public func definitions(
        mode: ToolPoolMode = .full,
        policy: PermissionPolicy
    ) -> [ToolDefinition] {
        availableTools(mode: mode, policy: policy).map { $0.toDefinition() }
    }
}

/// Registry that validates tool name uniqueness during construction.
public struct ToolRegistry: Sendable {
    private var tools: [any Tool] = []
    private var names: Set<String> = []

    public init() {}

    /// Register a tool. Throws if the name conflicts with an existing tool.
    public mutating func register(_ tool: any Tool) throws {
        guard !names.contains(tool.name) else {
            throw ToolRegistryError.duplicateName(tool.name)
        }
        names.insert(tool.name)
        tools.append(tool)
    }

    /// Build a ToolPool from all registered tools.
    public func buildPool(maxVisible: Int = ToolPool.defaultMaxVisible) -> ToolPool {
        ToolPool(tools: tools, maxVisible: maxVisible)
    }
}

public enum ToolRegistryError: Error, LocalizedError {
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateName(let name):
            return "Duplicate tool name: '\(name)'"
        }
    }
}
