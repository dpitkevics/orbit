# Orbit

**Open-source, LLM-agnostic agent platform for project and business operations.**

Orbit is a CLI-first tool that acts as a solo founder's chief of staff. It knows the state of each project, can analyze business data, run scheduled operational tasks, monitor proactively, and delegate coding tasks to external agents.

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-blue.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tests: 294](https://img.shields.io/badge/Tests-294%20passing-brightgreen.svg)]()

---

## What Orbit Is

Orbit is an **operations agent**, not a coding agent. It manages projects, analyzes data, runs scheduled tasks, and delegates coding work to purpose-built tools.

**The gap Orbit fills:** Coding agents (Claude Code, Codex) focus on writing code. IDE assistants (Cursor, Copilot) are embedded in editors. Chat interfaces (Claude.ai, ChatGPT) have no project context or scheduling. **Nobody** has built an open-source, LLM-agnostic operations agent that ties it all together.

### Key Features

- **LLM-agnostic** — Works with Anthropic (Claude), OpenAI (GPT-4o, o3), or any provider
- **3 auth modes** — API key, bridge (uses your existing Claude/Codex CLI subscription), OAuth PKCE
- **Multi-project** — Manages multiple projects with isolated memory, context, and config
- **14 built-in tools** — bash, file read/write/edit, glob, grep, web fetch/search, browser, computer use, git log, agent spawning, structured output, notifications
- **3-layer memory** — SQLite-backed with FTS5 search, optional vector embeddings for semantic retrieval
- **Memory consolidation** — autoDream: 4-phase cycle that merges observations, resolves contradictions, prunes stale facts
- **Scheduled tasks** — Cron-based task execution with TOML configuration
- **Agent tree** — Hierarchical sub-agent spawning with depth limits and full trace visibility
- **MCP integration** — Connect to external services via the Model Context Protocol
- **Deep analysis** — Long-running background tasks spanning multiple projects
- **Coding delegation** — Delegates code changes to Claude Code or Codex CLI
- **Interactive REPL** — Streaming chat with 16 slash commands, session persistence, cost tracking
- **Background daemon** — Proactive monitoring with launchd integration
- **Plugin system** — Extensible plugin architecture for custom tools and integrations
- **Desktop automation** — Browser control and computer use (screenshot, mouse, keyboard)

---

## Architecture

```
                    +-------------------------+
                    |      orbit CLI          |
                    |  (17 subcommands)       |
                    +-----------+-------------+
                                |
              +-----------------+-----------------+
              |                 |                 |
              v                 v                 v
        +----------+     +----------+     +----------+
        |  Chat /  |     | Schedule |     |  Deep    |
        |  Ask     |     | Runner   |     |  Task    |
        +----+-----+     +----+-----+     +----+-----+
             |                 |                |
             +--------+--------+--------+-------+
                      |                 |
               +------v------+   +------v------+
               | Query Engine|   |  Dream      |
               | (Turn Loop) |   |  Engine     |
               +------+------+   +------+------+
                      |                 |
          +-----------+----------+      |
          |           |          |      |
    +-----v-----+ +---v---+ +---v----+ |
    |  Context   | | Tool  | | Agent  | |
    |  Builder   | | Pool  | | Tree   | |
    +-----+-----+ +---+---+ +---+----+ |
          |           |          |      |
    +-----+-----+ +---+---+     |      |
    | Memory    | | Tools  |    |      |
    | (SQLite   | | (14    |    |      |
    |  + FTS5   | | built- |    |      |
    |  + Vector)| | in)    |    |      |
    +-----------+ +--------+    |      |
                                |      |
                    +-----------v------v--+
                    |    LLM Provider     |
                    | (Anthropic/OpenAI/  |
                    |  Bridge/OAuth)      |
                    +---------------------+
```

### Module Overview

| Module | Purpose | Key Types |
|--------|---------|-----------|
| **Types/** | Core data types | `JSONValue`, `ChatMessage`, `ContentBlock`, `StreamEvent`, `TokenUsage` |
| **Provider/** | LLM abstraction | `LLMProvider` protocol, `AnthropicProvider`, `OpenAIProvider`, `BridgeProvider` |
| **Auth/** | Authentication | `AuthMode` (apiKey/bridge/oauth), `OAuthManager`, `PKCECodePair` |
| **Config/** | Configuration | `OrbitConfig`, `ProjectConfig`, `ConfigLoader` (TOML) |
| **Tools/** | Tool execution | `Tool` protocol, `ToolPool`, 14 built-in tools, `PermissionEnforcer` |
| **Permissions/** | Access control | `PermissionMode` (5 levels), `PermissionPolicy`, `PermissionRule` |
| **Engine/** | Orchestration | `QueryEngine` (turn loop with tool execution) |
| **Memory/** | Persistent memory | `SQLiteMemory` (3-layer), `MemoryRetriever` (tiered), `DreamEngine`, `EmbeddingProvider` |
| **Context/** | Prompt assembly | `ContextBuilder`, `ORBIT.md` discovery, char limits, SHA256 dedup |
| **Session/** | Session management | `Session`, `FileSessionStore`, `CompactionEngine` |
| **Skills/** | Skill loading | `SkillLoader`, YAML frontmatter, trigger patterns |
| **Agents/** | Sub-agent tree | `AgentNode`, `AgentTree` actor, trace recording |
| **MCP/** | MCP integration | `MCPRegistry`, `MCPConnector`, name normalization, config hashing |
| **Scheduler/** | Cron tasks | `CronExpression`, `TaskDefinition`, `TaskRunner` |
| **Daemon/** | Background agent | `OrbitDaemon` actor, tick loop, cron matching, daily logs, launchd |
| **DeepTask/** | Deep analysis | `DeepTask`, `DeepTaskRunner` |
| **Coding/** | Code awareness | `CodingAwareness` (git log, repo structure), `CodingDelegate` |
| **Commands/** | Slash commands | `SlashCommandRegistry`, 16 built-in commands |
| **Plugins/** | Plugin system | `OrbitPlugin` protocol, `PluginManager` actor |

---

## Core Algorithms

### Query Engine Turn Loop

The central orchestration loop, adapted from [Claw Code's](https://github.com/ultraworkers/claw-code-parity) `ConversationRuntime`:

```
1. Receive user input
2. Build API request: system prompt + conversation history + tool definitions
3. Stream response from LLM provider
4. If response contains tool calls:
   a. Check permissions (mode-based + rule-based)
   b. Execute each tool
   c. Append tool results to conversation
   d. Go to step 2 (feed results back to LLM)
5. If response is text only: yield to user
6. Auto-compact if token threshold exceeded (100K input tokens)
```

### Session Compaction

Ported from Claw Code's `compact.rs`. Prevents context window overflow:

- **Token estimation:** ~4 characters per token heuristic
- **Trigger:** Message count > `preserveRecentMessages` (default: 4) AND estimated tokens > `maxEstimatedTokens` (default: 10,000)
- **Algorithm:** Summarize older messages, keep N most recent verbatim, prepend continuation message
- **Re-compaction:** Merges with existing summaries on subsequent compactions
- **Auto-compaction:** Transparent trigger at 100K cumulative input tokens

### 3-Layer Memory System

```
Layer 1: Memory Index        (always loaded, lightweight topic refs)
Layer 2: Topic Files         (loaded on demand, full content)
Layer 3: Session Transcripts (searchable via FTS5, never in context)
```

### Tiered Memory Retrieval

Automatically selects the best available strategy:

| Tier | Requires | Method |
|------|----------|--------|
| **Vector** | OpenAI API key | Cosine similarity on text-embedding-3-small vectors stored in SQLite |
| **Rerank** | Any LLM provider | LLM scores topic relevance to current query |
| **Keyword** | Nothing | FTS5 full-text search |

### autoDream Memory Consolidation

4-phase background cycle that keeps memory clean and current:

1. **Orient** — Scan recent transcripts, extract factual observations
2. **Gather** — Load all existing topics
3. **Consolidate** — Merge observations into topics, detect contradictions via number-keyword analysis, resolve by appending updates
4. **Prune** — Trim oversized topics, remove stale entries, rebuild memory index

### Permission System

5 graduated modes with rule-based overrides:

```
ReadOnly < WorkspaceWrite < DangerFullAccess < Prompt < Allow
```

Each tool declares its minimum required mode. Policy evaluation: deny rules (highest priority) > allow rules > mode comparison > interactive prompt.

### MCP Tool Naming

Following Claw Code's convention for collision-free multi-server tool names:

```
mcp__{normalized_server_name}__{normalized_tool_name}
```

Server identity tracked via SHA-256 config hash for change detection.

### Cron Expression Parser

Standard 5-field cron (`minute hour day-of-month month day-of-week`) with:
- Wildcards (`*`), steps (`*/15`), ranges (`9-17`), lists (`1,3,5`)
- Calendar weekday mapping (cron Sunday=0 to Calendar Sunday=1)
- Daemon tick loop auto-matches cron expressions against current time

### OAuth PKCE Authentication

Full OAuth 2.0 PKCE flow for subscription-based auth:

1. Generate cryptographic verifier (32 random bytes) + SHA-256 challenge
2. Open browser to provider's authorize endpoint
3. Listen on localhost for callback with authorization code
4. Exchange code + verifier for access/refresh tokens
5. Store credentials at `~/.orbit/credentials.json`
6. Auto-reuse Claude Code credentials from `~/.claude/credentials.json`

---

## Prerequisites

- **macOS 14+** (Sonoma or later)
- **Swift 6.0+** toolchain (ships with Xcode 16+)
- **Git** (for coding awareness features)

Optional:
- **Claude Code CLI** — for bridge auth mode (use your subscription, no API key needed)
- **Codex CLI** — for OpenAI coding delegation
- **OpenAI API key** — for vector embeddings and GPT-4o provider

---

## Installation

### From Source

```bash
git clone https://github.com/dpitkevics/orbit.git
cd orbit
swift build
```

The binary is at `.build/debug/orbit`. To install system-wide:

```bash
swift build -c release
cp .build/release/orbit /usr/local/bin/
```

### First Run

```bash
orbit init
```

This creates `~/.orbit/` with your configuration. It auto-detects:
- Installed Claude Code CLI (bridge auth)
- `ANTHROPIC_API_KEY` environment variable (API key auth)
- Available coding agents

---

## Configuration

### Global Config: `~/.orbit/orbit.toml`

```toml
[defaults]
provider = "anthropic"
model = "claude-sonnet-4-6"

[auth.anthropic]
mode = "bridge"       # Uses installed claude CLI (no API key needed)
# mode = "api_key"    # Requires ANTHROPIC_API_KEY env var
# mode = "oauth"      # OAuth PKCE (run `orbit auth login` first)

[auth.openai]
mode = "api_key"
api_key_env = "OPENAI_API_KEY"

[memory]
db_path = "~/.orbit/memory.db"

[context]
max_file_chars = 4000
max_total_chars = 12000
```

### Project Config: `~/.orbit/projects/{slug}.toml`

```toml
[project]
name = "My Project"
slug = "my-project"
description = "A SaaS product"
repo = "~/Projects/my-project"
model = "claude-sonnet-4-6"

[context]
files = ["docs/about.md", "docs/brand-voice.md"]

[mcps.analytics]
type = "http"
url = "https://analytics.example.com/mcp"

[mcps.support]
type = "http"
url = "https://support.example.com/mcp"
```

### Scheduled Task: `~/.orbit/schedules/{slug}.toml`

```toml
[task]
name = "Daily Brief"
slug = "daily-brief"
project = "my-project"
cron = "0 9 * * *"
enabled = true

[task.prompt]
text = "Summarize today's key metrics and any issues."
```

---

## Usage

### Interactive Chat (default)

```bash
orbit                              # Launches REPL with default/only project
orbit chat my-project              # Chat with specific project context
```

### One-Shot Queries

```bash
orbit ask default "What day is it?"
orbit ask my-project "Summarize recent git activity" --show-cost
orbit ask default "Hello" --model claude-haiku-4-5
```

### Slash Commands (in REPL)

| Command | Description |
|---------|-------------|
| `/help` | Show all commands |
| `/status` | Session info (model, tokens, messages) |
| `/cost` | Token usage and estimated cost |
| `/model <name>` | Switch active model |
| `/project [slug]` | Show or switch project |
| `/config` | Show current configuration |
| `/memory` | Show memory topics |
| `/dream` | Trigger memory consolidation |
| `/deep <prompt>` | Launch deep analysis task |
| `/trace` | Show session trace |
| `/permissions` | Show permission mode |
| `/compact` | Manually compact conversation |
| `/resume [id]` | List or resume previous sessions |
| `/export` | Export transcript to file |
| `/clear` | Clear conversation history |
| `/exit` | Exit session |

### Project Management

```bash
orbit init                         # First-time setup wizard
orbit project list                 # List all projects
orbit project show my-project      # Details + recent git activity
orbit project add                  # Interactive project creation
orbit project switch my-project    # Set default project
```

### Scheduled Tasks

```bash
orbit schedule list                # List all tasks
orbit schedule enable daily-brief  # Enable a task
orbit schedule disable weekly      # Disable a task
orbit run daily-brief              # Manually trigger a task
orbit logs daily-brief --last 5    # View execution logs
```

### Memory Management

```bash
orbit memory list my-project       # List memory topics
orbit memory search my-project "revenue"  # Search transcripts
orbit memory export my-project --output report.md  # Export topics
orbit memory dream my-project      # Run autoDream consolidation
```

### Deep Analysis

```bash
orbit deep "Analyze Q1 performance across all projects" --projects alpha,beta
```

### Coding

```bash
orbit code activity my-project --days 14  # Recent git activity
orbit code delegate my-project "Fix the login bug" --agent claude-code
```

### Authentication

```bash
orbit auth status                  # Show auth configuration
orbit auth login                   # OAuth PKCE login (opens browser)
orbit auth remove                  # Clear stored OAuth tokens
```

### Background Daemon

```bash
orbit daemon start                 # Start via launchd
orbit daemon status                # Check if running
orbit daemon stop                  # Stop daemon
```

### Skills

```bash
orbit skills list my-project       # List available skills
orbit skills add my-project ~/skills/seo-monitor.md  # Add a skill
```

### Other

```bash
orbit status                       # Global overview of all projects
orbit cost                         # Cost tracking info
orbit trace                        # Agent trace info
orbit completions zsh              # Generate shell completions
```

---

## Authentication Modes

| Mode | How | When to use |
|------|-----|-------------|
| **Bridge** | Shells out to `claude` CLI | You have Claude Code installed (uses your subscription) |
| **API Key** | `ANTHROPIC_API_KEY` env var | Direct API billing |
| **OAuth PKCE** | `orbit auth login` | Browser-based login, token stored locally |

### Bridge Mode (Recommended)

If you have the Claude Code CLI installed, Orbit can use it directly — no API key needed. Your queries are billed to your existing Claude subscription.

```bash
orbit ask default "Hello"  # Just works if claude is installed
```

### API Key Mode

```bash
export ANTHROPIC_API_KEY=sk-ant-...
orbit ask default "Hello"
```

### OAuth PKCE Mode

```bash
orbit auth login           # Opens browser, authenticates, stores token
orbit ask default "Hello" --auth-mode oauth
```

---

## Built-in Tools

| Tool | Category | Permission | Description |
|------|----------|-----------|-------------|
| `bash` | execution | dangerFullAccess | Shell command execution with timeout |
| `file_read` | fileIO | readOnly | Read files with offset/limit and line numbers |
| `file_write` | fileIO | workspaceWrite | Create or overwrite files |
| `file_edit` | fileIO | workspaceWrite | Targeted string replacement |
| `glob_search` | search | readOnly | Find files by pattern |
| `grep_search` | search | readOnly | Regex content search with context |
| `web_fetch` | network | readOnly | HTTP GET with HTML stripping |
| `web_search` | network | readOnly | Web search via DuckDuckGo |
| `git_log` | fileIO | readOnly | Git commit history |
| `agent` | agent | dangerFullAccess | Spawn sub-agent with own turn loop |
| `structured_output` | planning | readOnly | Return JSON or markdown tables |
| `send_notification` | network | readOnly | Send to stdout or file |
| `browser` | desktop | dangerFullAccess | Navigate, extract, screenshot, execute JS |
| `computer_use` | desktop | dangerFullAccess | Screenshot, mouse, click, keyboard |

---

## Project Structure

```
orbit/
+-- Package.swift                   # SwiftPM manifest
+-- Sources/
|   +-- Orbit/                      # CLI executable (8 files)
|   |   +-- OrbitCLI.swift          # Entry point, 17 subcommands
|   |   +-- ChatCommand.swift       # Interactive REPL
|   |   +-- ProviderResolver.swift  # Auth mode auto-detection
|   |   +-- InitCommand.swift       # Setup wizard
|   |   +-- ProjectCommands.swift   # Project, memory, auth, status
|   |   +-- ScheduleCommands.swift  # Schedule, daemon (launchd)
|   |   +-- DeepCommand.swift       # Deep analysis
|   |   +-- ExtraCommands.swift     # Code, skills, cost, trace, logs
|   |   +-- CompletionsCommand.swift # Shell completions
|   |
|   +-- OrbitCore/                  # Core library (55 files)
|       +-- Agents/                 # AgentNode, AgentTree
|       +-- Auth/                   # AuthTypes, OAuthPKCE
|       +-- Coding/                 # CodingAwareness, CodingDelegate
|       +-- Commands/               # SlashCommands (16 commands)
|       +-- Config/                 # OrbitConfig, ConfigLoader
|       +-- Context/                # ContextBuilder
|       +-- Daemon/                 # OrbitDaemon
|       +-- DeepTask/               # DeepTask, DeepTaskRunner
|       +-- Engine/                 # QueryEngine
|       +-- MCP/                    # MCPRegistry, MCPConnector, MCPTypes
|       +-- Memory/                 # SQLiteMemory, MemoryRetriever,
|       |                           # DreamEngine, EmbeddingProvider
|       +-- Permissions/            # PermissionTypes
|       +-- Plugins/                # PluginSystem
|       +-- Provider/               # LLMProvider, Anthropic, OpenAI, Bridge
|       +-- Scheduler/              # CronExpression, TaskDefinition, TaskRunner
|       +-- Session/                # Session, SessionStore, CompactionEngine
|       +-- Skills/                 # SkillLoader
|       +-- Tools/                  # ToolTypes, ToolPool
|           +-- Builtin/            # 14 tool implementations
|
+-- Tests/OrbitCoreTests/           # 294 tests (26 files)
+-- docs/                           # Architecture & design documents
```

**Stats:** 63 source files, 26 test files, ~10K source LOC, ~4K test LOC.

---

## Dependencies

| Package | Purpose |
|---------|---------|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI command parsing + shell completions |
| [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic) | Anthropic Claude API |
| [SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI) | OpenAI API + embeddings |
| [TOMLKit](https://github.com/LebJe/TOMLKit) | TOML config parsing |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite + FTS5 for memory |
| [swift-log](https://github.com/apple/swift-log) | Structured logging |
| [swift-crypto](https://github.com/apple/swift-crypto) | SHA-256 hashing (context dedup, MCP config, PKCE) |
| [MCP swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | Model Context Protocol client |

---

## Design Influences

Orbit's architecture is derived from studying [Claw Code](https://github.com/ultraworkers/claw-code-parity), a clean-room Rust/Python rewrite of Claude Code's agent harness. Key patterns adopted:

- **Query engine turn loop** with tool execution and auto-compaction
- **Session compaction** algorithm (preserve recent N, summarize rest)
- **MCP tool naming** convention (`mcp__{server}__{tool}`)
- **Permission system** with graduated modes and workspace boundaries
- **Context discovery** (ORBIT.md file walking with char limits and dedup)
- **Config cascade** (user > project > local)
- **OAuth PKCE** flow for subscription-based authentication

See `docs/CLAW_CODE_ANALYSIS.md` for the full architectural analysis.

---

## Contributing

Contributions are welcome. The project follows these conventions:

1. **Zero warnings** — Code must compile with zero warnings
2. **Full test coverage** — Add tests for all new functionality
3. **TDD for core logic** — Write tests first for algorithms (compaction, memory, context)
4. **Swift 6 concurrency** — Use actors, async/await, Sendable throughout
5. **No frameworks** — Targeted packages over frameworks. Each dependency solves one problem.

```bash
# Run tests before submitting
swift test

# Verify clean build
swift build 2>&1 | grep -c "warning:"  # Should output: 0
```

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## Acknowledgments

- [Claw Code](https://github.com/ultraworkers/claw-code-parity) — Architectural patterns and design inspiration
- [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic) / [SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI) — LLM SDK foundations
- [Model Context Protocol](https://modelcontextprotocol.io) — Official Swift SDK for MCP integration
