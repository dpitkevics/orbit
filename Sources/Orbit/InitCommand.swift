import ArgumentParser
import Foundation
import OrbitCore

/// Interactive setup wizard for first-time Orbit configuration.
struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Initialize Orbit configuration."
    )

    func run() {
        print("Welcome to Orbit! Let's set up your configuration.\n")

        let orbitHome = ConfigLoader.orbitHome

        // Create directory structure
        let dirs = ["projects", "schedules", "skills/_global", "sessions", "logs/daily", "logs/tasks"]
        for dir in dirs {
            let path = orbitHome.appendingPathComponent(dir)
            try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }

        // Check for existing config
        let configPath = orbitHome.appendingPathComponent("orbit.toml")
        if FileManager.default.fileExists(atPath: configPath.path) {
            print("Config already exists at \(configPath.path)")
            print("Skipping config creation.\n")
        } else {
            createGlobalConfig(at: configPath)
        }

        // Detect available tools
        print("Detecting available tools...")
        if BridgeProvider.detectClaudeCLI() != nil {
            print("  ✓ Claude Code CLI detected")
        } else {
            print("  ○ Claude Code CLI not found")
        }

        let agents = CodingDelegate.availableAgents()
        if !agents.isEmpty {
            print("  ✓ Coding agents: \(agents.map(\.rawValue).joined(separator: ", "))")
        }
        print()

        // Offer to create first project
        print("Would you like to create your first project? [y/N] ", terminator: "")
        fflush(stdout)
        if let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" {
            createFirstProject(at: orbitHome)
        }

        print("\nOrbit is ready! Run `orbit` to start chatting.")
        print("Config: \(orbitHome.path)")
    }

    private func createGlobalConfig(at path: URL) {
        // Detect auth mode
        let hasClaude = BridgeProvider.detectClaudeCLI() != nil
        let hasAPIKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil

        let authMode: String
        let authConfig: String
        if hasAPIKey {
            authMode = "api_key"
            authConfig = """
            [auth.anthropic]
            mode = "api_key"
            api_key_env = "ANTHROPIC_API_KEY"
            """
        } else if hasClaude {
            authMode = "bridge"
            authConfig = """
            [auth.anthropic]
            mode = "bridge"
            # cli_path auto-detected
            """
        } else {
            authMode = "api_key"
            authConfig = """
            [auth.anthropic]
            mode = "api_key"
            api_key_env = "ANTHROPIC_API_KEY"
            """
        }

        let config = """
        # Orbit Configuration
        # See ORBIT_PROJECT_SPEC.md for all options.

        [defaults]
        provider = "anthropic"
        model = "claude-sonnet-4-6"

        \(authConfig)

        [memory]
        db_path = "~/.orbit/memory.db"

        [context]
        max_file_chars = 4000
        max_total_chars = 12000

        [daemon]
        enabled = false
        tick_interval = 300
        """

        try? config.write(to: path, atomically: true, encoding: .utf8)
        print("Created config at \(path.path) (auth: \(authMode))\n")
    }

    private func createFirstProject(at orbitHome: URL) {
        print("\nProject name: ", terminator: "")
        fflush(stdout)
        guard let name = readLine()?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            print("Skipped.")
            return
        }

        let slug = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        print("Repository path (optional): ", terminator: "")
        fflush(stdout)
        let repo = readLine()?.trimmingCharacters(in: .whitespaces)

        print("Description (optional): ", terminator: "")
        fflush(stdout)
        let description = readLine()?.trimmingCharacters(in: .whitespaces)

        var toml = """
        [project]
        name = "\(name)"
        slug = "\(slug)"
        """

        if let desc = description, !desc.isEmpty {
            toml += "\ndescription = \"\(desc)\""
        }
        if let repo, !repo.isEmpty {
            toml += "\nrepo = \"\(repo)\""
        }

        let projectPath = orbitHome
            .appendingPathComponent("projects")
            .appendingPathComponent("\(slug).toml")
        try? toml.write(to: projectPath, atomically: true, encoding: .utf8)
        print("Created project '\(slug)' at \(projectPath.path)")

        // Create skills directory
        let skillsDir = orbitHome.appendingPathComponent("skills/\(slug)")
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
    }
}
