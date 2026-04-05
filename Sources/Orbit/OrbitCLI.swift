import ArgumentParser
import Foundation
import OrbitCore

@main
struct OrbitCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orbit",
        abstract: "LLM-agnostic agent platform for project operations.",
        version: "0.1.0",
        subcommands: [
            Chat.self, Ask.self, Run.self, Deep.self,
            Init.self, Project.self, Memory.self,
            Schedule.self, Daemon.self,
            Auth.self, Status.self,
        ],
        defaultSubcommand: Chat.self
    )
}

// MARK: - orbit ask

struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "One-shot query against a project."
    )

    @Argument(help: "Project slug (or 'default' to use global config).")
    var project: String

    @Argument(help: "The query to send to the LLM.")
    var query: String

    @Option(name: .long, help: "Override the model to use.")
    var model: String?

    @Option(name: .long, help: "Auth mode: 'apiKey' or 'bridge'.")
    var authMode: String?

    @Option(name: .long, help: "Maximum tool-use turns (default: 8).")
    var maxTurns: Int = 8

    @Flag(name: .long, help: "Disable tool use.")
    var noTools: Bool = false

    @Flag(name: .long, help: "Show token usage and cost after the response.")
    var showCost: Bool = false

    func run() async throws {
        let globalConfig = try ConfigLoader.loadGlobal()

        let projectConfig: ProjectConfig
        if project == "default" {
            projectConfig = ProjectConfig(name: "default", slug: "default")
        } else {
            projectConfig = try ConfigLoader.loadProject(slug: project)
        }

        let effectiveModel = model ?? projectConfig.effectiveModel(global: globalConfig)
        let effectiveProvider = projectConfig.effectiveProvider(global: globalConfig)

        let provider = try resolveProviderForChat(
            providerName: effectiveProvider,
            model: effectiveModel,
            authModeOverride: authMode,
            globalConfig: globalConfig
        )

        // Build full system prompt with context, memory, skills
        let cwd = URL(fileURLWithPath: projectConfig.repoPath.map {
            ($0 as NSString).expandingTildeInPath
        } ?? FileManager.default.currentDirectoryPath)
        let memoryStore: SQLiteMemory? = try? SQLiteMemory(path: globalConfig.memoryDBPath)
        let skillLoader = SkillLoader()
        let skills = skillLoader.loadSkills(project: projectConfig.slug)
        let systemPrompt = await buildFullAskSystemPrompt(
            project: projectConfig, cwd: cwd, memoryStore: memoryStore, skills: skills
        )

        let policy = PermissionPolicy(activeMode: .dangerFullAccess)
        let tools: [any Tool] = noTools ? [] : allTools(provider: provider, policy: policy)
        let toolPool = ToolPool(tools: tools)

        let engine = QueryEngine(
            provider: provider,
            toolPool: toolPool,
            policy: policy,
            config: QueryEngineConfig(maxTurns: maxTurns),
            prompter: TerminalPrompter()
        )

        var messages = [ChatMessage.userText(query)]
        let stream = engine.run(messages: &messages, systemPrompt: systemPrompt)

        var totalUsage = TokenUsage.zero
        var hasOutput = false

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
                    print(" ✗ \(name): \(result.output.prefix(100))")
                } else {
                    let preview = result.output.prefix(80).replacingOccurrences(of: "\n", with: " ")
                    print(" ✓ (\(preview)...)")
                }

            case .toolDenied(let name, let reason):
                print("  ⊘ \(name) denied: \(reason)")

            case .usageUpdate(let usage):
                totalUsage += usage

            case .turnComplete(let summary):
                if hasOutput { print() }
                if summary.toolCallCount > 0 {
                    print("[\(summary.iterations) turn\(summary.iterations == 1 ? "" : "s"), \(summary.toolCallCount) tool call\(summary.toolCallCount == 1 ? "" : "s")]")
                }
            }
        }

        if showCost {
            let cost = provider.estimateCost(usage: totalUsage)
            print()
            print("--- Usage ---")
            print("Input tokens:  \(totalUsage.inputTokens)")
            print("Output tokens: \(totalUsage.outputTokens)")
            if totalUsage.cacheReadInputTokens > 0 {
                print("Cache read:    \(totalUsage.cacheReadInputTokens)")
            }
            if totalUsage.cacheCreationInputTokens > 0 {
                print("Cache create:  \(totalUsage.cacheCreationInputTokens)")
            }
            print("Total cost:    \(cost.formattedUSD)")
        }
    }
}

// MARK: - Helpers

private func buildFullAskSystemPrompt(
    project: ProjectConfig,
    cwd: URL,
    memoryStore: SQLiteMemory?,
    skills: [Skill]
) async -> String {
    let identity = """
    You are Orbit, an AI operations assistant. You help manage projects, \
    analyze business data, and handle operational tasks. You are NOT a coding \
    agent — you are an operations manager. You have access to tools for \
    file operations, shell commands, and search. Use them when needed.
    """

    let instructionFiles = ContextBuilder.discoverInstructionFiles(at: cwd)

    var memoryContext: String? = nil
    if let store = memoryStore {
        memoryContext = try? await store.assembleContext(project: project.slug, currentQuery: "", maxEntries: 20)
    }

    var skillsContext: String? = nil
    if !skills.isEmpty {
        let texts = skills.map { "### \($0.name)\n\($0.content)" }
        skillsContext = "# Available Skills\n\n" + texts.joined(separator: "\n\n")
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"

    return ContextBuilder(
        identity: identity,
        projectContext: ProjectContext(
            projectName: project.name,
            projectDescription: project.description,
            instructionFiles: instructionFiles
        ),
        skillsContext: skillsContext,
        memoryContext: memoryContext,
        currentDate: formatter.string(from: Date())
    ).build()
}
