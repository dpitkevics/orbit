import Foundation

/// Graduated permission levels controlling what tools can do.
/// Ordered from most restrictive to most permissive.
public enum PermissionMode: String, Codable, Sendable, Comparable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    private var rank: Int {
        switch self {
        case .readOnly: return 0
        case .workspaceWrite: return 1
        case .dangerFullAccess: return 2
        }
    }

    public static func < (lhs: PermissionMode, rhs: PermissionMode) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Rule-based permission override for specific tools.
public struct PermissionRule: Codable, Sendable, Equatable {
    /// Tool name pattern. Exact match or prefix with `*` (e.g., "mcp__*").
    public let toolPattern: String

    public init(toolPattern: String) {
        self.toolPattern = toolPattern
    }

    /// Check whether this rule matches a given tool name.
    public func matches(_ toolName: String) -> Bool {
        if toolPattern.hasSuffix("*") {
            let prefix = String(toolPattern.dropLast())
            return toolName.hasPrefix(prefix)
        }
        return toolName == toolPattern
    }
}

/// Policy that evaluates whether a tool invocation is allowed.
public struct PermissionPolicy: Codable, Sendable {
    public var activeMode: PermissionMode
    public var allowRules: [PermissionRule]
    public var denyRules: [PermissionRule]

    public init(
        activeMode: PermissionMode = .workspaceWrite,
        allowRules: [PermissionRule] = [],
        denyRules: [PermissionRule] = []
    ) {
        self.activeMode = activeMode
        self.allowRules = allowRules
        self.denyRules = denyRules
    }

    /// Evaluate whether a tool can execute under this policy.
    public func authorize(
        toolName: String,
        requiredMode: PermissionMode
    ) -> PermissionOutcome {
        // Deny rules take priority
        if denyRules.contains(where: { $0.matches(toolName) }) {
            return .deny(reason: "Tool '\(toolName)' is blocked by a deny rule.")
        }

        // Allow rules override mode checks
        if allowRules.contains(where: { $0.matches(toolName) }) {
            return .allow
        }

        // Check mode
        if activeMode >= requiredMode {
            return .allow
        }

        return .deny(reason: "Tool '\(toolName)' requires '\(requiredMode.rawValue)' but active mode is '\(activeMode.rawValue)'.")
    }
}

/// Result of a permission check.
public enum PermissionOutcome: Sendable, Equatable {
    case allow
    case deny(reason: String)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// Protocol for interactive permission prompting in the terminal.
public protocol PermissionPrompter: Sendable {
    func prompt(toolName: String, input: String, reason: String) async -> Bool
}

/// Enforcer that combines policy checks with workspace boundary validation.
public struct PermissionEnforcer: Sendable {
    public let policy: PermissionPolicy
    public let workspaceRoot: String?

    public init(policy: PermissionPolicy, workspaceRoot: String? = nil) {
        self.policy = policy
        self.workspaceRoot = workspaceRoot
    }

    public func check(toolName: String, requiredMode: PermissionMode) -> PermissionOutcome {
        policy.authorize(toolName: toolName, requiredMode: requiredMode)
    }

    /// Validate a file write is within workspace boundaries.
    public func checkFileWrite(path: String) -> PermissionOutcome {
        let baseResult = policy.authorize(toolName: "file_write", requiredMode: .workspaceWrite)
        guard baseResult.isAllowed else { return baseResult }

        if policy.activeMode == .workspaceWrite, let root = workspaceRoot {
            let resolvedPath = (path as NSString).standardizingPath
            let resolvedRoot = (root as NSString).standardizingPath
            if !resolvedPath.hasPrefix(resolvedRoot) {
                return .deny(reason: "Path '\(path)' is outside workspace root '\(root)'.")
            }
        }

        return .allow
    }
}
