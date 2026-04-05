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

        let tools: [any Tool] = noTools ? [] : builtinTools()
        let toolPool = ToolPool(tools: tools)
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)
        let commandRegistry = SlashCommandRegistry.default

        // Session
        var session = Session()
        let sessionStore = FileSessionStore()

        // Print header
        print("Orbit v0.1.0 — \(projectConfig.name)")
        print("Model: \(effectiveModel) | Provider: \(effectiveProvider)")
        print("Type /help for commands, /exit to quit.\n")

        let systemPrompt = buildChatSystemPrompt(project: projectConfig)
        var messages: [ChatMessage] = []
        var totalUsage = TokenUsage.zero
        var currentModel = effectiveModel

        // REPL loop
        while true {
            print("▸ ", terminator: "")
            fflush(stdout)

            guard let input = readLine()?.trimmingCharacters(in: .whitespaces) else {
                break // EOF
            }

            guard !input.isEmpty else { continue }

            // Check for slash commands
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
                    try? sessionStore.save(session, project: projectConfig.slug)
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
                    do {
                        let memoryStore = try SQLiteMemory()
                        let report = try await DreamEngine.dream(
                            store: memoryStore,
                            project: projectConfig.slug
                        )
                        print("Dream complete: \(report.observationsExtracted) observations, \(report.topicsCreated) created, \(report.topicsUpdated) updated\n")
                    } catch {
                        print("Dream failed: \(error.localizedDescription)\n")
                    }
                case .deep(let deepPrompt):
                    let deepTask = DeepTask(
                        name: "Deep Analysis",
                        prompt: deepPrompt,
                        projects: [projectConfig.slug]
                    )
                    let runner = DeepTaskRunner(provider: provider)
                    let completed = try await runner.run(deepTask)
                    if let result = completed.result {
                        print(result)
                    }
                    print()
                case .resume, .none:
                    print()
                }
                continue
            }

            // Send to LLM via query engine
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
            var assistantText = ""

            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let text):
                        print(text, terminator: "")
                        fflush(stdout)
                        hasOutput = true
                        assistantText += text

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

            // Save session periodically
            try? sessionStore.save(session, project: projectConfig.slug)
        }
    }
}

// MARK: - Helpers

private func resolveDefaultProject(_ config: OrbitConfig) -> String {
    let projects = ConfigLoader.listProjects()
    if projects.count == 1 {
        return projects[0]
    }
    return "default"
}

private func buildChatSystemPrompt(project: ProjectConfig) -> String {
    var parts: [String] = []

    parts.append("""
    You are Orbit, an AI operations assistant. You help manage projects, \
    analyze business data, and handle operational tasks. You are NOT a coding \
    agent — you are an operations manager. You have access to tools for \
    file operations, shell commands, and search. Use them when needed.
    """)

    if !project.description.isEmpty {
        parts.append("Project: \(project.name)\n\(project.description)")
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    parts.append("Today's date: \(formatter.string(from: Date())).")

    return parts.joined(separator: "\n\n")
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
