import Foundation

/// Targeted string replacement in a file.
public struct FileEditTool: Tool, Sendable {
    public let name = "file_edit"
    public let description = "Replace a specific string in a file. The old_string must be unique in the file unless replace_all is true."
    public let category: ToolCategory = .fileIO
    public let requiredPermission: PermissionMode = .workspaceWrite

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "path": .object([
                "type": "string",
                "description": "Absolute or workspace-relative file path.",
            ]),
            "old_string": .object([
                "type": "string",
                "description": "The exact text to find and replace.",
            ]),
            "new_string": .object([
                "type": "string",
                "description": "The replacement text.",
            ]),
            "replace_all": .object([
                "type": "boolean",
                "description": "Replace all occurrences (default: false).",
            ]),
        ]),
        "required": .array(["path", "old_string", "new_string"]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let rawPath = input["path"]?.stringValue else {
            return .error("Missing required parameter: 'path'")
        }
        guard let oldString = input["old_string"]?.stringValue else {
            return .error("Missing required parameter: 'old_string'")
        }
        guard let newString = input["new_string"]?.stringValue else {
            return .error("Missing required parameter: 'new_string'")
        }

        let replaceAll = input["replace_all"]?.boolValue ?? false
        let path = resolvePath(rawPath, workspace: context.workspaceRoot)

        // Check workspace boundaries
        let writeCheck = context.enforcer.checkFileWrite(path: path)
        guard writeCheck.isAllowed else {
            if case .deny(let reason) = writeCheck {
                return .error(reason)
            }
            return .error("Edit denied.")
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return .error("File not found: \(rawPath)")
        }

        guard let data = FileManager.default.contents(atPath: path),
              var content = String(data: data, encoding: .utf8) else {
            return .error("Cannot read file: \(rawPath)")
        }

        guard oldString != newString else {
            return .error("old_string and new_string are identical.")
        }

        let occurrences = content.components(separatedBy: oldString).count - 1

        if occurrences == 0 {
            return .error("old_string not found in file.")
        }

        if !replaceAll && occurrences > 1 {
            return .error("old_string found \(occurrences) times. Use replace_all: true or provide more context to make it unique.")
        }

        if replaceAll {
            content = content.replacingOccurrences(of: oldString, with: newString)
        } else {
            if let range = content.range(of: oldString) {
                content.replaceSubrange(range, with: newString)
            }
        }

        guard let newData = content.data(using: .utf8) else {
            return .error("Cannot encode edited content as UTF-8.")
        }

        try newData.write(to: URL(fileURLWithPath: path))

        let replacedCount = replaceAll ? occurrences : 1
        return .success("Replaced \(replacedCount) occurrence\(replacedCount == 1 ? "" : "s") in \(rawPath)")
    }
}
