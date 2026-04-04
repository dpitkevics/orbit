import Foundation

/// Write or overwrite a file.
public struct FileWriteTool: Tool, Sendable {
    public let name = "file_write"
    public let description = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does."
    public let category: ToolCategory = .fileIO
    public let requiredPermission: PermissionMode = .workspaceWrite

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "path": .object([
                "type": "string",
                "description": "Absolute or workspace-relative file path.",
            ]),
            "content": .object([
                "type": "string",
                "description": "The content to write to the file.",
            ]),
        ]),
        "required": .array(["path", "content"]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let rawPath = input["path"]?.stringValue else {
            return .error("Missing required parameter: 'path'")
        }
        guard let content = input["content"]?.stringValue else {
            return .error("Missing required parameter: 'content'")
        }

        let path = resolvePath(rawPath, workspace: context.workspaceRoot)

        // Check workspace boundaries
        let writeCheck = context.enforcer.checkFileWrite(path: path)
        guard writeCheck.isAllowed else {
            if case .deny(let reason) = writeCheck {
                return .error(reason)
            }
            return .error("Write denied.")
        }

        // Create parent directory if needed
        let parentDir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )

        guard let data = content.data(using: .utf8) else {
            return .error("Cannot encode content as UTF-8.")
        }

        try data.write(to: URL(fileURLWithPath: path))

        let lineCount = content.components(separatedBy: "\n").count
        return .success("Wrote \(data.count) bytes (\(lineCount) lines) to \(rawPath)")
    }
}
