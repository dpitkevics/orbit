import Foundation
import GRDB

/// SQLite-backed implementation of the 3-layer memory system.
///
/// Uses GRDB.swift with FTS5 for full-text transcript search.
public final class SQLiteMemory: MemoryStore, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        let expandedPath = (path as NSString).expandingTildeInPath
        let dir = (expandedPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        dbQueue = try DatabaseQueue(path: expandedPath)
        try migrate()
    }

    /// In-memory database for testing.
    public init() throws {
        dbQueue = try DatabaseQueue()
        try migrate()
    }

    private func migrate() throws {
        try dbQueue.write { db in
            // Layer 1: Memory index
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS memory_index (
                    project TEXT NOT NULL,
                    slug TEXT NOT NULL,
                    title TEXT NOT NULL,
                    PRIMARY KEY (project, slug)
                )
                """)

            // Layer 2: Topics
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS topics (
                    project TEXT NOT NULL,
                    slug TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    embedding BLOB,
                    PRIMARY KEY (project, slug)
                )
                """)

            // Layer 3: Transcripts
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS transcripts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    project TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    content TEXT NOT NULL,
                    timestamp REAL NOT NULL
                )
                """)

            // FTS5 virtual table for transcript search
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
                    content,
                    content='transcripts',
                    content_rowid='id'
                )
                """)

            // Triggers to keep FTS in sync
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS transcripts_ai AFTER INSERT ON transcripts BEGIN
                    INSERT INTO transcripts_fts(rowid, content) VALUES (new.id, new.content);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS transcripts_ad AFTER DELETE ON transcripts BEGIN
                    INSERT INTO transcripts_fts(transcripts_fts, rowid, content) VALUES('delete', old.id, old.content);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS transcripts_au AFTER UPDATE ON transcripts BEGIN
                    INSERT INTO transcripts_fts(transcripts_fts, rowid, content) VALUES('delete', old.id, old.content);
                    INSERT INTO transcripts_fts(rowid, content) VALUES (new.id, new.content);
                END
                """)
        }
    }

    // MARK: - Layer 1: Index

    public func loadIndex(project: String) async throws -> [TopicRef] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT slug, title FROM memory_index WHERE project = ? ORDER BY slug
                """, arguments: [project])
            return rows.map { TopicRef(slug: $0["slug"], title: $0["title"]) }
        }
    }

    public func updateIndex(project: String, refs: [TopicRef]) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memory_index WHERE project = ?", arguments: [project])
            for ref in refs {
                try db.execute(sql: """
                    INSERT INTO memory_index (project, slug, title) VALUES (?, ?, ?)
                    """, arguments: [project, ref.slug, ref.title])
            }
        }
    }

    // MARK: - Layer 2: Topics

    public func loadTopic(slug: String, project: String) async throws -> TopicContent? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT slug, title, body, updated_at FROM topics WHERE project = ? AND slug = ?
                """, arguments: [project, slug]) else {
                return nil
            }
            let timestamp: Double = row["updated_at"]
            return TopicContent(
                slug: row["slug"],
                title: row["title"],
                body: row["body"],
                updatedAt: Date(timeIntervalSince1970: timestamp)
            )
        }
    }

    public func saveTopic(_ topic: TopicContent, project: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO topics (project, slug, title, body, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    project,
                    topic.slug,
                    topic.title,
                    topic.body,
                    topic.updatedAt.timeIntervalSince1970,
                ])
        }
    }

    public func deleteTopic(slug: String, project: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM topics WHERE project = ? AND slug = ?",
                           arguments: [project, slug])
        }
    }

    public func listTopics(project: String) async throws -> [TopicRef] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT slug, title FROM topics WHERE project = ? ORDER BY slug
                """, arguments: [project])
            return rows.map { TopicRef(slug: $0["slug"], title: $0["title"]) }
        }
    }

    // MARK: - Embeddings (Optional Vector Layer)

    /// Save an embedding vector for a topic.
    public func saveTopicEmbedding(slug: String, project: String, vector: [Float]) async throws {
        let data = serializeVector(vector)
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE topics SET embedding = ? WHERE project = ? AND slug = ?
                """, arguments: [data, project, slug])
        }
    }

    /// Load the embedding vector for a topic, if one exists.
    public func loadTopicEmbedding(slug: String, project: String) async throws -> [Float]? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT embedding FROM topics WHERE project = ? AND slug = ?
                """, arguments: [project, slug]) else {
                return nil
            }
            guard let data: Data = row["embedding"] else {
                return nil
            }
            return deserializeVector(data)
        }
    }

    /// Compute and store embeddings for all topics that don't have one.
    public func embedAllTopics(project: String, provider: any EmbeddingProvider) async throws -> Int {
        let refs = try await listTopics(project: project)
        var count = 0

        for ref in refs {
            let existing = try await loadTopicEmbedding(slug: ref.slug, project: project)
            if existing != nil { continue }

            guard let topic = try await loadTopic(slug: ref.slug, project: project) else { continue }
            let text = "\(topic.title)\n\(topic.body)"
            let vector = try await provider.embed(text)
            try await saveTopicEmbedding(slug: ref.slug, project: project, vector: vector)
            count += 1
        }

        return count
    }

    // MARK: - Layer 3: Transcripts

    public func storeTranscript(sessionID: String, content: String, project: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts (project, session_id, content, timestamp)
                VALUES (?, ?, ?, ?)
                """, arguments: [project, sessionID, content, Date().timeIntervalSince1970])
        }
    }

    public func searchTranscripts(query: String, project: String, limit: Int) async throws -> [TranscriptMatch] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.session_id, snippet(transcripts_fts, 0, '**', '**', '...', 32) as snippet, t.timestamp
                FROM transcripts_fts fts
                JOIN transcripts t ON t.id = fts.rowid
                WHERE fts.content MATCH ? AND t.project = ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [query, project, limit])
            return rows.map {
                let timestamp: Double = $0["timestamp"]
                return TranscriptMatch(
                    sessionID: $0["session_id"],
                    snippet: $0["snippet"],
                    timestamp: Date(timeIntervalSince1970: timestamp)
                )
            }
        }
    }

    /// Load recent transcripts ordered by timestamp descending (for DreamEngine orient phase).
    public func recentTranscripts(project: String, limit: Int) async throws -> [RecentTranscript] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT session_id, content, timestamp FROM transcripts
                WHERE project = ?
                ORDER BY timestamp DESC
                LIMIT ?
                """, arguments: [project, limit])
            return rows.map {
                let timestamp: Double = $0["timestamp"]
                return RecentTranscript(
                    sessionID: $0["session_id"],
                    content: $0["content"],
                    timestamp: Date(timeIntervalSince1970: timestamp)
                )
            }
        }
    }

    // MARK: - Context Assembly

    public func assembleContext(project: String, currentQuery: String, maxEntries: Int) async throws -> String {
        // Load the full index (Layer 1)
        let index = try await loadIndex(project: project)

        if index.isEmpty {
            return ""
        }

        // Load topic bodies (Layer 2) up to maxEntries
        var sections: [String] = []
        for ref in index.prefix(maxEntries) {
            if let topic = try await loadTopic(slug: ref.slug, project: project) {
                sections.append("## \(topic.title)\n\(topic.body)")
            }
        }

        if sections.isEmpty {
            return ""
        }

        return "# Memory\n\n" + sections.joined(separator: "\n\n")
    }
}
