# Claw Code Architecture Analysis

**Date:** 2026-04-04
**Repos Analyzed:**
- PRIMARY: `ultraworkers/claw-code-parity` (292+ commits, 48,599 Rust LOC, 9 crates)
- SECONDARY: `ultraworkers/claw-code` (44 commits, original Python workspace)

**Purpose:** Extract architectural patterns for Orbit's Swift implementation.

---

## 1. MCP Integration Patterns

### 1.1 Server Registry Pattern

**Files:** `rust/crates/runtime/src/mcp.rs`, `mcp_tool_bridge.rs`, `mcp_stdio.rs`, `mcp_client.rs`, `mcp_lifecycle_hardened.rs`

Claw Code manages MCP servers through a layered registry:

- **`McpToolRegistry`** (`mcp_tool_bridge.rs:66`): Thread-safe registry using `Arc<Mutex<HashMap<String, McpServerState>>>`. Stores per-server state including connection status, tools, resources, and error messages.

- **`McpServerManager`** (`mcp_stdio.rs`): Manages stdio-based MCP server processes. Wrapped in `Arc<Mutex<>>` and wired to the registry via `OnceLock`.

- **`McpConnectionStatus`** enum: `Disconnected`, `Connecting`, `Connected`, `AuthRequired`, `Error` — five lifecycle states.

### 1.2 Name Normalization

**File:** `rust/crates/runtime/src/mcp.rs:7-37`

```rust
pub fn normalize_name_for_mcp(name: &str) -> String {
    // Replace non-alphanumeric chars (except _ and -) with _
    // For claude.ai servers: collapse underscores, trim leading/trailing _
}

pub fn mcp_tool_prefix(server_name: &str) -> String {
    format!("mcp__{}__", normalize_name_for_mcp(server_name))
}

pub fn mcp_tool_name(server_name: &str, tool_name: &str) -> String {
    format!("{}{}", mcp_tool_prefix(server_name), normalize_name_for_mcp(tool_name))
}
```

**Convention:** `mcp__{normalized_server}__{normalized_tool}`. Special handling for `claude.ai` prefixed servers (collapse underscores). Characters allowed: `[a-zA-Z0-9_-]`, everything else → `_`.

### 1.3 Config Hashing

**File:** `rust/crates/runtime/src/mcp.rs:84-121`

`scoped_mcp_config_hash()` generates a deterministic hex hash of server configuration for identity comparison:

```
stdio|command|[args]|env_signature|timeout
sse|url|headers|headers_helper|oauth_signature
http|url|headers|headers_helper|oauth_signature
ws|url|headers|headers_helper
sdk|name
claudeai-proxy|url|id
```

Uses SHA-256 hex digest of the rendered configuration string. This allows detecting when a server config has changed and needs reconnection.

### 1.4 Server Lifecycle

- Servers have 5 connection states (enum `McpConnectionStatus`)
- `register_server()` stores full state including tools and resources
- `list_servers()` returns all tracked server states
- `list_resources()` and `read_resource()` validate connection status before returning data
- `call_tool()` proxies through the manager, routing by server name
- CCR proxy URLs are unwrapped to reveal underlying MCP endpoint URLs

### 1.5 MCP Config Scoping

**File:** `rust/crates/runtime/src/config.rs:82-93`

MCP configs are scoped to `ConfigSource` (User/Project/Local) via `ScopedMcpServerConfig`. The `McpConfigCollection` holds all servers after scope-aware merging:

```rust
pub struct McpConfigCollection {
    servers: BTreeMap<String, ScopedMcpServerConfig>,
}
```

Transport types supported: `Stdio`, `Sse`, `Http`, `Ws`, `Sdk`, `ManagedProxy`.

### 1.6 Key Patterns for Orbit

- **Server identity = config hash** — change detection via deterministic hashing
- **Normalized tool names** prevent collisions across servers
- **Connection status enum** enables UI/monitoring without polling internals
- **Scoped config** allows user/project/local overrides — Orbit needs this per-project

---

## 2. Session & Memory Management

### 2.1 Session Model

**File:** `rust/crates/runtime/src/session.rs`

```rust
pub struct Session {
    pub version: u32,                          // Schema version (currently 1)
    pub session_id: String,                    // Unique ID
    pub created_at_ms: u64,                    // Unix timestamp ms
    pub updated_at_ms: u64,                    // Last activity
    pub messages: Vec<ConversationMessage>,     // Full conversation
    pub compaction: Option<SessionCompaction>,  // Compaction metadata
    pub fork: Option<SessionFork>,             // Fork provenance
    persistence: Option<SessionPersistence>,    // File-backed storage
}
```

**Constants:** `ROTATE_AFTER_BYTES = 256KB`, `MAX_ROTATED_FILES = 3`.

Sessions support:
- File-backed persistence with auto-rotation at 256KB
- Forking (creates new session linked to parent)
- Compaction tracking (count, removed messages, summary)
- JSON serialization/deserialization via custom `JsonValue` layer

### 2.2 Python Session Store

**File:** `src/session_store.py`

Simpler but same pattern:

```python
@dataclass(frozen=True)
class StoredSession:
    session_id: str
    messages: tuple[str, ...]
    input_tokens: int
    output_tokens: int
```

Persisted as JSON to `.port_sessions/{session_id}.json`.

### 2.3 Transcript Store

**File:** `src/transcript.py`

```python
class TranscriptStore:
    entries: list[str]
    flushed: bool
    
    def compact(self, keep_last: int = 10): ...
    def replay(self) -> tuple[str, ...]: ...
    def flush(self): ...
```

Buffer-and-flush pattern: entries accumulate in memory, flushed flag tracks persistence state.

### 2.4 Compaction System

**File:** `rust/crates/runtime/src/compact.rs`

**Config defaults:**
```rust
pub struct CompactionConfig {
    pub preserve_recent_messages: usize,  // default: 4
    pub max_estimated_tokens: usize,       // default: 10,000
}
```

**Algorithm:**
1. `should_compact()` — checks if compactable messages exceed both count threshold (`preserve_recent_messages`) AND token estimate (`max_estimated_tokens`)
2. If existing summary exists (previous compaction), merge it with new summary
3. Split messages into `removed` (older) and `preserved` (recent tail)
4. `summarize_messages()` creates summary of removed messages
5. `format_compact_summary()` strips `<analysis>` tags, reformats `<summary>` blocks
6. Build continuation message with preamble + summary + instruction to resume directly

**Continuation format:**
```
"This session is being continued from a previous conversation that ran out of context. 
The summary below covers the earlier portion of the conversation.

[formatted summary]

Recent messages are preserved verbatim.
Continue the conversation from where it left off without asking the user any further 
questions. Resume directly — do not acknowledge the summary, do not recap what was 
happening, and do not preface with continuation text."
```

**Auto-compaction:** Triggered in `ConversationRuntime::maybe_auto_compact()` when cumulative input tokens exceed `auto_compaction_input_tokens_threshold` (default: 100,000, configurable via env `CLAUDE_CODE_AUTO_COMPACT_INPUT_TOKENS`).

### 2.5 Context Discovery

**File:** `rust/crates/runtime/src/prompt.rs`

**`ProjectContext`:**
```rust
pub struct ProjectContext {
    pub cwd: PathBuf,
    pub current_date: String,
    pub git_status: Option<String>,
    pub git_diff: Option<String>,
    pub instruction_files: Vec<ContextFile>,
}
```

`discover_instruction_files()` walks the directory hierarchy looking for `CLAUDE.md` files. Limits:
- `MAX_INSTRUCTION_FILE_CHARS = 4,000` per file
- `MAX_TOTAL_INSTRUCTION_CHARS = 12,000` across all files
- Content hash deduplication (same content at multiple paths → included once)

**Python context:** `src/context.py` provides `PortContext` with workspace scanning — counts Python files, test files, assets, and checks for archive availability.

### 2.6 Key Patterns for Orbit

- **Session versioning** enables schema migration
- **File rotation** prevents unbounded growth
- **Compaction preserves N recent messages** — keeps immediate context intact
- **Auto-compaction by token threshold** — transparent to user
- **Instruction file discovery** walks directory hierarchy with size limits
- **Content hash dedup** prevents bloating from identical files at different paths

---

## 3. Query Engine (Turn Loop)

### 3.1 Rust ConversationRuntime

**File:** `rust/crates/runtime/src/conversation.rs`

Core orchestration struct:

```rust
pub struct ConversationRuntime<C, T> {
    session: Session,
    api_client: C,               // impl ApiClient
    tool_executor: T,            // impl ToolExecutor
    permission_policy: PermissionPolicy,
    system_prompt: Vec<String>,
    max_iterations: usize,       // default: usize::MAX
    usage_tracker: UsageTracker,
    hook_runner: HookRunner,
    auto_compaction_input_tokens_threshold: u32,  // default: 100,000
    hook_abort_signal: HookAbortSignal,
    hook_progress_reporter: Option<Box<dyn HookProgressReporter>>,
    session_tracer: Option<SessionTracer>,
}
```

### 3.2 Turn Loop (`run_turn`)

**File:** `conversation.rs:296-485`

```
1. Push user input to session
2. Loop:
   a. Build ApiRequest (system_prompt + session.messages)
   b. Stream from api_client → collect AssistantEvents
   c. Build assistant message from events, record usage
   d. Push assistant message to session
   e. Extract pending tool_use blocks
   f. If no tool uses → break (response complete)
   g. For each tool use:
      i.   Run pre_tool_use hook → may modify input, override permission
      ii.  Evaluate permission (hook override → policy → prompt)
      iii. If denied → push error tool_result
      iv.  If allowed → execute tool → run post_tool_use hook
      v.   Push tool_result to session
   h. Continue loop (feed results back to LLM)
3. Maybe auto-compact session
4. Return TurnSummary
```

**Key design:** The loop has no hard-coded iteration cap (default `usize::MAX`) — it's controlled by the caller via `with_max_iterations()`. The Python engine uses `max_turns = 8`.

### 3.3 Streaming Events

**File:** `rust/crates/api/src/types.rs:238-246`

```rust
pub enum StreamEvent {
    MessageStart(MessageStartEvent),
    MessageDelta(MessageDeltaEvent),
    ContentBlockStart(ContentBlockStartEvent),
    ContentBlockDelta(ContentBlockDeltaEvent),
    ContentBlockStop(ContentBlockStopEvent),
    MessageStop(MessageStopEvent),
}
```

**ContentBlockDelta variants:**
- `TextDelta { text: String }`
- `InputJsonDelta { partial_json: String }`
- `ThinkingDelta { thinking: String }`
- `SignatureDelta { signature: String }`

The runtime's `AssistantEvent` is a simplified projection:
```rust
pub enum AssistantEvent {
    TextDelta(String),
    ToolUse { id, name, input },
    Usage(TokenUsage),
    PromptCache(PromptCacheEvent),
    MessageStop,
}
```

### 3.4 Python QueryEnginePort

**File:** `src/query_engine.py`

```python
class QueryEngineConfig:
    max_turns: int = 8
    max_budget_tokens: int = 2000
    compact_after_turns: int = 12
    structured_output: bool = False
    structured_retry_limit: int = 2
```

Budget enforcement: if projected tokens exceed `max_budget_tokens`, stop_reason = `'max_budget_reached'`. Compaction triggers after `compact_after_turns` message accumulations.

### 3.5 Cost Tracking

**File:** `rust/crates/runtime/src/usage.rs`

```rust
pub struct TokenUsage {
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub cache_creation_input_tokens: u32,
    pub cache_read_input_tokens: u32,
}

pub struct ModelPricing {
    pub input_cost_per_million: f64,
    pub output_cost_per_million: f64,
    pub cache_creation_cost_per_million: f64,
    pub cache_read_cost_per_million: f64,
}
```

**Per-model pricing:**
| Model | Input/M | Output/M | Cache Create/M | Cache Read/M |
|-------|---------|----------|----------------|--------------|
| Haiku | $1.00 | $5.00 | $1.25 | $0.10 |
| Sonnet | $15.00 | $75.00 | $18.75 | $1.50 |
| Opus | $15.00 | $75.00 | $18.75 | $1.50 |

`UsageTracker` accumulates per-turn and provides `cumulative_usage()`.

**Python `cost_tracker.py`:** Referenced in spec but the Python cost tracking uses word-count-based estimation (simple `len(text.split())`).

### 3.6 Key Patterns for Orbit

- **Generic runtime** — `ConversationRuntime<C, T>` is parameterized over API client and tool executor
- **Hook pipeline** wraps every tool call (pre + post) — enables middleware-style interception
- **Auto-compaction** is transparent — user never needs to manually compact
- **Budget controls** at two levels: token count and cost estimate
- **Prompt cache tracking** for cost optimization awareness

---

## 4. Tool System

### 4.1 Tool Definitions (Rust)

**File:** `rust/crates/tools/src/lib.rs:384+`

19 built-in tools defined as `ToolSpec`:

```rust
pub struct ToolSpec {
    pub name: &'static str,
    pub description: &'static str,
    pub input_schema: Value,           // JSON Schema
    pub required_permission: PermissionMode,
}
```

**Complete tool inventory:**

| Tool | Permission | Purpose |
|------|-----------|---------|
| `bash` | DangerFullAccess | Shell command execution with sandbox options |
| `read_file` | ReadOnly | File reading with offset/limit |
| `write_file` | WorkspaceWrite | File creation/overwrite |
| `edit_file` | WorkspaceWrite | Targeted string replacement |
| `glob_search` | ReadOnly | Pattern-based file discovery |
| `grep_search` | ReadOnly | Regex content search with context |
| `WebFetch` | ReadOnly | URL fetching + text extraction |
| `WebSearch` | ReadOnly | Web search with domain filtering |
| `TodoWrite` | WorkspaceWrite | Structured task list management |
| `Skill` | ReadOnly | Skill definition loading |
| `Agent` | DangerFullAccess | Sub-agent spawning |
| `ToolSearch` | ReadOnly | Deferred tool discovery |
| `NotebookEdit` | WorkspaceWrite | Jupyter notebook cell editing |
| `Sleep` | ReadOnly | Duration-based waiting |
| `SendUserMessage` | ReadOnly | User messaging with attachments |
| `Config` | WorkspaceWrite | Settings get/set |
| `EnterPlanMode` | WorkspaceWrite | Plan mode toggle on |
| `ExitPlanMode` | WorkspaceWrite | Plan mode toggle off |
| `AskUserQuestion` | ReadOnly | Interactive user prompting |

### 4.2 Tool Registration & Registry

**File:** `rust/crates/tools/src/lib.rs:70-183`

```rust
pub struct GlobalToolRegistry {
    plugin_tools: Vec<PluginTool>,       // From plugins
    runtime_tools: Vec<RuntimeToolDefinition>,  // Dynamically added
    enforcer: Option<PermissionEnforcer>,
}
```

**Registration flow:**
1. `GlobalToolRegistry::builtin()` — starts with empty plugin/runtime tools
2. `with_plugin_tools(Vec<PluginTool>)` — validates no name collisions with builtins
3. `with_runtime_tools(Vec<RuntimeToolDefinition>)` — validates no collisions with builtins or plugins
4. `with_enforcer(PermissionEnforcer)` — attaches permission enforcement

**Name collision prevention:** Builtin names are reserved. Plugin and runtime tool names cannot collide with builtins or each other.

### 4.3 Tool Pool & Filtering

**File:** `src/tool_pool.py`

```python
class ToolPool:
    tools: tuple[PortingModule, ...]
    simple_mode: bool
    include_mcp: bool
    
    def as_markdown(self) -> str:
        # Shows first 15 tools only
```

**Filtering chain:**
1. `simple_mode` → restrict to `{BashTool, FileReadTool, FileEditTool}`
2. `include_mcp = False` → exclude MCP-related tools
3. `filter_tools_by_permission_context()` → deny-list filtering by name/prefix
4. Display cap: first 15 tools in markdown output

### 4.4 Tool Execution

**File:** `rust/crates/tools/src/lib.rs` (tool executor)

The `ToolExecutor` trait is implemented by the tools crate, dispatching by tool name:

```rust
pub trait ToolExecutor {
    fn execute(&mut self, tool_name: &str, input: &str) -> Result<String, ToolError>;
}
```

Each tool has dedicated execution: `execute_bash()`, `read_file()`, `write_file()`, `edit_file()`, `glob_search()`, `grep_search()`, etc. Tools like `Agent` spawn sub-processes. MCP tools are routed through `McpToolRegistry`.

### 4.5 Key Patterns for Orbit

- **JSON Schema per tool** — enables LLM to understand parameters
- **Permission level per tool** — graduated access control
- **Plugin + runtime + builtin** layering with collision prevention
- **Simple mode** concept — reduced tool surface for specific contexts
- **15-tool display cap** — prevents context window bloat
- **Name-based dispatch** — tool executor routes by string name

---

## 5. Permission System

### 5.1 Permission Modes

**File:** `rust/crates/runtime/src/permissions.rs`

```rust
pub enum PermissionMode {
    ReadOnly,           // Can only read files and search
    WorkspaceWrite,     // Can write within workspace boundaries
    DangerFullAccess,   // Can do anything (bash, agent spawn, etc.)
    Prompt,             // Ask user before each action
    Allow,              // Allow everything
}
```

**Ordering:** `ReadOnly < WorkspaceWrite < DangerFullAccess < Prompt < Allow`

### 5.2 Permission Policy

```rust
pub struct PermissionPolicy {
    active_mode: PermissionMode,
    tool_requirements: BTreeMap<String, PermissionMode>,  // Per-tool minimum
    allow_rules: Vec<PermissionRule>,  // Explicit allow patterns
    deny_rules: Vec<PermissionRule>,   // Explicit deny patterns
    ask_rules: Vec<PermissionRule>,    // Force-prompt patterns
}
```

**Evaluation order (with context):**
1. Check hook-provided `PermissionOverride` (Allow/Deny/Ask)
2. Check deny_rules — if any match, deny immediately
3. Check allow_rules — if any match, allow immediately
4. Check ask_rules — if any match, prompt user
5. Compare tool's `required_mode` against `active_mode`
6. If `active_mode >= required_mode` → allow
7. If prompter available and mode is Prompt → ask user
8. Otherwise → deny

### 5.3 Permission Enforcer

**File:** `rust/crates/runtime/src/permission_enforcer.rs`

```rust
pub struct PermissionEnforcer {
    policy: PermissionPolicy,
}

pub enum EnforcementResult {
    Allowed,
    Denied { tool, active_mode, required_mode, reason },
}
```

Specialized checks:
- `check_file_write(path, workspace_root)` — validates workspace boundaries
- `check_bash(command)` — validates bash commands against read-only restrictions

### 5.4 Permission Rules (from Config)

**File:** `rust/crates/runtime/src/config.rs:75-80`

```rust
pub struct RuntimePermissionRuleConfig {
    allow: Vec<String>,   // Tool patterns to always allow
    deny: Vec<String>,    // Tool patterns to always deny
    ask: Vec<String>,     // Tool patterns to always prompt
}
```

Rules are loaded from the 3-tier config (User → Project → Local) with cascading.

### 5.5 Interactive Prompting

```rust
pub trait PermissionPrompter {
    fn decide(&mut self, request: &PermissionRequest) -> PermissionPromptDecision;
}

pub enum PermissionPromptDecision {
    Allow,
    Deny { reason: String },
}
```

The prompter is passed into `run_turn()` as an optional `&mut dyn PermissionPrompter`, allowing the CLI to implement terminal-based prompting.

### 5.6 Key Patterns for Orbit

- **Graduated modes** not just allow/deny — workspace-scoped writes are a middle ground
- **Rule-based overrides** on top of mode-based defaults
- **Hook integration** — hooks can override permission decisions
- **Prompter trait** — decouples permission UI from enforcement logic
- **Workspace boundary enforcement** — prevents writes outside project root

---

## 6. API Client & Authentication

### 6.1 Provider Abstraction

**File:** `rust/crates/api/src/client.rs`

```rust
pub enum ProviderClient {
    Anthropic(AnthropicClient),
    Xai(OpenAiCompatClient),
    OpenAi(OpenAiCompatClient),
}
```

Factory: `ProviderClient::from_model(model)` detects provider from model name (claude-* → Anthropic, grok-* → xAI, gpt-* / o3-* → OpenAI).

### 6.2 Multi-Provider API

```rust
impl ProviderClient {
    pub async fn send_message(&self, request: &MessageRequest) -> Result<MessageResponse, ApiError>;
    pub async fn stream_message(&self, request: &MessageRequest) -> Result<MessageStream, ApiError>;
}
```

Both `AnthropicClient` and `OpenAiCompatClient` implement the same message interface. OpenAI-compatible path supports xAI and OpenAI via configurable base URL.

### 6.3 Authentication Sources

**File:** `rust/crates/api/src/providers/anthropic.rs` (referenced)

```rust
pub enum AuthSource {
    None,
    ApiKey(String),
    BearerToken(String),
    ApiKeyAndBearer { api_key: String, bearer: String },
}
```

`AnthropicClient::from_env()` reads `ANTHROPIC_API_KEY` env var. `from_auth(AuthSource)` accepts explicit auth.

### 6.4 SSE Streaming

**File:** `rust/crates/api/src/sse.rs`

Custom SSE parser that handles:
- `event:` and `data:` lines
- Multi-line data accumulation
- Connection keep-alive handling
- Request ID extraction from response headers

`MessageStream` enum wraps provider-specific streams with unified `next_event()` interface.

### 6.5 OAuth PKCE Flow

**File:** `rust/crates/runtime/src/oauth.rs`

**Complete PKCE implementation:**

```rust
pub struct PkceCodePair {
    pub verifier: String,          // 32 random bytes → base64url
    pub challenge: String,         // SHA-256(verifier) → base64url
    pub challenge_method: PkceChallengeMethod,  // Always S256
}

pub struct OAuthAuthorizationRequest {
    pub authorize_url: String,
    pub client_id: String,
    pub redirect_uri: String,      // http://localhost:{port}/callback
    pub scopes: Vec<String>,
    pub state: String,             // 32 random bytes → base64url
    pub code_challenge: String,
    pub code_challenge_method: PkceChallengeMethod,
    pub extra_params: BTreeMap<String, String>,
}
```

**PKCE generation:**
```rust
pub fn generate_pkce_pair() -> io::Result<PkceCodePair> {
    let verifier = generate_random_token(32)?;  // 32 bytes from /dev/urandom → base64url
    PkceCodePair {
        challenge: code_challenge_s256(&verifier),  // SHA-256 → base64url
        verifier,
        challenge_method: PkceChallengeMethod::S256,
    }
}
```

**Authorization URL construction:**
```
{authorize_url}?response_type=code&client_id={id}&redirect_uri={uri}
  &scope={scopes}&state={state}&code_challenge={challenge}
  &code_challenge_method=S256{&extra_params}
```

**Token exchange:**
```rust
pub struct OAuthTokenExchangeRequest {
    pub grant_type: "authorization_code",
    pub code: String,
    pub redirect_uri: String,
    pub client_id: String,
    pub code_verifier: String,
    pub state: String,
}
```

**Token refresh:**
```rust
pub struct OAuthRefreshRequest {
    pub grant_type: "refresh_token",
    pub refresh_token: String,
    pub client_id: String,
    pub scopes: Vec<String>,
}
```

**Credential storage:**
```rust
pub struct OAuthTokenSet {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at: Option<u64>,
    pub scopes: Vec<String>,
}
```

Stored at `~/.claw/credentials.json` (or `$CLAW_CONFIG_HOME/credentials.json`) under the `"oauth"` key. Format is JSON with camelCase keys.

**Callback parsing:** `parse_oauth_callback_request_target()` parses `/callback?code=X&state=Y` from the localhost listener.

### 6.6 Credential Reuse

Credentials are stored at `~/.claw/credentials.json`. Claude Code stores at `~/.claude/credentials.json`. Same format — Orbit can read either path if configured via `credentials_path` in config.

### 6.7 Model Aliases

```rust
"opus" → "claude-opus-4-6"
"grok" → "grok-3"
"grok-mini" → "grok-3-mini"
```

Provider detection by model prefix: `claude-*` → Anthropic, `grok-*` → xAI, `gpt-*` / `o3-*` → OpenAI.

### 6.8 Key Patterns for Orbit

- **Provider enum** wraps multiple backends behind unified interface
- **Model name → provider routing** — automatic provider selection
- **OAuth PKCE** is fully implemented — verifier/challenge pair, authorization URL, token exchange, refresh, credential storage
- **Credential file format** is reusable — same JSON structure as Claude Code
- **SSE parsing** is custom — handles provider-specific event formats
- **Auth source enum** supports multiple simultaneous auth methods

---

## 7. Bootstrap Sequence

### 7.1 Bootstrap Plan

**File:** `rust/crates/runtime/src/bootstrap.rs`

12-phase bootstrap sequence:

```rust
pub enum BootstrapPhase {
    CliEntry,                    // CLI argument parsing
    FastPathVersion,             // --version fast exit
    StartupProfiler,             // Performance measurement
    SystemPromptFastPath,        // --system-prompt dump
    ChromeMcpFastPath,           // Chrome MCP special path
    DaemonWorkerFastPath,        // Daemon worker mode
    BridgeFastPath,              // Bridge mode
    DaemonFastPath,              // Daemon mode
    BackgroundSessionFastPath,   // Background session
    TemplateFastPath,            // Template generation
    EnvironmentRunnerFastPath,   // Environment runner
    MainRuntime,                 // Full runtime initialization
}
```

**Design pattern:** "Fast paths" allow early exit for specific invocation modes without full initialization. This is the staged bootstrap graph — each phase is optional and the plan deduplicates.

### 7.2 Python Bootstrap

**File:** `src/bootstrap_graph.py`, `src/bootstrap/`

The Python side references a 7-stage graph: Prefetch → Warning handler → CLI parser → Setup + Commands (parallel) → Deferred init → Mode routing → Query engine.

### 7.3 Relevance to Orbit

**Keep:**
- CLI entry / version fast path
- Config loading phase
- Runtime initialization

**Adapt:**
- Replace coding-specific fast paths with operations paths (daemon, schedule runner)
- Add project selection phase (multi-project support)
- Add MCP connection phase (connect configured servers)

**Drop:**
- Chrome MCP, Bridge, template, environment runner fast paths (coding-agent-specific)
- Startup profiler (premature for MVP)

---

## 8. Command System

### 8.1 Python Command Architecture

**File:** `src/commands.py`

```python
@dataclass(frozen=True)
class CommandExecution:
    name: str
    source_hint: str
    payload: str
    handled: bool
    message: str
```

Commands are loaded from a snapshot file (`reference_data/commands_snapshot.json`), similar to tools. The `execute_command()` function routes by name.

### 8.2 Command Discovery

```python
load_command_snapshot() → tuple[PortingModule, ...]  # Cached
get_command(name) → PortingModule | None
find_commands(query, limit) → list[PortingModule]
render_command_index(limit, query) → str
```

### 8.3 Relevant Commands for Orbit

| Command | Keep/Adapt | Notes |
|---------|-----------|-------|
| `/compact` | Keep | Manual compaction trigger |
| `/cost` | Keep | Session cost display |
| `/model` | Keep | Model switching |
| `/memory` | Adapt | Multi-project memory access |
| `/status` | Keep | Active agents, token usage |
| `/resume` | Keep | Session resume |
| `/config` | Keep | Configuration management |
| `/export` | Keep | Transcript export |
| `/dream` | New | Orbit-specific memory consolidation |
| `/deep` | New | Orbit-specific deep task launch |
| `/project` | New | Orbit-specific project switching |
| `/trace` | New | Agent tree visualization |

---

## 9. Message Model

### 9.1 Rust Message Types

**File:** `rust/crates/runtime/src/session.rs`

```rust
pub enum MessageRole {
    System,
    User,
    Assistant,
    Tool,
}

pub enum ContentBlock {
    Text { text: String },
    ToolUse { id: String, name: String, input: String },
    ToolResult { tool_use_id: String, tool_name: String, output: String, is_error: bool },
}

pub struct ConversationMessage {
    pub role: MessageRole,
    pub blocks: Vec<ContentBlock>,
    pub usage: Option<TokenUsage>,
}
```

### 9.2 API-Level Types

**File:** `rust/crates/api/src/types.rs`

Input types (sent to API):
```rust
pub struct InputMessage {
    pub role: String,
    pub content: Vec<InputContentBlock>,
}

pub enum InputContentBlock {
    Text { text },
    ToolUse { id, name, input: Value },
    ToolResult { tool_use_id, content: Vec<ToolResultContentBlock>, is_error },
}
```

Output types (received from API):
```rust
pub enum OutputContentBlock {
    Text { text },
    ToolUse { id, name, input: Value },
    Thinking { thinking, signature },
    RedactedThinking { data: Value },
}
```

### 9.3 Tool Call Correlation

Tool calls are correlated via `id`/`tool_use_id`:
- Assistant sends `ToolUse { id: "toolu_xxx", name: "bash", input: "..." }`
- Response contains `ToolResult { tool_use_id: "toolu_xxx", output: "...", is_error: false }`

### 9.4 Key Patterns for Orbit

- **Separate internal and API message types** — internal types are richer (include tool_name on results), API types match provider format
- **ContentBlock enum** with associated values maps perfectly to Swift enums
- **Usage tracking per message** enables precise cost attribution
- **Thinking/RedactedThinking** — extended thinking support for capable models

---

## 10. Architecture Patterns to Adopt

### 10.1 Dual-Layer Separation of Concerns

Claw Code separates:
- **Orchestration layer** (Python): query engine, context assembly, command routing, session management
- **Performance layer** (Rust): streaming parser, tool execution, sandbox, permission enforcement

Orbit should maintain this separation in Swift:
- **OrbitCore** library: orchestration (QueryEngine, ContextBuilder, DreamEngine)
- **Low-level modules**: streaming, MCP transport, file I/O, shell execution

### 10.2 Configuration Cascade

3-tier config: User (`~/.claw/`) → Project (`.claw/`) → Local (`.claw.local`).

Each tier can override keys from the tier above. MCP servers, permissions, and hooks all support this cascade.

### 10.3 Snapshot-Based Inventories

Tools and commands are loaded from JSON snapshot files via `@lru_cache`. This means:
- Tool inventory is static per session (no hot-reload complexity)
- Easy to inspect and debug (just read the JSON file)
- Fast startup (no dynamic discovery)

### 10.4 Global Registries via OnceLock

**File:** `rust/crates/tools/src/lib.rs:34-68`

Global singletons for stateful subsystems:
```rust
fn global_lsp_registry() -> &'static LspRegistry { ... }
fn global_mcp_registry() -> &'static McpToolRegistry { ... }
fn global_task_registry() -> &'static TaskRegistry { ... }
fn global_team_registry() -> &'static TeamRegistry { ... }
fn global_cron_registry() -> &'static CronRegistry { ... }
fn global_worker_registry() -> &'static WorkerRegistry { ... }
```

Each uses `OnceLock` for lazy, thread-safe initialization. In Swift, this maps to `actor`-based singletons.

### 10.5 Hook Pipeline

Every tool call passes through pre/post hooks:
1. `PreToolUse` — can modify input, override permissions, cancel tool
2. Tool execution
3. `PostToolUse` (on success) or `PostToolUseFailure` (on error) — can modify output, force error

Hooks are user-configurable shell commands in settings.

### 10.6 Cost Tracking Model

Per-model pricing tables + cumulative usage tracking throughout the session. Transparent cost awareness.

---

## 11. Patterns to Adapt (Not Copy)

### 11.1 Single-Project → Multi-Project

Claw Code assumes one working directory. Orbit needs:
- Project registry (`~/.orbit/projects/*.toml`)
- Per-project session stores, memory, MCP configs
- Project switching in REPL
- Cross-project analysis in deep tasks

### 11.2 Coding Tools → Operations Tools

Claw Code's tool set is coding-focused (LSP, notebook editing, plan mode). Orbit needs:
- Replace LSP with web scraping/browser tools
- Replace notebook editing with structured output/reporting
- Add desktop automation (computer use)
- Keep file I/O, bash, search tools as-is

### 11.3 Flat Sub-Agents → Agent Tree

Claw Code spawns sub-agents flatly via the `Agent` tool. Orbit needs:
- Parent-child relationships
- Recursive spawning with depth limits
- Cost aggregation across tree
- Full trace visualization
- Failure isolation (child failure doesn't crash parent)

### 11.4 No Scheduler → Full Scheduler

Claw Code has no cron/scheduling. Orbit needs:
- Task definitions in TOML
- Cron expression parsing
- Execution logging
- Manual trigger support

### 11.5 No Daemon → Proactive Daemon

Claw Code has no daemon mode. Orbit needs:
- Tick-based monitoring loop
- Per-project observation
- Decision engine (quiet/notify/act)
- Daily log accumulation
- autoDream integration

### 11.6 No Memory Consolidation → autoDream

Claw Code's session store is append-only. Orbit needs:
- 4-phase dream cycle (Orient → Gather → Consolidate → Prune)
- Automatic trigger on idle
- Contradiction resolution
- Memory pruning

### 11.7 TypeScript/Python/Rust → Swift

Type mappings:
| Claw Code | Orbit (Swift) |
|-----------|---------------|
| `enum` (Rust) | `enum` with associated values |
| `struct` (Rust frozen dataclass) | `struct` (value type) |
| `Arc<Mutex<T>>` | `actor` |
| `OnceLock` | `actor` with lazy init |
| `trait` (Rust) | `protocol` |
| `Result<T, E>` | `throws` / `Result<T, E>` |
| `Vec<AssistantEvent>` | `AsyncThrowingStream<StreamEvent, Error>` |
| `HashMap` | `Dictionary` |
| `BTreeMap` | `SortedDictionary` or regular `Dictionary` |
| JSON `Value` | `JSONValue` (custom) or `AnyCodable` |
