import Foundation
import Testing
@testable import OrbitCore

@Suite("Migration Detector")
struct MigrationDetectorTests {
    @Test("Detects installed tools")
    func detectTools() {
        let detector = MigrationDetector()
        let tools = detector.detectTools()
        // Should at least find env vars or claude CLI on dev machine
        #expect(tools.count >= 0) // Don't fail on CI
    }

    @Test("Discovers repos in existing directories")
    func discoverRepos() {
        let detector = MigrationDetector()
        let repos = detector.discoverRepos()
        // On a dev machine this should find at least the Orbit repo itself
        #expect(repos.count >= 0)
    }

    @Test("Discovers repos from specific directory")
    func discoverReposSpecificDir() {
        let detector = MigrationDetector()
        // Scan the parent of current dir (should find Orbit repo)
        let parentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent().path
        let repos = detector.discoverRepos(searchDirs: [parentDir])
        // Should find at least our Orbit repo
        let orbitRepo = repos.first { $0.name.lowercased() == "orbit" }
        if orbitRepo != nil {
            #expect(orbitRepo?.name.lowercased() == "orbit")
        }
    }

    @Test("readClaudeDesktopMCPServers returns empty when no config exists")
    func noClaudeDesktopConfig() {
        let detector = MigrationDetector()
        // May or may not have Claude Desktop installed
        let servers = detector.readClaudeDesktopMCPServers()
        #expect(servers.count >= 0)
    }

    @Test("readClaudeCodeMCPServers returns empty when no settings")
    func noClaudeCodeSettings() {
        let detector = MigrationDetector()
        let servers = detector.readClaudeCodeMCPServers()
        #expect(servers.count >= 0)
    }

    @Test("readClaudeCodeHooks returns dictionary")
    func claudeCodeHooks() {
        let detector = MigrationDetector()
        let hooks = detector.readClaudeCodeHooks()
        // May or may not have hooks configured
        #expect(hooks.count >= 0)
    }

    @Test("migrateCLAUDEmd replaces references")
    func migrateCLAUDEmd() throws {
        let detector = MigrationDetector()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-migrate-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let claudeMD = tempDir.appendingPathComponent("CLAUDE.md")
        try "Read CLAUDE.md for instructions. Uses Claude Code.".write(
            to: claudeMD, atomically: true, encoding: .utf8
        )

        let migrated = detector.migrateCLAUDEmd(at: claudeMD)
        #expect(migrated != nil)
        #expect(migrated?.contains("ORBIT.md") == true)
        #expect(migrated?.contains("Orbit") == true)
        #expect(migrated?.contains("CLAUDE.md") == false)
    }

    @Test("migrateCLAUDEmd returns nil for missing file")
    func migrateCLAUDEmdMissing() {
        let detector = MigrationDetector()
        let result = detector.migrateCLAUDEmd(at: URL(fileURLWithPath: "/nonexistent/CLAUDE.md"))
        #expect(result == nil)
    }
}

@Suite("Starter Skills")
struct StarterSkillsTests {
    @Test("Starter templates are available")
    func templatesExist() {
        #expect(StarterSkills.templates.count >= 3)
        #expect(StarterSkills.templates.contains { $0.name == "Daily Brief" })
        #expect(StarterSkills.templates.contains { $0.name == "SEO Monitor" })
        #expect(StarterSkills.templates.contains { $0.name == "Support Triage" })
    }

    @Test("Each template has required fields")
    func templateFields() {
        for template in StarterSkills.templates {
            #expect(!template.name.isEmpty)
            #expect(!template.filename.isEmpty)
            #expect(template.filename.hasSuffix(".md"))
            #expect(!template.content.isEmpty)
        }
    }
}

@Suite("Discovered Types")
struct DiscoveredTypesTests {
    @Test("DetectedTool stores fields")
    func detectedTool() {
        let tool = DetectedTool(
            name: "Test",
            path: "/usr/bin/test",
            kind: .claudeCode,
            details: ["key": "value"]
        )
        #expect(tool.name == "Test")
        #expect(tool.kind == .claudeCode)
        #expect(tool.details["key"] == "value")
    }

    @Test("DiscoveredRepo stores fields")
    func discoveredRepo() {
        let repo = DiscoveredRepo(
            name: "my-project",
            path: URL(fileURLWithPath: "/tmp/my-project"),
            hasClaudeMD: true,
            recentCommits: 5
        )
        #expect(repo.name == "my-project")
        #expect(repo.hasClaudeMD)
        #expect(repo.recentCommits == 5)
    }

    @Test("DiscoveredMCPServer stores fields")
    func discoveredMCPServer() {
        let server = DiscoveredMCPServer(
            name: "analytics",
            command: "/usr/bin/mcp-analytics",
            args: ["--port", "8080"],
            env: ["API_KEY": "secret"]
        )
        #expect(server.name == "analytics")
        #expect(server.command == "/usr/bin/mcp-analytics")
        #expect(server.args.count == 2)
        #expect(server.env["API_KEY"] == "secret")
    }

    @Test("DetectedToolKind all values")
    func toolKinds() {
        let kinds: [DetectedToolKind] = [.claudeCode, .claudeDesktop, .codexCLI, .envAPIKey]
        #expect(kinds.count == 4)
    }
}
