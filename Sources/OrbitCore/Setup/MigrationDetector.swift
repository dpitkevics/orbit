import Foundation

/// Detected installation of an existing AI tool.
public struct DetectedTool: Sendable {
    public let name: String
    public let path: String
    public let kind: DetectedToolKind
    public let details: [String: String]

    public init(name: String, path: String, kind: DetectedToolKind, details: [String: String] = [:]) {
        self.name = name
        self.path = path
        self.kind = kind
        self.details = details
    }
}

public enum DetectedToolKind: String, Sendable {
    case claudeCode
    case claudeDesktop
    case codexCLI
    case envAPIKey
}

/// Discovered git repository on the filesystem.
public struct DiscoveredRepo: Sendable {
    public let name: String
    public let path: URL
    public let hasClaudeMD: Bool
    public let recentCommits: Int

    public init(name: String, path: URL, hasClaudeMD: Bool, recentCommits: Int) {
        self.name = name
        self.path = path
        self.hasClaudeMD = hasClaudeMD
        self.recentCommits = recentCommits
    }
}

/// MCP server config discovered from Claude Desktop.
public struct DiscoveredMCPServer: Sendable {
    public let name: String
    public let command: String?
    public let args: [String]
    public let url: String?
    public let env: [String: String]

    public init(name: String, command: String? = nil, args: [String] = [], url: String? = nil, env: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.args = args
        self.url = url
        self.env = env
    }
}

/// Scans the system for existing AI tools, credentials, repos, and MCP configs.
public struct MigrationDetector: Sendable {
    private let home: URL

    public init() {
        self.home = FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Tool Detection

    /// Detect all installed AI tools and existing credentials.
    public func detectTools() -> [DetectedTool] {
        var tools: [DetectedTool] = []

        // Claude Code CLI
        if let cliPath = BridgeProvider.detectClaudeCLI() {
            var details: [String: String] = ["cli": cliPath]
            let configDir = home.appendingPathComponent(".claude")
            if FileManager.default.fileExists(atPath: configDir.path) {
                details["configDir"] = configDir.path
            }
            if FileManager.default.fileExists(atPath: configDir.appendingPathComponent("credentials.json").path) {
                details["hasCredentials"] = "true"
            }
            if FileManager.default.fileExists(atPath: configDir.appendingPathComponent("settings.json").path) {
                details["hasSettings"] = "true"
            }
            tools.append(DetectedTool(name: "Claude Code", path: cliPath, kind: .claudeCode, details: details))
        }

        // Claude Desktop
        let claudeDesktopConfig = home
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        if FileManager.default.fileExists(atPath: claudeDesktopConfig.path) {
            tools.append(DetectedTool(
                name: "Claude Desktop",
                path: claudeDesktopConfig.path,
                kind: .claudeDesktop,
                details: ["configPath": claudeDesktopConfig.path]
            ))
        }

        // Codex CLI
        let codexPaths = [
            home.appendingPathComponent(".local/bin/codex").path,
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
        ]
        for path in codexPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                var details: [String: String] = ["cli": path]
                let codexConfig = home.appendingPathComponent(".codex")
                if FileManager.default.fileExists(atPath: codexConfig.path) {
                    details["configDir"] = codexConfig.path
                }
                tools.append(DetectedTool(name: "Codex CLI", path: path, kind: .codexCLI, details: details))
                break
            }
        }

        // Environment API keys
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
            tools.append(DetectedTool(
                name: "Anthropic API Key",
                path: "ANTHROPIC_API_KEY",
                kind: .envAPIKey,
                details: ["suffix": String(key.suffix(4))]
            ))
        }
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] {
            tools.append(DetectedTool(
                name: "OpenAI API Key",
                path: "OPENAI_API_KEY",
                kind: .envAPIKey,
                details: ["suffix": String(key.suffix(4))]
            ))
        }

        return tools
    }

    // MARK: - Claude Code Migration

    /// Read MCP server configs from Claude Code settings.
    public func readClaudeCodeMCPServers() -> [DiscoveredMCPServer] {
        let settingsPath = home.appendingPathComponent(".claude/settings.json")
        return parseMCPFromJSON(at: settingsPath, key: "mcpServers")
    }

    /// Read Claude Code hooks configuration.
    public func readClaudeCodeHooks() -> [String: [String]] {
        let settingsPath = home.appendingPathComponent(".claude/settings.json")
        guard let data = FileManager.default.contents(atPath: settingsPath.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return [:]
        }

        var result: [String: [String]] = [:]
        for (event, value) in hooks {
            if let commands = value as? [[String: Any]] {
                result[event] = commands.compactMap { $0["command"] as? String }
            }
        }
        return result
    }

    // MARK: - Claude Desktop Migration

    /// Read MCP server configs from Claude Desktop.
    public func readClaudeDesktopMCPServers() -> [DiscoveredMCPServer] {
        let configPath = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        return parseMCPFromJSON(at: configPath, key: "mcpServers")
    }

    // MARK: - Project Discovery

    /// Scan common directories for git repositories.
    public func discoverRepos(searchDirs: [String]? = nil) -> [DiscoveredRepo] {
        let dirs = searchDirs ?? [
            home.appendingPathComponent("Projects").path,
            home.appendingPathComponent("Developer").path,
            home.appendingPathComponent("Code").path,
            home.appendingPathComponent("repos").path,
            home.appendingPathComponent("XcodeProjects").path,
            home.appendingPathComponent("src").path,
        ]

        var repos: [DiscoveredRepo] = []
        let fm = FileManager.default

        for dir in dirs {
            guard fm.fileExists(atPath: dir) else { continue }
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }

            for item in contents where !item.hasPrefix(".") {
                let itemPath = URL(fileURLWithPath: dir).appendingPathComponent(item)
                let gitPath = itemPath.appendingPathComponent(".git")
                guard fm.fileExists(atPath: gitPath.path) else { continue }

                let hasClaudeMD = fm.fileExists(atPath: itemPath.appendingPathComponent("CLAUDE.md").path)
                let commits = CodingAwareness.recentCommits(repo: itemPath, days: 30, limit: 1)

                repos.append(DiscoveredRepo(
                    name: item,
                    path: itemPath,
                    hasClaudeMD: hasClaudeMD,
                    recentCommits: commits.count > 0 ? 1 : 0
                ))
            }
        }

        return repos.sorted { $0.name < $1.name }
    }

    // MARK: - CLAUDE.md Migration

    /// Read a CLAUDE.md file and convert to ORBIT.md content.
    public func migrateCLAUDEmd(at path: URL) -> String? {
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        // Replace CLAUDE.md references with ORBIT.md
        return content
            .replacingOccurrences(of: "CLAUDE.md", with: "ORBIT.md")
            .replacingOccurrences(of: "Claude Code", with: "Orbit")
    }

    // MARK: - Helpers

    private func parseMCPFromJSON(at path: URL, key: String) -> [DiscoveredMCPServer] {
        guard let data = FileManager.default.contents(atPath: path.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json[key] as? [String: [String: Any]] else {
            return []
        }

        return servers.compactMap { name, config -> DiscoveredMCPServer? in
            let command = config["command"] as? String
            let args = config["args"] as? [String] ?? []
            let url = config["url"] as? String
            let env = config["env"] as? [String: String] ?? [:]

            guard command != nil || url != nil else { return nil }

            return DiscoveredMCPServer(
                name: name,
                command: command,
                args: args,
                url: url,
                env: env
            )
        }
    }
}

/// Common starter skill templates.
public struct StarterSkills {
    public static let templates: [(name: String, filename: String, content: String)] = [
        (
            name: "Daily Brief",
            filename: "daily-brief.md",
            content: """
            ---
            description: Daily project briefing with metrics and issues
            triggers: daily brief, morning update, standup
            ---
            # Daily Brief

            1. Summarize today's key metrics and any notable changes
            2. Check for any open critical issues or support tickets
            3. Review recent git activity (last 24h)
            4. Flag anything that needs immediate attention
            5. Suggest top 3 priorities for today
            """
        ),
        (
            name: "SEO Monitor",
            filename: "seo-monitor.md",
            content: """
            ---
            description: Check search rankings and SEO health
            triggers: seo, search ranking, organic traffic
            ---
            # SEO Monitor

            1. Check current search rankings for main keywords
            2. Compare with previous positions
            3. Flag any significant drops (>3 positions)
            4. Review recent organic traffic trends
            5. Suggest any immediate SEO actions needed
            """
        ),
        (
            name: "Support Triage",
            filename: "support-triage.md",
            content: """
            ---
            description: Review and prioritize support tickets
            triggers: support, tickets, triage, customer issues
            ---
            # Support Triage

            1. List all open support tickets by priority
            2. Identify any recurring issues or patterns
            3. Flag tickets that have been open > 48 hours
            4. Suggest responses for common questions
            5. Escalate anything that needs engineering attention
            """
        ),
    ]
}
