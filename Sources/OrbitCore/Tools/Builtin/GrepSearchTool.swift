import Foundation

/// Search file contents with regex.
public struct GrepSearchTool: Tool, Sendable {
    public let name = "grep_search"
    public let description = "Search file contents with a regex pattern. Returns matching lines with file paths and line numbers."
    public let category: ToolCategory = .search
    public let requiredPermission: PermissionMode = .readOnly

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "pattern": .object([
                "type": "string",
                "description": "Regular expression pattern to search for.",
            ]),
            "path": .object([
                "type": "string",
                "description": "File or directory to search in (default: workspace root).",
            ]),
            "glob": .object([
                "type": "string",
                "description": "File glob filter (e.g., '*.swift').",
            ]),
            "context": .object([
                "type": "integer",
                "description": "Number of context lines before and after each match.",
                "minimum": 0,
            ]),
            "case_insensitive": .object([
                "type": "boolean",
                "description": "Case-insensitive search (default: false).",
            ]),
            "max_results": .object([
                "type": "integer",
                "description": "Maximum number of matching lines to return (default: 100).",
                "minimum": 1,
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

        let searchPath: String
        if let path = input["path"]?.stringValue {
            searchPath = resolvePath(path, workspace: context.workspaceRoot)
        } else {
            searchPath = context.workspaceRoot.path
        }

        let contextLines = input["context"]?.intValue ?? 0
        let caseInsensitive = input["case_insensitive"]?.boolValue ?? false
        let maxResults = input["max_results"]?.intValue ?? 100
        let globFilter = input["glob"]?.stringValue

        // Build grep command
        var args: [String] = ["grep", "-rn"]

        if caseInsensitive {
            args.append("-i")
        }

        if contextLines > 0 {
            args.append("-C")
            args.append("\(contextLines)")
        }

        if let glob = globFilter {
            args.append("--include=\(glob)")
        }

        // Exclude common non-text directories
        args.append("--exclude-dir=.git")
        args.append("--exclude-dir=.build")
        args.append("--exclude-dir=node_modules")
        args.append("--exclude-dir=.swiftpm")

        args.append("-E")
        args.append(pattern)
        args.append(searchPath)

        let command = args.map { shellQuote($0) }.joined(separator: " ") + " 2>/dev/null | head -\(maxResults)"

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
            return .success("No matches found for '\(pattern)'")
        }

        // Make paths relative to workspace
        let workspacePath = context.workspaceRoot.path
        let result = output.replacingOccurrences(of: workspacePath + "/", with: "")

        return .success(result)
    }
}
