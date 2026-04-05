import Foundation

/// Reference to a topic in the memory index.
public struct TopicRef: Codable, Sendable, Equatable, Hashable {
    public let slug: String
    public let title: String

    public init(slug: String, title: String) {
        self.slug = slug
        self.title = title
    }
}

/// Content of a memory topic.
public struct TopicContent: Codable, Sendable, Equatable {
    public let slug: String
    public let title: String
    public var body: String
    public var updatedAt: Date

    public init(slug: String, title: String, body: String, updatedAt: Date = Date()) {
        self.slug = slug
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }
}

/// A recent transcript entry (full content, not a search snippet).
public struct RecentTranscript: Sendable {
    public let sessionID: String
    public let content: String
    public let timestamp: Date

    public init(sessionID: String, content: String, timestamp: Date) {
        self.sessionID = sessionID
        self.content = content
        self.timestamp = timestamp
    }
}

/// A match from searching transcripts.
public struct TranscriptMatch: Codable, Sendable {
    public let sessionID: String
    public let snippet: String
    public let timestamp: Date

    public init(sessionID: String, snippet: String, timestamp: Date) {
        self.sessionID = sessionID
        self.snippet = snippet
        self.timestamp = timestamp
    }
}

/// Protocol for the 3-layer memory system.
///
/// - Layer 1: Memory index (lightweight, always loaded)
/// - Layer 2: Topic files (loaded on demand)
/// - Layer 3: Session transcripts (searchable, never loaded into context)
public protocol MemoryStore: Sendable {
    // Layer 1: Index
    func loadIndex(project: String) async throws -> [TopicRef]
    func updateIndex(project: String, refs: [TopicRef]) async throws

    // Layer 2: Topics
    func loadTopic(slug: String, project: String) async throws -> TopicContent?
    func saveTopic(_ topic: TopicContent, project: String) async throws
    func deleteTopic(slug: String, project: String) async throws
    func listTopics(project: String) async throws -> [TopicRef]

    // Layer 3: Transcripts
    func storeTranscript(sessionID: String, content: String, project: String) async throws
    func searchTranscripts(query: String, project: String, limit: Int) async throws -> [TranscriptMatch]

    // Context assembly — smart selection of relevant memory for the prompt
    func assembleContext(project: String, currentQuery: String, maxEntries: Int) async throws -> String
}
