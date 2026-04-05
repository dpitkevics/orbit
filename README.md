# Orbit

**Open-source, LLM-agnostic agent platform for project and business operations.**

Orbit is a CLI-first tool that acts as a solo founder's chief of staff. It knows the state of each project, can analyze business data, run scheduled operational tasks, monitor proactively, and delegate coding tasks to external agents.

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-blue.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tests: 256](https://img.shields.io/badge/Tests-256%20passing-brightgreen.svg)]()

---

## What Orbit Is

Orbit is an **operations agent**, not a coding agent. It manages projects, analyzes data, runs scheduled tasks, and delegates coding work to purpose-built tools.

**The gap Orbit fills:** Coding agents (Claude Code, Codex) focus on writing code. IDE assistants (Cursor, Copilot) are embedded in editors. Chat interfaces (Claude.ai, ChatGPT) have no project context or scheduling. **Nobody** has built an open-source, LLM-agnostic operations agent that ties it all together.

### Key Features

- **LLM-agnostic** — Works with Anthropic (Claude), OpenAI (GPT-4o, o3), or any provider
- **Multi-project** — Manages multiple projects with isolated memory, context, and config
- **Tool system** — 6 built-in tools (bash, file read/write/edit, glob, grep) with permission-gated execution
- **3-layer memory** — SQLite-backed with FTS5 search, optional vector embeddings for semantic retrieval
- **Scheduled tasks** — Cron-based task execution with TOML configuration
- **Agent tree** — Hierarchical sub-agent spawning with depth limits and full trace visibility
- **MCP integration** — Connect to external services via the Model Context Protocol
- **Memory consolidation** — autoDream: 4-phase cycle that merges observations, resolves contradictions, prunes stale facts
- **Deep analysis** — Long-running background tasks spanning multiple projects
- **Coding delegation** — Delegates code changes to Claude Code or Codex CLI
- **Interactive REPL** — Streaming chat with slash commands, session persistence, cost tracking

---

## Architecture

```
                    +-------------------------+
                    |      orbit CLI          |
                    |  (ArgumentParser)       |
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
    | (SQLite   | | (6     |    |      |
    |  + FTS5   | | built- |    |      |
    |  + Vector)| | in)    |    |      |
    +-----------+ +--------+    |      |
                                |      |
                    +-----------v------v--+
                    |    LLM Provider     |
                    | (Anthropic/OpenAI/  |
                    |  Bridge)            |
                    +---------------------+
```

### Module Overview

| Module | Purpose | Key Types |
|--------|---------|-----------|
| **Types/** | Core data types | `JSONValue`, `ChatMessage`, `ContentBlock`, `StreamEvent`, `TokenUsage` |
| **Provider/** | LLM abstraction | `LLMProvider` protocol, `AnthropicProvider`, `OpenAIProvider`, `BridgeProvider` |
| **Auth/** | Authentication | `AuthMode` (apiKey/bridge/oauth), `AuthConfig`, `AuthCredential` |
| **Config/** | Configuration | `OrbitConfig`, `ProjectConfig`, `ConfigLoader` (TOML) |
| **Tools/** | Tool execution | `Tool` protocol, `ToolPool`, 6 built-in tools, `PermissionEnforcer` |
| **Permissions/** | Access control | `PermissionMode` (5 levels), `PermissionPolicy`, `PermissionRule` |
| **Engine/** | Orchestration | `QueryEngine` (turn loop with tool execution) |
| **Memory/** | Persistent memory | `SQLiteMemory` (3-layer), `MemoryRetriever` (tiered), `DreamEngine` |
| **Context/** | Prompt assembly | `ContextBuilder`, `ORBIT.md` discovery, char limits, dedup |
| **Session/** | Session management | `Session`, `FileSessionStore`, `CompactionEngine` |
| **Skills/** | Skill loading | `SkillLoader`, YAML frontmatter, trigger patterns |
| **Agents/** | Sub-agent tree | `AgentNode`, `AgentTree` actor, trace recording |
| **MCP/** | MCP integration | `MCPRegistry`, `MCPConnector`, name normalization |
| **Scheduler/** | Cron tasks | `CronExpression`, `TaskDefinition`, `TaskRunner` |
| **Daemon/** | Background agent | `OrbitDaemon` actor, tick loop, daily logs |
| **DeepTask/** | Deep analysis | `DeepTask`, `DeepTaskRunner` |
| **Coding/** | Code awareness | `CodingAwareness`, `CodingDelegate` |
| **Commands/** | Slash commands | `SlashCommandRegistry`, 11 built-in commands |

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
| **Vector** | OpenAI API key | Cosine similarity on text-embedding-3-small vectors |
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
| `/dream` | Trigger memory consolidation |
| `/deep <prompt>` | Launch deep analysis task |
| `/compact` | Manually compact conversation |
| `/export` | Export transcript to file |
| `/clear` | Clear conversation history |
| `/exit` | Exit session |

### Scheduled Tasks

```bash
orbit schedule list                # List all scheduled tasks
orbit run daily-brief              # Manually trigger a task
```

### Deep Analysis

```bash
orbit deep "Analyze Q1 performance across all projects" --projects alpha,beta
```

### Project Management

```bash
orbit project list                 # List all projects
orbit project show my-project      # Show project details + recent git activity
orbit status                       # Global overview
```

### Authentication

```bash
orbit auth status                  # Show auth configuration
```

Three auth modes:

| Mode | How | When to use |
|------|-----|-------------|
| **Bridge** | Shells out to `claude` CLI | You have Claude Code installed (uses your subscription) |
| **API Key** | `ANTHROPIC_API_KEY` env var | Direct API billing |
| **OAuth PKCE** | Direct subscription auth | Planned for future release |

---

## Authentication Modes

### Bridge Mode (Recommended)

If you have the Claude Code CLI installed, Orbit can use it directly — no API key needed. Your queries are billed to your existing Claude subscription.

```bash
# Just works if claude is installed and authenticated
orbit ask default "Hello"
```

### API Key Mode

```bash
export ANTHROPIC_API_KEY=sk-ant-...
orbit ask default "Hello"

# Or for OpenAI
export OPENAI_API_KEY=sk-...
orbit ask default "Hello" --model gpt-4o
```

---

## Project Structure

```
orbit/
+-- Package.swift                   # SwiftPM manifest
+-- Sources/
|   +-- Orbit/                      # CLI executable (6 files)
|   |   +-- OrbitCLI.swift          # Entry point + ask command
|   |   +-- ChatCommand.swift       # Interactive REPL
|   |   +-- DeepCommand.swift       # Deep analysis command
|   |   +-- InitCommand.swift       # Setup wizard
|   |   +-- ProjectCommands.swift   # Project, memory, auth, status
|   |   +-- ProviderResolver.swift  # Auth mode auto-detection
|   |   +-- ScheduleCommands.swift  # Schedule + daemon commands
|   |
|   +-- OrbitCore/                  # Core library (45 files)
|       +-- Agents/                 # AgentNode, AgentTree
|       +-- Auth/                   # AuthTypes
|       +-- Coding/                 # CodingAwareness, CodingDelegate
|       +-- Commands/               # SlashCommands
|       +-- Config/                 # OrbitConfig, ConfigLoader
|       +-- Context/                # ContextBuilder
|       +-- Daemon/                 # OrbitDaemon
|       +-- DeepTask/               # DeepTask, DeepTaskRunner
|       +-- Engine/                 # QueryEngine
|       +-- MCP/                    # MCPRegistry, MCPConnector, MCPTypes
|       +-- Memory/                 # SQLiteMemory, MemoryRetriever,
|       |                           # DreamEngine, EmbeddingProvider
|       +-- Permissions/            # PermissionTypes
|       +-- Provider/               # LLMProvider, Anthropic, OpenAI, Bridge
|       +-- Scheduler/              # CronExpression, TaskDefinition, TaskRunner
|       +-- Session/                # Session, SessionStore, CompactionEngine
|       +-- Skills/                 # SkillLoader
|       +-- Tools/                  # ToolTypes, ToolPool
|           +-- Builtin/            # bash, file_read/write/edit, glob, grep
|
+-- Tests/OrbitCoreTests/           # 256 tests (23 files)
+-- docs/                           # Architecture & design documents
```

---

## Dependencies

| Package | Purpose |
|---------|---------|
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI command parsing |
| [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic) | Anthropic Claude API |
| [SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI) | OpenAI API + embeddings |
| [TOMLKit](https://github.com/LebJe/TOMLKit) | TOML config parsing |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite + FTS5 for memory |
| [swift-log](https://github.com/apple/swift-log) | Structured logging |
| [swift-crypto](https://github.com/apple/swift-crypto) | SHA-256 hashing |
| [MCP swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | Model Context Protocol |

---

## Design Influences

Orbit's architecture is derived from studying [Claw Code](https://github.com/ultraworkers/claw-code-parity), a clean-room Rust/Python rewrite of Claude Code's agent harness. Key patterns adopted:

- **Query engine turn loop** with tool execution and auto-compaction
- **Session compaction** algorithm (preserve recent N, summarize rest)
- **MCP tool naming** convention (`mcp__{server}__{tool}`)
- **Permission system** with graduated modes
- **Context discovery** (ORBIT.md file walking with char limits and dedup)
- **Config cascade** (user > project > local)

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
