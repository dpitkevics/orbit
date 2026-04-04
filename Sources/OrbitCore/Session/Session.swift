import Foundation

/// Persisted conversational state for a session.
public struct Session: Codable, Sendable {
    public static let currentVersion: UInt32 = 1

    public let version: UInt32
    public let sessionID: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var compaction: SessionCompaction?
    public var fork: SessionFork?

    public init(
        sessionID: String = UUID().uuidString,
        messages: [ChatMessage] = []
    ) {
        self.version = Self.currentVersion
        self.sessionID = sessionID
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = messages
        self.compaction = nil
        self.fork = nil
    }

    public mutating func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        updatedAt = Date()
    }

    public mutating func recordCompaction(summary: String, removedCount: Int) {
        let count = (compaction?.count ?? 0) + 1
        compaction = SessionCompaction(
            count: count,
            removedMessageCount: removedCount,
            summary: summary
        )
        updatedAt = Date()
    }

    /// Create a forked session linked to this one.
    public func fork(branchName: String? = nil) -> Session {
        var forked = Session(messages: messages)
        forked.fork = SessionFork(
            parentSessionID: sessionID,
            branchName: branchName
        )
        return forked
    }

    /// Estimated total tokens across all messages.
    public var estimatedTokens: Int {
        messages.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Count of messages by role.
    public var messageCount: Int { messages.count }
}

/// Metadata about the latest compaction.
public struct SessionCompaction: Codable, Sendable, Equatable {
    public let count: UInt32
    public let removedMessageCount: Int
    public let summary: String

    public init(count: UInt32, removedMessageCount: Int, summary: String) {
        self.count = count
        self.removedMessageCount = removedMessageCount
        self.summary = summary
    }
}

/// Provenance when a session is forked from another.
public struct SessionFork: Codable, Sendable, Equatable {
    public let parentSessionID: String
    public let branchName: String?

    public init(parentSessionID: String, branchName: String? = nil) {
        self.parentSessionID = parentSessionID
        self.branchName = branchName
    }
}

/// Summary used when listing sessions.
public struct SessionSummary: Codable, Sendable {
    public let sessionID: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messageCount: Int
    public let estimatedTokens: Int

    public init(from session: Session) {
        self.sessionID = session.sessionID
        self.createdAt = session.createdAt
        self.updatedAt = session.updatedAt
        self.messageCount = session.messageCount
        self.estimatedTokens = session.estimatedTokens
    }
}
