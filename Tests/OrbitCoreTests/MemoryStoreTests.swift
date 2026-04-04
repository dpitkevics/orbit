import Foundation
import Testing
@testable import OrbitCore

@Suite("SQLite Memory Store")
struct MemoryStoreTests {
    func makeStore() throws -> SQLiteMemory {
        try SQLiteMemory() // In-memory database
    }

    // MARK: - Layer 1: Index

    @Test("Save and load memory index")
    func indexRoundtrip() async throws {
        let store = try makeStore()
        let refs = [
            TopicRef(slug: "team", title: "Team Members"),
            TopicRef(slug: "goals", title: "Q2 Goals"),
        ]

        try await store.updateIndex(project: "test", refs: refs)
        let loaded = try await store.loadIndex(project: "test")

        #expect(loaded.count == 2)
        #expect(loaded[0].slug == "goals") // sorted by slug
        #expect(loaded[1].slug == "team")
    }

    @Test("Index is project-scoped")
    func indexProjectScoped() async throws {
        let store = try makeStore()
        try await store.updateIndex(project: "alpha", refs: [TopicRef(slug: "a", title: "Alpha")])
        try await store.updateIndex(project: "beta", refs: [TopicRef(slug: "b", title: "Beta")])

        let alpha = try await store.loadIndex(project: "alpha")
        let beta = try await store.loadIndex(project: "beta")

        #expect(alpha.count == 1)
        #expect(alpha[0].slug == "a")
        #expect(beta.count == 1)
        #expect(beta[0].slug == "b")
    }

    @Test("Update index replaces previous entries")
    func indexReplace() async throws {
        let store = try makeStore()
        try await store.updateIndex(project: "test", refs: [TopicRef(slug: "old", title: "Old")])
        try await store.updateIndex(project: "test", refs: [TopicRef(slug: "new", title: "New")])

        let loaded = try await store.loadIndex(project: "test")
        #expect(loaded.count == 1)
        #expect(loaded[0].slug == "new")
    }

    @Test("Empty index returns empty array")
    func indexEmpty() async throws {
        let store = try makeStore()
        let loaded = try await store.loadIndex(project: "empty")
        #expect(loaded.isEmpty)
    }

    // MARK: - Layer 2: Topics

    @Test("Save and load topic")
    func topicRoundtrip() async throws {
        let store = try makeStore()
        let topic = TopicContent(
            slug: "team",
            title: "Team Members",
            body: "Alice: Engineering\nBob: Design"
        )

        try await store.saveTopic(topic, project: "test")
        let loaded = try await store.loadTopic(slug: "team", project: "test")

        #expect(loaded?.slug == "team")
        #expect(loaded?.title == "Team Members")
        #expect(loaded?.body == "Alice: Engineering\nBob: Design")
    }

    @Test("Topic update replaces content")
    func topicUpdate() async throws {
        let store = try makeStore()
        let v1 = TopicContent(slug: "goals", title: "Goals", body: "v1")
        let v2 = TopicContent(slug: "goals", title: "Goals Updated", body: "v2")

        try await store.saveTopic(v1, project: "test")
        try await store.saveTopic(v2, project: "test")

        let loaded = try await store.loadTopic(slug: "goals", project: "test")
        #expect(loaded?.title == "Goals Updated")
        #expect(loaded?.body == "v2")
    }

    @Test("Topic delete removes it")
    func topicDelete() async throws {
        let store = try makeStore()
        let topic = TopicContent(slug: "temp", title: "Temp", body: "data")
        try await store.saveTopic(topic, project: "test")
        try await store.deleteTopic(slug: "temp", project: "test")

        let loaded = try await store.loadTopic(slug: "temp", project: "test")
        #expect(loaded == nil)
    }

    @Test("Load nonexistent topic returns nil")
    func topicNotFound() async throws {
        let store = try makeStore()
        let loaded = try await store.loadTopic(slug: "missing", project: "test")
        #expect(loaded == nil)
    }

    @Test("List topics returns refs")
    func topicList() async throws {
        let store = try makeStore()
        try await store.saveTopic(
            TopicContent(slug: "alpha", title: "Alpha", body: "a"), project: "test")
        try await store.saveTopic(
            TopicContent(slug: "beta", title: "Beta", body: "b"), project: "test")

        let refs = try await store.listTopics(project: "test")
        #expect(refs.count == 2)
        #expect(refs[0].slug == "alpha")
    }

    @Test("Topics are project-scoped")
    func topicProjectScoped() async throws {
        let store = try makeStore()
        try await store.saveTopic(
            TopicContent(slug: "x", title: "X", body: "for alpha"), project: "alpha")
        try await store.saveTopic(
            TopicContent(slug: "x", title: "X", body: "for beta"), project: "beta")

        let alpha = try await store.loadTopic(slug: "x", project: "alpha")
        let beta = try await store.loadTopic(slug: "x", project: "beta")

        #expect(alpha?.body == "for alpha")
        #expect(beta?.body == "for beta")
    }

    // MARK: - Layer 3: Transcripts

    @Test("Store and search transcripts with FTS5")
    func transcriptSearch() async throws {
        let store = try makeStore()
        try await store.storeTranscript(
            sessionID: "s1",
            content: "The user asked about deployment strategies for microservices",
            project: "test"
        )
        try await store.storeTranscript(
            sessionID: "s2",
            content: "Discussion about marketing campaigns and SEO optimization",
            project: "test"
        )

        let results = try await store.searchTranscripts(query: "deployment", project: "test", limit: 10)
        #expect(results.count == 1)
        #expect(results[0].sessionID == "s1")
        #expect(results[0].snippet.contains("deployment"))
    }

    @Test("Transcript search returns empty for no matches")
    func transcriptSearchEmpty() async throws {
        let store = try makeStore()
        try await store.storeTranscript(sessionID: "s1", content: "hello world", project: "test")

        let results = try await store.searchTranscripts(query: "nonexistent", project: "test", limit: 10)
        #expect(results.isEmpty)
    }

    @Test("Transcripts are project-scoped")
    func transcriptProjectScoped() async throws {
        let store = try makeStore()
        try await store.storeTranscript(sessionID: "s1", content: "alpha project data", project: "alpha")
        try await store.storeTranscript(sessionID: "s2", content: "beta project data", project: "beta")

        let alphaResults = try await store.searchTranscripts(query: "project", project: "alpha", limit: 10)
        let betaResults = try await store.searchTranscripts(query: "project", project: "beta", limit: 10)

        #expect(alphaResults.count == 1)
        #expect(alphaResults[0].sessionID == "s1")
        #expect(betaResults.count == 1)
        #expect(betaResults[0].sessionID == "s2")
    }

    // MARK: - Context Assembly

    @Test("assembleContext builds memory section from index and topics")
    func assembleContextBasic() async throws {
        let store = try makeStore()

        try await store.saveTopic(
            TopicContent(slug: "team", title: "Team", body: "Alice, Bob"), project: "test")
        try await store.saveTopic(
            TopicContent(slug: "goals", title: "Goals", body: "Ship v2"), project: "test")
        try await store.updateIndex(project: "test", refs: [
            TopicRef(slug: "team", title: "Team"),
            TopicRef(slug: "goals", title: "Goals"),
        ])

        let context = try await store.assembleContext(project: "test", currentQuery: "", maxEntries: 20)
        #expect(context.contains("# Memory"))
        #expect(context.contains("## Team"))
        #expect(context.contains("Alice, Bob"))
        #expect(context.contains("## Goals"))
    }

    @Test("assembleContext returns empty for no memory")
    func assembleContextEmpty() async throws {
        let store = try makeStore()
        let context = try await store.assembleContext(project: "empty", currentQuery: "", maxEntries: 20)
        #expect(context.isEmpty)
    }

    @Test("assembleContext respects maxEntries")
    func assembleContextMaxEntries() async throws {
        let store = try makeStore()

        for i in 0..<5 {
            try await store.saveTopic(
                TopicContent(slug: "t\(i)", title: "Topic \(i)", body: "Body \(i)"), project: "test")
        }
        try await store.updateIndex(project: "test", refs: (0..<5).map {
            TopicRef(slug: "t\($0)", title: "Topic \($0)")
        })

        let context = try await store.assembleContext(project: "test", currentQuery: "", maxEntries: 2)
        // Should only contain 2 topics
        let topicCount = context.components(separatedBy: "## Topic").count - 1
        #expect(topicCount == 2)
    }
}
