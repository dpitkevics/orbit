import Foundation

/// Send a notification to stdout or file.
public struct SendNotificationTool: Tool, Sendable {
    public let name = "send_notification"
    public let description = "Send a notification message. Outputs to stdout or saves to a file."
    public let category: ToolCategory = .network
    public let requiredPermission: PermissionMode = .readOnly

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "message": .object([
                "type": "string",
                "description": "The notification message.",
            ]),
            "channel": .object([
                "type": "string",
                "description": "Output channel: 'stdout' (default) or 'file'.",
            ]),
            "file_path": .object([
                "type": "string",
                "description": "File path to write to (when channel is 'file').",
            ]),
        ]),
        "required": .array(["message"]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let message = input["message"]?.stringValue else {
            return .error("Missing required parameter: 'message'")
        }

        let channel = input["channel"]?.stringValue ?? "stdout"

        switch channel {
        case "file":
            guard let filePath = input["file_path"]?.stringValue else {
                return .error("'file' channel requires 'file_path' parameter.")
            }
            let path = resolvePath(filePath, workspace: context.workspaceRoot)
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let entry = "[\(timestamp)] \(message)\n"

            if FileManager.default.fileExists(atPath: path) {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                handle.seekToEndOfFile()
                handle.write(Data(entry.utf8))
                handle.closeFile()
            } else {
                try entry.write(toFile: path, atomically: true, encoding: .utf8)
            }
            return .success("Notification saved to \(filePath)")

        default: // stdout
            return .success("NOTIFICATION: \(message)")
        }
    }
}
