import Foundation

// MARK: - Token Usage

public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: UInt32
    public var outputTokens: UInt32
    public var cacheCreationInputTokens: UInt32
    public var cacheReadInputTokens: UInt32

    public init(
        inputTokens: UInt32 = 0,
        outputTokens: UInt32 = 0,
        cacheCreationInputTokens: UInt32 = 0,
        cacheReadInputTokens: UInt32 = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    public var totalTokens: UInt32 {
        inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    public static let zero = TokenUsage()

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}

// MARK: - Model Pricing

public struct ModelPricing: Sendable {
    public let inputCostPerMillion: Double
    public let outputCostPerMillion: Double
    public let cacheCreationCostPerMillion: Double
    public let cacheReadCostPerMillion: Double

    public init(
        inputCostPerMillion: Double,
        outputCostPerMillion: Double,
        cacheCreationCostPerMillion: Double,
        cacheReadCostPerMillion: Double
    ) {
        self.inputCostPerMillion = inputCostPerMillion
        self.outputCostPerMillion = outputCostPerMillion
        self.cacheCreationCostPerMillion = cacheCreationCostPerMillion
        self.cacheReadCostPerMillion = cacheReadCostPerMillion
    }

    public static let haiku = ModelPricing(
        inputCostPerMillion: 1.0,
        outputCostPerMillion: 5.0,
        cacheCreationCostPerMillion: 1.25,
        cacheReadCostPerMillion: 0.1
    )

    public static let sonnet = ModelPricing(
        inputCostPerMillion: 3.0,
        outputCostPerMillion: 15.0,
        cacheCreationCostPerMillion: 3.75,
        cacheReadCostPerMillion: 0.3
    )

    public static let opus = ModelPricing(
        inputCostPerMillion: 15.0,
        outputCostPerMillion: 75.0,
        cacheCreationCostPerMillion: 18.75,
        cacheReadCostPerMillion: 1.5
    )

    public static func forModel(_ model: String) -> ModelPricing {
        let lower = model.lowercased()
        if lower.contains("haiku") { return .haiku }
        if lower.contains("opus") { return .opus }
        return .sonnet
    }
}

// MARK: - Cost Estimate

public struct CostEstimate: Sendable {
    public let inputCost: Double
    public let outputCost: Double
    public let cacheCreationCost: Double
    public let cacheReadCost: Double

    public var totalCost: Double {
        inputCost + outputCost + cacheCreationCost + cacheReadCost
    }

    public var formattedUSD: String {
        if totalCost < 0.01 {
            return String(format: "$%.4f", totalCost)
        }
        return String(format: "$%.2f", totalCost)
    }
}

extension TokenUsage {
    public func estimateCost(pricing: ModelPricing = .sonnet) -> CostEstimate {
        CostEstimate(
            inputCost: Double(inputTokens) / 1_000_000.0 * pricing.inputCostPerMillion,
            outputCost: Double(outputTokens) / 1_000_000.0 * pricing.outputCostPerMillion,
            cacheCreationCost: Double(cacheCreationInputTokens) / 1_000_000.0 * pricing.cacheCreationCostPerMillion,
            cacheReadCost: Double(cacheReadInputTokens) / 1_000_000.0 * pricing.cacheReadCostPerMillion
        )
    }
}

// MARK: - Usage Tracker

public struct UsageTracker: Sendable {
    private var cumulative: TokenUsage = .zero
    private var turns: [TokenUsage] = []
    private var model: String

    public init(model: String) {
        self.model = model
    }

    public mutating func record(_ usage: TokenUsage) {
        turns.append(usage)
        cumulative += usage
    }

    public var cumulativeUsage: TokenUsage { cumulative }
    public var turnCount: Int { turns.count }

    public var estimatedCost: CostEstimate {
        cumulative.estimateCost(pricing: ModelPricing.forModel(model))
    }
}
