import Foundation
@preconcurrency import SwiftOpenAI

/// Protocol for computing text embeddings.
/// Optional — when not configured, memory falls back to FTS5 + LLM reranking.
public protocol EmbeddingProvider: Sendable {
    /// Compute embedding vector for a text string.
    func embed(_ text: String) async throws -> [Float]

    /// Compute embeddings for multiple texts in a batch.
    func embedBatch(_ texts: [String]) async throws -> [[Float]]

    /// Dimensionality of the embedding vectors.
    var dimensions: Int { get }
}

/// OpenAI embedding provider using text-embedding-3-small.
/// Requires an OpenAI API key.
public struct OpenAIEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    private let service: OpenAIService
    public let dimensions: Int

    public init(apiKey: String, dimensions: Int = 1536) {
        self.service = OpenAIServiceFactory.service(apiKey: apiKey)
        self.dimensions = dimensions
    }

    public func embed(_ text: String) async throws -> [Float] {
        let parameter = EmbeddingParameter(
            input: text,
            model: .textEmbedding3Small,
            encodingFormat: nil,
            dimensions: dimensions
        )
        let response = try await service.createEmbeddings(parameters: parameter)
        guard let first = response.data.first else {
            throw EmbeddingError.emptyResponse
        }
        return first.embedding
    }

    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        // OpenAI supports batch in a single call, but SwiftOpenAI takes single input.
        // Parallelize individual calls.
        try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask {
                    let vector = try await embed(text)
                    return (index, vector)
                }
            }
            var results = Array(repeating: [Float](), count: texts.count)
            for try await (index, vector) in group {
                results[index] = vector
            }
            return results
        }
    }
}

public enum EmbeddingError: Error, LocalizedError {
    case emptyResponse
    case dimensionMismatch(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Embedding API returned empty response."
        case .dimensionMismatch(let expected, let got):
            return "Embedding dimension mismatch: expected \(expected), got \(got)."
        }
    }
}

// MARK: - Vector Math

/// Cosine similarity between two vectors. Returns value in [-1, 1].
public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }

    var dotProduct: Float = 0
    var normA: Float = 0
    var normB: Float = 0

    for i in 0..<a.count {
        dotProduct += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }

    let denominator = sqrt(normA) * sqrt(normB)
    guard denominator > 0 else { return 0 }
    return dotProduct / denominator
}

/// Serialize a float vector to Data for SQLite BLOB storage.
public func serializeVector(_ vector: [Float]) -> Data {
    vector.withUnsafeBufferPointer { buffer in
        Data(buffer: buffer)
    }
}

/// Deserialize a float vector from SQLite BLOB storage.
public func deserializeVector(_ data: Data) -> [Float] {
    data.withUnsafeBytes { buffer in
        Array(buffer.bindMemory(to: Float.self))
    }
}
