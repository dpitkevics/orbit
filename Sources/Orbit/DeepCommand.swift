import ArgumentParser
import Foundation
import OrbitCore

/// Launch a deep analysis task.
struct Deep: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Launch a deep analysis task."
    )

    @Argument(help: "The analysis prompt.")
    var prompt: String

    @Option(name: .long, help: "Comma-separated project slugs (default: 'default').")
    var projects: String = "default"

    @Option(name: .long, help: "Override the model (default: uses config).")
    var model: String?

    @Option(name: .long, help: "Auth mode: 'apiKey' or 'bridge'.")
    var authMode: String?

    func run() async throws {
        let globalConfig = try ConfigLoader.loadGlobal()
        let projectList = projects.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        let effectiveModel = model ?? globalConfig.defaultModel
        let provider = try resolveProviderForChat(
            providerName: globalConfig.defaultProvider,
            model: effectiveModel,
            authModeOverride: authMode,
            globalConfig: globalConfig
        )

        let task = DeepTask(
            name: "Deep Analysis",
            prompt: prompt,
            projects: projectList,
            model: effectiveModel
        )

        print("Deep task: \(task.name)")
        print("Projects: \(projectList.joined(separator: ", "))")
        print("Model: \(effectiveModel)")
        print("Running...\n")

        let runner = DeepTaskRunner(provider: provider)
        let completed = try await runner.run(task)

        if let result = completed.result {
            print(result)
        }

        print("\n--- Deep Task Complete ---")
        print("Status:   \(completed.status.rawValue)")
        if let usage = completed.usage {
            print("Tokens:   \(usage.totalTokens)")
        }
        if let start = completed.startedAt, let end = completed.completedAt {
            let duration = end.timeIntervalSince(start)
            print("Duration: \(String(format: "%.1f", duration))s")
        }

        try DeepTaskRunner.save(completed)
        print("Saved to: ~/.orbit/deep-tasks/\(completed.id.uuidString)/")
    }
}
