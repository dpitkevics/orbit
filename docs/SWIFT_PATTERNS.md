# Swift Patterns — Orbit Type Definitions

**Derived from:** Claw Code Rust/Python patterns
**Target:** Swift 6.0+ with strict concurrency

---

## 1. Message Model

Derived from Claw Code's `session.rs` and `api/types.rs`.

```swift
// MARK: - Message Types

public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public enum ContentBlock: Codable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, toolName: String, output: String, isError: Bool)
    case thinking(content: String, signature: String?)
}

public struct ChatMessage: Codable, Sendable {
    public let role: MessageRole
    public var blocks: [ContentBlock]
    public var usage: TokenUsage?
    
    public static func userText(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, blocks: [.text(text)])
    }
    
    public static func toolResult(
        toolUseId: String,
        toolName: String,
        output: String,
        isError: Bool
    ) -> ChatMessage {
        ChatMessage(
            role: .tool,
            blocks: [.toolResult(
                toolUseId: toolUseId,
                toolName: toolName,
                output: output,
                isError: isError
            )]
        )
    }
}
```

---

## 2. LLM Provider Layer

Derived from Claw Code's `ProviderClient` enum and `ApiClient` trait.

```swift
// MARK: - Provider Protocol

public protocol LLMProvider: Sendable {
    var name: String { get }
    var model: String { get }
    
    func stream(
        messages: [ChatMessage],
        systemPrompt: [String],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamEvent, Error>
    
    func estimateCost(usage: TokenUsage) -> CostEstimate
}

// MARK: - Stream Events (from api/types.rs StreamEvent)

public enum StreamEvent: Sendable {
    case messageStart(id: String, model: String)
    case textDelta(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case usage(TokenUsage)
    case contentBlockStop(index: Int)
    case messageStop(stopReason: String?)
}

// MARK: - Provider Implementations

public struct AnthropicProvider: LLMProvider {
    public let name = "anthropic"
    public let model: String
    private let auth: AuthToken
    // Uses SwiftAnthropic SDK internally
}

public struct OpenAIProvider: LLMProvider {
    public let name = "openai"
    public let model: String
    private let auth: AuthToken
    // Uses SwiftOpenAI SDK internally
}

public struct BridgeProvider: LLMProvider {
    public let name: String   // "anthropic" or "openai"
    public let model: String
    private let cliPath: String
    // Shells out to claude/codex CLI
}
```

---

## 3. Authentication

Derived from Claw Code's `oauth.rs` and `AuthSource` enum.

```swift
// MARK: - Auth Modes (from oauth.rs + config)

public enum AuthMode: String, Codable, Sendable {
    case apiKey
    case bridge
    case oauth
}

public enum AuthSource: Sendable {
    case none
    case apiKey(String)
    case bearerToken(String)
    case apiKeyAndBearer(apiKey: String, bearer: String)
}

public struct AuthToken: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
}

public protocol Authenticator: Sendable {
    func authenticate() async throws -> AuthToken
    func refresh(token: AuthToken) async throws -> AuthToken
    var isAuthenticated: Bool { get }
}

// MARK: - OAuth PKCE (from oauth.rs)

public struct PKCECodePair: Sendable {
    public let verifier: String          // 32 random bytes → base64url
    public let challenge: String         // SHA256(verifier) → base64url
    public let challengeMethod: String   // "S256"
    
    public static func generate() throws -> PKCECodePair { ... }
}

public struct OAuthAuthorizationRequest: Sendable {
    public let authorizeURL: String
    public let clientID: String
    public let redirectURI: String       // http://localhost:{port}/callback
    public let scopes: [String]
    public let state: String
    public let codeChallenge: String
    public let codeChallengeMethod: String
    
    public func buildURL() -> URL { ... }
}

public struct OAuthTokenExchangeRequest: Sendable {
    public let grantType: String = "authorization_code"
    public let code: String
    public let redirectURI: String
    public let clientID: String
    public let codeVerifier: String
    public let state: String
    
    public func formParams() -> [String: String] { ... }
}

public struct OAuthCallbackParams: Sendable {
    public let code: String?
    public let state: String?
    public let error: String?
    public let errorDescription: String?
}

// Credential storage (from oauth.rs credentials_path)
public struct CredentialStore {
    public func load() throws -> AuthToken? { ... }
    public func save(_ token: AuthToken) throws { ... }
    public func clear() throws { ... }
    // Path: ~/.orbit/credentials.json or configurable
    // Can also read ~/.claude/credentials.json for reuse
}
```

---

## 4. Tool System

Derived from Claw Code's `ToolSpec`, `GlobalToolRegistry`, and `ToolExecutor`.

```swift
// MARK: - Tool Protocol (from tools/lib.rs ToolSpec)

public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }         // JSON Schema
    var requiredPermission: PermissionMode { get }
    
    func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult
}

public struct ToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: JSONValue
}

public struct ToolResult: Sendable {
    public let output: String
    public let isError: Bool
}

public struct ToolContext: Sendable {
    public let workspaceRoot: URL
    public let project: String
    public let permissionMode: PermissionMode
}

// MARK: - Tool Pool (from tool_pool.py + tools/lib.rs)

public struct ToolPool: Sendable {
    private let builtinTools: [any Tool]
    private let pluginTools: [any Tool]
    private let mcpTools: [any Tool]          // Dynamically registered
    private let maxVisible: Int               // Default: 15
    
    public func availableTools(
        mode: ToolPoolMode,
        permissions: PermissionPolicy
    ) -> [any Tool]
    
    public func definitions(
        mode: ToolPoolMode,
        permissions: PermissionPolicy
    ) -> [ToolDefinition]
    
    public mutating func registerMCPTool(_ tool: any Tool)
    public mutating func unregisterMCPTools(server: String)
}

public enum ToolPoolMode: Sendable {
    case full                          // All tools
    case simple                        // bash, read, edit only
    case restricted(allowed: Set<String>)  // Specific tool set
}

// MARK: - Tool Registry (from tools/lib.rs GlobalToolRegistry)

public struct ToolRegistry: Sendable {
    private var tools: [String: any Tool] = [:]
    
    public mutating func register(_ tool: any Tool) throws {
        // Validates no name collision
    }
    
    public func tool(named: String) -> (any Tool)? { ... }
    
    public func execute(
        name: String,
        input: JSONValue,
        context: ToolContext
    ) async throws -> ToolResult
}
```

---

## 5. Permission System

Derived from Claw Code's `permissions.rs` and `permission_enforcer.rs`.

```swift
// MARK: - Permission Modes (from permissions.rs)

public enum PermissionMode: String, Codable, Sendable, Comparable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
    case prompt
    case allow
}

// MARK: - Permission Policy (from permissions.rs)

public struct PermissionPolicy: Codable, Sendable {
    public var activeMode: PermissionMode
    public var toolRequirements: [String: PermissionMode]  // Per-tool minimums
    public var allowRules: [PermissionRule]
    public var denyRules: [PermissionRule]
    public var askRules: [PermissionRule]
    
    public func authorize(
        tool: String,
        input: String,
        prompter: (any PermissionPrompter)?
    ) -> PermissionOutcome
}

public enum PermissionOutcome: Sendable {
    case allow
    case deny(reason: String)
}

public struct PermissionRule: Codable, Sendable {
    public let pattern: String     // Tool name pattern (supports glob)
}

// MARK: - Permission Prompter (from permissions.rs)

public protocol PermissionPrompter: Sendable {
    func decide(request: PermissionRequest) async -> PermissionPromptDecision
}

public struct PermissionRequest: Sendable {
    public let toolName: String
    public let input: String
    public let currentMode: PermissionMode
    public let requiredMode: PermissionMode
    public let reason: String?
}

public enum PermissionPromptDecision: Sendable {
    case allow
    case deny(reason: String)
}

// MARK: - Permission Enforcer (from permission_enforcer.rs)

public struct PermissionEnforcer: Sendable {
    private let policy: PermissionPolicy
    
    public func check(tool: String, input: String) -> EnforcementResult
    public func checkFileWrite(path: String, workspaceRoot: String) -> EnforcementResult
    public func checkBash(command: String) -> EnforcementResult
}

public enum EnforcementResult: Sendable {
    case allowed
    case denied(tool: String, activeMode: String, requiredMode: String, reason: String)
}
```

---

## 6. Session Management

Derived from Claw Code's `session.rs` and `compact.rs`.

```swift
// MARK: - Session (from session.rs)

public struct Session: Codable, Sendable {
    public let version: UInt32              // Schema version
    public let sessionID: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var compaction: SessionCompaction?
    public var fork: SessionFork?
    
    public mutating func pushMessage(_ message: ChatMessage)
    public mutating func recordCompaction(summary: String, removedCount: Int)
    public func fork(branchName: String?) -> Session
}

public struct SessionCompaction: Codable, Sendable {
    public let count: UInt32
    public let removedMessageCount: Int
    public let summary: String
}

public struct SessionFork: Codable, Sendable {
    public let parentSessionID: String
    public let branchName: String?
}

// MARK: - Session Store

public protocol SessionStore: Sendable {
    func save(_ session: Session, project: String) async throws
    func load(id: String, project: String) async throws -> Session
    func list(project: String, limit: Int) async throws -> [SessionSummary]
    func resume(id: String, project: String) async throws -> Session
}

public struct SessionSummary: Codable, Sendable {
    public let sessionID: String
    public let createdAt: Date
    public let updatedAt: Date
    public let messageCount: Int
    public let totalTokens: UInt32
}

// MARK: - Compaction (from compact.rs)

public struct CompactionConfig: Sendable {
    public var preserveRecentMessages: Int = 4
    public var maxEstimatedTokens: Int = 10_000
}

public struct CompactionResult: Sendable {
    public let summary: String
    public let formattedSummary: String
    public let compactedSession: Session
    public let removedMessageCount: Int
}

public struct CompactionEngine: Sendable {
    public let config: CompactionConfig
    
    public func shouldCompact(session: Session) -> Bool
    public func compact(session: Session) -> CompactionResult
    public func estimateTokens(session: Session) -> Int
}
```

---

## 7. Query Engine

Derived from Claw Code's `ConversationRuntime` and `QueryEnginePort`.

```swift
// MARK: - Query Engine (from conversation.rs)

public actor QueryEngine {
    private var session: Session
    private let provider: any LLMProvider
    private let toolRegistry: ToolRegistry
    private let permissionPolicy: PermissionPolicy
    private let systemPrompt: [String]
    private let config: QueryEngineConfig
    private var usageTracker: UsageTracker
    private let compactionEngine: CompactionEngine
    private let autoCompactionThreshold: UInt32   // Default: 100,000
    
    public func runTurn(
        userInput: String,
        prompter: (any PermissionPrompter)?
    ) -> AsyncThrowingStream<TurnEvent, Error>
    
    public func compact() -> CompactionResult
    public var estimatedTokens: Int { get }
    public var usage: UsageTracker { get }
}

public struct QueryEngineConfig: Sendable {
    public var maxTurns: Int = 8
    public var maxBudgetTokens: Int = 50_000
    public var compactAfterTurns: Int = 12
}

// MARK: - Turn Events (combined from AssistantEvent + custom)

public enum TurnEvent: Sendable {
    case textDelta(String)
    case toolCallStart(id: String, name: String)
    case toolCallEnd(id: String, name: String, result: ToolResult)
    case permissionRequest(tool: String, input: JSONValue)
    case usageUpdate(TokenUsage)
    case turnComplete(TurnSummary)
}

public struct TurnSummary: Sendable {
    public let assistantMessages: [ChatMessage]
    public let toolResults: [ChatMessage]
    public let iterations: Int
    public let usage: TokenUsage
    public let autoCompacted: Bool
}
```

---

## 8. Cost Tracking

Derived from Claw Code's `usage.rs`.

```swift
// MARK: - Token Usage (from usage.rs)

public struct TokenUsage: Codable, Sendable {
    public var inputTokens: UInt32 = 0
    public var outputTokens: UInt32 = 0
    public var cacheCreationInputTokens: UInt32 = 0
    public var cacheReadInputTokens: UInt32 = 0
    
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
}

// MARK: - Cost Estimation (from usage.rs)

public struct ModelPricing: Sendable {
    public let inputCostPerMillion: Double
    public let outputCostPerMillion: Double
    public let cacheCreationCostPerMillion: Double
    public let cacheReadCostPerMillion: Double
    
    public static let sonnet = ModelPricing(
        inputCostPerMillion: 15.0,
        outputCostPerMillion: 75.0,
        cacheCreationCostPerMillion: 18.75,
        cacheReadCostPerMillion: 1.5
    )
    
    public static let haiku = ModelPricing(
        inputCostPerMillion: 1.0,
        outputCostPerMillion: 5.0,
        cacheCreationCostPerMillion: 1.25,
        cacheReadCostPerMillion: 0.1
    )
    
    public static let opus = ModelPricing(
        inputCostPerMillion: 15.0,
        outputCostPerMillion: 75.0,
        cacheCreationCostPerMillion: 18.75,
        cacheReadCostPerMillion: 1.5
    )
}

public struct CostEstimate: Sendable {
    public let inputCost: Double
    public let outputCost: Double
    public let cacheCreationCost: Double
    public let cacheReadCost: Double
    
    public var totalCost: Double {
        inputCost + outputCost + cacheCreationCost + cacheReadCost
    }
    
    public var formattedUSD: String {
        String(format: "$%.4f", totalCost)
    }
}

public struct UsageTracker: Sendable {
    private var cumulative: TokenUsage = .zero
    private var turns: [TokenUsage] = []
    
    public mutating func record(_ usage: TokenUsage) {
        turns.append(usage)
        cumulative = cumulative + usage
    }
    
    public var cumulativeUsage: TokenUsage { cumulative }
    public var turnCount: Int { turns.count }
}
```

---

## 9. MCP Integration

Derived from Claw Code's `mcp.rs`, `mcp_tool_bridge.rs`, and spec's MCP SDK usage.

```swift
// MARK: - MCP Registry (from mcp_tool_bridge.rs)

public enum MCPConnectionStatus: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case authRequired = "auth_required"
    case error
}

public struct MCPServerState: Sendable {
    public let serverName: String
    public var status: MCPConnectionStatus
    public var tools: [MCPToolInfo]
    public var resources: [MCPResourceInfo]
    public var serverInfo: String?
    public var errorMessage: String?
}

public struct MCPToolInfo: Codable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: JSONValue?
}

public struct MCPResourceInfo: Codable, Sendable {
    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String?
}

// MARK: - MCP Name Normalization (from mcp.rs)

public enum MCPNaming {
    /// Normalize a server/tool name for MCP convention
    public static func normalize(_ name: String) -> String {
        // [a-zA-Z0-9_-] pass through, everything else → _
        // For "claude.ai " prefixed: collapse underscores, trim
    }
    
    /// Generate prefixed tool name: mcp__{server}__{tool}
    public static func toolName(server: String, tool: String) -> String {
        "mcp__\(normalize(server))__\(normalize(tool))"
    }
    
    /// Generate tool prefix for a server: mcp__{server}__
    public static func toolPrefix(server: String) -> String {
        "mcp__\(normalize(server))__"
    }
}

// MARK: - MCP Config Hashing (from mcp.rs)

public enum MCPConfigHash {
    /// Generate deterministic hash of MCP server config for identity comparison
    public static func hash(config: MCPServerConfig) -> String {
        // SHA-256 hex digest of: transport|url|args|env|...
    }
}

// MARK: - MCP Server Config (from config.rs)

public enum MCPTransport: String, Codable, Sendable {
    case stdio
    case sse
    case http
}

public struct MCPServerConfig: Codable, Sendable {
    public let name: String
    public let transport: MCPTransport
    public let command: String?      // For stdio
    public let args: [String]?       // For stdio
    public let url: String?          // For http/sse
    public let headers: [String: String]?
    public let env: [String: String]?
}
```

---

## 10. Configuration

Derived from Claw Code's `config.rs`.

```swift
// MARK: - Config Sources (from config.rs)

public enum ConfigSource: String, Codable, Sendable, Comparable {
    case user       // ~/.orbit/
    case project    // Per-project TOML
    case local      // .orbit.local (overrides, not committed)
}

public struct ConfigEntry: Sendable {
    public let source: ConfigSource
    public let path: URL
}

// MARK: - Runtime Config (merged from all sources)

public struct RuntimeConfig: Codable, Sendable {
    public let defaultProvider: String
    public let defaultModel: String
    public let auth: [String: AuthConfig]
    public let memory: MemoryConfig
    public let daemon: DaemonConfig
    public let permissions: PermissionPolicy
    public let context: ContextConfig
    public let mcpServers: [String: MCPServerConfig]
    public let hooks: HookConfig
}

public struct AuthConfig: Codable, Sendable {
    public let mode: AuthMode
    public let apiKeyEnv: String?
    public let apiKeyKeychain: String?
    public let cliPath: String?
    public let credentialsPath: String?
}

public struct MemoryConfig: Codable, Sendable {
    public let dbPath: String
    public let autoSummarize: Bool
    public let maxContextEntries: Int
}

public struct ContextConfig: Codable, Sendable {
    public let maxFileChars: Int       // Default: 4000
    public let maxTotalChars: Int      // Default: 12000
}

public struct HookConfig: Codable, Sendable {
    public let preToolUse: [String]
    public let postToolUse: [String]
    public let postToolUseFailure: [String]
}
```

---

## 11. Context Builder

Derived from Claw Code's `prompt.rs`.

```swift
// MARK: - Context Assembly (from prompt.rs)

public struct ContextFile: Sendable {
    public let path: URL
    public let content: String
}

public struct ProjectContext: Sendable {
    public let cwd: URL
    public let currentDate: String
    public let gitStatus: String?
    public let gitDiff: String?
    public let instructionFiles: [ContextFile]
    
    public static func discover(
        at cwd: URL,
        currentDate: String,
        includeGit: Bool
    ) throws -> ProjectContext
}

public struct SystemPromptBuilder: Sendable {
    public func build(
        projectContext: ProjectContext,
        memory: String,          // Assembled memory context
        skills: [String],        // Loaded skill content
        config: RuntimeConfig
    ) -> [String]               // Prompt sections
}

// Constants from prompt.rs
public enum ContextLimits {
    public static let maxInstructionFileChars = 4_000
    public static let maxTotalInstructionChars = 12_000
}
```

---

## 12. Agent Tree (Orbit-Original)

Not from Claw Code — derived from Orbit spec, using Swift concurrency patterns.

```swift
// MARK: - Agent Tree

public final class AgentNode: @unchecked Sendable {
    public let id: UUID
    public let parentID: UUID?
    public let task: String
    public let project: String
    public let depth: Int
    public let maxDepth: Int                    // Default: 5
    
    public let provider: any LLMProvider
    public let tools: [any Tool]
    public let permissions: PermissionPolicy
    public let memoryAccess: MemoryAccessLevel
    
    public private(set) var children: [AgentNode] = []
    public private(set) var status: AgentStatus = .pending
    public private(set) var result: AgentResult?
    public private(set) var trace: [TraceEntry] = []
    public private(set) var usage: TokenUsage = .zero
    public private(set) var startTime: Date
    public private(set) var endTime: Date?
}

public enum AgentStatus: String, Codable, Sendable {
    case pending, running, completed, failed, cancelled
}

public enum MemoryAccessLevel: String, Codable, Sendable {
    case full, readOnly, none
}

public struct AgentResult: Sendable {
    public let output: String
    public let usage: TokenUsage
    public let success: Bool
}

public struct TraceEntry: Codable, Sendable {
    public let timestamp: Date
    public let type: TraceType
    public let content: String
    public let metadata: JSONValue?
}

public enum TraceType: String, Codable, Sendable {
    case toolCall, toolResult, llmCall, llmResponse, spawn, error
}

public actor AgentTree {
    private var root: AgentNode
    private var allNodes: [UUID: AgentNode] = [:]
    
    public func trace() -> TreeTrace
    public func nodesAtDepth(_ depth: Int) -> [AgentNode]
    public func totalCost() -> TokenUsage
    public func totalDuration() -> TimeInterval
    public func failedNodes() -> [AgentNode]
}
```

---

## 13. JSONValue

Needed throughout for dynamic JSON handling.

```swift
// MARK: - JSON Value

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    
    public var stringValue: String? { ... }
    public var intValue: Int? { ... }
    public var boolValue: Bool? { ... }
    public subscript(key: String) -> JSONValue? { ... }
    public subscript(index: Int) -> JSONValue? { ... }
}
```
