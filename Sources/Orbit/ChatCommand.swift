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

    @Option(name: .long, help: "Attach text files to context.")
    var file: [String] = []

    @Option(name: .long, help: "Attach images (base64-encoded for vision).")
    var image: [String] = []

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

        // Terminal rendering
        let theme = ColorTheme.default
        let renderer = TerminalRenderer(theme: theme)
        let useRichRendering = TerminalDetector.isInteractive

        // Full-screen TUI for interactive terminals
        if useRichRendering {
            let tui = TUIApplication(
                provider: provider,
                toolPool: toolPool,
                policy: policy,
                commandRegistry: commandRegistry,
                sessionStore: sessionStore,
                memoryStore: memoryStore,
                session: session,
                systemPrompt: systemPrompt,
                projectName: projectConfig.name,
                projectSlug: projectConfig.slug,
                model: effectiveModel,
                providerName: effectiveProvider,
                theme: theme
            )
            try await tui.run()
            return
        }

        // Fallback: plain REPL for non-interactive terminals
        // Print startup banner
        let connectedMCP = await mcpRegistry.connectedCount
        if useRichRendering {
            print(StartupBanner.render(
                model: effectiveModel,
                provider: effectiveProvider,
                permissionMode: "full-access",
                project: projectConfig.name,
                cwd: cwd.path,
                sessionID: session.sessionID,
                mcpCount: connectedMCP,
                skillCount: allSkills.count
            ))
        } else {
            print("Orbit v0.1.0 — \(projectConfig.name)")
            print("Model: \(effectiveModel) | Provider: \(effectiveProvider)")
            print("Type /help for commands, /exit to quit.\n")
        }

        // LineNoise editor with history + tab completion
        // Raw terminal input with clipboard image support
        let historyPath = ConfigLoader.orbitHome.appendingPathComponent("history").path
        let termInput = RawTerminalInput(historyPath: historyPath, theme: theme)

        // Slash command tab completion
        let slashCommands = commandRegistry.allCommands().map { "/\($0.name)" }
        termInput.setCompletionCallback { buffer in
            if buffer.hasPrefix("/") {
                return slashCommands.filter { $0.hasPrefix(buffer) }
            }
            return []
        }

        var messages: [ChatMessage] = []
        var totalUsage = TokenUsage.zero
        var pendingAttachments: [ContentBlock] = []

        // Load initial file/image attachments from CLI flags
        for filePath in file {
            if let block = loadFileAttachment(path: filePath) {
                pendingAttachments.append(block)
                print(ANSI.colored("  Attached: \(filePath)", theme.dim))
            }
        }
        for imagePath in image {
            if let block = loadImageAttachment(path: imagePath) {
                pendingAttachments.append(block)
                print(ANSI.colored("  Attached image: \(imagePath)", theme.dim))
            }
        }
        var currentModel = effectiveModel

        // REPL loop
        while true {
            let result = termInput.readLine(prompt: "> ")

            let input: String
            switch result {
            case .submit(let text, let attachments):
                input = text.trimmingCharacters(in: .whitespaces)
                pendingAttachments.append(contentsOf: attachments)
            case .cancel:
                continue
            case .eof:
                // Save and exit
                await saveTranscript(messages: messages, session: session, store: memoryStore, project: projectConfig.slug)
                try? sessionStore.save(session, project: projectConfig.slug)
                await mcpConnector.disconnectAll()
                return
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
                case .memory:
                    if let store = memoryStore {
                        let topics = (try? await store.listTopics(project: projectConfig.slug)) ?? []
                        if topics.isEmpty {
                            print("No memory topics for this project.\n")
                        } else {
                            print("Memory topics (\(topics.count)):")
                            for topic in topics {
                                print("  \(topic.slug) — \(topic.title)")
                            }
                            print()
                        }
                    } else {
                        print("Memory store not available.\n")
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
                case .switchProject(let newProject):
                    print("Project switching requires restarting the session.")
                    print("Run: orbit chat \(newProject)\n")
                case .attach(let path):
                    if let block = loadFileAttachment(path: path) ?? loadImageAttachment(path: path) {
                        pendingAttachments.append(block)
                    } else {
                        print("Could not read file: \(path)\n")
                    }
                case .none:
                    print()
                }
                continue
            }

            // Send to LLM (include any pending attachments)
            var userBlocks: [ContentBlock] = [.text(input)]
            userBlocks.append(contentsOf: pendingAttachments)
            pendingAttachments.removeAll()

            let userMsg = ChatMessage(role: .user, blocks: userBlocks)
            messages.append(userMsg)
            session.appendMessage(userMsg)

            let engine = QueryEngine(
                provider: provider,
                toolPool: toolPool,
                policy: policy,
                config: QueryEngineConfig(maxTurns: 8),
                prompter: TerminalPrompter()
            )

            let stream = engine.run(messages: &messages, systemPrompt: systemPrompt)

            var streamState = MarkdownStreamState(renderer: renderer)
            var thinkingSpinner = Spinner(theme: theme)
            var hasOutput = false
            var thinkingShown = false

            // Show thinking spinner
            thinkingSpinner.tick(label: "Thinking...")
            thinkingShown = true

            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let text):
                        // Clear thinking spinner on first text
                        if thinkingShown {
                            thinkingSpinner.finish(label: "")
                            thinkingShown = false
                        }

                        if useRichRendering {
                            if let rendered = streamState.push(text) {
                                print(rendered, terminator: "")
                                fflush(stdout)
                            }
                        } else {
                            print(text, terminator: "")
                            fflush(stdout)
                        }
                        hasOutput = true

                    case .toolCallStart(_, let name):
                        // Clear thinking spinner
                        if thinkingShown {
                            thinkingSpinner.finish(label: "")
                            thinkingShown = false
                        }

                        if hasOutput {
                            if let remaining = streamState.flush() {
                                print(remaining, terminator: "")
                            }
                            print()
                        }

                        // Find tool input from the stream context
                        let toolInput: JSONValue = .object([:])
                        print(ToolCallDisplay.formatStart(name: name, input: toolInput))

                        // Start spinner for tool execution
                        var toolSpinner = Spinner(theme: theme)
                        toolSpinner.tick(label: "\(ToolCallDisplay.icon(for: name)) Running...")

                    case .toolCallEnd(_, let name, let result):
                        if result.isError {
                            print(ToolCallDisplay.formatFailure(name: name, error: result.output))
                        } else {
                            print(ToolCallDisplay.formatSuccess(name: name, output: result.output))
                        }

                    case .toolDenied(let name, let reason):
                        print(ToolCallDisplay.formatDenied(name: name, reason: reason))

                    case .usageUpdate(let usage):
                        totalUsage += usage

                    case .turnComplete(let summary):
                        // Flush any remaining markdown
                        if let remaining = streamState.flush() {
                            print(remaining, terminator: "")
                        }
                        if hasOutput { print() }

                        // Show turn summary
                        if summary.toolCallCount > 0 {
                            let info = ANSI.colored(
                                "[\(summary.iterations) turn\(summary.iterations == 1 ? "" : "s"), \(summary.toolCallCount) tool call\(summary.toolCallCount == 1 ? "" : "s")]",
                                theme.dim
                            )
                            print(info)
                        }

                        // Show usage
                        if totalUsage.totalTokens > 0 {
                            let cost = provider.estimateCost(usage: totalUsage)
                            print(ANSI.colored(
                                "\(totalUsage.inputTokens)↑ \(totalUsage.outputTokens)↓ \(cost.formattedUSD)",
                                theme.dim
                            ))
                        }
                        print()
                    }
                }
            } catch {
                print("\n\(ANSI.colored("Error:", ANSI.red)) \(error.localizedDescription)\n")
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
    for serverConfig in project.mcpServers {
        do {
            try await connector.connect(config: serverConfig)
        } catch {
            print("  MCP '\(serverConfig.name)': failed to connect (\(error.localizedDescription))")
        }
    }
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

// MARK: - File/Image Attachment Helpers

/// Load a text file as a document content block.
private func loadFileAttachment(path: String) -> ContentBlock? {
    let expanded = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else { return nil }

    let ext = (expanded as NSString).pathExtension.lowercased()
    let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
    guard !imageExtensions.contains(ext) else { return nil } // Not a text file

    guard let data = FileManager.default.contents(atPath: expanded),
          let content = String(data: data, encoding: .utf8) else { return nil }

    let filename = (expanded as NSString).lastPathComponent
    let mediaType: String = switch ext {
    case "md": "text/markdown"
    case "json": "application/json"
    case "toml": "application/toml"
    case "yaml", "yml": "text/yaml"
    case "csv": "text/csv"
    default: "text/plain"
    }

    // Truncate very large files
    let maxChars = 50_000
    let truncated = content.count > maxChars
        ? String(content.prefix(maxChars)) + "\n... (truncated, \(content.count) total chars)"
        : content

    return .document(name: filename, mediaType: mediaType, content: truncated)
}

/// Load an image file as a base64 image content block.
private func loadImageAttachment(path: String) -> ContentBlock? {
    let expanded = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else { return nil }

    let ext = (expanded as NSString).pathExtension.lowercased()
    let mediaType: String
    switch ext {
    case "png": mediaType = "image/png"
    case "gif": mediaType = "image/gif"
    case "webp": mediaType = "image/webp"
    case "jpg", "jpeg": mediaType = "image/jpeg"
    default: return nil
    }

    guard let data = FileManager.default.contents(atPath: expanded) else { return nil }
    let base64 = data.base64EncodedString()

    return .image(source: .base64(mediaType: mediaType, data: base64))
}
