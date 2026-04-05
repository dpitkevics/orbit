# Orbit

Read ORBIT_PROJECT_SPEC.md for the full project specification.

## Current Phase

Phase 6 — Interactive REPL. Phases 0-5 are complete.

## Completed Phases

### Phase 0 — Claw Code Analysis
Located in `docs/`: CLAW_CODE_ANALYSIS.md, SWIFT_PATTERNS.md, ADAPTATION_NOTES.md

### Phase 1 — Core Skeleton (37 tests)
- Package.swift with all dependencies
- Core types: JSONValue, ChatMessage, ContentBlock, StreamEvent, TokenUsage
- Config system: TOML loading (orbit.toml, project configs)
- LLM Provider protocol + AnthropicProvider (SwiftAnthropic SDK)
- BridgeProvider (shells out to claude CLI for subscription auth)
- Auth: API key + bridge modes with auto-detection
- CLI: `orbit ask` command end-to-end

### Phase 2 — Tool System + Permissions + Query Engine (89 tests)
- Tool protocol with JSON Schema, permission levels, execute()
- ToolPool with filtering (max 15 visible, simple mode, permission filtering)
- ToolRegistry with name collision prevention
- Permission system: 5 graduated modes (readOnly → dangerFullAccess)
- PermissionPolicy with allow/deny rules, PermissionEnforcer with workspace boundary checks
- 6 built-in tools: bash, file_read, file_write, file_edit, glob_search, grep_search
- QueryEngine turn loop: LLM → tool calls → execute → feed back → repeat
- Terminal permission prompter

### Phase 3 — Memory + Context + Sessions (139 tests)
- Session struct with JSON persistence (save/load/list/delete/fork)
- Compaction engine: token estimation, should_compact, compact_session, preserve recent 4, summary merging, continuation messages (TDD)
- ContextBuilder: ORBIT.md discovery walking directory tree, 4000/file + 12000 total char limits, SHA256 content hash dedup (TDD)
- SQLiteMemory (GRDB): 3-layer memory — index, topics, transcripts with FTS5 full-text search (TDD)
- MemoryStore protocol with assembleContext for smart context selection
- SkillLoader: markdown skill files with YAML frontmatter, trigger pattern matching, global + project scoping

### Phase 4 — MCP Integration (174 tests)
- MCPNaming: tool name normalization (mcp__{server}__{tool}), config hashing (SHA256)
- MCPRegistry actor: multi-server state tracking, tool definition generation with prefixing
- MCPConnector: official MCP Swift SDK integration, StdioTransport (subprocess piping), HTTPClientTransport
- Value conversion between Orbit JSONValue and MCP Value types
- Connection lifecycle: connect/disconnect/reconnect with status tracking

### Phase 5 — Agent Tree (190 tests)
- AgentNode: hierarchical spawning with parent-child links, depth limits (max 5), status transitions, trace recording
- AgentTree actor: global tracking, cost aggregation, failed node detection, depth filtering, trace visualization
- AgentResult, TraceEntry, MemoryAccessLevel types
- TDD for all core logic

## Key Architecture Decisions

- **Language:** Swift 6.0+ with strict concurrency (actors, async/await)
- **Config format:** TOML via TOMLKit
- **Memory backend:** SQLite via GRDB.swift (FTS5 for search)
- **MCP:** Official modelcontextprotocol/swift-sdk
- **LLM SDKs:** SwiftAnthropic + SwiftOpenAI (jamesrochabrun)
- **CLI:** swift-argument-parser
- **Auth:** API key, bridge (claude CLI), OAuth PKCE (Phase 9)
- **Zero warnings policy:** All code must compile with zero warnings
- **Test coverage:** 100% test coverage required per phase
- **TDD:** Core logic (compaction, memory, context) uses TDD; plumbing uses implementation-first
