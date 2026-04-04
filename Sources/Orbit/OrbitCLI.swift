import ArgumentParser
import Foundation
import OrbitCore

@main
struct OrbitCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orbit",
        abstract: "LLM-agnostic agent platform for project operations.",
        version: "0.1.0",
        subcommands: [Ask.self]
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

    @Option(name: .long, help: "Auth mode: 'apiKey' or 'bridge' (auto-detected if omitted).")
    var authMode: String?

    @Option(name: .long, help: "Maximum tool-use turns (default: 8).")
    var maxTurns: Int = 8

    @Flag(name: .long, help: "Disable tool use (text-only response).")
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

        let provider = try resolveProvider(
            providerName: effectiveProvider,
            model: effectiveModel,
            authModeOverride: authMode,
            globalConfig: globalConfig
        )

        let systemPrompt = buildSystemPrompt(project: projectConfig)

        // Build tool pool
        let tools: [any Tool] = noTools ? [] : builtinTools()
        let toolPool = ToolPool(tools: tools)

        // Permission policy — default to workspace-write for ask
        let policy = PermissionPolicy(activeMode: .dangerFullAccess)

        // Build query engine
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

// MARK: - Terminal Permission Prompter

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

// MARK: - Provider Resolution

private func resolveProvider(
    providerName: String,
    model: String,
    authModeOverride: String?,
    globalConfig: OrbitConfig
) throws -> any LLMProvider {
    let authConfig = globalConfig.auth[providerName]
    let resolvedMode: AuthMode

    if let override = authModeOverride {
        guard let mode = AuthMode(rawValue: override) else {
            throw AuthError.unsupportedAuthMode(.bridge)
        }
        resolvedMode = mode
    } else if let configured = authConfig?.mode {
        resolvedMode = configured
    } else {
        resolvedMode = autoDetectAuthMode(provider: providerName, authConfig: authConfig)
    }

    switch resolvedMode {
    case .apiKey:
        let apiKey = try resolveAPIKey(provider: providerName, authConfig: authConfig)
        return AnthropicProvider(apiKey: apiKey, model: model)

    case .bridge:
        let cliPath = try resolveCLIPath(provider: providerName, authConfig: authConfig)
        return BridgeProvider(name: providerName, cliPath: cliPath, model: model)

    case .oauth:
        throw AuthError.unsupportedAuthMode(.oauth)
    }
}

private func autoDetectAuthMode(provider: String, authConfig: AuthConfig?) -> AuthMode {
    if authConfig?.resolveAPIKey() != nil {
        return .apiKey
    }

    let envVarName: String = switch provider {
    case "anthropic": "ANTHROPIC_API_KEY"
    case "openai": "OPENAI_API_KEY"
    default: "\(provider.uppercased())_API_KEY"
    }

    if ProcessInfo.processInfo.environment[envVarName] != nil {
        return .apiKey
    }

    if let cliPath = authConfig?.cliPath,
       FileManager.default.isExecutableFile(atPath: cliPath) {
        return .bridge
    }

    if BridgeProvider.detectClaudeCLI() != nil {
        return .bridge
    }

    return .apiKey
}

private func resolveAPIKey(provider: String, authConfig: AuthConfig?) throws -> String {
    if let key = authConfig?.resolveAPIKey() {
        return key
    }

    let envVarName: String = switch provider {
    case "anthropic": "ANTHROPIC_API_KEY"
    case "openai": "OPENAI_API_KEY"
    default: "\(provider.uppercased())_API_KEY"
    }

    if let key = ProcessInfo.processInfo.environment[envVarName] {
        return key
    }

    throw AuthError.missingAPIKey(provider: provider, envVar: envVarName)
}

private func resolveCLIPath(provider: String, authConfig: AuthConfig?) throws -> String {
    if let path = authConfig?.cliPath,
       FileManager.default.isExecutableFile(atPath: path) {
        return path
    }

    if provider == "anthropic", let path = BridgeProvider.detectClaudeCLI() {
        return path
    }

    throw ProviderError.authenticationFailed(
        "No CLI tool found for '\(provider)'. Install the claude CLI or set cli_path in config."
    )
}

// MARK: - System Prompt

private func buildSystemPrompt(project: ProjectConfig) -> String {
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

    parts.append("Today's date: \(formattedDate()).")

    return parts.joined(separator: "\n\n")
}

private func formattedDate() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}
