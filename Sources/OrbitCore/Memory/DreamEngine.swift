import Foundation

/// An observation extracted from a transcript during the Orient phase.
public struct DreamObservation: Sendable {
    public let content: String
    public let source: String

    public init(content: String, source: String) {
        self.content = content
        self.source = source
    }
}

/// Report of a completed dream cycle.
public struct DreamReport: Codable, Sendable {
    public let timestamp: Date
    public let project: String
    public let transcriptsScanned: Int
    public let observationsExtracted: Int
    public let conflictsFound: Int
    public let conflictsResolved: Int
    public let topicsCreated: Int
    public let topicsUpdated: Int
    public let entriesPruned: Int
    public let duration: TimeInterval

    public init(
        project: String,
        transcriptsScanned: Int = 0,
        observationsExtracted: Int = 0,
        conflictsFound: Int = 0,
        conflictsResolved: Int = 0,
        topicsCreated: Int = 0,
        topicsUpdated: Int = 0,
        entriesPruned: Int = 0,
        duration: TimeInterval = 0
    ) {
        self.timestamp = Date()
        self.project = project
        self.transcriptsScanned = transcriptsScanned
        self.observationsExtracted = observationsExtracted
        self.conflictsFound = conflictsFound
        self.conflictsResolved = conflictsResolved
        self.topicsCreated = topicsCreated
        self.topicsUpdated = topicsUpdated
        self.entriesPruned = entriesPruned
        self.duration = duration
    }
}

/// 4-phase memory consolidation engine.
///
/// - Phase 1 **Orient**: Scan recent transcripts for new observations
/// - Phase 2 **Gather**: Load all topic files, identify potential conflicts
/// - Phase 3 **Consolidate**: Merge observations into topics, resolve contradictions
/// - Phase 4 **Prune**: Remove stale entries, trim oversized topics, update index
public enum DreamEngine {

    /// Run the full 4-phase dream cycle.
    public static func dream(
        store: SQLiteMemory,
        project: String,
        recentSessionCount: Int = 20,
        maxTopicSize: Int = 5_000
    ) async throws -> DreamReport {
        let startTime = Date()

        // Phase 1: Orient
        let observations = try await orient(
            store: store,
            project: project,
            recentSessionCount: recentSessionCount
        )

        // Phase 2: Gather
        let existingTopics = try await gather(store: store, project: project)

        // Phase 3: Consolidate
        let consolidationResult = try await consolidate(
            observations: observations,
            existingTopics: existingTopics,
            store: store,
            project: project
        )

        // Phase 4: Prune
        let pruneResult = try await prune(
            store: store,
            project: project,
            maxTopicSize: maxTopicSize
        )

        let duration = Date().timeIntervalSince(startTime)

        return DreamReport(
            project: project,
            transcriptsScanned: recentSessionCount,
            observationsExtracted: observations.count,
            conflictsFound: consolidationResult.conflictsFound,
            conflictsResolved: consolidationResult.conflictsResolved,
            topicsCreated: consolidationResult.topicsCreated,
            topicsUpdated: consolidationResult.topicsUpdated,
            entriesPruned: pruneResult,
            duration: duration
        )
    }

    // MARK: - Phase 1: Orient

    /// Scan recent transcripts and extract factual observations.
    public static func orient(
        store: SQLiteMemory,
        project: String,
        recentSessionCount: Int
    ) async throws -> [DreamObservation] {
        // Load recent transcripts directly (not via FTS5 search)
        let transcripts = try await store.recentTranscripts(
            project: project,
            limit: recentSessionCount
        )

        // Extract observations from transcript content
        var observations: [DreamObservation] = []
        for transcript in transcripts {
            let sentences = transcript.content
                .components(separatedBy: ".")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 10 }

            for sentence in sentences {
                observations.append(DreamObservation(
                    content: sentence,
                    source: transcript.sessionID
                ))
            }
        }

        return observations
    }

    // MARK: - Phase 2: Gather

    /// Load all existing topics for the project.
    public static func gather(
        store: SQLiteMemory,
        project: String
    ) async throws -> [TopicContent] {
        let refs = try await store.listTopics(project: project)
        var topics: [TopicContent] = []
        for ref in refs {
            if let topic = try await store.loadTopic(slug: ref.slug, project: project) {
                topics.append(topic)
            }
        }
        return topics
    }

    // MARK: - Phase 3: Consolidate

    /// Merge observations into existing or new topics.
    public static func consolidate(
        observations: [DreamObservation],
        existingTopics: [TopicContent],
        store: SQLiteMemory,
        project: String
    ) async throws -> ConsolidationResult {
        var created = 0
        var updated = 0
        var conflictsFound = 0
        var conflictsResolved = 0

        // Group observations by rough topic similarity
        for observation in observations {
            // Try to match to an existing topic by keyword overlap
            var matched = false
            for existing in existingTopics {
                let overlap = keywordOverlap(observation.content, existing.body)
                if overlap > 0.2 {
                    // Check for contradiction
                    if containsContradiction(observation.content, existing.body) {
                        conflictsFound += 1
                        // Resolve by appending with note
                        var updatedTopic = existing
                        updatedTopic.body += "\n\nUpdated: \(observation.content)"
                        updatedTopic.updatedAt = Date()
                        try await store.saveTopic(updatedTopic, project: project)
                        conflictsResolved += 1
                    } else {
                        // Append observation to topic
                        var updatedTopic = existing
                        updatedTopic.body += "\n\(observation.content)"
                        updatedTopic.updatedAt = Date()
                        try await store.saveTopic(updatedTopic, project: project)
                    }
                    updated += 1
                    matched = true
                    break
                }
            }

            if !matched && !observation.content.contains("no notable observations") {
                // Create new topic from observation
                let slug = slugify(observation.content)
                let title = String(observation.content.prefix(60))
                let topic = TopicContent(
                    slug: slug,
                    title: title,
                    body: observation.content
                )
                try await store.saveTopic(topic, project: project)
                created += 1
            }
        }

        return ConsolidationResult(
            topicsCreated: created,
            topicsUpdated: updated,
            conflictsFound: conflictsFound,
            conflictsResolved: conflictsResolved
        )
    }

    // MARK: - Phase 4: Prune

    /// Remove stale entries, trim oversized topics, rebuild index.
    @discardableResult
    public static func prune(
        store: SQLiteMemory,
        project: String,
        maxTopicSize: Int
    ) async throws -> Int {
        let refs = try await store.listTopics(project: project)
        var pruned = 0

        for ref in refs {
            guard var topic = try await store.loadTopic(slug: ref.slug, project: project) else {
                continue
            }

            // Trim oversized topics
            if topic.body.count > maxTopicSize {
                topic.body = String(topic.body.prefix(maxTopicSize)) + "\n... (trimmed by autoDream)"
                topic.updatedAt = Date()
                try await store.saveTopic(topic, project: project)
                pruned += 1
            }
        }

        // Rebuild index from current topics
        let currentRefs = try await store.listTopics(project: project)
        try await store.updateIndex(project: project, refs: currentRefs)

        return pruned
    }

    // MARK: - Helpers

    /// Simple keyword overlap score between two texts (0.0 to 1.0).
    private static func keywordOverlap(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(separator: " ").map(String.init))
        let wordsB = Set(b.lowercased().split(separator: " ").map(String.init))
        guard !wordsA.isEmpty else { return 0 }
        let intersection = wordsA.intersection(wordsB)
        return Double(intersection.count) / Double(wordsA.count)
    }

    /// Simple contradiction detection based on number keywords.
    private static func containsContradiction(_ new: String, _ existing: String) -> Bool {
        let numberPattern = try? NSRegularExpression(pattern: "\\$?[\\d,]+\\.?\\d*[KkMm]?")
        guard let regex = numberPattern else { return false }

        let newNumbers = regex.matches(in: new, range: NSRange(new.startIndex..., in: new))
            .compactMap { Range($0.range, in: new).map { String(new[$0]) } }
        let existingNumbers = regex.matches(in: existing, range: NSRange(existing.startIndex..., in: existing))
            .compactMap { Range($0.range, in: existing).map { String(existing[$0]) } }

        // If both mention numbers and they differ, likely a contradiction
        for newNum in newNumbers {
            for existNum in existingNumbers where newNum != existNum {
                // Same magnitude context suggests contradiction
                return true
            }
        }

        return false
    }

    /// Generate a URL-safe slug from text.
    private static func slugify(_ text: String) -> String {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
        return words.joined(separator: "-")
    }
}

/// Result from the consolidation phase.
public struct ConsolidationResult: Sendable {
    public let topicsCreated: Int
    public let topicsUpdated: Int
    public let conflictsFound: Int
    public let conflictsResolved: Int
}
