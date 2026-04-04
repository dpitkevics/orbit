import Foundation

/// Read the contents of a text file.
public struct FileReadTool: Tool, Sendable {
    public let name = "file_read"
    public let description = "Read a text file from the workspace. Supports offset and line limit."
    public let category: ToolCategory = .fileIO
    public let requiredPermission: PermissionMode = .readOnly

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "path": .object([
                "type": "string",
                "description": "Absolute or workspace-relative file path.",
            ]),
            "offset": .object([
                "type": "integer",
                "description": "Line number to start reading from (0-based).",
                "minimum": 0,
            ]),
            "limit": .object([
                "type": "integer",
                "description": "Maximum number of lines to read.",
                "minimum": 1,
            ]),
        ]),
        "required": .array(["path"]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let rawPath = input["path"]?.stringValue else {
            return .error("Missing required parameter: 'path'")
        }

        let path = resolvePath(rawPath, workspace: context.workspaceRoot)

        guard FileManager.default.fileExists(atPath: path) else {
            return .error("File not found: \(rawPath)")
        }

        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return .error("Cannot read file (binary or encoding issue): \(rawPath)")
        }

        let lines = content.components(separatedBy: "\n")
        let offset = input["offset"]?.intValue ?? 0
        let limit = input["limit"]?.intValue ?? 2000

        let startLine = min(offset, lines.count)
        let endLine = min(startLine + limit, lines.count)
        let selectedLines = lines[startLine..<endLine]

        // Format with line numbers (1-based display)
        let numbered = selectedLines.enumerated().map { index, line in
            "\(startLine + index + 1)\t\(line)"
        }

        var output = numbered.joined(separator: "\n")
        if endLine < lines.count {
            output += "\n... (\(lines.count - endLine) more lines)"
        }

        return .success(output)
    }
}
