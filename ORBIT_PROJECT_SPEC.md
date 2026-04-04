# Orbit — Project Specification

## Open-Source, LLM-Agnostic Agent Platform for Project Operations

**Version:** 0.1.0-spec
**Author:** Daniels
**Date:** April 2026
**Language:** Go
**License:** MIT (TBD)

---

## Table of Contents

1. [Vision & Purpose](#1-vision--purpose)
2. [Pre-Implementation: Claw Code Analysis](#2-pre-implementation-claw-code-analysis)
3. [Core Principles](#3-core-principles)
4. [Architecture Overview](#4-architecture-overview)
5. [Module Specifications](#5-module-specifications)
   - 5.1 [LLM Provider Layer](#51-llm-provider-layer)
   - 5.2 [Tool System](#52-tool-system)
   - 5.3 [Permission System](#53-permission-system)
   - 5.4 [Agent Tree System](#54-agent-tree-system)
   - 5.5 [Memory System (3-Layer)](#55-memory-system-3-layer)
   - 5.6 [autoDream — Memory Consolidation](#56-autodream--memory-consolidation)
   - 5.7 [MCP Client](#57-mcp-client)
   - 5.8 [Query Engine](#58-query-engine)
   - 5.9 [Context System](#59-context-system)
   - 5.10 [Skills System](#510-skills-system)
   - 5.11 [Scheduler](#511-scheduler)
   - 5.12 [Orbit Daemon (KAIROS-equivalent)](#512-orbit-daemon-kairos-equivalent)
   - 5.13 [Deep Tasks (ULTRAPLAN-equivalent)](#513-deep-tasks-ultraplan-equivalent)
   - 5.14 [Coding Awareness & Delegation](#514-coding-awareness--delegation)
   - 5.15 [Session Management](#515-session-management)
   - 5.16 [Slash Commands](#516-slash-commands)
   - 5.17 [CLI Interface](#517-cli-interface)
6. [Configuration Design](#6-configuration-design)
7. [Directory Structure](#7-directory-structure)
8. [Build Phases](#8-build-phases)
9. [Dependencies](#9-dependencies)
10. [Design Decisions & Rationale](#10-design-decisions--rationale)

---

## 1. Vision & Purpose

### What Orbit Is

Orbit is an open-source, LLM-agnostic agent platform designed for **project and business operations management**. It is a CLI-first tool that acts as a solo founder's chief of staff — it knows the state of each project, can analyze business data, run scheduled operational tasks, monitor proactively, and delegate coding tasks to external agents.

### What Orbit Is NOT

Orbit is NOT an IDE, a code editor, or a code completion tool. It does not compete with Cursor, Copilot, or Windsurf. It is not a coding agent — though it is **aware** of code, can read codebases, can edit files for operational tasks, and can **delegate** coding work to Claude Code, Codex CLI, or other coding agents.

### The Gap Orbit Fills

The current landscape has:
- **Coding agents** (Claude Code, Codex, Claw Code) — focused on writing/editing code
- **IDE assistants** (Cursor, Copilot, Antigravity) — embedded in editors for code workflows
- **Chat interfaces** (Claude.ai, ChatGPT) — general purpose but no project context, no scheduling, no proactivity

**Nobody** has built an open-source, LLM-agnostic **operations agent** that:
- Manages multiple projects with persistent context and memory
- Runs scheduled operational tasks (daily briefs, support triage, SEO monitoring)
- Monitors proactively and alerts when something needs attention (KAIROS-style)
- Performs deep cross-project analysis asynchronously (ULTRAPLAN-style)
- Consolidates its own memory automatically (autoDream-style)
- Has a full tool system (file ops, web scraping, shell execution) for non-coding operational tasks
- Delegates coding to external agents when actual codebase changes are needed
- Works with any LLM provider (Anthropic, OpenAI, Google, local models)

### Target Users

Solo founders, indie hackers, and small teams managing multiple bootstrapped projects who need an AI operations layer across their ventures.

---

## 2. Pre-Implementation: Claw Code Analysis

### CRITICAL FIRST STEP

Before writing any Orbit code, the implementer MUST deeply analyze the Claw Code repository to understand the architectural patterns that Orbit will adapt. Claw Code is a clean-room rewrite of Claude Code's agent harness architecture — it contains battle-tested patterns for every core subsystem Orbit needs.

### Repositories

Both repos must be analyzed. They are the same project at different stages:

```
PRIMARY (active development, 346 commits, Rust parity work):
https://github.com/ultraworkers/claw-code-parity

SECONDARY (original, locked during ownership transfer, 44 commits):
https://github.com/ultraworkers/claw-code
```

The `-parity` repo is where active development happens and has the most
complete Rust implementation. The original repo has the initial Python
workspace. Analyze both, but prioritize `-parity` for Rust patterns.

The Rust crate structure (the primary source of architectural patterns) lives
in `rust/crates/` in both repos:
- `api-client` / `api` — API client with provider abstraction, OAuth, streaming
- `runtime` — session state, compaction, MCP orchestration, prompt construction
- `tools` — tool manifest definitions and execution framework
- `commands` — slash commands, skills discovery, config inspection
- `plugins` — plugin model, hook pipeline, bundled plugins
- `compat-harness` — compatibility layer for upstream editor integration
- `claw-cli` — interactive REPL, markdown rendering, project bootstrap

### What to Study and Extract

The analysis should produce a document (`CLAW_CODE_ANALYSIS.md`) covering:

#### 2.1 MCP Integration Patterns
- NOTE: Orbit will use the official `modelcontextprotocol/swift-sdk` for the
  MCP protocol layer. The analysis of Claw Code's MCP implementation should
  focus on **application-level patterns**, not protocol implementation.
- How Claw Code manages multiple MCP server connections simultaneously
- The OAuth PKCE flow for MCP authentication (still relevant for auth)
- Name normalization (`mcp__{server}__{tool}` convention)
- Config hashing for server identity
- How tools from MCP servers are surfaced to the LLM and filtered by ToolPool
- Server lifecycle management (connect/disconnect/reconnect)
- **Extract:** Server registry pattern, tool normalization, config hashing,
  lifecycle management — these sit on top of the official SDK

#### 2.2 Session & Memory Management
- The `StoredSession` dataclass and JSON persistence
- How the `TranscriptStore` buffers and flushes conversation history
- The compaction system: `CompactionConfig`, `should_compact`, `compact_session`
- Token estimation heuristics (~4 chars/token)
- The `preserve_recent_messages = 4` and `max_estimated_tokens = 10000` defaults
- The `format_compact_summary` function: stripping analysis tags, collecting file references, inferring pending/current work
- The `HistoryEvent` / `HistoryLog` structured history
- Context discovery: `PortContext` workspace scanning
- System prompt assembly: `CLAUDE.md` file discovery, character limits (4000 per file, 12000 total), content hash deduplication
- **Extract:** Compaction algorithm, context discovery patterns, prompt assembly logic

#### 2.3 Query Engine
- The turn loop: how `QueryEnginePort` orchestrates LLM calls, tool execution, and message management
- Configuration: `max_turns = 8`, `max_budget_tokens = 2000`, `compact_after_turns = 12`
- The 6 streaming event types: `message_start`, `command_match`, `tool_match`, `permission_denial`, `message_delta`, `message_stop`
- How the engine handles tool call results and feeds them back into the next turn
- The Rust `ConversationRuntime` with its 16-iteration cap
- Budget controls and cost tracking
- **Extract:** Turn loop structure, streaming event model, budget control patterns

#### 2.4 Tool System
- The plugin architecture: how tools are registered, discovered, and filtered
- JSON Schema definitions for each tool (the 19 tool specs in the Rust `tools` crate)
- The `ToolPool` class and its max 15 visible tools limit
- How `filter_tools_by_permission_context` works
- The `simple_mode` concept (restricting to BashTool, FileReadTool, FileEditTool)
- The `Agent` tool specifically — how sub-agents are spawned and managed
- **Extract:** Tool protocol design, registration pattern, schema definitions, pool filtering

#### 2.5 Permission System
- The three `PermissionMode` values: Allow, Deny, Prompt
- `PermissionPolicy` per-tool configuration
- Deny lists and pattern matching
- How permissions gate tool execution
- Interactive permission prompting in the terminal
- **Extract:** Permission model, policy enforcement patterns

#### 2.6 API Client & Authentication (Rust)
- The `AnthropicClient` implementation
- Retry logic: HTTP status codes 408, 409, 429, 500, 502, 503, 504
- `AuthSource` enum: None, ApiKey, BearerToken, ApiKeyAndBearer
- SSE streaming via `MessageStream` and `SseParser`
- **OAuth PKCE flow** — THIS IS CRITICAL. Study every detail:
  - How PKCE code_verifier and code_challenge are generated
  - The OAuth authorize endpoint URL and parameters
  - The localhost callback listener
  - Token exchange flow
  - Credential storage format and location (`~/.claude/credentials.json`)
  - Token refresh logic
  - How the resulting token is used in subsequent API calls
  - Whether Orbit can reuse tokens from Claude Code's credential file
- Model pricing: per-model rate structures
- `format_usd` display utility
- **Extract:** Retry policies, streaming parser, auth patterns (ALL THREE: API key,
  bearer token, OAuth PKCE), cost tracking. The OAuth flow is the highest-priority
  extraction target because it enables subscription-based auth.

#### 2.7 Bootstrap Sequence
- The 7-stage bootstrap graph: Prefetch → Warning handler → CLI parser → Setup + Commands parallel → Deferred init → Mode routing → Query engine
- What each stage does and why it exists
- **Extract:** Startup sequence design — which parts Orbit needs, which are coding-agent-specific

#### 2.8 Command System
- The slash command architecture: `CommandExecution` dataclass, command snapshot loading
- The `load_command_snapshot`, `get_command`, `find_commands`, `execute_command` API
- How commands interact with the query engine vs. being handled directly
- Relevant commands for Orbit: `/compact`, `/cost`, `/model`, `/memory`, `/status`, `/resume`, `/config`, `/export`
- **Extract:** Command registry pattern, dispatch logic

#### 2.9 Message Model
- `MessageRole` enum: System, User, Assistant, Tool
- `ContentBlock` variants: Text, ToolUse, ToolResult
- How tool calls are correlated via `id` / `tool_use_id`
- The `is_error` flag on ToolResult
- **Extract:** Message type definitions — these map directly to Swift types

#### 2.10 Architecture Patterns to Adopt
- The dual-layer design (orchestration + performance) — Orbit uses Swift throughout but the separation of concerns is valuable
- The `runtime.py` routing: how `route_prompt` scores input against commands and tools
- The `execution_registry.py` bridging pattern
- The `cost_tracker.py` accumulation model
- The `parity_audit.py` approach (useful for tracking feature completeness vs. this spec)

#### 2.11 Patterns to Adapt (Not Copy)
- Claw Code's tool system is coding-focused. Orbit needs the same architecture but with a different tool set (more web scraping, less LSP integration)
- Claw Code is single-project. Orbit is multi-project. The session store, context discovery, and memory all need project-scoping
- Claw Code has no scheduler, daemon mode, or deep tasks. These are Orbit-original
- Claw Code's sub-agent system is flat. Orbit uses a tree structure

### Analysis Output

The analysis should produce:
1. `CLAW_CODE_ANALYSIS.md` — detailed findings organized by the sections above
2. `SWIFT_PATTERNS.md` — Swift protocol/type definitions derived from Claw Code's patterns
3. `ADAPTATION_NOTES.md` — specific notes on what changes between Claw Code → Orbit

---

## 3. Core Principles

1. **LLM-Agnostic** — Every feature works with any provider. No Anthropic-specific assumptions leak into core logic. Provider-specific bridges (claude-mem, Basic Memory) are optional add-ons.

2. **Project-Scoped** — Everything is scoped to a project: memory, context, tools, MCP servers, permissions. Global defaults exist but projects can override everything.

3. **Operations-First** — The default persona is a business operations manager, not a coding assistant. Skills, prompts, and context are oriented around business analysis, support triage, marketing, and project management.

4. **Coding-Aware, Not Coding-Focused** — Orbit knows codebases exist (git log, repo structure), can edit files for operational tasks, and can delegate coding to external agents. It does not try to be an IDE.

5. **Proactive, Not Just Reactive** — The daemon mode (KAIROS-equivalent) monitors projects and acts without being asked. The system should be helpful without being annoying (15-second blocking budget, Brief output mode).

6. **Self-Maintaining Memory** — The autoDream system ensures memory stays clean, current, and contradiction-free. Memory is not just append-only — it's actively maintained.

7. **Full Traceability** — Every agent spawn, every tool call, every decision is tracked in the agent tree. You can always answer "what happened and why."

8. **Open Source & Publishable** — No hardcoded project names, API keys, or personal data. Configuration is user-provided. The codebase should be clean enough to publish on GitHub for other solo founders.

---

## 4. Architecture Overview

```
                    ┌─────────────────────────┐
                    │      orbit CLI          │
                    │  (ArgumentParser)       │
                    └────────┬────────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │  Chat /  │  │ Daemon   │  │ Schedule │
        │  Ask     │  │ (KAIROS) │  │ Runner   │
        └────┬─────┘  └────┬─────┘  └────┬─────┘
             │              │              │
             └──────────────┼──────────────┘
                            │
                   ┌────────▼────────┐
                   │  Query Engine   │
                   │  (Turn Loop)    │
                   └────────┬────────┘
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                 │
    ┌─────▼─────┐    ┌─────▼─────┐    ┌─────▼─────┐
    │  Context   │    │   Tool    │    │   Agent   │
    │  Builder   │    │   Pool    │    │   Tree    │
    └─────┬─────┘    └─────┬─────┘    └─────┬─────┘
          │                │                 │
    ┌─────┼─────┐    ┌─────┼─────┐          │
    │     │     │    │     │     │          │
    ▼     ▼     ▼    ▼     ▼     ▼          ▼
  Config Skills Memory Tools  MCP      Sub-agents
  Files        (3-layer) (Builtin   Servers  (recursive
               + Dream   + MCP             spawning)
                bridge)
                            │
                   ┌────────▼────────┐
                   │  LLM Provider   │
                   │  (Anthropic /   │
                   │   OpenAI / ...) │
                   └─────────────────┘
```

---

## 5. Module Specifications

### 5.1 LLM Provider Layer

**Purpose:** Abstract away LLM-specific APIs behind a unified protocol.

**Reference:** Study Claw Code's `models.py` and `api` Rust crate.

```swift
public protocol LLMProvider: Sendable {
    var name: String { get }
    var model: String { get }
    var supportsMCP: Bool { get }
    
    func chat(
        messages: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDefinition]
    ) async throws -> ChatResponse
    
    func stream(
        messages: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<StreamEvent, Error>
    
    func estimateCost(input: Int, output: Int) -> Cost
}
```

**Providers to implement:**
- `AnthropicProvider` — wraps `SwiftAnthropic` package (jamesrochabrun/SwiftAnthropic).
  Supports streaming, tools, vision, extended thinking, prompt caching.
- `OpenAIProvider` — wraps `SwiftOpenAI` package (jamesrochabrun/SwiftOpenAI).
  Supports GPT-5 family, streaming, tools, function calling.

Both SDKs handle the raw HTTP/SSE complexity. The provider implementations
are thin wrappers that adapt SDK types to Orbit's `LLMProvider` protocol.

**Requirements:**
- Streaming via the SDK's built-in SSE support
- Automatic retry on transient errors (SDKs handle some of this; add
  additional retry logic as needed, study Claw Code's retry patterns)
- Token usage tracking and cost estimation per-model
- Auth via multiple modes (see Authentication Architecture below)
- The provider is selected per-project in config, with a global default

#### Authentication Architecture

Orbit supports THREE authentication modes per provider. This is critical because
users may want to use their existing subscriptions (Claude Pro, ChatGPT Plus)
rather than paying for separate API tokens.

**Mode 1: API Key (Direct API billing)**

Traditional approach — user provides an API key, all usage is billed at
API rates per token.

```toml
[auth.anthropic]
mode = "api_key"
api_key_env = "ANTHROPIC_API_KEY"
# or: api_key_keychain = "orbit-anthropic"  # macOS Keychain
```

**Mode 2: Bridge (Uses installed CLI tool + user's subscription)**

Orbit shells out to the official CLI tool (Claude Code, Codex CLI) which
handles its own OAuth authentication. Usage draws from the user's existing
subscription (e.g., Claude Pro $20/mo, ChatGPT Plus $20/mo) — no separate
API billing.

```toml
[auth.anthropic]
mode = "bridge"
cli_path = "/usr/local/bin/claude"   # or auto-detect

[auth.openai]
mode = "bridge"
cli_path = "/usr/local/bin/codex"    # or auto-detect
```

Implementation: The bridge wraps CLI invocations. For Claude Code:
`echo <prompt> | claude --print --output-format json`. For Codex:
non-interactive mode with JSON output. The bridge must handle streaming
output parsing from the subprocess.

Pros: Works immediately, always uses subscription, auth maintained by
official tools, no undocumented API usage.

Cons: Requires CLI tools installed, less control over streaming, slight
process spawn overhead.

**Mode 3: OAuth PKCE (Direct subscription auth, like Claude Code does)**

Orbit implements the same OAuth PKCE flow that Claude Code uses to
authenticate against the user's Anthropic/OpenAI account. This gives
native API access billed to the subscription, without needing the CLI
tools installed.

```toml
[auth.anthropic]
mode = "oauth"
# Reuse Claude Code's existing credentials if available:
credentials_path = "~/.claude/credentials.json"

[auth.openai]
mode = "oauth"
credentials_path = "~/.codex/credentials.json"
```

CRITICAL: Study Claw Code's `rust/crates/api/` — specifically the OAuth
module — to understand the PKCE flow. The implementation includes:
1. Generate PKCE code_verifier + code_challenge
2. Open browser to provider's OAuth authorize endpoint
3. Listen on localhost for callback
4. Exchange authorization code for access token
5. Store credentials (can reuse Claude Code's credential file)
6. Auto-refresh tokens when expired

Key insight: If the user already has Claude Code or Codex CLI installed
and authenticated, Orbit can READ their existing credential files and
reuse the OAuth tokens. No re-authentication needed.

Pros: Full native control, native streaming, subscription billing, no
external CLI dependency.

Cons: Relies on OAuth endpoints that could change, must be studied from
Claw Code's implementation.

**Chosen approach: Hybrid (Approach C)**

All three modes are implemented. The user chooses per-provider in config.
Build order:
- Phase 1 (MVP): API Key + Bridge modes. This covers all users immediately.
- Phase 2: OAuth PKCE mode using patterns extracted from Claw Code's api crate.
- Always: Auto-detect available auth. If Claude Code is installed and
  authenticated, offer to reuse its credentials.

```swift
public enum AuthMode: String, Codable {
    case apiKey       // Direct API key
    case bridge       // Shell out to official CLI
    case oauth        // Direct OAuth PKCE flow
}

public struct AuthConfig: Codable, Sendable {
    let mode: AuthMode
    let apiKeyEnv: String?          // For .apiKey mode
    let apiKeyKeychain: String?     // For .apiKey mode (macOS Keychain)
    let cliPath: String?            // For .bridge mode
    let credentialsPath: String?    // For .oauth mode
}

public protocol Authenticator: Sendable {
    func authenticate() async throws -> AuthToken
    func refresh(token: AuthToken) async throws -> AuthToken
    var isAuthenticated: Bool { get }
}
```

### 5.2 Tool System

**Purpose:** Plugin-based tool architecture where each capability is a self-contained, permission-gated tool with a JSON Schema definition.

**Reference:** Study Claw Code's `tools.py`, `tool_pool.py`, and the Rust `tools` crate (19 JSON Schema specs).

```swift
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var category: ToolCategory { get }
    var schema: JSONSchema { get }   // Parameter schema for LLM
    
    func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult
}

public enum ToolCategory: String, Codable {
    case fileIO       // read, write, edit
    case execution    // bash, shell
    case search       // glob, grep, web search
    case network      // web fetch, API calls
    case desktop      // browser control, computer use, GUI interaction
    case agent        // sub-agent spawning
    case planning     // todo, structured output
    case mcp          // tools from MCP servers
    case plugin       // tools from plugins
}
```

**Built-in tools:**

| Tool | Category | Description |
|------|----------|-------------|
| `bash` | execution | Run shell commands with configurable sandboxing |
| `file_read` | fileIO | Read file contents with offset/limit |
| `file_write` | fileIO | Write or overwrite files |
| `file_edit` | fileIO | Targeted string replacements (like Claude Code's edit) |
| `glob_search` | search | Pattern-based file discovery |
| `grep_search` | search | Regex content search |
| `web_fetch` | network | HTTP requests to URLs |
| `web_search` | network | Web search queries |
| `browser` | desktop | Headless browser control (Playwright/CDP) — navigate, click, extract, screenshot |
| `computer_use` | desktop | Desktop interaction — screenshot, mouse, keyboard control (like Anthropic's computer use) |
| `git_log` | fileIO | Read git history for a repo |
| `agent` | agent | Spawn a sub-agent (see Agent Tree System) |
| `structured_output` | planning | Return structured JSON |
| `send_notification` | network | Push notification / Slack / stdout |

The `browser` tool enables web scraping, form filling, and web-based
automation without MCP — useful for operational tasks like checking
competitor pages, submitting forms, or monitoring web dashboards.

The `computer_use` tool enables desktop GUI interaction — taking
screenshots, moving the mouse, clicking buttons, typing text. This
enables automation of desktop applications that don't have CLI or API
interfaces.

Both of these follow the same Tool protocol as all other tools — they
are permission-gated, JSON Schema defined, and can be enabled/disabled
per project.

**ToolPool:**
- Filters available tools based on project config, permissions, and context
- Caps visible tools to prevent overwhelming the LLM context (study Claw Code's max 15 limit)
- MCP-provided tools are dynamically added when MCP servers are connected

### 5.3 Permission System

**Purpose:** Granular, per-tool access control to prevent unintended actions.

**Reference:** Study Claw Code's `permissions.py` and Rust `permissions` module.

```swift
public enum PermissionMode: String, Codable {
    case allow    // Tool can execute freely
    case deny     // Tool is blocked
    case prompt   // Ask user before executing
}

public struct PermissionPolicy: Codable, Sendable {
    var defaultMode: PermissionMode = .prompt
    var toolOverrides: [String: PermissionMode] = [:]  // per-tool
    var denyPatterns: [String] = []  // regex patterns for denied operations
}
```

**Requirements:**
- Permission policy is configurable globally and per-project
- Interactive prompting in the REPL when mode is `.prompt`
- Deny list supports glob/regex patterns (e.g., deny `rm -rf /`, deny writing to certain dirs)
- Sub-agents inherit parent permissions by default but can be further restricted
- The daemon has its own permission policy (typically more restricted)

### 5.4 Agent Tree System

**Purpose:** Hierarchical sub-agent spawning with full execution tracing. Every agent knows its parent and children. The tree provides complete visibility into what happened during complex operations.

**This is Orbit-original — Claw Code has flat sub-agent spawning. Orbit's tree structure is a differentiator.**

```swift
public final class AgentNode: @unchecked Sendable {
    let id: UUID
    let parentID: UUID?
    let task: String
    let project: String
    let depth: Int
    let maxDepth: Int  // prevent runaway recursion (default: 5)
    
    let provider: any LLMProvider
    let tools: [any Tool]
    let permissions: PermissionPolicy
    let memoryAccess: MemoryAccessLevel  // .full, .readOnly, .none
    
    private(set) var children: [AgentNode] = []
    private(set) var status: AgentStatus
    private(set) var result: AgentResult?
    private(set) var trace: [TraceEntry] = []
    private(set) var usage: UsageSummary = .zero
    private(set) var startTime: Date
    private(set) var endTime: Date?
    
    /// Spawn a child agent
    func spawn(
        task: String,
        tools: [any Tool]? = nil,           // nil = inherit parent's
        permissions: PermissionPolicy? = nil, // nil = inherit parent's
        memoryAccess: MemoryAccessLevel? = nil
    ) async throws -> AgentNode
}

public enum AgentStatus: String, Codable {
    case pending, running, completed, failed, cancelled
}

public struct TraceEntry: Codable, Sendable {
    let timestamp: Date
    let type: TraceType       // .toolCall, .toolResult, .llmCall, .llmResponse, .spawn, .error
    let content: String       // Human-readable description
    let metadata: JSONValue?  // Structured data (tool input/output, token counts, etc.)
}

/// Full tree with global tracking
public actor AgentTree {
    private var root: AgentNode
    private var allNodes: [UUID: AgentNode] = [:]
    
    func trace() -> TreeTrace            // Full execution trace as tree
    func nodesAtDepth(_ depth: Int) -> [AgentNode]
    func totalCost() -> UsageSummary     // Aggregate across all agents
    func totalDuration() -> TimeInterval
    func failedNodes() -> [AgentNode]
}
```

**Behavior:**
- Root agent is created by the QueryEngine for each user query
- Sub-agents are spawned via the `agent` tool
- Each sub-agent gets its own turn loop (runs through the QueryEngine)
- Sub-agents can spawn their own sub-agents (up to maxDepth)
- Parent agents receive their children's results and can reason over them
- The full tree is available for inspection via `/status` or `orbit trace`
- Failed sub-agents don't crash the parent — the parent receives the error and can decide what to do

### 5.5 Memory System (3-Layer)

**Purpose:** Persistent, project-scoped memory that survives across sessions and is automatically maintained.

**Reference:** Study Claude Code's 3-layer memory design as revealed in the source leak, and Claw Code's `session_store.py` and `transcript.py`.

```
Layer 1: Memory Index (ORBIT_MEMORY.md)
├── Lightweight index file per project
├── Contains topic references, not actual content
├── Loaded into context on every session
└── Updated by autoDream during consolidation

Layer 2: Topic Files (topics/*.md)
├── Standalone markdown files per topic
├── Loaded on demand when relevant to current query
├── Created automatically when the system learns something persistent
└── Consolidated and pruned by autoDream

Layer 3: Session Transcripts (transcripts/*.json)
├── Full conversation history, searchable
├── NOT loaded into context (too large)
├── Searchable via /memory search
└── Source material for autoDream consolidation
```

```swift
public protocol MemoryStore: Sendable {
    // Layer 1: Index
    func loadIndex(project: String) async throws -> MemoryIndex
    func updateIndex(project: String, index: MemoryIndex) async throws
    
    // Layer 2: Topics
    func loadTopic(_ ref: TopicRef, project: String) async throws -> TopicContent
    func saveTopic(_ ref: TopicRef, content: TopicContent, project: String) async throws
    func listTopics(project: String) async throws -> [TopicRef]
    
    // Layer 3: Transcripts
    func storeTranscript(_ session: SessionRecord, project: String) async throws
    func searchTranscripts(query: String, project: String, limit: Int) async throws -> [TranscriptMatch]
    func recentTranscripts(project: String, count: Int) async throws -> [SessionRecord]
    
    // Context assembly — smart selection of Layer 1+2 content for the prompt
    func assembleContext(project: String, currentQuery: String) async throws -> String
    
    // Consolidation (used by autoDream)
    func consolidate(project: String, provider: any LLMProvider) async throws -> DreamReport
}
```

**Built-in Implementation:** `SQLiteMemory` — uses SQLite for all three layers with FTS5 for transcript search. Works with any LLM provider.

**Optional Bridges:**
- `ClaudeMemBridge` — syncs with claude-mem when Anthropic provider is active, so memories are also available in Claude Code
- `BasicMemoryBridge` — syncs with Basic Memory MCP for cross-tool compatibility

### 5.6 autoDream — Memory Consolidation

**Purpose:** Background process that consolidates memory during idle periods. Merges observations, resolves contradictions, prunes stale facts, and ensures context is clean and relevant.

**Reference:** Study the autoDream architecture as described in Claude Code leak analysis.

```swift
public struct DreamEngine {
    let provider: any LLMProvider
    let memory: MemoryStore
    
    /// Run the 4-phase dream cycle
    func dream(project: String) async throws -> DreamReport {
        // Phase 1: ORIENT — scan recent transcripts for new observations
        // Phase 2: GATHER — load all topic files, identify conflicts with new observations
        // Phase 3: CONSOLIDATE — use LLM to merge, resolve contradictions, confirm tentative facts
        // Phase 4: PRUNE — remove stale entries, trim oversized topics, update index
    }
}

public struct DreamReport: Codable, Sendable {
    let timestamp: Date
    let project: String
    let transcriptsScanned: Int
    let observationsExtracted: Int
    let conflictsFound: Int
    let conflictsResolved: Int
    let topicsCreated: Int
    let topicsUpdated: Int
    let entriesPruned: Int
    let duration: TimeInterval
}
```

**Trigger conditions:**
- Manually via `/dream` slash command
- Automatically when the daemon detects idle time exceeding a threshold (configurable, default: 30 minutes)
- On a schedule (e.g., nightly at 2 AM)

### 5.7 MCP Client

**Purpose:** Connect Orbit to external tool servers via Model Context Protocol.

**Primary dependency:** The official `modelcontextprotocol/swift-sdk` package
provides the MCP client, transports, and protocol types. Orbit should use
this SDK directly rather than reimplementing MCP from scratch.

**Reference:** Still study Claw Code's MCP implementation for patterns around
tool name normalization, config hashing, server lifecycle management, and
how MCP tools are surfaced to the LLM — these are application-level concerns
that sit on top of the SDK.

```swift
// Using the official MCP SDK
import MCP

// Orbit's wrapper around the official SDK
public struct OrbitMCPRegistry {
    private var clients: [String: Client] = [:]
    
    func connect(server: MCPServerConfig) async throws {
        let client = Client(name: "orbit", version: "0.1.0")
        let transport: any Transport = switch server.type {
            case .http: HTTPClientTransport(endpoint: server.url, streaming: true)
            case .stdio: StdioTransport()
        }
        try await client.connect(transport: transport)
        clients[server.name] = client
    }
    
    func listTools(server: String) async throws -> [ToolDefinition] {
        let (tools, _) = try await clients[server]!.listTools()
        return tools.map { /* normalize to Orbit's ToolDefinition */ }
    }
    
    func callTool(server: String, tool: String, input: JSONValue) async throws -> ToolResult {
        let (content, isError) = try await clients[server]!.callTool(
            name: tool, arguments: input
        )
        return ToolResult(content: content, isError: isError)
    }
}
```

**What the official SDK provides (no need to implement):**
- `Client` — full MCP client with connection lifecycle
- `StdioTransport` — for local MCP servers launched as subprocesses
- `HTTPClientTransport` — for remote MCP servers with SSE streaming
- `InMemoryTransport` — for testing
- Tool listing, calling, resource access, prompt access, sampling
- Request batching for performance

**What Orbit adds on top of the SDK:**
- `OrbitMCPRegistry` — manages multiple MCP server connections per project
- Tool name normalization: `mcp__{server}__{tool}` convention (from Claw Code)
- Config-driven server management (TOML config → connect/disconnect)
- Automatic reconnection on transport failure
- Dynamic tool registration into the ToolPool
- Server lifecycle tied to project activation/deactivation

### 5.8 Query Engine

**Purpose:** Central orchestration hub managing the conversation loop between user, LLM, tools, and sub-agents.

**Reference:** Study Claw Code's `query_engine.py` and Rust `ConversationRuntime`.

```swift
public actor QueryEngine {
    let config: QueryEngineConfig
    let provider: any LLMProvider
    let toolPool: ToolPool
    let memory: MemoryStore
    let agentTree: AgentTree
    
    struct QueryEngineConfig {
        var maxTurns: Int = 8                // Max LLM round-trips per query
        var maxBudgetTokens: Int = 50_000    // Token budget cap per session
        var compactAfterTurns: Int = 12      // Trigger compaction after this many turns
    }
    
    func execute(query: String, project: ProjectConfig) -> AsyncThrowingStream<StreamEvent, Error>
}

public enum StreamEvent: Sendable {
    case messageStart
    case messageDelta(String)           // Streaming text chunk
    case messageStop
    case toolCall(name: String, input: JSONValue)
    case toolResult(name: String, output: JSONValue, isError: Bool)
    case agentSpawn(id: UUID, task: String)
    case agentComplete(id: UUID, result: AgentResult)
    case permissionRequest(tool: String, input: JSONValue)
    case costUpdate(UsageSummary)
}
```

**Turn loop (per turn):**
1. Assemble context: system prompt (context files + skills + memory) + conversation history + available tools
2. Send to LLM provider via streaming
3. If response contains tool calls → execute tools (checking permissions) → feed results back → next turn
4. If response contains agent spawn → create child AgentNode → run sub-agent's own turn loop → feed result back → next turn
5. If response is text only → yield to user → wait for next input
6. After `compactAfterTurns`, trigger compaction (preserve recent N messages, summarize rest)
7. Track token usage and cost throughout

### 5.9 Context System

**Purpose:** Assemble the system prompt from multiple sources with smart filtering and size limits.

**Reference:** Study Claw Code's `context.py`, `PortContext`, and the Rust `prompt` module. Pay attention to `MAX_INSTRUCTION_FILE_CHARS = 4000` and `MAX_TOTAL_INSTRUCTION_CHARS = 12000`.

```swift
public struct ContextBuilder {
    /// Assemble system prompt for a project
    func build(
        project: ProjectConfig,
        memory: MemoryStore,
        currentQuery: String
    ) async throws -> String
}
```

**Context sources (in assembly order):**
1. **Global identity** — who Orbit is (operations manager, not coding assistant)
2. **Project context files** — user-defined `.md` files (brand voice, project overview, etc.)
3. **ORBIT.md files** — discovered by walking the project directory (like CLAUDE.md)
4. **Skills** — relevant skill files loaded based on context
5. **Memory** — Layer 1 index + relevant Layer 2 topics (selected by semantic relevance to current query)
6. **Recent activity** — last few git commits, recent session summary

**Limits:**
- Max 4000 chars per context file
- Max 12000 chars total instruction content
- Content hash deduplication (same content at multiple levels → included once)
- Memory context capped at configurable limit (default: 20 entries)

### 5.10 Skills System

**Purpose:** Modular knowledge files that teach Orbit how to handle specific operational tasks.

```swift
public struct Skill: Codable, Sendable {
    let name: String
    let description: String
    let triggerPatterns: [String]    // Keywords/phrases that activate this skill
    let content: String             // Markdown instruction content
    let requiredMCPs: [String]      // MCP servers this skill needs
    let requiredTools: [String]     // Tools this skill needs
}
```

**Organization:**
```
~/.orbit/skills/
├── _global/                    # Applies to all projects
│   └── brand-voice.md
├── caliverse/
│   ├── daily-brief.md
│   ├── zoho-triage.md
│   ├── seo-monitoring.md
│   └── smart-coach-context.md
└── gardlink/
    └── farm-outreach.md
```

Skills are loaded at context assembly time. The ContextBuilder selects relevant skills based on the current query (keyword matching on triggerPatterns, or explicit invocation).

### 5.11 Scheduler

**Purpose:** Cron-based task scheduling for recurring operational tasks.

```swift
public struct TaskDefinition: Codable, Sendable {
    let name: String
    let slug: String
    let project: String
    let cron: String                    // Standard cron expression
    let provider: String?               // Override project default
    let model: String?                  // Override project default
    let promptFile: String?             // Path to prompt markdown
    let promptText: String?             // Or inline prompt
    let mcpServers: [String]            // Which MCPs to activate
    let skills: [String]               // Which skills to load
    let output: TaskOutputConfig
    let enabled: Bool
}

public struct TaskOutputConfig: Codable, Sendable {
    let format: OutputFormat            // .markdown, .json
    let saveTo: String?                 // Directory for output files
    let notify: NotifyChannel           // .stdout, .slack, .file
}
```

**Requirements:**
- Tasks defined in TOML files in `~/.orbit/schedules/`
- Manual trigger: `orbit run <task-slug>`
- List: `orbit schedule list`
- Enable/disable: `orbit schedule enable/disable <slug>`
- View logs: `orbit logs <slug> --last N`
- Each execution creates a log entry with: timestamp, duration, token usage, cost, output, errors

### 5.12 Orbit Daemon (KAIROS-equivalent)

**Purpose:** Always-on background agent that monitors projects and acts proactively.

**Reference:** Study the KAIROS architecture from Claude Code leak analysis.

```swift
public actor OrbitDaemon {
    let config: DaemonConfig
    
    struct DaemonConfig {
        var tickInterval: TimeInterval = 300    // Check every 5 minutes
        var maxBlockingBudget: TimeInterval = 15  // Max 15s for proactive actions
        var dreamThreshold: TimeInterval = 1800   // Dream after 30min idle
        var briefMode: Bool = true                // Concise output for daemon actions
        var notifyChannel: NotifyChannel = .stdout
    }
}
```

**Tick loop behavior:**
1. Every `tickInterval`, the daemon wakes up
2. For each monitored project:
   a. Check MCP data sources for changes (new tickets, metric drops, etc.)
   b. Check daily log for patterns
   c. Ask the LLM: "Given this context, should I notify the user, take action, or stay quiet?"
3. Based on LLM decision:
   - **Quiet:** Append observation to daily log, do nothing visible
   - **Notify:** Send alert via configured channel
   - **Act:** Execute a bounded action (within blocking budget), log it
4. If idle long enough, trigger autoDream consolidation

**Daily logs:**
- Append-only markdown files: `~/.orbit/logs/daily/{project}/{YYYY-MM-DD}.md`
- Every tick appends what was observed
- These logs are the source material for autoDream

**Daemon lifecycle:**
- `orbit daemon start` — runs in background (launchd on macOS, systemd on Linux)
- `orbit daemon stop`
- `orbit daemon status`
- `orbit daemon logs --today`

### 5.13 Deep Tasks (ULTRAPLAN-equivalent)

**Purpose:** Long-running, asynchronous analysis tasks that require significant reasoning time.

```swift
public struct DeepTask: Codable, Sendable {
    let id: UUID
    let name: String
    let prompt: String
    let projects: [String]              // Can span multiple projects
    let provider: String?               // Can use a more powerful model
    let model: String?                  // e.g., claude-opus-4-6 for deep analysis
    let maxDuration: TimeInterval       // Cap at 30 minutes
    let mcpServers: [String: [String]]  // project → [servers]
    let status: DeepTaskStatus
}

public enum DeepTaskStatus: String, Codable {
    case pending, running, completed, failed, reviewPending
}
```

**Behavior:**
- Launched via `orbit deep "Analyze Q1 performance across all projects"` or `/deep` in REPL
- Runs in background — user can continue working
- Can pull data from multiple projects' MCP servers
- Uses a configurable model (default to the most capable available)
- On completion, presents results for review
- Results stored as a report in `~/.orbit/deep-tasks/{id}/`

### 5.14 Coding Awareness & Delegation

**Purpose:** Orbit understands that code exists, can read codebases, and delegates actual coding work to external agents.

```swift
public struct CodingAwareness {
    /// Read recent git activity for a project
    func recentCommits(repo: URL, days: Int) async throws -> [CommitSummary]
    
    /// Get high-level repo structure
    func repoStructure(repo: URL) async throws -> RepoStructure
    
    /// Read a specific file (for operational context, not editing)
    func readFile(path: String, repo: URL) async throws -> String
}

public struct CodingDelegate {
    /// Available coding agents on this system
    func availableAgents() -> [CodingAgent]
    
    /// Delegate a coding task to an external agent
    func delegate(
        task: String,
        repo: URL,
        agent: CodingAgent,
        branch: String?
    ) async throws -> DelegationResult
}

public enum CodingAgent: String, Codable, CaseIterable {
    case claudeCode = "claude-code"
    case codexCLI = "codex-cli"
    case custom
}
```

**Important:** Orbit can edit files itself (via `file_write` and `file_edit` tools) for operational tasks — editing config files, updating markdown docs, modifying TOML configs, etc. The `CodingDelegate` is specifically for delegating **project codebase changes** (implementing features, fixing bugs, refactoring) to purpose-built coding agents.

### 5.15 Session Management

**Purpose:** Persist, resume, and compact interactive sessions.

**Reference:** Deeply study Claw Code's `session_store.py` and `transcript.py`.

```swift
public struct SessionStore {
    func save(_ session: SessionRecord) async throws
    func load(id: String) async throws -> SessionRecord
    func list(project: String, limit: Int) async throws -> [SessionSummary]
    func resume(id: String) async throws -> SessionRecord
}

public struct CompactionEngine {
    let config: CompactionConfig
    
    struct CompactionConfig {
        var preserveRecentMessages: Int = 4
        var maxEstimatedTokens: Int = 10_000
    }
    
    func shouldCompact(messages: [ChatMessage]) -> Bool
    func compact(messages: [ChatMessage]) async throws -> [ChatMessage]
}
```

**Session storage:** `~/.orbit/sessions/{project}/{session-id}.json`

### 5.16 Slash Commands

**Purpose:** Interactive commands available in the REPL.

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/status` | Current project status, active agents, token usage |
| `/compact` | Manually trigger transcript compaction |
| `/cost` | Show accumulated session costs |
| `/model` | Switch active model |
| `/memory` | View/search/manage memory |
| `/dream` | Trigger manual autoDream consolidation |
| `/deep` | Launch a deep task |
| `/project` | Switch active project |
| `/resume` | Resume a previous session |
| `/config` | View/edit configuration |
| `/export` | Export conversation transcript |
| `/trace` | Show agent tree trace for current session |
| `/permissions` | View/modify tool permissions |
| `/clear` | Clear conversation |
| `/exit` | Exit session |

### 5.17 CLI Interface

**Purpose:** Top-level commands for non-interactive use.

```bash
# ─── Default: just type orbit ───
orbit                                   # Launches interactive REPL
                                        # If one project configured: uses it
                                        # If multiple: shows project picker
                                        # Equivalent to `orbit chat`

# ─── Interactive with specific project ───
orbit chat caliverse                    # Interactive REPL with project context
orbit chat                              # Same as bare `orbit` — picks default/shows picker

# Core operations
orbit ask <project> "<query>"           # One-shot query
orbit run <task-slug>                   # Run a scheduled task manually
orbit deep "<prompt>"                   # Launch a deep task

# Project management
orbit init                              # Interactive setup wizard
orbit project list
orbit project add --interactive
orbit project show <slug>
orbit project switch <slug>

# Memory
orbit memory search <project> "<query>"
orbit memory list <project> --recent N
orbit memory export <project> --format markdown
orbit memory import <project> <file>
orbit memory dream <project>            # Trigger autoDream

# Scheduler
orbit schedule list
orbit schedule add --interactive
orbit schedule enable <slug>
orbit schedule disable <slug>
orbit logs <slug> --last N

# Daemon
orbit daemon start
orbit daemon stop
orbit daemon status
orbit daemon logs --today

# Auth
orbit auth add <provider>               # Interactive key setup
orbit auth status
orbit auth remove <provider>

# Coding
orbit code activity <project> --days N
orbit code delegate <project> "<task>" --agent claude-code

# Skills
orbit skills list [project]
orbit skills add <project> <file>

# Trace & diagnostics
orbit trace <session-id>                # Full agent tree trace
orbit cost --today                      # Today's total cost across all
orbit status                            # Overview of all projects
orbit version
```

---

## 6. Configuration Design

### Global Config: `~/.orbit/orbit.toml`

```toml
[defaults]
provider = "anthropic"
model = "claude-sonnet-4-6"
memory_backend = "sqlite"

[auth.anthropic]
# mode = "api_key"                      # Direct API billing
# api_key_env = "ANTHROPIC_API_KEY"

# mode = "bridge"                       # Use installed Claude Code CLI
# cli_path = "/usr/local/bin/claude"    # Auto-detected if not set

mode = "oauth"                          # Direct subscription auth
credentials_path = "~/.claude/credentials.json"  # Reuse Claude Code's auth

[auth.openai]
# mode = "api_key"
# api_key_env = "OPENAI_API_KEY"

mode = "bridge"                         # Use installed Codex CLI
# cli_path = "/usr/local/bin/codex"

[memory]
db_path = "~/.orbit/memory.db"
auto_summarize = true
max_context_entries = 20

[daemon]
enabled = false
tick_interval = 300
dream_threshold = 1800
notify = "stdout"

[permissions]
default_mode = "prompt"
deny_patterns = [
    "rm -rf /",
    "sudo rm",
]

[context]
max_file_chars = 4000
max_total_chars = 12000
```

### Project Config: `~/.orbit/projects/{slug}.toml`

```toml
[project]
name = "My Project"
slug = "my-project"
description = "Description of the project"
repo = "~/Projects/my-project"

# Override global defaults
provider = "anthropic"
model = "claude-sonnet-4-6"

[context]
files = [
    "docs/about.md",
    "docs/brand-voice.md",
]

[skills]
dirs = ["skills/my-project"]

[coding]
enabled = true
preferred_agent = "claude-code"
watch_branches = ["main", "develop"]

[permissions]
default_mode = "prompt"
tool_overrides = { bash = "allow", file_write = "prompt" }

[mcps.my-analytics]
type = "http"
url = "https://example.com/mcp"

[mcps.my-support]
type = "http"
url = "https://support.example.com/mcp"
headers = { key = "secret" }
```

### Schedule Config: `~/.orbit/schedules/{slug}.toml`

```toml
[task]
name = "Daily Brief"
slug = "daily-brief"
project = "my-project"
cron = "0 9 * * *"
enabled = true

[task.prompt]
file = "prompts/daily-brief.md"

[task.mcps]
include = ["my-analytics", "my-support"]

[task.output]
format = "markdown"
save_to = "~/.orbit/logs/daily-brief/"
notify = "stdout"
```

---

## 7. Directory Structure

### Source Code

```
orbit/
├── Package.swift
├── README.md
├── LICENSE
├── Sources/
│   ├── orbit/                          # CLI executable
│   │   └── OrbitCLI.swift
│   │
│   └── OrbitCore/                      # Core library
│       ├── Config/
│       ├── Provider/
│       ├── Tools/
│       │   ├── Builtin/
│       │   └── External/
│       ├── Permissions/
│       ├── Agents/
│       ├── Memory/
│       │   └── Bridges/
│       ├── MCP/
│       ├── Engine/
│       ├── Context/
│       ├── Skills/
│       ├── Scheduler/
│       ├── Daemon/
│       ├── DeepTask/
│       ├── Coding/
│       ├── Session/
│       ├── Commands/
│       └── History/
│
├── Tests/
│   └── OrbitCoreTests/
│
└── docs/
    ├── ARCHITECTURE.md
    ├── CONFIGURATION.md
    ├── SKILLS_GUIDE.md
    └── CLAW_CODE_ANALYSIS.md           # Pre-implementation analysis
```

### User Data (Runtime)

```
~/.orbit/
├── orbit.toml                          # Global config
├── memory.db                           # SQLite memory store
├── projects/
│   ├── my-project.toml
│   └── another-project.toml
├── schedules/
│   ├── daily-brief.toml
│   └── weekly-report.toml
├── skills/
│   ├── _global/
│   └── my-project/
├── sessions/
│   └── my-project/
│       └── {session-id}.json
├── transcripts/
│   └── my-project/
│       └── {date}/
│           └── {session-id}.json
├── logs/
│   ├── daily/                          # Daemon daily logs
│   │   └── my-project/
│   │       └── {YYYY-MM-DD}.md
│   ├── tasks/                          # Scheduled task execution logs
│   │   └── daily-brief/
│   │       └── {timestamp}.json
│   └── deep-tasks/
│       └── {task-id}/
│           ├── result.md
│           └── trace.json
└── prompts/                            # Prompt templates
    └── daily-brief.md
```

---

## 8. Build Phases

### Phase 0 — Claw Code Analysis (Week 1)
- Clone and deeply study both repos:
  - PRIMARY: `https://github.com/ultraworkers/claw-code-parity` (346 commits, active)
  - SECONDARY: `https://github.com/ultraworkers/claw-code` (original, locked)
- Produce `CLAW_CODE_ANALYSIS.md`, `SWIFT_PATTERNS.md`, `ADAPTATION_NOTES.md`
- Identify all architectural patterns to adopt and adapt
- Map Claw Code modules to Orbit modules
- Pay special attention to: MCP integration, session compaction, query engine
  turn loop, tool pool filtering, permission enforcement, OAuth PKCE flow

### Phase 1 — Core Skeleton (Week 2)
- `Package.swift` with all dependencies (MCP SDK, SwiftAnthropic, SwiftOpenAI,
  GRDB, TOMLKit, swift-argument-parser, swift-log)
- Config loading (`orbit.toml`, project TOML via TOMLKit)
- LLM Provider protocol + Anthropic implementation using `SwiftAnthropic`
- Auth system: API key mode working first (simplest path)
- Basic `orbit ask <project> "<query>"` working end-to-end
- Message types (ChatMessage, StreamEvent, etc.)

### Phase 2 — Tool System + Permissions (Week 3)
- Tool protocol + built-in tools (bash, file_read, file_write, file_edit, grep, glob)
- ToolPool with filtering (study Claw Code's max 15 limit)
- Permission system (Allow/Deny/Prompt)
- Query Engine turn loop with tool execution

### Phase 3 — Memory + Context (Week 4)
- SQLiteMemory using GRDB.swift (all 3 layers with FTS5 for transcript search)
- ContextBuilder (context files + skills + memory → system prompt)
- ORBIT.md file discovery (walk directory hierarchy, char limits, dedup)
- Session compaction (port algorithm from Claw Code)
- Skill loader

### Phase 4 — MCP Integration (Week 5)
- Integrate official `modelcontextprotocol/swift-sdk`
- Use `HTTPClientTransport` for cloud MCP servers (Mixpanel, Zoho, etc.)
- Use `StdioTransport` for local MCP servers
- MCP tool registration into ToolPool
- Tool name normalization (`mcp__{server}__{tool}`)
- OAuth PKCE flow for authenticated servers

### Phase 5 — Agent Tree (Week 6)
- AgentNode + AgentTree actor implementation
- Agent tool (spawns sub-agents with tree tracking)
- Recursive turn loops for sub-agents
- Full trace tracking with cost aggregation
- `/trace` command

### Phase 6 — Interactive REPL (Week 7)
- Chat session with readline (history, autocomplete)
- Slash command system
- Streaming output rendering (study Claw Code's terminal rendering)
- Session persistence + resume
- OpenAI provider using `SwiftOpenAI`
- Bridge auth mode (shell out to claude/codex CLIs)

### Phase 7 — Scheduler + Daemon (Week 8)
- TaskScheduler with cron parsing (Swift Concurrency based)
- TaskRunner (wires project config + MCPs + prompt)
- Execution logging to SQLite
- Daemon mode (tick loop, daily logs, proactive decisions)
- launchd plist generation for macOS, systemd unit for Linux

### Phase 8 — autoDream + Deep Tasks (Week 9)
- DreamEngine (4-phase consolidation: Orient → Gather → Consolidate → Prune)
- Deep task runner (background, async, cross-project)
- `/dream` and `/deep` commands
- Integration with daemon idle detection

### Phase 9 — Browser + Computer Use + Polish (Week 10)
- Browser tool (CDP over WebSocket or Playwright bridge)
- Computer use tool (CoreGraphics on macOS)
- CodingAwareness (git log, repo structure)
- CodingDelegate (shell out to Claude Code / Codex)
- OAuth PKCE auth mode (study Claw Code's implementation)
- `orbit init` wizard
- Shell completions (zsh, bash, fish)
- Plugin system skeleton
- Error handling polish
- README + docs for GitHub

---

## 9. Dependencies

### Core Swift Packages

| Package | Source | Purpose |
|---------|--------|---------|
| `swift-argument-parser` | apple/swift-argument-parser | CLI command parsing and subcommands |
| `swift-nio` | apple/swift-nio | Async networking foundation |
| `async-http-client` | swift-server/async-http-client | HTTP client for API calls |
| `GRDB.swift` | groue/GRDB.swift | SQLite for memory store (FTS5 support) |
| `swift-log` | apple/swift-log | Structured logging |
| `swift-crypto` | apple/swift-crypto | Hashing, PKCE code challenge |
| `TOMLKit` | LebJe/TOMLKit | TOML configuration file parsing |

### MCP SDK

| Package | Source | Purpose |
|---------|--------|---------|
| `MCP` (swift-sdk) | **modelcontextprotocol/swift-sdk** | **Official** MCP SDK — client + server, Stdio + HTTP + SSE transports, tool calling, resource access, OAuth. This is the cornerstone dependency for all MCP integration. v0.10.2, 1.2k stars. |

This is the **official** Model Context Protocol SDK maintained by the MCP
organization. It provides `Client`, `StdioTransport`, `HTTPClientTransport`,
tool listing/calling, resource subscriptions, request batching, and sampling.
Orbit should use this directly rather than implementing MCP from scratch.

### LLM Provider SDKs

| Package | Source | Purpose |
|---------|--------|---------|
| `SwiftAnthropic` | jamesrochabrun/SwiftAnthropic | Anthropic Claude API — streaming, tools, web search, prompt caching, extended thinking, vision. Most comprehensive Swift Anthropic SDK. |
| `SwiftOpenAI` | jamesrochabrun/SwiftOpenAI | OpenAI API — GPT-5 family, streaming, tools, function calling. Same author as SwiftAnthropic, consistent API patterns. |

Both SDKs are by the same author (James Rochabrun), actively maintained,
and support the latest model families. Using the same author's packages
ensures consistent API patterns across providers.

**Alternative SDKs (evaluate if primary choices have gaps):**
- `AnthropicSwiftSDK` (fumito-ito) — has built-in computer use + bash tool support, Bedrock/Vertex AI
- `MacPaw/OpenAI` — Responses API, built-in MCP tool support, very popular

### Terminal UI

| Package | Source | Purpose |
|---------|--------|---------|
| TBD — evaluate during Phase 6 | | REPL readline, syntax highlighting, markdown rendering |

Options to evaluate:
- Build custom on top of `swift-nio` terminal handling
- `SwiftTerm` for terminal emulation primitives
- Study Claw Code's `rusty-claude-cli` approach (crossterm + syntect + pulldown_cmark)
  and find Swift equivalents

### System Dependencies

- Swift 6.0+ toolchain (required by MCP SDK)
- SQLite3 (bundled with macOS/Linux)
- Git (for coding awareness)
- Playwright / Chrome (optional, for browser tool — evaluate CDP over WebSocket)

### Optional Runtime Dependencies

- `claude` CLI (for bridge auth mode + coding delegation to Claude Code)
- `codex` CLI (for bridge auth mode + coding delegation to Codex)
- `basic-memory` (for Basic Memory MCP bridge)

---

## 10. Design Decisions & Rationale

### Why Swift?
- **Official MCP SDK** — the Model Context Protocol has an official Swift SDK
  (`modelcontextprotocol/swift-sdk`), providing battle-tested MCP client/server
  implementation. Go has no official equivalent.
- **Rich LLM SDK ecosystem** — multiple mature, actively maintained packages
  for both Anthropic (`SwiftAnthropic`) and OpenAI (`SwiftOpenAI`) APIs,
  with streaming, tool use, and latest model support.
- **Actors for concurrency** — `AgentTree`, `OrbitDaemon`, `TaskScheduler`,
  and `MemoryStore` are all shared mutable state accessed by multiple tasks.
  Swift actors provide compile-time thread safety without manual locking.
- **Expressive type system** — enums with associated values (`StreamEvent`,
  `ToolResult`, `AuthMode`, `PermissionMode`), protocols with associated types
  (`LLMProvider`, `Tool`, `MemoryStore`), and generics enable safe, self-documenting
  architecture that catches errors at compile time.
- **AsyncStream** — the query engine's streaming events map directly to
  `AsyncThrowingStream<StreamEvent, Error>`, providing typed, cancellable
  event streams with backpressure.
- **Native macOS integration** — Keychain for credential storage, launchd for
  daemon management, system notifications. First-class on Swift, requires
  workarounds in other languages.
- **Author familiarity** — the author has deep Swift experience from iOS
  development (Caliverse), enabling faster code review, debugging, and
  architectural decisions.
- **Single binary** — compiles to a native binary with no runtime dependencies.
- **Trade-off acknowledged:** smaller contributor pool for AI tooling compared
  to Go/Python/Rust. This is acceptable because the project is maintainer-driven
  and the ecosystem advantages outweigh contributor pool concerns.

### Why no frameworks?
- Orbit is a CLI tool, not a web server. There is no need for Vapor,
  Hummingbird, or any HTTP server framework.
- All HTTP is **outbound** (calling LLM APIs, connecting to MCP servers).
  This is handled by `async-http-client` and the LLM/MCP SDKs.
- The CLI layer uses `swift-argument-parser` — lightweight, Apple-maintained.
- SQLite uses `GRDB.swift` — a focused database library, not an ORM framework.
- Config uses `TOMLKit` — a parser, not a framework.
- The architectural principle: **targeted packages over frameworks**.
  Each dependency solves exactly one problem. No framework lock-in,
  no unused abstractions, no dependency bloat.
- The only "big" dependencies are the MCP SDK and LLM SDKs, which are
  essential and provide significant value over hand-rolling.

### The bare `orbit` command
- Typing `orbit` with no arguments should feel identical to typing `claude`
  for Claude Code — it drops you into a full interactive session immediately.
- If only one project is configured: use it automatically.
- If multiple projects exist: show an interactive picker (arrow keys to select).
- If no projects exist: launch `orbit init` setup wizard.
- The REPL should show: project name, active model, connected MCP servers,
  and a prompt ready for input.
- This is the primary interface. All other commands (`orbit ask`, `orbit run`,
  `orbit schedule`, etc.) are secondary entry points for automation and scripting.

### Why not a Claw Code fork?
- Claw Code is Python + Rust — different language entirely
- Claw Code is a coding agent — fundamentally different purpose
- We want the architectural patterns, not the codebase
- Clean implementation avoids inheriting coding-agent assumptions

### Why 3-layer memory?
- Layer 1 (index) is always loaded — lightweight orientation
- Layer 2 (topics) is loaded on demand — avoids context bloat
- Layer 3 (transcripts) is never loaded but searchable — full history without cost
- This is the pattern Claude Code uses internally and it works at scale

### Why tree-based agents instead of flat?
- Flat agents have no visibility into what sub-agents did
- Tree structure enables: full tracing, cost aggregation, failure isolation
- Parent agents can make decisions based on multiple children's results
- Depth limits prevent runaway recursion

### Why operations-first instead of coding-first?
- The coding agent space is crowded (Claude Code, Codex, Cursor, Claw Code, etc.)
- Nobody has built an operations agent for solo founders
- Operations tasks (support triage, analytics review, SEO monitoring) are repetitive and high-value
- Coding delegation means Orbit doesn't need to compete — it orchestrates

---

## 11. Architecture & Coding Style Guidelines

### Follow Claw Code's Architectural Patterns

Orbit's architecture and code organization should mirror Claw Code's patterns
wherever applicable. Specifically:

1. **Dual-layer thinking:** Claw Code separates orchestration (Python) from
   performance-critical paths (Rust). Orbit uses Swift throughout but should
   maintain the same separation of concerns — high-level orchestration logic
   (query engine, context builder, daemon) should be clearly separated from
   low-level I/O (streaming parsers, MCP transports, file operations).

2. **Module boundaries:** Each module owns exactly one responsibility. Follow
   Claw Code's pattern where `tools.py` owns tool inventory, `commands.py`
   owns command dispatch, `models.py` owns shared types. No god-files.

3. **Configuration-driven:** Like Claw Code's `ConfigSources` (User, Project,
   Local), Orbit should support cascading configuration with clear priority.

4. **Snapshot-based inventories:** Claw Code loads tool and command inventories
   from snapshot files. Orbit should similarly have declarative tool/command
   registries rather than hardcoded lists.

5. **Event-driven streaming:** Follow Claw Code's 6 streaming event types
   (`message_start`, `command_match`, `tool_match`, `permission_denial`,
   `message_delta`, `message_stop`). Extend as needed but keep the same
   pattern of typed events flowing through an async stream.

### Extensibility as a First-Class Concern

**Every major subsystem must be designed for extension:**

#### Tool Extensibility
New tools should be addable without modifying core code:

```swift
// Third-party tool — just implement the protocol
public struct SlackNotifyTool: Tool {
    public let name = "slack_notify"
    public let description = "Send a message to a Slack channel"
    public let category: ToolCategory = .network
    public let schema: JSONSchema = ...
    
    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        // implementation
    }
}

// Register at startup
toolRegistry.register(SlackNotifyTool())
```

#### Plugin System
Orbit should support a plugin model inspired by Claw Code's `plugins` crate:

```swift
public protocol OrbitPlugin: Sendable {
    var name: String { get }
    var version: String { get }
    
    /// Called during bootstrap — register tools, commands, hooks
    func activate(registry: PluginRegistry) async throws
    
    /// Called on shutdown
    func deactivate() async throws
}

public struct PluginRegistry {
    func registerTool(_ tool: any Tool)
    func registerCommand(_ command: any SlashCommand)
    func registerHook(_ hook: any LifecycleHook)
    func registerMemoryBridge(_ bridge: any MemoryStore)
    func registerProvider(_ provider: any LLMProvider)
}
```

Plugins can:
- Add new tools (e.g., a Jira plugin adding `jira_create_ticket` tool)
- Add new slash commands (e.g., `/deploy` for a deployment plugin)
- Add lifecycle hooks (e.g., post-session hooks for analytics)
- Add memory bridges (e.g., a Notion sync bridge)
- Add LLM providers (e.g., a local Ollama provider)

Plugin discovery: plugins live in `~/.orbit/plugins/` as Swift packages
or dynamically loaded libraries. Built-in plugins are bundled with the
binary.

#### Skill Extensibility
Skills are already extensible (just markdown files in directories), but
the skill system should support:
- Skill dependencies (skill A requires MCP server X)
- Skill triggers (activate skill based on keywords or context)
- Skill templates (parameterized skills for common patterns)
- Community skill packs (installable skill collections)

#### MCP Server Extensibility
New MCP transport types should be addable via the plugin system:

```swift
public protocol MCPTransport: Sendable {
    var type: String { get }
    func connect(config: MCPServerConfig) async throws
    func send(_ request: MCPRequest) async throws -> MCPResponse
    func disconnect() async throws
}
```

### Code Quality Standards

- **Protocol-oriented:** Define protocols for all major abstractions. Concrete
  types implement protocols. This enables testing, swapping, and extending.
- **Actor-based concurrency:** Use Swift actors for shared mutable state
  (AgentTree, TaskScheduler, OrbitDaemon, MemoryStore).
- **Structured error handling:** Define typed errors per module. No stringly-typed
  errors.
- **Comprehensive logging:** Use `swift-log` with structured metadata. Every
  tool call, LLM request, agent spawn, and daemon tick should be loggable.
- **Testability:** OrbitCore is a library that can be tested without the CLI.
  Every protocol should have a mock implementation in tests.

---

## 12. GitHub Repository

### Repository Name

```
orbit-agent
```

**GitHub URL:** `github.com/{owner}/orbit-agent`

**CLI command:** `orbit`

**Swift package name:** `OrbitAgent`

### Repository Description

```
Open-source, LLM-agnostic agent platform for project operations. 
Multi-project management, scheduled tasks, proactive monitoring, 
memory consolidation, and MCP integration — built in Swift.
```

### Repository Topics

```
agent, ai, cli, llm, mcp, operations, automation, swift, 
multi-agent, memory, scheduler, anthropic, openai
```

### README Badge Ideas

```
[Swift 6.0+] [License: MIT] [Platform: macOS | Linux] [LLM: Any]
```

---

## 13. Pre-Launch Considerations

### Things to Resolve Before Starting

#### License
**Recommendation: MIT License.** It's the most permissive, encourages
adoption, and matches the solo-founder target audience who want to fork
and customize. Apache 2.0 is the alternative if patent protection is
desired.

#### Platform Support
- **Primary:** macOS (author's platform, Swift is native)
- **Secondary:** Linux (Swift on Linux is mature for server-side, but
  `computer_use` and `browser` tools may need platform-specific code)
- **Not planned:** Windows (Swift on Windows is experimental)

For cross-platform concerns:
- Keychain → use `Security` framework on macOS, fall back to encrypted
  file on Linux
- launchd → use `launchd` on macOS, `systemd` on Linux
- Browser tool → Playwright/CDP works cross-platform
- Computer use → needs platform abstraction (CoreGraphics on macOS,
  X11/Wayland on Linux)

#### TOML Parser
Swift doesn't have a built-in TOML parser. Options:
- `TOMLKit` (Swift-native, most stars)
- `swift-toml` (pure Swift)
- Evaluate during Phase 1 and pick the most reliable

#### Cost Protection
Add safeguards against runaway costs:
- Per-session token budget (default: 50,000 tokens)
- Per-day cost cap (configurable)
- Daemon tick cost tracking with automatic pause if threshold exceeded
- Deep task cost estimation before execution
- `orbit cost --today` shows aggregate spend

#### Data Migration
Design the config and data formats with versioning from day 1:
- `orbit.toml` should have a `version = 1` field
- `memory.db` schema should have a version table
- Session JSON should include a schema version
- Write migration logic early — config format WILL evolve

#### Security Considerations
- API keys and OAuth tokens must be stored securely (Keychain on macOS,
  encrypted file with restrictive permissions on Linux)
- MCP server credentials in config files should support env var references
  (`${ENV_VAR}` syntax) so secrets aren't stored in plaintext
- The daemon runs with the user's permissions — document this clearly
- Plugin system needs sandboxing considerations for untrusted plugins
- Tool execution (especially `bash`, `browser`, `computer_use`) needs
  the permission system enforced strictly

#### Testing Strategy
- Unit tests for each module (protocols + mocks)
- Integration tests for LLM provider calls (with recorded responses)
- Integration tests for MCP client (with a mock MCP server)
- End-to-end tests for the query engine turn loop
- Snapshot tests for context assembly
- No tests that require live API calls in CI (use recorded fixtures)

#### Documentation Plan
- `README.md` — quick start, installation, basic usage
- `docs/ARCHITECTURE.md` — system design overview
- `docs/CONFIGURATION.md` — full config reference
- `docs/TOOLS.md` — built-in tool reference
- `docs/PLUGINS.md` — plugin development guide
- `docs/SKILLS_GUIDE.md` — how to write skills
- `docs/CLAW_CODE_ANALYSIS.md` — the pre-implementation analysis (Phase 0)
- Inline code documentation on all public APIs

#### CI/CD
- GitHub Actions for: build (macOS + Linux), test, lint (SwiftLint)
- Release automation: build universal binary for macOS, Linux x86_64 binary
- Installation script: `curl -fsSL https://orbit-agent.dev/install.sh | bash`
  (future, once stable)

---

*End of specification. The implementer should begin with Phase 0: Claw Code Analysis.*

