import Foundation

/// External coding agents Orbit can delegate to.
public enum CodingAgent: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codexCLI = "codex-cli"
}

/// Result from delegating a coding task.
public struct DelegationResult: Sendable {
    public let agent: CodingAgent
    public let output: String
    public let success: Bool
    public let duration: TimeInterval

    public init(agent: CodingAgent, output: String, success: Bool, duration: TimeInterval) {
        self.agent = agent
        self.output = output
        self.success = success
        self.duration = duration
    }
}

/// Delegates coding tasks to external agents (Claude Code, Codex CLI).
///
/// Orbit doesn't try to be a coding agent — it orchestrates and delegates.
public struct CodingDelegate: Sendable {

    /// Detect which coding agents are available on this system.
    public static func availableAgents() -> [CodingAgent] {
        var agents: [CodingAgent] = []

        if BridgeProvider.detectClaudeCLI() != nil {
            agents.append(.claudeCode)
        }

        if detectCodexCLI() != nil {
            agents.append(.codexCLI)
        }

        return agents
    }

    /// Delegate a coding task to an external agent.
    public static func delegate(
        task: String,
        repo: URL,
        agent: CodingAgent,
        branch: String? = nil
    ) async throws -> DelegationResult {
        let startTime = Date()

        let cliPath: String
        switch agent {
        case .claudeCode:
            guard let path = BridgeProvider.detectClaudeCLI() else {
                throw DelegationError.agentNotFound(agent)
            }
            cliPath = path
        case .codexCLI:
            guard let path = detectCodexCLI() else {
                throw DelegationError.agentNotFound(agent)
            }
            cliPath = path
        }

        // Optionally create and switch to branch
        if let branch {
            let gitProcess = Process()
            gitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            gitProcess.arguments = ["checkout", "-b", branch]
            gitProcess.currentDirectoryURL = repo
            gitProcess.standardOutput = FileHandle.nullDevice
            gitProcess.standardError = FileHandle.nullDevice
            try? gitProcess.run()
            gitProcess.waitUntilExit()
        }

        // Run the coding agent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.currentDirectoryURL = repo

        switch agent {
        case .claudeCode:
            process.arguments = ["--print", "--output-format", "json", task]
        case .codexCLI:
            process.arguments = ["--quiet", task]
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        let success = process.terminationStatus == 0
        let duration = Date().timeIntervalSince(startTime)

        return DelegationResult(
            agent: agent,
            output: output,
            success: success,
            duration: duration
        )
    }

    private static func detectCodexCLI() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.local/bin/codex" },
            Optional("/usr/local/bin/codex"),
            Optional("/opt/homebrew/bin/codex"),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

public enum DelegationError: Error, LocalizedError {
    case agentNotFound(CodingAgent)

    public var errorDescription: String? {
        switch self {
        case .agentNotFound(let agent):
            return "Coding agent '\(agent.rawValue)' not found. Please install it."
        }
    }
}
