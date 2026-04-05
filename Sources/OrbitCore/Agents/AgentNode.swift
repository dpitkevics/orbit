import Foundation

/// Status of an agent in the tree.
public enum AgentStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

/// Memory access level for sub-agents.
public enum MemoryAccessLevel: String, Codable, Sendable {
    case full
    case readOnly
    case none
}

/// Result of an agent's execution.
public struct AgentResult: Sendable {
    public let output: String
    public let usage: TokenUsage
    public let success: Bool

    public init(output: String, usage: TokenUsage = .zero, success: Bool = true) {
        self.output = output
        self.usage = usage
        self.success = success
    }
}

/// Entry in an agent's execution trace.
public struct TraceEntry: Sendable {
    public let timestamp: Date
    public let type: TraceType
    public let content: String
    public let metadata: JSONValue?

    public init(type: TraceType, content: String, metadata: JSONValue? = nil) {
        self.timestamp = Date()
        self.type = type
        self.content = content
        self.metadata = metadata
    }
}

/// Type of trace entry.
public enum TraceType: String, Codable, Sendable {
    case toolCall
    case toolResult
    case llmCall
    case llmResponse
    case spawn
    case error
}

/// A node in the hierarchical agent tree.
///
/// Each agent knows its parent and children. The tree provides complete
/// visibility into what happened during complex operations.
public final class AgentNode: @unchecked Sendable {
    public let id: UUID
    public let parentID: UUID?
    public let task: String
    public let project: String
    public let depth: Int
    public let maxDepth: Int
    public let memoryAccess: MemoryAccessLevel
    public let startTime: Date

    public private(set) var children: [AgentNode] = []
    public private(set) var status: AgentStatus = .pending
    public private(set) var result: AgentResult?
    public private(set) var trace: [TraceEntry] = []
    public private(set) var usage: TokenUsage = .zero
    public private(set) var endTime: Date?

    public init(
        task: String,
        project: String,
        parentID: UUID? = nil,
        depth: Int = 0,
        maxDepth: Int = 5,
        memoryAccess: MemoryAccessLevel = .full
    ) {
        self.id = UUID()
        self.parentID = parentID
        self.task = task
        self.project = project
        self.depth = depth
        self.maxDepth = maxDepth
        self.memoryAccess = memoryAccess
        self.startTime = Date()
    }

    /// Spawn a child agent. Throws if depth limit would be exceeded.
    public func spawn(
        task: String,
        memoryAccess: MemoryAccessLevel? = nil
    ) throws -> AgentNode {
        let childDepth = depth + 1
        guard childDepth <= maxDepth else {
            throw AgentError.maxDepthExceeded(depth: childDepth, max: maxDepth)
        }

        let child = AgentNode(
            task: task,
            project: project,
            parentID: id,
            depth: childDepth,
            maxDepth: maxDepth,
            memoryAccess: memoryAccess ?? self.memoryAccess
        )

        children.append(child)
        recordTrace(.spawn, content: "Spawned child: \(task)")
        return child
    }

    // MARK: - Status Transitions

    public func markRunning() {
        status = .running
    }

    public func markCompleted(output: String, usage: TokenUsage) {
        status = .completed
        result = AgentResult(output: output, usage: usage, success: true)
        self.usage = usage
        endTime = Date()
    }

    public func markFailed(error: String) {
        status = .failed
        result = AgentResult(output: error, usage: usage, success: false)
        endTime = Date()
    }

    public func markCancelled() {
        status = .cancelled
        endTime = Date()
    }

    // MARK: - Trace

    public func recordTrace(_ type: TraceType, content: String, metadata: JSONValue? = nil) {
        trace.append(TraceEntry(type: type, content: content, metadata: metadata))
    }

    /// Duration from start to end (or now if still running).
    public var duration: TimeInterval {
        let end = endTime ?? Date()
        return end.timeIntervalSince(startTime)
    }
}

/// Errors from the agent system.
public enum AgentError: Error, LocalizedError {
    case maxDepthExceeded(depth: Int, max: Int)

    public var errorDescription: String? {
        switch self {
        case .maxDepthExceeded(let depth, let max):
            return "Agent depth \(depth) exceeds maximum of \(max)."
        }
    }
}
