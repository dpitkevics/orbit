import Foundation
import Testing
@testable import OrbitCore

@Suite("Embeddings & Vector Search")
struct EmbeddingTests {
    // MARK: - Vector Math

    @Test("Cosine similarity of identical vectors is 1.0")
    func cosineSimilarityIdentical() {
        let v: [Float] = [1.0, 2.0, 3.0]
        let sim = cosineSimilarity(v, v)
        #expect(abs(sim - 1.0) < 0.0001)
    }

    @Test("Cosine similarity of orthogonal vectors is 0.0")
    func cosineSimilarityOrthogonal() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [0.0, 1.0]
        let sim = cosineSimilarity(a, b)
        #expect(abs(sim) < 0.0001)
    }

    @Test("Cosine similarity of opposite vectors is -1.0")
    func cosineSimilarityOpposite() {
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [-1.0, -2.0, -3.0]
        let sim = cosineSimilarity(a, b)
        #expect(abs(sim + 1.0) < 0.0001)
    }

    @Test("Cosine similarity of empty vectors is 0.0")
    func cosineSimilarityEmpty() {
        let sim = cosineSimilarity([], [])
        #expect(sim == 0)
    }

    @Test("Cosine similarity of mismatched lengths is 0.0")
    func cosineSimilarityMismatch() {
        let sim = cosineSimilarity([1.0], [1.0, 2.0])
        #expect(sim == 0)
    }

    // MARK: - Vector Serialization

    @Test("Vector serialize/deserialize roundtrip")
    func vectorSerializationRoundtrip() {
        let original: [Float] = [1.5, -2.3, 0.0, 42.0, -0.001]
        let data = serializeVector(original)
        let restored = deserializeVector(data)

        #expect(restored.count == original.count)
        for i in 0..<original.count {
            #expect(abs(restored[i] - original[i]) < 0.00001)
        }
    }

    @Test("Empty vector serialization")
    func emptyVectorSerialization() {
        let original: [Float] = []
        let data = serializeVector(original)
        let restored = deserializeVector(data)
        #expect(restored.isEmpty)
    }

    // MARK: - SQLiteMemory Embedding Storage

    @Test("Save and load topic embedding")
    func topicEmbeddingRoundtrip() async throws {
        let store = try SQLiteMemory()
        let topic = TopicContent(slug: "team", title: "Team", body: "Alice and Bob")
        try await store.saveTopic(topic, project: "test")

        let vector: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        try await store.saveTopicEmbedding(slug: "team", project: "test", vector: vector)

        let loaded = try await store.loadTopicEmbedding(slug: "team", project: "test")
        #expect(loaded != nil)
        #expect(loaded?.count == 5)
        if let loaded {
            #expect(abs(loaded[0] - 0.1) < 0.0001)
        }
    }

    @Test("Load embedding returns nil when none stored")
    func topicEmbeddingMissing() async throws {
        let store = try SQLiteMemory()
        let topic = TopicContent(slug: "plain", title: "Plain", body: "No embedding")
        try await store.saveTopic(topic, project: "test")

        let loaded = try await store.loadTopicEmbedding(slug: "plain", project: "test")
        #expect(loaded == nil)
    }

    @Test("Load embedding returns nil for nonexistent topic")
    func topicEmbeddingNonexistent() async throws {
        let store = try SQLiteMemory()
        let loaded = try await store.loadTopicEmbedding(slug: "missing", project: "test")
        #expect(loaded == nil)
    }

    // MARK: - Memory Retriever

    @Test("MemoryRetriever tier detection")
    func retrieverTierDetection() throws {
        let store = try SQLiteMemory()

        // No providers → keyword
        let r1 = MemoryRetriever(memory: store)
        #expect(r1.activeTier == .keyword)

        // LLM provider only → rerank
        let mockProvider = MockProvider.textOnly("test")
        let r2 = MemoryRetriever(memory: store, llmProvider: mockProvider)
        #expect(r2.activeTier == .rerank)

        // Embedding provider → vector
        let mockEmbedder = MockEmbeddingProvider()
        let r3 = MemoryRetriever(memory: store, embeddingProvider: mockEmbedder)
        #expect(r3.activeTier == .vector)
    }

    @Test("MemoryRetriever keyword tier returns topics")
    func retrieverKeywordTier() async throws {
        let store = try SQLiteMemory()
        try await store.saveTopic(
            TopicContent(slug: "alpha", title: "Alpha", body: "First topic"), project: "test")
        try await store.saveTopic(
            TopicContent(slug: "beta", title: "Beta", body: "Second topic"), project: "test")
        try await store.updateIndex(project: "test", refs: [
            TopicRef(slug: "alpha", title: "Alpha"),
            TopicRef(slug: "beta", title: "Beta"),
        ])

        let retriever = MemoryRetriever(memory: store)
        let topics = try await retriever.retrieveTopics(project: "test", query: "anything")
        #expect(topics.count == 2)
    }

    @Test("MemoryRetriever vector tier uses cosine similarity")
    func retrieverVectorTier() async throws {
        let store = try SQLiteMemory()

        // Create topics with embeddings
        try await store.saveTopic(
            TopicContent(slug: "deploy", title: "Deployment", body: "How to deploy"), project: "test")
        try await store.saveTopic(
            TopicContent(slug: "market", title: "Marketing", body: "Marketing plan"), project: "test")
        try await store.updateIndex(project: "test", refs: [
            TopicRef(slug: "deploy", title: "Deployment"),
            TopicRef(slug: "market", title: "Marketing"),
        ])

        // Assign embeddings — deploy is closer to the query vector
        try await store.saveTopicEmbedding(slug: "deploy", project: "test", vector: [0.9, 0.1, 0.0])
        try await store.saveTopicEmbedding(slug: "market", project: "test", vector: [0.1, 0.9, 0.0])

        // Mock embedder returns a vector close to "deploy"
        let embedder = MockEmbeddingProvider(fixedVector: [0.8, 0.2, 0.0])
        let retriever = MemoryRetriever(memory: store, embeddingProvider: embedder)

        let topics = try await retriever.retrieveTopics(project: "test", query: "deployment", maxTopics: 1)
        #expect(topics.count == 1)
        #expect(topics[0].slug == "deploy")
    }

    @Test("MemoryRetriever assembleContext returns formatted string")
    func retrieverAssembleContext() async throws {
        let store = try SQLiteMemory()
        try await store.saveTopic(
            TopicContent(slug: "team", title: "Team", body: "Alice: Eng"), project: "test")
        try await store.updateIndex(project: "test", refs: [
            TopicRef(slug: "team", title: "Team"),
        ])

        let retriever = MemoryRetriever(memory: store)
        let context = try await retriever.assembleContext(project: "test", query: "")
        #expect(context.contains("# Memory"))
        #expect(context.contains("## Team"))
        #expect(context.contains("Alice: Eng"))
    }

    @Test("MemoryRetriever empty memory returns empty string")
    func retrieverEmptyMemory() async throws {
        let store = try SQLiteMemory()
        let retriever = MemoryRetriever(memory: store)
        let context = try await retriever.assembleContext(project: "empty", query: "test")
        #expect(context.isEmpty)
    }
}

/// Mock embedding provider for testing.
struct MockEmbeddingProvider: EmbeddingProvider, Sendable {
    let dimensions: Int = 3
    let fixedVector: [Float]

    init(fixedVector: [Float] = [0.5, 0.5, 0.0]) {
        self.fixedVector = fixedVector
    }

    func embed(_ text: String) async throws -> [Float] {
        fixedVector
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in fixedVector }
    }
}
