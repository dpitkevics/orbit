import ArgumentParser
import Foundation
import OrbitCore

/// Interactive REPL session — the primary interface for Orbit.
struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an interactive chat session."
    )

    @Argument(help: "Project slug (auto-detected if omitted).")
    var project: String?

    @Option(name: .long, help: "Override the model to use.")
    var model: String?

    @Option(name: .long, help: "Auth mode: 'apiKey' or 'bridge'.")
    var authMode: String?

    @Flag(name: .long, help: "Disable tool use.")
    var noTools: Bool = false

    func run() async throws {
        let globalConfig = try ConfigLoader.loadGlobal()

        // Resolve project
        let projectSlug = project ?? resolveDefaultProject(globalConfig)
        let projectConfig: ProjectConfig
        if projectSlug == "default" {
            projectConfig = ProjectConfig(name: "default", slug: "default")
        } else {
            do {
                projectConfig = try ConfigLoader.loadProject(slug: projectSlug)
            } catch {
                projectConfig = ProjectConfig(name: projectSlug, slug: projectSlug)
            }
        }

        let effectiveModel = model ?? projectConfig.effectiveModel(global: globalConfig)
        let effectiveProvider = projectConfig.effectiveProvider(global: globalConfig)

        let provider = try resolveProviderForChat(
            providerName: effectiveProvider,
            model: effectiveModel,
            authModeOverride: authMode,
            globalConfig: globalConfig
        )

        // Tools
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)
        let tools: [any Tool] = noTools ? [] : allTools(provider: provider, policy: policy)
        let toolPool = ToolPool(tools: tools)
        let commandRegistry = SlashCommandRegistry.default

        // Memory
        let memoryStore: SQLiteMemory? = try? SQLiteMemory(path: globalConfig.memoryDBPath)

        // Skills
        let skillLoader = SkillLoader()
        let allSkills = skillLoader.loadSkills(project: projectConfig.slug)

        // MCP — connect configured servers
        let mcpRegistry = MCPRegistry()
        let mcpConnector = MCPConnector(registry: mcpRegistry)
        await connectMCPServers(config: globalConfig, project: projectConfig, connector: mcpConnector)

        // Session
        var session = Session()
        let sessionStore = FileSessionStore()

        // Build system prompt using ContextBuilder
        let cwd = URL(fileURLWithPath: projectConfig.repoPath.map {
            ($0 as NSString).expandingTildeInPath
        } ?? FileManager.default.currentDirectoryPath)
        let systemPrompt = await buildFullSystemPrompt(
            project: projectConfig,
            cwd: cwd,
            memoryStore: memoryStore,
            skills: allSkills,
            mcpRegistry: mcpRegistry
        )

        // Print header
        let connectedMCP = await mcpRegistry.connectedCount
        print("Orbit v0.1.0 — \(projectConfig.name)")
        print("Model: \(effectiveModel) | Provider: \(effectiveProvider)", terminator: "")
        if connectedMCP > 0 {
            print(" | MCP: \(connectedMCP) server\(connectedMCP == 1 ? "" : "s")", terminator: "")
        }
        if !allSkills.isEmpty {
            print(" | Skills: \(allSkills.count)", terminator: "")
        }
        print("\nType /help for commands, /exit to quit.\n")

        var messages: [ChatMessage] = []
        var totalUsage = TokenUsage.zero
        var currentModel = effectiveModel

        // REPL loop
        while true {
            print("▸ ", terminator: "")
            fflush(stdout)

            guard let input = readLine()?.trimmingCharacters(in: .whitespaces) else {
                break
            }

            guard !input.isEmpty else { continue }

            // Slash commands
            let (cmdName, cmdArgs) = SlashCommandParser.parse(input)
            if let cmdName, let cmd = commandRegistry.find(cmdName) {
                let ctx = SlashCommandContext(
                    sessionID: session.sessionID,
                    model: currentModel,
                    provider: effectiveProvider,
                    project: projectConfig.slug,
                    messageCount: messages.count,
                    sessionUsage: totalUsage
                )
                let result = cmd.execute(args: cmdArgs, context: ctx)

                if !result.output.isEmpty {
                    print(result.output)
                }

                switch result.action {
                case .exit:
                    await saveTranscript(messages: messages, session: session, store: memoryStore, project: projectConfig.slug)
                    try? sessionStore.save(session, project: projectConfig.slug)
                    await mcpConnector.disconnectAll()
                    return
                case .clearConversation:
                    messages.removeAll()
                    session = Session()
                    totalUsage = .zero
                    print("Conversation cleared.\n")
                case .compact:
                    let config = CompactionConfig()
                    let compResult = CompactionEngine.compact(session: session, config: config)
                    if compResult.removedMessageCount > 0 {
                        session = compResult.compactedSession
                        messages = session.messages
                        print("Compacted: removed \(compResult.removedMessageCount) messages.\n")
                    } else {
                        print("Nothing to compact.\n")
                    }
                case .switchModel(let newModel):
                    currentModel = newModel
                    print()
                case .export:
                    let transcript = messages.map { msg -> String in
                        let role = msg.role.rawValue.capitalized
                        return "[\(role)] \(msg.textContent)"
                    }.joined(separator: "\n\n")
                    let exportPath = FileManager.default.temporaryDirectory
                        .appendingPathComponent("orbit-export-\(session.sessionID.prefix(8)).md")
                    try transcript.write(to: exportPath, atomically: true, encoding: .utf8)
                    print("Exported to \(exportPath.path)\n")
                case .dream:
                    if let store = memoryStore {
                        do {
                            let report = try await DreamEngine.dream(store: store, project: projectConfig.slug)
                            print("Dream complete: \(report.observationsExtracted) observations, \(report.topicsCreated) created, \(report.topicsUpdated) updated\n")
                        } catch {
                            print("Dream failed: \(error.localizedDescription)\n")
                        }
                    } else {
                        print("Memory store not available.\n")
                    }
                case .deep(let deepPrompt):
                    let deepTask = DeepTask(name: "Deep Analysis", prompt: deepPrompt, projects: [projectConfig.slug])
                    let runner = DeepTaskRunner(provider: provider)
                    do {
                        let completed = try await runner.run(deepTask)
                        if let output = completed.result {
                            print(output)
                        }
                    } catch {
                        print("Deep task failed: \(error.localizedDescription)")
                    }
                    print()
                case .resume(let sessionID):
                    if let sid = sessionID {
                        do {
                            let loaded = try sessionStore.load(id: sid, project: projectConfig.slug)
                            session = loaded
                            messages = loaded.messages
                            totalUsage = .zero
                            print("Resumed session \(sid.prefix(8)) (\(messages.count) messages)\n")
                        } catch {
                            print("Failed to resume: \(error.localizedDescription)\n")
                        }
                    } else {
                        let list = (try? sessionStore.list(project: projectConfig.slug, limit: 10)) ?? []
                        if list.isEmpty {
                            print("No previous sessions.\n")
                        } else {
                            print("Recent sessions:")
                            let formatter = DateFormatter()
                            formatter.dateStyle = .short
                            formatter.timeStyle = .short
                            for s in list {
                                print("  \(s.sessionID.prefix(8)) — \(s.messageCount) msgs, \(formatter.string(from: s.updatedAt))")
                            }
                            print("Use /resume <session-id> to resume.\n")
                        }
                    }
                case .none:
                    print()
                }
                continue
            }

            // Send to LLM
            messages.append(.userText(input))
            session.appendMessage(.userText(input))

            let engine = QueryEngine(
                provider: provider,
                toolPool: toolPool,
                policy: policy,
                config: QueryEngineConfig(maxTurns: 8),
                prompter: TerminalPrompter()
            )

            let stream = engine.run(messages: &messages, systemPrompt: systemPrompt)

            var hasOutput = false

            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let text):
                        print(text, terminator: "")
                        fflush(stdout)
                        hasOutput = true

                    case .toolCallStart(_, let name):
                        if hasOutput { print() }
                        print("  ▶ \(name)", terminator: "")
                        fflush(stdout)

                    case .toolCallEnd(_, let name, let result):
                        if result.isError {
                            print(" ✗ \(name)")
                        } else {
                            let preview = result.output.prefix(60).replacingOccurrences(of: "\n", with: " ")
                            print(" ✓ (\(preview)...)")
                        }

                    case .toolDenied(let name, let reason):
                        print("  ⊘ \(name) denied: \(reason)")

                    case .usageUpdate(let usage):
                        totalUsage += usage

                    case .turnComplete(let summary):
                        if hasOutput { print("\n") }
                        if summary.toolCallCount > 0 {
                            print("[\(summary.iterations) turn\(summary.iterations == 1 ? "" : "s"), \(summary.toolCallCount) tool call\(summary.toolCallCount == 1 ? "" : "s")]")
                        }
                    }
                }
            } catch {
                print("\nError: \(error.localizedDescription)\n")
            }

            // Save session after each turn
            try? sessionStore.save(session, project: projectConfig.slug)
        }
    }
}

// MARK: - System Prompt Builder

private func buildFullSystemPrompt(
    project: ProjectConfig,
    cwd: URL,
    memoryStore: SQLiteMemory?,
    skills: [Skill],
    mcpRegistry: MCPRegistry
) async -> String {
    let identity = """
    You are Orbit, an AI operations assistant. You help manage projects, \
    analyze business data, and handle operational tasks. You are NOT a coding \
    agent — you are an operations manager. You have access to tools for \
    file operations, shell commands, and search. Use them when needed.
    """

    // Discover ORBIT.md files
    let instructionFiles = ContextBuilder.discoverInstructionFiles(at: cwd)

    // Load memory context
    var memoryContext: String? = nil
    if let store = memoryStore {
        memoryContext = try? await store.assembleContext(
            project: project.slug,
            currentQuery: "",
            maxEntries: 20
        )
    }

    // Format skills context
    var skillsContext: String? = nil
    if !skills.isEmpty {
        let skillTexts = skills.map { "### \($0.name)\n\($0.content)" }
        skillsContext = "# Available Skills\n\n" + skillTexts.joined(separator: "\n\n")
    }

    // Add MCP server info
    let mcpTools = await mcpRegistry.toolDefinitions()
    var mcpContext: String? = nil
    if !mcpTools.isEmpty {
        let toolNames = mcpTools.map { $0.name }.joined(separator: ", ")
        mcpContext = "Connected MCP tools: \(toolNames)"
    }

    // Add coding awareness if repo configured
    var codingContext: String? = nil
    if project.repoPath != nil {
        let commits = CodingAwareness.recentCommits(repo: cwd, days: 7)
        if !commits.isEmpty {
            codingContext = CodingAwareness.formatCommitsContext(commits: commits)
        }
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"

    let builder = ContextBuilder(
        identity: identity,
        projectContext: ProjectContext(
            projectName: project.name,
            projectDescription: project.description,
            instructionFiles: instructionFiles
        ),
        skillsContext: [skillsContext, mcpContext, codingContext].compactMap { $0 }.joined(separator: "\n\n"),
        memoryContext: memoryContext,
        currentDate: formatter.string(from: Date())
    )

    return builder.build()
}

// MARK: - MCP Connection

private func connectMCPServers(
    config: OrbitConfig,
    project: ProjectConfig,
    connector: MCPConnector
) async {
    // MCP servers would be configured in project TOML under [mcps.*]
    // For now, we just initialize — actual config parsing for MCP servers
    // would read from the TOML and call connector.connect() for each
}

// MARK: - Transcript Saving

private func saveTranscript(
    messages: [ChatMessage],
    session: Session,
    store: SQLiteMemory?,
    project: String
) async {
    guard let store, !messages.isEmpty else { return }

    let transcript = messages.map { msg -> String in
        let role = msg.role.rawValue.capitalized
        return "[\(role)] \(msg.textContent)"
    }.joined(separator: "\n")

    try? await store.storeTranscript(
        sessionID: session.sessionID,
        content: transcript,
        project: project
    )
}

// MARK: - Helpers

private func resolveDefaultProject(_ config: OrbitConfig) -> String {
    let projects = ConfigLoader.listProjects()
    if projects.count == 1 {
        return projects[0]
    }
    return "default"
}

/// Terminal permission prompter (shared with Ask command).
struct TerminalPrompter: PermissionPrompter {
    func prompt(toolName: String, input: String, reason: String) async -> Bool {
        print("\n⚠ Permission required: \(toolName)")
        print("  Reason: \(reason)")
        print("  Allow? [y/N] ", terminator: "")
        fflush(stdout)
        guard let line = readLine()?.lowercased() else { return false }
        return line == "y" || line == "yes"
    }
}
