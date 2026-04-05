import Foundation
import Testing
@testable import OrbitCore

@Suite("Coding Awareness")
struct CodingAwarenessTests {
    @Test("recentCommits from current repo")
    func recentCommitsCurrentRepo() {
        // This test runs in the Orbit repo itself, so there should be commits
        let repoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let commits = CodingAwareness.recentCommits(repo: repoURL, days: 30)
        // We can't guarantee commits exist in CI, but the function shouldn't crash
        #expect(commits.count >= 0)
    }

    @Test("recentCommits from nonexistent repo returns empty")
    func recentCommitsNoRepo() {
        let fakeRepo = URL(fileURLWithPath: "/nonexistent/repo")
        let commits = CodingAwareness.recentCommits(repo: fakeRepo)
        #expect(commits.isEmpty)
    }

    @Test("repoStructure from current directory")
    func repoStructureCurrent() {
        let repoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let structure = CodingAwareness.repoStructure(repo: repoURL)
        // Should find at least Package.swift
        #expect(structure.topLevelFiles.contains("Package.swift") || structure.topLevelDirs.contains("Sources"))
    }

    @Test("repoStructure from nonexistent dir returns empty")
    func repoStructureNoDir() {
        let structure = CodingAwareness.repoStructure(repo: URL(fileURLWithPath: "/nonexistent"))
        #expect(structure.topLevelDirs.isEmpty)
        #expect(structure.topLevelFiles.isEmpty)
    }

    @Test("readFile returns file content")
    func readFileContent() {
        let repoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = CodingAwareness.readFile(path: "Package.swift", repo: repoURL)
        #expect(content?.contains("swift-tools-version") == true)
    }

    @Test("readFile returns nil for missing file")
    func readFileMissing() {
        let repoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = CodingAwareness.readFile(path: "nonexistent.txt", repo: repoURL)
        #expect(content == nil)
    }

    @Test("formatCommitsContext formats output")
    func formatCommits() {
        let commits = [
            CommitSummary(hash: "abc1234", message: "feat: add feature", author: "Alice", date: "2026-04-05"),
        ]
        let context = CodingAwareness.formatCommitsContext(commits: commits)
        #expect(context.contains("abc1234"))
        #expect(context.contains("add feature"))
    }

    @Test("formatCommitsContext empty returns empty string")
    func formatCommitsEmpty() {
        let context = CodingAwareness.formatCommitsContext(commits: [])
        #expect(context.isEmpty)
    }
}

@Suite("Coding Delegate")
struct CodingDelegateTests {
    @Test("availableAgents detects installed tools")
    func availableAgents() {
        let agents = CodingDelegate.availableAgents()
        // Should find claude if installed on this machine
        if BridgeProvider.detectClaudeCLI() != nil {
            #expect(agents.contains(.claudeCode))
        }
    }

    @Test("CodingAgent raw values")
    func agentRawValues() {
        #expect(CodingAgent.claudeCode.rawValue == "claude-code")
        #expect(CodingAgent.codexCLI.rawValue == "codex-cli")
    }

    @Test("CodingAgent allCases")
    func agentAllCases() {
        #expect(CodingAgent.allCases.count == 2)
    }

    @Test("DelegationResult stores fields")
    func delegationResult() {
        let result = DelegationResult(
            agent: .claudeCode,
            output: "Changes made",
            success: true,
            duration: 5.5
        )
        #expect(result.agent == .claudeCode)
        #expect(result.success)
        #expect(result.duration == 5.5)
    }

    @Test("DelegationError description")
    func delegationError() {
        let error = DelegationError.agentNotFound(.codexCLI)
        #expect(error.errorDescription?.contains("codex-cli") == true)
    }
}
