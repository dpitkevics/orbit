import Foundation

/// Actor managing the full agent tree with global tracking.
///
/// Provides visibility into all spawned agents, their relationships,
/// costs, and execution traces.
public actor AgentTree {
    public let root: AgentNode
    private var allNodes: [UUID: AgentNode]

    public init(root: AgentNode) {
        self.root = root
        self.allNodes = [root.id: root]
    }

    /// Register a newly spawned node in the tree.
    public func register(_ node: AgentNode) {
        allNodes[node.id] = node
    }

    /// Get a node by ID.
    public func node(id: UUID) -> AgentNode? {
        allNodes[id]
    }

    /// Total number of nodes in the tree.
    public var allNodeCount: Int {
        allNodes.count
    }

    /// Aggregate token usage across all nodes.
    public func totalCost() -> TokenUsage {
        allNodes.values.reduce(TokenUsage.zero) { $0 + $1.usage }
    }

    /// Total duration from root start to latest end time.
    public func totalDuration() -> TimeInterval {
        let latestEnd = allNodes.values.compactMap { $0.endTime }.max() ?? Date()
        return latestEnd.timeIntervalSince(root.startTime)
    }

    /// All nodes that failed.
    public func failedNodes() -> [AgentNode] {
        allNodes.values.filter { $0.status == .failed }
    }

    /// Nodes at a specific depth level.
    public func nodesAtDepth(_ depth: Int) -> [AgentNode] {
        allNodes.values.filter { $0.depth == depth }
    }

    /// Generate a text-based trace of the full tree.
    public func traceDescription() -> String {
        renderNode(root, indent: 0)
    }

    private func renderNode(_ node: AgentNode, indent: Int) -> String {
        let prefix = String(repeating: "  ", count: indent)
        let statusIcon = switch node.status {
        case .pending: "○"
        case .running: "▶"
        case .completed: "✓"
        case .failed: "✗"
        case .cancelled: "⊘"
        }

        var lines: [String] = []
        lines.append("\(prefix)\(statusIcon) [\(node.id.uuidString.prefix(8))] \(node.task)")

        if node.usage.totalTokens > 0 {
            lines.append("\(prefix)  tokens: \(node.usage.totalTokens)")
        }

        if let result = node.result, !result.success {
            lines.append("\(prefix)  error: \(result.output.prefix(80))")
        }

        for child in node.children {
            lines.append(renderNode(child, indent: indent + 1))
        }

        return lines.joined(separator: "\n")
    }
}
