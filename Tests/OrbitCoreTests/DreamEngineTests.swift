import Foundation
import Testing
@testable import OrbitCore

@Suite("Dream Engine")
struct DreamEngineTests {
    func makeStore() throws -> SQLiteMemory {
        try SQLiteMemory()
    }

    // MARK: - Phase 1: Orient (extract observations from transcripts)

    @Test("Orient extracts observations from recent transcripts")
    func orientPhase() async throws {
        let store = try makeStore()
        try await store.storeTranscript(
            sessionID: "s1",
            content: "User asked about Q1 revenue. Revenue was $50K. Team size is 5.",
            project: "test"
        )
        try await store.storeTranscript(
            sessionID: "s2",
            content: "Discussed SEO strategy. Current ranking is #12 for main keyword.",
            project: "test"
        )

        let observations = try await DreamEngine.orient(
            store: store,
            project: "test",
            recentSessionCount: 10
        )

        #expect(!observations.isEmpty)
        #expect(observations.count >= 1)
    }

    // MARK: - Phase 2: Gather (load existing topics, identify conflicts)

    @Test("Gather loads existing topics")
    func gatherPhase() async throws {
        let store = try makeStore()
        try await store.saveTopic(
            TopicContent(slug: "revenue", title: "Revenue", body: "Q1: $40K"),
            project: "test"
        )
        try await store.saveTopic(
            TopicContent(slug: "team", title: "Team", body: "4 people"),
            project: "test"
        )

        let existing = try await DreamEngine.gather(store: store, project: "test")
        #expect(existing.count == 2)
    }

    @Test("Gather returns empty for project with no topics")
    func gatherEmpty() async throws {
        let store = try makeStore()
        let existing = try await DreamEngine.gather(store: store, project: "empty")
        #expect(existing.isEmpty)
    }

    // MARK: - Phase 3: Consolidate (merge observations into topics)

    @Test("Consolidate creates new topics from observations")
    func consolidateCreatesTopics() async throws {
        let store = try makeStore()
        let observations = [
            DreamObservation(content: "Team size is 5 people", source: "s1"),
            DreamObservation(content: "Revenue for Q1 was $50K", source: "s1"),
        ]

        let result = try await DreamEngine.consolidate(
            observations: observations,
            existingTopics: [],
            store: store,
            project: "test"
        )

        #expect(result.topicsCreated > 0)
    }

    @Test("Consolidate updates existing topics with new observations")
    func consolidateUpdatesTopics() async throws {
        let store = try makeStore()
        let existing = [
            TopicContent(slug: "revenue", title: "Revenue", body: "Q1: $40K"),
        ]
        let observations = [
            DreamObservation(content: "Revenue was actually $50K for Q1", source: "s2"),
        ]

        let result = try await DreamEngine.consolidate(
            observations: observations,
            existingTopics: existing,
            store: store,
            project: "test"
        )

        #expect(result.topicsUpdated > 0 || result.topicsCreated > 0)
    }

    // MARK: - Phase 4: Prune (remove stale, update index)

    @Test("Prune updates memory index to match topics")
    func pruneUpdatesIndex() async throws {
        let store = try makeStore()
        try await store.saveTopic(
            TopicContent(slug: "active", title: "Active Topic", body: "Still relevant"),
            project: "test"
        )

        try await DreamEngine.prune(store: store, project: "test", maxTopicSize: 10_000)

        let index = try await store.loadIndex(project: "test")
        #expect(index.count == 1)
        #expect(index[0].slug == "active")
    }

    @Test("Prune trims oversized topics")
    func pruneTrimOversized() async throws {
        let store = try makeStore()
        let longBody = String(repeating: "x", count: 5000)
        try await store.saveTopic(
            TopicContent(slug: "big", title: "Big Topic", body: longBody),
            project: "test"
        )

        try await DreamEngine.prune(store: store, project: "test", maxTopicSize: 1000)

        let topic = try await store.loadTopic(slug: "big", project: "test")
        #expect((topic?.body.count ?? 0) <= 1100) // Allow for truncation suffix
    }

    // MARK: - Full Dream Cycle

    @Test("DreamReport captures all phase metrics")
    func dreamReport() {
        let report = DreamReport(
            project: "test",
            transcriptsScanned: 5,
            observationsExtracted: 12,
            conflictsFound: 2,
            conflictsResolved: 1,
            topicsCreated: 3,
            topicsUpdated: 4,
            entriesPruned: 1,
            duration: 2.5
        )
        #expect(report.transcriptsScanned == 5)
        #expect(report.observationsExtracted == 12)
        #expect(report.duration == 2.5)
    }

    @Test("DreamObservation stores content and source")
    func dreamObservation() {
        let obs = DreamObservation(content: "Team size is 5", source: "session-123")
        #expect(obs.content == "Team size is 5")
        #expect(obs.source == "session-123")
    }
}

@Suite("Deep Task")
struct DeepTaskTests {
    @Test("DeepTask initialization")
    func deepTaskInit() {
        let task = DeepTask(
            name: "Q1 Analysis",
            prompt: "Analyze Q1 performance across all projects",
            projects: ["alpha", "beta"]
        )
        #expect(task.name == "Q1 Analysis")
        #expect(task.projects.count == 2)
        #expect(task.status == .pending)
    }

    @Test("DeepTask status transitions")
    func deepTaskStatusTransitions() {
        var task = DeepTask(name: "Test", prompt: "Test prompt", projects: ["p"])
        #expect(task.status == .pending)

        task.status = .running
        #expect(task.status == .running)

        task.status = .completed
        #expect(task.status == .completed)
    }

    @Test("DeepTaskStatus all values")
    func deepTaskStatuses() {
        let statuses: [DeepTaskStatus] = [.pending, .running, .completed, .failed, .reviewPending]
        #expect(statuses.count == 5)
    }

    @Test("DeepTask result storage")
    func deepTaskResult() {
        var task = DeepTask(name: "Test", prompt: "Analyze", projects: ["p"])
        task.result = "Analysis complete: revenue up 15%"
        task.status = .completed
        #expect(task.result?.contains("15%") == true)
    }
}
