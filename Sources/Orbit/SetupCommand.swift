import ArgumentParser
import Foundation
import OrbitCore

/// Comprehensive onboarding wizard — detects existing tools, migrates configs,
/// sets up authentication, discovers projects, and creates starter content.
struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Interactive setup wizard — configure Orbit with migration from existing tools."
    )

    func run() async throws {
        let orbitHome = ConfigLoader.orbitHome
        let detector = MigrationDetector()

        print("""
        ╔══════════════════════════════════════════╗
        ║          Welcome to Orbit Setup          ║
        ║   LLM-Agnostic Operations Platform       ║
        ╚══════════════════════════════════════════╝
        """)

        // Step 1: Create directory structure
        print("Setting up ~/.orbit/ directory structure...")
        createDirectoryStructure(at: orbitHome)
        print("  Done.\n")

        // Step 2: Detect existing tools
        print("Scanning for existing AI tools...\n")
        let tools = detector.detectTools()
        if tools.isEmpty {
            print("  No existing tools detected.\n")
        } else {
            for tool in tools {
                let icon: String = switch tool.kind {
                case .claudeCode: "🤖"
                case .claudeDesktop: "🖥"
                case .codexCLI: "⚡"
                case .envAPIKey: "🔑"
                }
                print("  \(icon) \(tool.name)")
                if let suffix = tool.details["suffix"] {
                    print("     Key: ***\(suffix)")
                }
                if tool.details["hasCredentials"] == "true" {
                    print("     OAuth credentials found")
                }
                if tool.details["hasSettings"] == "true" {
                    print("     Settings found (hooks, MCP configs)")
                }
            }
            print()
        }

        // Step 3: Authentication
        print("── Authentication ──\n")
        let authConfig = try await setupAuthentication(tools: tools)

        // Step 4: Migrate MCP servers
        print("\n── MCP Server Migration ──\n")
        let mcpServers = migrateMCPServers(detector: detector, tools: tools)

        // Step 5: Model selection
        print("── Model Selection ──\n")
        let (provider, model) = selectModel(authConfig: authConfig)

        // Step 6: Permission preference
        print("\n── Permission Mode ──\n")
        let permMode = selectPermissionMode()

        // Step 7: Write global config
        print("\n── Writing Configuration ──\n")
        writeGlobalConfig(
            at: orbitHome,
            provider: provider,
            model: model,
            authConfig: authConfig,
            permMode: permMode
        )

        // Step 8: Project discovery
        print("── Project Discovery ──\n")
        let repos = detector.discoverRepos()
        let configuredProjects = setupProjects(repos: repos, detector: detector, mcpServers: mcpServers, at: orbitHome)

        // Step 9: Starter skills
        print("\n── Starter Skills ──\n")
        setupStarterSkills(at: orbitHome, projects: configuredProjects)

        // Step 10: Test connection
        print("\n── Connection Test ──\n")
        await testConnection(provider: provider, model: model, authConfig: authConfig)

        // Done
        print("""

        ╔══════════════════════════════════════════╗
        ║          Setup Complete!                  ║
        ╚══════════════════════════════════════════╝

        Config:   \(orbitHome.path)/orbit.toml
        Projects: \(configuredProjects.count) configured
        Provider: \(provider) (\(model))

        Get started:
          orbit                  # Start interactive chat
          orbit ask default "Hello"  # One-shot query
          orbit status           # Overview

        """)
    }

    // MARK: - Step 1: Directory Structure

    private func createDirectoryStructure(at orbitHome: URL) {
        let dirs = [
            "projects", "schedules", "skills/_global", "sessions",
            "logs/daily", "logs/tasks", "deep-tasks",
        ]
        for dir in dirs {
            try? FileManager.default.createDirectory(
                at: orbitHome.appendingPathComponent(dir),
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Step 3: Authentication

    private func setupAuthentication(tools: [DetectedTool]) async throws -> SetupAuthConfig {
        let hasClaude = tools.contains { $0.kind == .claudeCode }
        let hasAnthropicKey = tools.contains { $0.kind == .envAPIKey && $0.path == "ANTHROPIC_API_KEY" }
        let hasOpenAIKey = tools.contains { $0.kind == .envAPIKey && $0.path == "OPENAI_API_KEY" }
        let hasClaudeCredentials = tools.first { $0.kind == .claudeCode }?.details["hasCredentials"] == "true"

        print("How would you like to authenticate?\n")

        var options: [(String, String)] = []
        if hasClaude {
            options.append(("bridge", "Bridge mode — use installed Claude CLI (recommended, uses your subscription)"))
        }
        if hasAnthropicKey {
            options.append(("api_key_anthropic", "Anthropic API key (ANTHROPIC_API_KEY detected)"))
        }
        if hasOpenAIKey {
            options.append(("api_key_openai", "OpenAI API key (OPENAI_API_KEY detected)"))
        }
        if hasClaudeCredentials {
            options.append(("oauth_reuse", "OAuth — reuse Claude Code credentials"))
        }
        options.append(("oauth_new", "OAuth — login via browser"))
        options.append(("api_key_manual", "Enter an API key manually"))

        for (i, option) in options.enumerated() {
            print("  \(i + 1). \(option.1)")
        }

        print("\nChoice [\(hasClaude ? "1" : "1")]: ", terminator: "")
        fflush(stdout)
        let input = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let choice = Int(input) ?? 1
        let selected = options.indices.contains(choice - 1) ? options[choice - 1].0 : options[0].0

        switch selected {
        case "bridge":
            print("  Using bridge mode with Claude CLI.\n")
            return SetupAuthConfig(provider: "anthropic", mode: .bridge)

        case "api_key_anthropic":
            print("  Using existing ANTHROPIC_API_KEY.\n")
            return SetupAuthConfig(provider: "anthropic", mode: .apiKey, apiKeyEnv: "ANTHROPIC_API_KEY")

        case "api_key_openai":
            print("  Using existing OPENAI_API_KEY.\n")
            return SetupAuthConfig(provider: "openai", mode: .apiKey, apiKeyEnv: "OPENAI_API_KEY")

        case "oauth_reuse":
            if let tokenSet = OAuthManager.loadFromClaudeCode() {
                let manager = OAuthManager()
                try manager.saveCredentials(tokenSet)
                print("  Imported OAuth credentials from Claude Code.\n")
                return SetupAuthConfig(provider: "anthropic", mode: .oauth)
            }
            print("  Could not read Claude Code credentials. Falling back to bridge.\n")
            return SetupAuthConfig(provider: "anthropic", mode: .bridge)

        case "oauth_new":
            print("  OAuth login will open your browser.\n")
            return SetupAuthConfig(provider: "anthropic", mode: .oauth, needsLogin: true)

        case "api_key_manual":
            print("\n  Provider (anthropic/openai): ", terminator: "")
            fflush(stdout)
            let prov = readLine()?.trimmingCharacters(in: .whitespaces) ?? "anthropic"

            print("  API key: ", terminator: "")
            fflush(stdout)
            let key = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""

            if !key.isEmpty {
                let envName = prov == "openai" ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY"
                print("  Tip: Set \(envName)=\(key.prefix(8))... in your shell profile for persistence.\n")
                return SetupAuthConfig(provider: prov, mode: .apiKey, apiKeyEnv: envName, manualKey: key)
            }
            return SetupAuthConfig(provider: "anthropic", mode: .bridge)

        default:
            return SetupAuthConfig(provider: "anthropic", mode: .bridge)
        }
    }

    // MARK: - Step 4: MCP Migration

    private func migrateMCPServers(detector: MigrationDetector, tools: [DetectedTool]) -> [DiscoveredMCPServer] {
        var allServers: [DiscoveredMCPServer] = []

        // From Claude Code
        let claudeCodeServers = detector.readClaudeCodeMCPServers()
        if !claudeCodeServers.isEmpty {
            print("  Found \(claudeCodeServers.count) MCP server(s) from Claude Code:")
            for server in claudeCodeServers {
                print("    - \(server.name)")
            }
            print("  Import these? [Y/n] ", terminator: "")
            fflush(stdout)
            let answer = readLine()?.lowercased() ?? "y"
            if answer != "n" && answer != "no" {
                allServers.append(contentsOf: claudeCodeServers)
                print("  Imported.\n")
            }
        }

        // From Claude Desktop
        let desktopServers = detector.readClaudeDesktopMCPServers()
        if !desktopServers.isEmpty {
            print("  Found \(desktopServers.count) MCP server(s) from Claude Desktop:")
            for server in desktopServers {
                print("    - \(server.name)")
            }
            print("  Import these? [Y/n] ", terminator: "")
            fflush(stdout)
            let answer = readLine()?.lowercased() ?? "y"
            if answer != "n" && answer != "no" {
                allServers.append(contentsOf: desktopServers)
                print("  Imported.\n")
            }
        }

        if allServers.isEmpty {
            print("  No MCP servers found to migrate.\n")
        }

        return allServers
    }

    // MARK: - Step 5: Model Selection

    private func selectModel(authConfig: SetupAuthConfig) -> (String, String) {
        let isOpenAI = authConfig.provider == "openai"

        if isOpenAI {
            print("  Available OpenAI models:")
            print("    1. gpt-4o          ($2.50/M in, $10/M out) — recommended")
            print("    2. gpt-4o-mini     ($0.15/M in, $0.60/M out) — fast & cheap")
            print("    3. o3              ($10/M in, $40/M out) — strongest reasoning")
        } else {
            print("  Available Anthropic models:")
            print("    1. claude-sonnet-4-6  ($3/M in, $15/M out) — recommended")
            print("    2. claude-haiku-4-5   ($1/M in, $5/M out) — fast & cheap")
            print("    3. claude-opus-4-6    ($15/M in, $75/M out) — strongest reasoning")
        }

        print("\n  Choice [1]: ", terminator: "")
        fflush(stdout)
        let input = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let choice = Int(input) ?? 1

        if isOpenAI {
            let model: String = switch choice {
            case 2: "gpt-4o-mini"
            case 3: "o3"
            default: "gpt-4o"
            }
            return ("openai", model)
        } else {
            let model: String = switch choice {
            case 2: "claude-haiku-4-5"
            case 3: "claude-opus-4-6"
            default: "claude-sonnet-4-6"
            }
            return ("anthropic", model)
        }
    }

    // MARK: - Step 6: Permission Mode

    private func selectPermissionMode() -> String {
        print("  How cautious should Orbit be with tool execution?\n")
        print("    1. Full access    — execute tools freely (recommended for solo use)")
        print("    2. Workspace only — can write files only within project directories")
        print("    3. Read only      — can only read files and search, no writes or commands")

        print("\n  Choice [1]: ", terminator: "")
        fflush(stdout)
        let input = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        let choice = Int(input) ?? 1

        return switch choice {
        case 2: "workspace-write"
        case 3: "read-only"
        default: "danger-full-access"
        }
    }

    // MARK: - Step 7: Write Config

    private func writeGlobalConfig(
        at orbitHome: URL,
        provider: String,
        model: String,
        authConfig: SetupAuthConfig,
        permMode: String
    ) {
        let configPath = orbitHome.appendingPathComponent("orbit.toml")

        var authSection: String
        switch authConfig.mode {
        case .bridge:
            authSection = """
            [auth.\(authConfig.provider)]
            mode = "bridge"
            """
        case .apiKey:
            authSection = """
            [auth.\(authConfig.provider)]
            mode = "api_key"
            api_key_env = "\(authConfig.apiKeyEnv ?? "ANTHROPIC_API_KEY")"
            """
        case .oauth:
            authSection = """
            [auth.\(authConfig.provider)]
            mode = "oauth"
            credentials_path = "~/.orbit/credentials.json"
            """
        }

        let config = """
        # Orbit Configuration
        # Generated by `orbit setup` on \(formattedDate())

        [defaults]
        provider = "\(provider)"
        model = "\(model)"

        \(authSection)

        [memory]
        db_path = "~/.orbit/memory.db"
        auto_summarize = true
        max_context_entries = 20

        [context]
        max_file_chars = 4000
        max_total_chars = 12000

        [permissions]
        default_mode = "\(permMode)"

        [daemon]
        enabled = false
        tick_interval = 300
        dream_threshold = 1800
        """

        try? config.write(to: configPath, atomically: true, encoding: .utf8)
        print("  Written: \(configPath.path)")
    }

    // MARK: - Step 8: Project Discovery

    private func setupProjects(
        repos: [DiscoveredRepo],
        detector: MigrationDetector,
        mcpServers: [DiscoveredMCPServer],
        at orbitHome: URL
    ) -> [String] {
        if repos.isEmpty {
            print("  No git repositories found in common directories.")
            print("  You can add projects later with `orbit project add`.\n")
            return createManualProject(mcpServers: mcpServers, at: orbitHome)
        }

        print("  Found \(repos.count) git repositor\(repos.count == 1 ? "y" : "ies"):\n")
        for (i, repo) in repos.prefix(15).enumerated() {
            var flags: [String] = []
            if repo.hasClaudeMD { flags.append("has CLAUDE.md") }
            if repo.recentCommits > 0 { flags.append("active") }
            let flagStr = flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
            print("    \(i + 1). \(repo.name)\(flagStr)")
            print("       \(repo.path.path)")
        }

        print("\n  Enter numbers to configure (comma-separated), or 'skip': ", terminator: "")
        fflush(stdout)
        let input = readLine()?.trimmingCharacters(in: .whitespaces) ?? "skip"

        if input.lowercased() == "skip" {
            return createManualProject(mcpServers: mcpServers, at: orbitHome)
        }

        let indices = input.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .map { $0 - 1 }
            .filter { repos.indices.contains($0) }

        var configured: [String] = []
        for idx in indices {
            let repo = repos[idx]
            let slug = repo.name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")

            // Build project TOML
            var toml = """
            [project]
            name = "\(repo.name)"
            slug = "\(slug)"
            repo = "\(repo.path.path)"
            """

            // Add MCP servers if available
            if !mcpServers.isEmpty {
                toml += "\n"
                for server in mcpServers {
                    if let command = server.command {
                        toml += "\n[mcps.\(server.name)]\ntype = \"stdio\"\ncommand = \"\(command)\""
                        if !server.args.isEmpty {
                            toml += "\nargs = [\(server.args.map { "\"\($0)\"" }.joined(separator: ", "))]"
                        }
                    } else if let url = server.url {
                        toml += "\n[mcps.\(server.name)]\ntype = \"http\"\nurl = \"\(url)\""
                    }
                }
            }

            let projectPath = orbitHome.appendingPathComponent("projects/\(slug).toml")
            try? toml.write(to: projectPath, atomically: true, encoding: .utf8)

            // Migrate CLAUDE.md → ORBIT.md if present
            if repo.hasClaudeMD {
                let claudeMDPath = repo.path.appendingPathComponent("CLAUDE.md")
                if let content = detector.migrateCLAUDEmd(at: claudeMDPath) {
                    let orbitMDPath = repo.path.appendingPathComponent("ORBIT.md")
                    if !FileManager.default.fileExists(atPath: orbitMDPath.path) {
                        try? content.write(to: orbitMDPath, atomically: true, encoding: .utf8)
                        print("  Migrated CLAUDE.md → ORBIT.md for \(repo.name)")
                    }
                }
            }

            // Create skills directory
            let skillsDir = orbitHome.appendingPathComponent("skills/\(slug)")
            try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

            configured.append(slug)
            print("  Configured: \(slug)")
        }

        return configured
    }

    private func createManualProject(mcpServers: [DiscoveredMCPServer], at orbitHome: URL) -> [String] {
        print("\n  Create a project manually? [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.lowercased() ?? "n"
        guard answer == "y" || answer == "yes" else { return [] }

        print("  Project name: ", terminator: "")
        fflush(stdout)
        guard let name = readLine()?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return [] }

        let slug = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        print("  Repository path (optional): ", terminator: "")
        fflush(stdout)
        let repo = readLine()?.trimmingCharacters(in: .whitespaces)

        var toml = "[project]\nname = \"\(name)\"\nslug = \"\(slug)\""
        if let repo, !repo.isEmpty { toml += "\nrepo = \"\(repo)\"" }

        let projectPath = orbitHome.appendingPathComponent("projects/\(slug).toml")
        try? toml.write(to: projectPath, atomically: true, encoding: .utf8)

        let skillsDir = orbitHome.appendingPathComponent("skills/\(slug)")
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        print("  Created: \(slug)")
        return [slug]
    }

    // MARK: - Step 9: Starter Skills

    private func setupStarterSkills(at orbitHome: URL, projects: [String]) {
        print("  Install starter skill templates?\n")
        for (i, template) in StarterSkills.templates.enumerated() {
            print("    \(i + 1). \(template.name)")
        }
        print("    a. All of them")
        print("    n. Skip")

        print("\n  Choice [a]: ", terminator: "")
        fflush(stdout)
        let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "a"

        var selectedTemplates: [Int]
        if input == "n" || input == "skip" {
            selectedTemplates = []
        } else if input == "a" || input.isEmpty {
            selectedTemplates = Array(StarterSkills.templates.indices)
        } else {
            selectedTemplates = input.split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .map { $0 - 1 }
                .filter { StarterSkills.templates.indices.contains($0) }
        }

        let targetDir = orbitHome.appendingPathComponent("skills/_global")
        for idx in selectedTemplates {
            let template = StarterSkills.templates[idx]
            let path = targetDir.appendingPathComponent(template.filename)
            if !FileManager.default.fileExists(atPath: path.path) {
                try? template.content.write(to: path, atomically: true, encoding: .utf8)
                print("  Added: \(template.name)")
            }
        }

        if selectedTemplates.isEmpty {
            print("  Skipped.")
        }
    }

    // MARK: - Step 10: Connection Test

    private func testConnection(provider: String, model: String, authConfig: SetupAuthConfig) async {
        print("  Testing connection to \(provider) (\(model))...")

        do {
            let globalConfig = try ConfigLoader.loadGlobal()
            let llmProvider = try resolveProviderForChat(
                providerName: provider,
                model: model,
                authModeOverride: authConfig.mode.rawValue,
                globalConfig: globalConfig
            )

            let stream = llmProvider.stream(
                messages: [.userText("Say 'Orbit is ready!' and nothing else.")],
                systemPrompt: "You are Orbit. Respond with exactly the requested text.",
                tools: []
            )

            var response = ""
            for try await event in stream {
                if case .textDelta(let text) = event {
                    response += text
                }
            }

            print("  Response: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
            print("  Connection successful!")
        } catch {
            print("  Connection failed: \(error.localizedDescription)")
            print("  You can reconfigure later with `orbit setup`.")
        }
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// Internal config used during setup.
struct SetupAuthConfig {
    let provider: String
    let mode: AuthMode
    var apiKeyEnv: String?
    var manualKey: String?
    var needsLogin: Bool = false
}
