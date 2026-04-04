import Foundation

/// Execute shell commands in the workspace.
public struct BashTool: Tool, Sendable {
    public let name = "bash"
    public let description = "Execute a shell command in the workspace. Returns stdout and stderr."
    public let category: ToolCategory = .execution
    public let requiredPermission: PermissionMode = .dangerFullAccess

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "command": .object([
                "type": "string",
                "description": "The shell command to execute.",
            ]),
            "timeout": .object([
                "type": "integer",
                "description": "Timeout in seconds (default: 120).",
                "minimum": 1,
            ]),
        ]),
        "required": .array(["command"]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let command = input["command"]?.stringValue else {
            return .error("Missing required parameter: 'command'")
        }

        let timeoutSeconds = input["timeout"]?.intValue ?? 120

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = context.workspaceRoot

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set up environment
        var env = ProcessInfo.processInfo.environment
        env["PWD"] = context.workspaceRoot.path
        process.environment = env

        try process.run()

        // Timeout handling
        let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: timeoutWorkItem)

        process.waitUntilExit()
        timeoutWorkItem.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        let exitCode = process.terminationStatus

        var output = ""
        if !stdout.isEmpty {
            output += stdout
        }
        if !stderr.isEmpty {
            if !output.isEmpty { output += "\n" }
            output += "STDERR: \(stderr)"
        }
        if output.isEmpty {
            output = "(no output)"
        }

        if exitCode != 0 {
            return .error("Exit code \(exitCode)\n\(output)")
        }

        return .success(output)
    }
}
