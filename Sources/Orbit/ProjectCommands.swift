import ArgumentParser
import Foundation
import OrbitCore

// MARK: - orbit project

struct Project: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage projects.",
        subcommands: [ProjectList.self, ProjectShow.self]
    )
}

struct ProjectList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all configured projects."
    )

    func run() {
        let projects = ConfigLoader.listProjects()
        if projects.isEmpty {
            print("No projects configured.")
            print("Run `orbit init` to set up your first project.")
            return
        }

        print("Projects:\n")
        for slug in projects {
            if let config = try? ConfigLoader.loadProject(slug: slug) {
                let provider = config.provider ?? "default"
                let model = config.model ?? "default"
                print("  \(slug) — \(config.name)")
                if !config.description.isEmpty {
                    print("    \(config.description)")
                }
                print("    provider: \(provider) | model: \(model)")
                if let repo = config.repoPath {
                    print("    repo: \(repo)")
                }
            } else {
                print("  \(slug) (error loading config)")
            }
        }
    }
}

struct ProjectShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show details of a project."
    )

    @Argument(help: "Project slug.")
    var slug: String

    func run() {
        do {
            let config = try ConfigLoader.loadProject(slug: slug)
            print("Project: \(config.name)")
            print("Slug:    \(config.slug)")
            if !config.description.isEmpty {
                print("Desc:    \(config.description)")
            }
            if let repo = config.repoPath {
                print("Repo:    \(repo)")

                let repoURL = URL(fileURLWithPath: (repo as NSString).expandingTildeInPath)
                let commits = CodingAwareness.recentCommits(repo: repoURL, days: 7)
                if !commits.isEmpty {
                    print("\nRecent commits:")
                    for commit in commits.prefix(5) {
                        print("  \(commit.hash.prefix(7)) \(commit.message)")
                    }
                }

                let structure = CodingAwareness.repoStructure(repo: repoURL)
                if structure.totalFiles > 0 {
                    print("\nRepo: \(structure.totalFiles) files")
                    let topLangs = structure.languages.sorted { $0.value > $1.value }.prefix(5)
                    if !topLangs.isEmpty {
                        let langStr = topLangs.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                        print("Languages: \(langStr)")
                    }
                }
            }
            if let provider = config.provider {
                print("Provider: \(provider)")
            }
            if let model = config.model {
                print("Model:    \(model)")
            }
            if !config.contextFiles.isEmpty {
                print("Context:  \(config.contextFiles.joined(separator: ", "))")
            }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - orbit memory

struct Memory: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage project memory.",
        subcommands: [MemorySearch.self, MemoryList.self]
    )
}

struct MemorySearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search memory transcripts."
    )

    @Argument(help: "Project slug.")
    var project: String

    @Argument(help: "Search query.")
    var query: String

    @Option(name: .long, help: "Maximum results (default: 10).")
    var limit: Int = 10

    func run() async throws {
        let store = try SQLiteMemory(path: "~/.orbit/memory.db")
        let results = try await store.searchTranscripts(query: query, project: project, limit: limit)

        if results.isEmpty {
            print("No matches found for '\(query)' in project '\(project)'.")
            return
        }

        print("Found \(results.count) match\(results.count == 1 ? "" : "es"):\n")
        for result in results {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            print("  [\(formatter.string(from: result.timestamp))] Session: \(result.sessionID.prefix(8))")
            print("  \(result.snippet)\n")
        }
    }
}

struct MemoryList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List memory topics."
    )

    @Argument(help: "Project slug.")
    var project: String

    func run() async throws {
        let store = try SQLiteMemory(path: "~/.orbit/memory.db")
        let topics = try await store.listTopics(project: project)

        if topics.isEmpty {
            print("No memory topics for project '\(project)'.")
            return
        }

        print("Memory topics (\(topics.count)):\n")
        for topic in topics {
            print("  \(topic.slug) — \(topic.title)")
        }
    }
}

// MARK: - orbit auth

struct Auth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage authentication.",
        subcommands: [AuthStatus.self, AuthLogin.self]
    )
}

struct AuthLogin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Authenticate via OAuth PKCE (opens browser)."
    )

    @Option(name: .long, help: "OAuth authorize URL.")
    var authorizeUrl: String = "https://console.anthropic.com/oauth/authorize"

    @Option(name: .long, help: "OAuth token exchange URL.")
    var tokenUrl: String = "https://console.anthropic.com/oauth/token"

    @Option(name: .long, help: "OAuth client ID.")
    var clientId: String = "orbit-cli"

    @Option(name: .long, help: "Callback port (default: 9876).")
    var port: Int = 9876

    func run() async throws {
        let manager = OAuthManager()
        print("Starting OAuth PKCE login flow...")

        let tokenSet = try await manager.login(
            authorizeURL: authorizeUrl,
            tokenURL: tokenUrl,
            clientID: clientId,
            scopes: ["read", "write"],
            callbackPort: UInt16(port)
        )

        print("Authenticated successfully!")
        if let expiresAt = tokenSet.expiresAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            print("Token expires: \(formatter.string(from: expiresAt))")
        }
    }
}

struct AuthStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show authentication status."
    )

    func run() {
        print("Authentication status:\n")

        // Check Anthropic
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
            print("  Anthropic: API key set (***\(key.suffix(4)))")
        } else if BridgeProvider.detectClaudeCLI() != nil {
            print("  Anthropic: Bridge mode (claude CLI detected)")
        } else {
            print("  Anthropic: Not configured")
        }

        // Check OpenAI
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] {
            print("  OpenAI:    API key set (***\(key.suffix(4)))")
        } else {
            print("  OpenAI:    Not configured")
        }

        // Check embedding
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil {
            print("  Embeddings: Available (OpenAI text-embedding-3-small)")
        } else {
            print("  Embeddings: Not available (set OPENAI_API_KEY for vector search)")
        }

        print()
        let agents = CodingDelegate.availableAgents()
        if agents.isEmpty {
            print("  Coding agents: None detected")
        } else {
            print("  Coding agents: \(agents.map(\.rawValue).joined(separator: ", "))")
        }
    }
}

// MARK: - orbit status (global overview)

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show overview of all projects."
    )

    func run() {
        let projects = ConfigLoader.listProjects()
        let globalConfig = (try? ConfigLoader.loadGlobal()) ?? OrbitConfig()

        print("Orbit v0.1.0\n")
        print("Provider: \(globalConfig.defaultProvider)")
        print("Model:    \(globalConfig.defaultModel)")
        print("Home:     \(ConfigLoader.orbitHome.path)")
        print()

        if projects.isEmpty {
            print("No projects configured. Run `orbit init` to get started.")
        } else {
            print("Projects (\(projects.count)):")
            for slug in projects {
                print("  - \(slug)")
            }
        }

        let tasks = TaskDefinitionParser.loadAll()
        if !tasks.isEmpty {
            print("\nScheduled tasks (\(tasks.count)):")
            for task in tasks {
                let status = task.enabled ? "enabled" : "disabled"
                print("  - \(task.slug) [\(status)]")
            }
        }
    }
}
