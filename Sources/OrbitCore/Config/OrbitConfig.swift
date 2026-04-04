import Foundation
import TOMLKit

/// Global Orbit configuration loaded from ~/.orbit/orbit.toml.
public struct OrbitConfig: Sendable {
    public var defaultProvider: String
    public var defaultModel: String
    public var auth: [String: AuthConfig]
    public var memoryDBPath: String
    public var contextMaxFileChars: Int
    public var contextMaxTotalChars: Int

    public init(
        defaultProvider: String = "anthropic",
        defaultModel: String = "claude-sonnet-4-6",
        auth: [String: AuthConfig] = [:],
        memoryDBPath: String = "~/.orbit/memory.db",
        contextMaxFileChars: Int = 4_000,
        contextMaxTotalChars: Int = 12_000
    ) {
        self.defaultProvider = defaultProvider
        self.defaultModel = defaultModel
        self.auth = auth
        self.memoryDBPath = memoryDBPath
        self.contextMaxFileChars = contextMaxFileChars
        self.contextMaxTotalChars = contextMaxTotalChars
    }
}

/// Project-specific configuration loaded from ~/.orbit/projects/{slug}.toml.
public struct ProjectConfig: Sendable {
    public let name: String
    public let slug: String
    public let description: String
    public let repoPath: String?
    public let provider: String?
    public let model: String?
    public let contextFiles: [String]

    public init(
        name: String,
        slug: String,
        description: String = "",
        repoPath: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        contextFiles: [String] = []
    ) {
        self.name = name
        self.slug = slug
        self.description = description
        self.repoPath = repoPath
        self.provider = provider
        self.model = model
        self.contextFiles = contextFiles
    }

    /// Resolve the effective model, falling back to the global config.
    public func effectiveModel(global: OrbitConfig) -> String {
        model ?? global.defaultModel
    }

    /// Resolve the effective provider, falling back to the global config.
    public func effectiveProvider(global: OrbitConfig) -> String {
        provider ?? global.defaultProvider
    }
}

// MARK: - Config Loading

public enum ConfigError: Error, LocalizedError {
    case fileNotFound(String)
    case parseError(String, underlying: Error)
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Config file not found: \(path)"
        case .parseError(let path, let error):
            return "Failed to parse config at \(path): \(error)"
        case .missingField(let field):
            return "Missing required config field: \(field)"
        }
    }
}

public struct ConfigLoader: Sendable {
    /// Default Orbit config directory.
    public static var orbitHome: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".orbit")
    }

    /// Load global config from ~/.orbit/orbit.toml.
    /// Returns default config if the file doesn't exist yet.
    public static func loadGlobal() throws -> OrbitConfig {
        let path = orbitHome.appendingPathComponent("orbit.toml")

        guard FileManager.default.fileExists(atPath: path.path) else {
            return OrbitConfig()
        }

        let content = try String(contentsOf: path, encoding: .utf8)
        return try parseGlobalConfig(content, path: path.path)
    }

    /// Load a project config from ~/.orbit/projects/{slug}.toml.
    public static func loadProject(slug: String) throws -> ProjectConfig {
        let path = orbitHome
            .appendingPathComponent("projects")
            .appendingPathComponent("\(slug).toml")

        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ConfigError.fileNotFound(path.path)
        }

        let content = try String(contentsOf: path, encoding: .utf8)
        return try parseProjectConfig(content, path: path.path)
    }

    /// List all configured project slugs.
    public static func listProjects() -> [String] {
        let dir = orbitHome.appendingPathComponent("projects")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return files
            .filter { $0.hasSuffix(".toml") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    // MARK: - Parsing

    static func parseGlobalConfig(_ toml: String, path: String) throws -> OrbitConfig {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: toml)
        } catch {
            throw ConfigError.parseError(path, underlying: error)
        }

        let defaults = table["defaults"]?.table
        let provider = defaults?["provider"]?.string ?? "anthropic"
        let model = defaults?["model"]?.string ?? "claude-sonnet-4-6"

        var auth: [String: AuthConfig] = [:]
        if let authTable = table["auth"]?.table {
            for key in authTable.keys {
                if let providerAuth = authTable[key]?.table {
                    let mode = AuthMode(rawValue: providerAuth["mode"]?.string ?? "api_key") ?? .apiKey
                    auth[key] = AuthConfig(
                        mode: mode,
                        apiKeyEnv: providerAuth["api_key_env"]?.string,
                        apiKeyKeychain: providerAuth["api_key_keychain"]?.string,
                        cliPath: providerAuth["cli_path"]?.string,
                        credentialsPath: providerAuth["credentials_path"]?.string
                    )
                }
            }
        }

        let context = table["context"]?.table
        let maxFileChars = context?["max_file_chars"]?.int ?? 4_000
        let maxTotalChars = context?["max_total_chars"]?.int ?? 12_000

        let memory = table["memory"]?.table
        let dbPath = memory?["db_path"]?.string ?? "~/.orbit/memory.db"

        return OrbitConfig(
            defaultProvider: provider,
            defaultModel: model,
            auth: auth,
            memoryDBPath: dbPath,
            contextMaxFileChars: maxFileChars,
            contextMaxTotalChars: maxTotalChars
        )
    }

    static func parseProjectConfig(_ toml: String, path: String) throws -> ProjectConfig {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: toml)
        } catch {
            throw ConfigError.parseError(path, underlying: error)
        }

        let project = table["project"]?.table
        guard let name = project?["name"]?.string else {
            throw ConfigError.missingField("project.name")
        }
        guard let slug = project?["slug"]?.string else {
            throw ConfigError.missingField("project.slug")
        }

        let description = project?["description"]?.string ?? ""
        let repo = project?["repo"]?.string
        let provider = project?["provider"]?.string
        let model = project?["model"]?.string

        var contextFiles: [String] = []
        if let contextTable = table["context"]?.table,
           let files = contextTable["files"]?.array {
            for i in 0..<files.count {
                if let s = files[i]?.string {
                    contextFiles.append(s)
                }
            }
        }

        return ProjectConfig(
            name: name,
            slug: slug,
            description: description,
            repoPath: repo,
            provider: provider,
            model: model,
            contextFiles: contextFiles
        )
    }
}
