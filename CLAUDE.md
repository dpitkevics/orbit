# Orbit

Open-source, LLM-agnostic agent platform for project operations.

## Project Structure

- `Sources/Orbit/` — CLI executable (swift-argument-parser)
- `Sources/OrbitCore/` — Core library (all business logic)
- `Tests/OrbitCoreTests/` — 256 tests across 35 suites
- `docs/` — Architecture analysis, spec, design documents

## Build & Test

```bash
swift build       # Build the project
swift test        # Run all 256 tests
swift run orbit   # Launch interactive REPL
```

## Conventions

- **Swift 6.0+** with strict concurrency (actors, async/await, Sendable)
- **Zero warnings policy** — all code must compile with zero warnings
- **100% test coverage** — every phase must have full test coverage
- **TDD for core logic** — compaction, memory queries, context assembly
- **Implementation-first for plumbing** — config loading, CLI wiring, type definitions
- **Config format:** TOML via TOMLKit
- **No Xcode project** — pure SwiftPM package, macOS 14+ minimum

## Key Types

| Type | Location | Purpose |
|------|----------|---------|
| `LLMProvider` | Provider/ | Protocol for LLM backends |
| `Tool` | Tools/ | Protocol for executable tools |
| `QueryEngine` | Engine/ | Turn loop orchestration |
| `PermissionPolicy` | Permissions/ | Tool access control |
| `SQLiteMemory` | Memory/ | 3-layer memory with FTS5 |
| `ContextBuilder` | Context/ | System prompt assembly |
| `AgentTree` | Agents/ | Hierarchical sub-agent tracking |
| `CronExpression` | Scheduler/ | Cron parsing for scheduled tasks |
| `DreamEngine` | Memory/ | 4-phase memory consolidation |
| `MCPRegistry` | MCP/ | Multi-server MCP management |

## Full Specification

See `docs/ORBIT_PROJECT_SPEC.md` for the complete project specification.
