# Adaptation Notes — Claw Code → Orbit

**Purpose:** Document specific changes, additions, and design decisions when adapting Claw Code's patterns for Orbit's operations-agent use case.

---

## 1. Language & Concurrency Model

### Claw Code: Rust + Python dual-layer
- Python for orchestration (query engine, context, session)
- Rust for performance (streaming, tool execution, sandbox, permissions)
- `Arc<Mutex<T>>` for shared state
- `OnceLock` for lazy globals

### Orbit: Swift throughout
- Swift actors replace `Arc<Mutex<T>>` with compile-time safety
- `async/await` + `AsyncThrowingStream` replace SSE callbacks
- Swift protocols replace Rust traits
- Swift enums with associated values replace Rust enums (1:1 mapping)
- No dual-layer needed — Swift handles both orchestration and performance

### Key actor candidates:
| Component | Why actor |
|-----------|----------|
| `QueryEngine` | Manages session state across concurrent tool executions |
| `AgentTree` | Shared mutable tree structure across spawned agents |
| `ToolPool` | Dynamic MCP tool registration during active sessions |
| `SessionStore` | Concurrent session reads/writes |
| `MemoryStore` | Concurrent memory access from agents and dream engine |
| `OrbitDaemon` | Long-running tick loop with shared monitoring state |

---

## 2. Single-Project → Multi-Project

### Claw Code: Single working directory
- Session store: `.port_sessions/{id}.json` (local to workspace)
- Context: discovers `CLAUDE.md` by walking up from cwd
- Config: `~/.claw/` (user) + `.claw/` (project) + `.claw.local` (local)
- MCP servers: configured globally or per-workspace

### Orbit: Multi-project with switching
- **Project registry:** `~/.orbit/projects/{slug}.toml`
- **Session store:** `~/.orbit/sessions/{project}/{id}.json`
- **Memory store:** Per-project memory with cross-project query support
- **Context:** `ORBIT.md` file discovery per-project root, plus shared global context
- **Config cascade:** `~/.orbit/orbit.toml` (global) → `~/.orbit/projects/{slug}.toml` (project-specific)
- **MCP servers:** Configured per-project, connected/disconnected on project switch
- **REPL:** `/project` command to switch active project mid-session

### Migration pattern:
```
Claw Code                          Orbit
─────────                          ─────
.port_sessions/                 → ~/.orbit/sessions/{project}/
.claw/                          → ~/.orbit/projects/{slug}.toml
CLAUDE.md                       → ORBIT.md
context.py PortContext          → ContextBuilder (project-scoped)
```

---

## 3. Coding Tools → Operations Tools

### Tools to keep as-is:
| Tool | Reason |
|------|--------|
| `bash` | Operations tasks need shell execution |
| `read_file` | Reading configs, logs, data files |
| `write_file` | Writing reports, configs, markdown |
| `edit_file` | Modifying config files, updating docs |
| `glob_search` | Finding files across project trees |
| `grep_search` | Searching log files, code for context |
| `WebFetch` | Fetching URLs for monitoring |
| `WebSearch` | Research and competitive analysis |

### Tools to adapt:
| Claw Code Tool | Orbit Adaptation |
|----------------|-----------------|
| `Agent` (flat spawn) | `Agent` (tree-based with depth tracking, cost aggregation) |
| `TodoWrite` | `structured_output` (return structured JSON for reports) |
| `Skill` | Keep, but skills are operations-focused |
| `Config` | Keep, but manages Orbit config (TOML, not JSON settings) |

### Tools to drop:
| Tool | Why |
|------|-----|
| `NotebookEdit` | Jupyter is coding-specific |
| `EnterPlanMode` / `ExitPlanMode` | Coding-agent planning concept |
| `LSP` | Language server is IDE territory |

### Tools to add (Orbit-original):
| Tool | Category | Purpose |
|------|----------|---------|
| `browser` | desktop | Headless browser via CDP — navigate, click, extract, screenshot |
| `computer_use` | desktop | Desktop GUI interaction — screenshot, mouse, keyboard |
| `git_log` | fileIO | Read git history for coding awareness |
| `send_notification` | network | Push to Slack, stdout, or other channels |
| `structured_output` | planning | Return typed JSON for downstream consumption |

---

## 4. Flat Sub-Agents → Agent Tree

### Claw Code: Flat agent spawning
- `Agent` tool spawns a sub-process
- No parent-child tracking
- No cost aggregation across agents
- No depth limits
- Sub-agent results returned as plain text

### Orbit: Hierarchical agent tree
- **Parent-child links:** Every `AgentNode` knows its parent and children
- **Depth limits:** `maxDepth = 5` prevents runaway recursion
- **Cost aggregation:** `AgentTree.totalCost()` sums across all nodes
- **Trace visualization:** `/trace` command renders the full tree
- **Failure isolation:** Failed children don't crash parents
- **Memory access levels:** Sub-agents can be restricted to read-only or no memory
- **Permission inheritance:** Children inherit parent permissions but can be further restricted

### Implementation pattern:
```swift
// Root agent created by QueryEngine
let root = AgentNode(task: "user query", project: "my-project")

// Sub-agent spawned via Agent tool
let child = root.spawn(task: "research pricing", tools: [webFetch, webSearch])

// Grandchild spawned by sub-agent
let grandchild = child.spawn(task: "fetch competitor page", tools: [webFetch])

// Tree provides full visibility
let tree = AgentTree(root: root)
tree.totalCost()      // Aggregated across all 3 nodes
tree.failedNodes()    // Any failures?
tree.trace()          // Full execution trace as tree
```

---

## 5. No Scheduler → Cron-Based Scheduler

### Claw Code: No scheduling capability

### Orbit: Full scheduler
- **Task definitions:** TOML files in `~/.orbit/schedules/{slug}.toml`
- **Cron parsing:** Standard cron expressions
- **Execution:** Each run creates a session with project context + MCP servers
- **Output:** Configurable — file, stdout, Slack
- **Logging:** Execution history with duration, tokens, cost, output
- **Manual trigger:** `orbit run <slug>`

### Pattern from Claw Code to reuse:
- Claw Code's `TaskRegistry` (`runtime/task_registry.rs`) provides the CRUD pattern: create, get, list, stop, update. Orbit adapts this for persistent scheduled tasks.
- Claw Code's `CronRegistry` (`runtime/team_cron_registry.rs`) provides the in-memory cron tracking pattern.

---

## 6. No Daemon → Proactive Daemon

### Claw Code: No daemon mode
- (But has `DaemonWorkerFastPath` and `DaemonFastPath` in bootstrap — these are for a different daemon concept related to editor integration, not proactive monitoring)

### Orbit: KAIROS-style proactive daemon
- **Tick loop:** Every 5 minutes (configurable), check each monitored project
- **Data sources:** MCP server queries (analytics, support tickets, etc.)
- **Decision engine:** LLM decides: quiet (log), notify (alert), or act (bounded action)
- **Blocking budget:** Max 15 seconds for proactive actions
- **Daily logs:** Append-only markdown at `~/.orbit/logs/daily/{project}/{date}.md`
- **autoDream integration:** Trigger memory consolidation on idle (30min threshold)

### System integration:
- macOS: `launchd` plist for background execution
- Linux: `systemd` unit file
- `orbit daemon start/stop/status/logs`

---

## 7. No Memory Consolidation → autoDream

### Claw Code: Append-only session history
- Sessions stored as JSON, never consolidated
- Compaction only within a single session (context window management)
- No cross-session learning

### Orbit: 4-phase dream cycle
1. **ORIENT:** Scan recent transcripts for new observations
2. **GATHER:** Load all topic files, identify conflicts with new observations
3. **CONSOLIDATE:** Use LLM to merge, resolve contradictions, confirm tentative facts
4. **PRUNE:** Remove stale entries, trim oversized topics, update memory index

### Triggers:
- Manual: `/dream` slash command or `orbit memory dream <project>`
- Automatic: Daemon detects idle time > threshold (default: 30 minutes)
- Scheduled: Nightly at configurable time

### Claw Code pattern reused:
- Compaction's `format_compact_summary()` — stripping tags, reformatting blocks — is reused in ORIENT phase for extracting observations from transcripts
- Session transcript search (FTS5) provides the raw material for GATHER phase

---

## 8. Context Assembly Differences

### Claw Code: Coding-agent context
- System prompt: "You are Claude, made by Anthropic" + coding instructions
- `CLAUDE.md` discovery with char limits (4000/file, 12000 total)
- Git status and diff included
- Tool descriptions oriented to coding tasks

### Orbit: Operations-agent context
- System prompt: "You are Orbit, an operations manager" + project-specific instructions
- `ORBIT.md` discovery with same char limits
- Git status included for coding awareness (not primary focus)
- Memory context (Layer 1 index + relevant Layer 2 topics)
- Skills loaded based on query relevance
- Project metadata (team members, current phase, deadlines)

### Context assembly order:
```
1. Global identity ("You are Orbit...")
2. Project context files (from project config)
3. ORBIT.md files (discovered by walking project directory)
4. Skills (matched by trigger patterns or explicit invocation)
5. Memory (index + relevant topics, capped at maxContextEntries)
6. Recent activity (git commits, last session summary)
```

---

## 9. Configuration Format Differences

### Claw Code: JSON settings files
- `~/.claw/settings.json` (user)
- `.claw/settings.json` (project)
- `.claw.local/settings.json` (local)
- Schema-based with `SettingsSchema` marker

### Orbit: TOML configuration
- `~/.orbit/orbit.toml` (global)
- `~/.orbit/projects/{slug}.toml` (per-project)
- `~/.orbit/schedules/{slug}.toml` (per-task)

### Why TOML over JSON:
- Comments (documenting why a setting exists)
- More readable for human-edited config files
- No trailing comma issues
- Section headers (`[auth.anthropic]`) for grouping
- Better for operations config that users frequently edit

### Config loading:
- Claw Code uses `ConfigLoader` with 3-tier merge (User > Project > Local)
- Orbit uses same cascade but with TOML via `TOMLKit`
- Project configs inherit from global, override specific keys

---

## 10. Permission Model Refinements

### Claw Code: 5 permission modes
```
ReadOnly → WorkspaceWrite → DangerFullAccess → Prompt → Allow
```

### Orbit: Same 5 modes + operations-specific defaults
- **Default for REPL:** `prompt` (ask before destructive actions)
- **Default for daemon:** `readOnly` (daemon can only observe, not modify)
- **Default for scheduled tasks:** `workspaceWrite` (can write reports, not delete files)
- **Deep tasks:** `readOnly` by default (analysis, not action)

### Additional permission consideration:
- MCP tool permissions: MCP tools inherit the permission level of their category (network tools → ReadOnly, etc.)
- Sub-agent permissions: Children inherit parent but can be further restricted
- Delegation permissions: Coding delegation to Claude Code/Codex requires explicit `dangerFullAccess`

---

## 11. Command System Mapping

### Claw Code commands → Orbit commands:

| Claw Code | Orbit | Changes |
|-----------|-------|---------|
| `/compact` | `/compact` | Same — manual compaction |
| `/cost` | `/cost` | Same — show session costs |
| `/model` | `/model` | Same — switch active model |
| N/A | `/memory` | New — view/search/manage memory |
| N/A | `/dream` | New — trigger autoDream |
| N/A | `/deep` | New — launch deep task |
| N/A | `/project` | New — switch active project |
| `/resume` | `/resume` | Same — resume previous session |
| `/config` | `/config` | Adapted for TOML config |
| `/export` | `/export` | Same — export transcript |
| N/A | `/trace` | New — agent tree visualization |
| N/A | `/permissions` | New — view/modify tool permissions |
| `/status` | `/status` | Adapted — includes project overview |

---

## 12. Streaming Architecture

### Claw Code: Custom SSE parser → events
- `api/src/sse.rs` — custom SSE line parser
- Provider-specific stream wrappers (`MessageStream::Anthropic`, `MessageStream::OpenAiCompat`)
- Events collected into `Vec<AssistantEvent>` per turn

### Orbit: SDK-provided streaming → AsyncThrowingStream
- SwiftAnthropic SDK handles SSE parsing for Anthropic
- SwiftOpenAI SDK handles SSE parsing for OpenAI
- Orbit wraps SDK streams into unified `AsyncThrowingStream<StreamEvent, Error>`
- No need for custom SSE parser (SDKs handle this)

### Key difference: Claw Code's Rust runtime collects all events synchronously per turn. Orbit should yield events as they arrive for real-time REPL rendering.

---

## 13. Hook System

### Claw Code: Shell-based hooks
```rust
pub struct RuntimeHookConfig {
    pre_tool_use: Vec<String>,      // Shell commands run before tool
    post_tool_use: Vec<String>,     // Shell commands run after tool
    post_tool_use_failure: Vec<String>,
}
```

Hooks can:
- Modify tool input
- Override permission decisions (allow/deny/ask)
- Cancel tool execution
- Modify tool output
- Report progress

### Orbit: Same hook model
- Keep the shell-based hook pipeline — it's proven and flexible
- Add operation-specific hooks:
  - `pre_daemon_tick` / `post_daemon_tick`
  - `pre_dream` / `post_dream`
  - `pre_deep_task` / `post_deep_task`
  - `pre_schedule_run` / `post_schedule_run`

---

## 14. Build Order — Maximizing Reuse

### Phase 1 (Core): Direct from Claw Code patterns
1. **Message types** — 1:1 from `session.rs` content blocks
2. **LLM Provider protocol** — from `ProviderClient` enum pattern
3. **Auth system** — API key mode first (simplest)
4. **Config loading** — from `ConfigLoader`, adapted for TOML
5. **Basic query loop** — simplified `run_turn` from `ConversationRuntime`

### Phase 2 (Tools): Adapted from Claw Code
6. **Tool protocol** — from `ToolSpec` + `ToolExecutor`
7. **Permission system** — from `permissions.rs` + `permission_enforcer.rs`
8. **Tool Pool** — from `tool_pool.py` filtering logic
9. **Built-in tools** — bash, file_read/write/edit, grep, glob (same schemas)

### Phase 3 (Memory): New, using Claw Code session patterns
10. **Session management** — from `session.rs`, adapted for multi-project
11. **Compaction engine** — from `compact.rs`, same algorithm
12. **Memory store** — New (SQLite + FTS5), using compaction patterns
13. **Context builder** — from `prompt.rs`, adapted for operations context

### Phase 4 (MCP): From Claw Code + official SDK
14. **MCP integration** — name normalization from `mcp.rs`, SDK for protocol
15. **MCP tool registration** — from `mcp_tool_bridge.rs` registry pattern

### Phase 5+ (Orbit-original): No Claw Code equivalent
16. Agent tree, scheduler, daemon, autoDream, deep tasks, browser, computer use

---

## 15. Risk Areas & Mitigations

| Risk | Mitigation |
|------|-----------|
| SwiftAnthropic SDK streaming bugs | Test with mock server; fallback to raw HTTP if needed |
| MCP Swift SDK maturity | Monitor modelcontextprotocol/swift-sdk issues; can wrap with retry logic |
| TOML parsing edge cases | TOMLKit is well-tested; keep configs simple |
| OAuth PKCE endpoint changes | Read credential files first (reuse); implement PKCE as fallback |
| Agent tree runaway cost | Hard depth limit (5), per-agent token budget, tree-wide cost cap |
| Daemon resource usage | Configurable tick interval, blocking budget, brief output mode |
| Memory consolidation quality | autoDream is LLM-dependent; include manual override, review step |

---

## Summary

Orbit inherits Claw Code's battle-tested patterns for:
- Message model & streaming events
- Session management & compaction
- Permission enforcement (graduated modes + rules)
- Tool system (JSON Schema + registration + pool filtering)
- MCP integration (name normalization, config hashing, lifecycle)
- OAuth PKCE authentication
- Configuration cascade
- Hook pipeline

Orbit adds entirely new systems for:
- Multi-project management
- Agent tree (hierarchical sub-agents)
- Scheduled task execution
- Proactive daemon monitoring
- Memory consolidation (autoDream)
- Deep cross-project analysis
- Operations-focused tool set (browser, computer use, notifications)
- Coding delegation to external agents
