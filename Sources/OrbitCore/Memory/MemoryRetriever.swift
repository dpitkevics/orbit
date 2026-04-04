import Foundation

/// Tiered memory retrieval strategy.
///
/// - **Tier 1 (vector):** Embedding-based semantic search (requires OpenAI API key)
/// - **Tier 2 (rerank):** FTS5 recall + LLM reranking (uses existing provider, no extra key)
/// - **Tier 3 (keyword):** FTS5 keyword search only (no LLM calls)
public struct MemoryRetriever: Sendable {
    private let memory: SQLiteMemory
    private let embeddingProvider: (any EmbeddingProvider)?
    private let llmProvider: (any LLMProvider)?

    public init(
        memory: SQLiteMemory,
        embeddingProvider: (any EmbeddingProvider)? = nil,
        llmProvider: (any LLMProvider)? = nil
    ) {
        self.memory = memory
        self.embeddingProvider = embeddingProvider
        self.llmProvider = llmProvider
    }

    /// The active retrieval tier based on available providers.
    public var activeTier: RetrievalTier {
        if embeddingProvider != nil { return .vector }
        if llmProvider != nil { return .rerank }
        return .keyword
    }

    /// Retrieve the most relevant topics for a query, using the best available tier.
    public func retrieveTopics(
        project: String,
        query: String,
        maxTopics: Int = 5
    ) async throws -> [TopicContent] {
        let allRefs = try await memory.listTopics(project: project)
        guard !allRefs.isEmpty else { return [] }

        switch activeTier {
        case .vector:
            return try await vectorRetrieve(
                project: project, query: query, refs: allRefs, maxTopics: maxTopics
            )
        case .rerank:
            return try await rerankRetrieve(
                project: project, query: query, refs: allRefs, maxTopics: maxTopics
            )
        case .keyword:
            return try await keywordRetrieve(
                project: project, refs: allRefs, maxTopics: maxTopics
            )
        }
    }

    /// Assemble memory context string from retrieved topics.
    public func assembleContext(
        project: String,
        query: String,
        maxTopics: Int = 5
    ) async throws -> String {
        let topics = try await retrieveTopics(
            project: project, query: query, maxTopics: maxTopics
        )

        if topics.isEmpty { return "" }

        var sections = topics.map { "## \($0.title)\n\($0.body)" }
        sections.insert("# Memory", at: 0)
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Tier 1: Vector Search

    private func vectorRetrieve(
        project: String,
        query: String,
        refs: [TopicRef],
        maxTopics: Int
    ) async throws -> [TopicContent] {
        guard let embedder = embeddingProvider else { return [] }

        let queryVector = try await embedder.embed(query)

        // Load all topics with their embeddings
        var scored: [(TopicContent, Float)] = []
        for ref in refs {
            guard let topic = try await memory.loadTopic(slug: ref.slug, project: project) else {
                continue
            }
            if let storedVector = try await memory.loadTopicEmbedding(slug: ref.slug, project: project) {
                let score = cosineSimilarity(queryVector, storedVector)
                scored.append((topic, score))
            }
        }

        // Sort by similarity descending
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(maxTopics).map { $0.0 }
    }

    // MARK: - Tier 2: LLM Reranking

    private func rerankRetrieve(
        project: String,
        query: String,
        refs: [TopicRef],
        maxTopics: Int
    ) async throws -> [TopicContent] {
        guard let provider = llmProvider else { return [] }

        // Build a prompt asking the LLM to select relevant topics
        let topicList = refs.enumerated().map { index, ref in
            "\(index + 1). \(ref.title) [\(ref.slug)]"
        }.joined(separator: "\n")

        let rerankPrompt = """
        Given the user's query, select the most relevant topics from the list below.
        Return ONLY the slug identifiers of relevant topics, one per line, most relevant first.
        Return at most \(maxTopics) slugs. If none are relevant, return "NONE".

        User query: \(query)

        Available topics:
        \(topicList)

        Relevant slugs:
        """

        // Use the LLM to score relevance
        let messages = [ChatMessage.userText(rerankPrompt)]
        let stream = provider.stream(
            messages: messages,
            systemPrompt: "You are a relevance scoring system. Output only topic slugs, one per line.",
            tools: []
        )

        var responseText = ""
        for try await event in stream {
            if case .textDelta(let text) = event {
                responseText += text
            }
        }

        // Parse the response — extract slugs
        let selectedSlugs = responseText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "NONE" }

        // Load topics in the order the LLM ranked them
        var topics: [TopicContent] = []
        for slug in selectedSlugs.prefix(maxTopics) {
            // Handle both bare slugs and formatted references
            let cleanSlug = slug
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespaces)

            if let topic = try await memory.loadTopic(slug: cleanSlug, project: project) {
                topics.append(topic)
            }
        }

        // If LLM reranking returned nothing useful, fall back to keyword
        if topics.isEmpty {
            return try await keywordRetrieve(
                project: project, refs: refs, maxTopics: maxTopics
            )
        }

        return topics
    }

    // MARK: - Tier 3: Keyword (FTS5)

    private func keywordRetrieve(
        project: String,
        refs: [TopicRef],
        maxTopics: Int
    ) async throws -> [TopicContent] {
        // Simply load the first N topics by slug order
        var topics: [TopicContent] = []
        for ref in refs.prefix(maxTopics) {
            if let topic = try await memory.loadTopic(slug: ref.slug, project: project) {
                topics.append(topic)
            }
        }
        return topics
    }
}

/// Which retrieval tier is active.
public enum RetrievalTier: String, Sendable {
    case vector   // Embedding-based semantic search
    case rerank   // LLM reranking of FTS5 candidates
    case keyword  // FTS5 keyword search only
}
