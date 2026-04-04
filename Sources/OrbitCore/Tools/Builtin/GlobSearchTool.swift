import Foundation

/// Find files by glob pattern.
public struct GlobSearchTool: Tool, Sendable {
    public let name = "glob_search"
    public let description = "Find files matching a glob pattern in the workspace."
    public let category: ToolCategory = .search
    public let requiredPermission: PermissionMode = .readOnly

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "pattern": .object([
                "type": "string",
                "description": "Glob pattern to match (e.g., '**/*.swift', 'Sources/**/*.swift').",
            ]),
            "path": .object([
                "type": "string",
                "description": "Directory to search in (default: workspace root).",
            ]),
        ]),
        "required": .array(["pattern"]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let pattern = input["pattern"]?.stringValue else {
            return .error("Missing required parameter: 'pattern'")
        }

        let searchDir: String
        if let path = input["path"]?.stringValue {
            searchDir = resolvePath(path, workspace: context.workspaceRoot)
        } else {
            searchDir = context.workspaceRoot.path
        }

        // Use find + fnmatch via shell for glob expansion
        let command: String
        if pattern.contains("**") {
            // Recursive glob — use find
            let filePattern = (pattern as NSString).lastPathComponent
            let dirPattern = (pattern as NSString).deletingLastPathComponent
            let searchPath = dirPattern.isEmpty ? searchDir : "\(searchDir)/\(dirPattern)"
            command = "find \(shellQuote(searchPath)) -name \(shellQuote(filePattern)) -type f 2>/dev/null | sort | head -200"
        } else {
            command = "find \(shellQuote(searchDir)) -path \(shellQuote("\(searchDir)/\(pattern)")) -type f 2>/dev/null | sort | head -200"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output.isEmpty {
            return .success("No files found matching '\(pattern)'")
        }

        // Make paths relative to workspace
        let lines = output.components(separatedBy: "\n")
        let relativePaths = lines.map { line -> String in
            if line.hasPrefix(searchDir) {
                return String(line.dropFirst(searchDir.count + 1))
            }
            return line
        }

        return .success(relativePaths.joined(separator: "\n"))
    }
}
