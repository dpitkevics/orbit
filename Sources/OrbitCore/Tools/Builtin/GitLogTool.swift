import Foundation

/// Read git history for a repository.
public struct GitLogTool: Tool, Sendable {
    public let name = "git_log"
    public let description = "Read recent git commit history. Returns commit hashes, messages, authors, and dates."
    public let category: ToolCategory = .fileIO
    public let requiredPermission: PermissionMode = .readOnly

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "path": .object([
                "type": "string",
                "description": "Repository path (default: workspace root).",
            ]),
            "days": .object([
                "type": "integer",
                "description": "Number of days of history (default: 7).",
                "minimum": 1,
            ]),
            "limit": .object([
                "type": "integer",
                "description": "Maximum commits to return (default: 20).",
                "minimum": 1,
            ]),
        ]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        let repoPath: URL
        if let path = input["path"]?.stringValue {
            repoPath = URL(fileURLWithPath: resolvePath(path, workspace: context.workspaceRoot))
        } else {
            repoPath = context.workspaceRoot
        }

        let days = input["days"]?.intValue ?? 7
        let limit = input["limit"]?.intValue ?? 20

        let commits = CodingAwareness.recentCommits(repo: repoPath, days: days, limit: limit)

        if commits.isEmpty {
            return .success("No commits found in the last \(days) days.")
        }

        let lines = commits.map { commit in
            "\(commit.hash.prefix(7)) \(commit.date) \(commit.author): \(commit.message)"
        }

        return .success(lines.joined(separator: "\n"))
    }
}
