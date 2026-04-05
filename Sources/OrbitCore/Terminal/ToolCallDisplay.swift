import Foundation

/// Formats tool calls with box-drawing characters matching Claw Code's style.
public struct ToolCallDisplay: Sendable {

    /// Tool-specific icons.
    public static func icon(for toolName: String) -> String {
        switch toolName {
        case "bash": return "🐚"
        case "file_read": return "📄"
        case "file_write": return "✏️"
        case "file_edit": return "📝"
        case "glob_search", "grep_search": return "🔎"
        case "web_fetch": return "🌐"
        case "web_search": return "🔍"
        case "git_log": return "📊"
        case "agent": return "🤖"
        case "browser": return "🖥"
        case "computer_use": return "🖱"
        case "structured_output": return "📋"
        case "send_notification": return "🔔"
        default:
            if toolName.hasPrefix("mcp__") { return "🔌" }
            return "⚙️"
        }
    }

    /// Format the start of a tool call with box-drawing border.
    public static func formatStart(name: String, input: JSONValue) -> String {
        let toolIcon = icon(for: name)
        let detail = summarizeInput(name: name, input: input)
        let borderLen = max(name.count + 6, detail.count + 4)
        let topBorder = String(repeating: "─", count: borderLen)

        return """
        \(ANSI.darkGray)╭─ \(ANSI.bold)\(ANSI.cyan)\(name)\(ANSI.reset)\(ANSI.darkGray) ─╮\(ANSI.reset)
        \(ANSI.darkGray)│\(ANSI.reset) \(toolIcon) \(detail)
        \(ANSI.darkGray)╰\(topBorder)╯\(ANSI.reset)
        """
    }

    /// Format a successful tool result.
    public static func formatSuccess(name: String, output: String) -> String {
        let summary = truncate(output.trimmingCharacters(in: .whitespacesAndNewlines), maxLen: 160)
        if summary.isEmpty {
            return "\(ANSI.bold)\(ANSI.green)✓\(ANSI.reset) \(ANSI.darkGray)\(name)\(ANSI.reset)"
        }
        return "\(ANSI.bold)\(ANSI.green)✓\(ANSI.reset) \(ANSI.darkGray)\(name)\(ANSI.reset)\n\(summary)"
    }

    /// Format a failed tool result.
    public static func formatFailure(name: String, error: String) -> String {
        let summary = truncate(error.trimmingCharacters(in: .whitespacesAndNewlines), maxLen: 160)
        if summary.isEmpty {
            return "\(ANSI.bold)\(ANSI.red)✗\(ANSI.reset) \(ANSI.darkGray)\(name)\(ANSI.reset)"
        }
        return "\(ANSI.bold)\(ANSI.red)✗\(ANSI.reset) \(ANSI.darkGray)\(name)\(ANSI.reset)\n\(ANSI.fg(203, 100, 100))\(summary)\(ANSI.reset)"
    }

    /// Format a permission denial.
    public static func formatDenied(name: String, reason: String) -> String {
        "\(ANSI.darkGray)⊘\(ANSI.reset) \(name) denied: \(reason)"
    }

    // MARK: - Input Summarization

    private static func summarizeInput(name: String, input: JSONValue) -> String {
        switch name {
        case "bash":
            return input["command"]?.stringValue ?? ""
        case "file_read":
            let path = input["path"]?.stringValue ?? ""
            let offset = input["offset"]?.intValue
            let limit = input["limit"]?.intValue
            var desc = path
            if let offset { desc += " (from line \(offset)" }
            if let limit { desc += desc.contains("(") ? ", \(limit) lines)" : " (\(limit) lines)" }
            else if desc.contains("(") { desc += ")" }
            return desc
        case "file_write":
            let path = input["path"]?.stringValue ?? ""
            let contentLen = input["content"]?.stringValue?.count ?? 0
            return "\(path) (\(contentLen) chars)"
        case "file_edit":
            let path = input["path"]?.stringValue ?? ""
            return path
        case "glob_search":
            return input["pattern"]?.stringValue ?? ""
        case "grep_search":
            return input["pattern"]?.stringValue ?? ""
        case "web_fetch":
            return input["url"]?.stringValue ?? ""
        case "web_search":
            return input["query"]?.stringValue ?? ""
        case "git_log":
            let days = input["days"]?.intValue ?? 7
            return "last \(days) days"
        case "agent":
            return input["task"]?.stringValue ?? ""
        default:
            return ""
        }
    }

    private static func truncate(_ text: String, maxLen: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= maxLen { return singleLine }
        return String(singleLine.prefix(maxLen)) + "..."
    }
}

/// Startup banner matching Claw Code's ASCII art style.
public struct StartupBanner {
    public static func render(
        model: String,
        provider: String,
        permissionMode: String,
        project: String,
        cwd: String,
        sessionID: String,
        mcpCount: Int,
        skillCount: Int
    ) -> String {
        let gitBranch = readGitBranch(cwd: cwd) ?? "n/a"

        return """
        \(ANSI.fg(66, 135, 245))\
         ██████╗ ██████╗ ██████╗ ██╗████████╗
        ██╔═══██╗██╔══██╗██╔══██╗██║╚══██╔══╝
        ██║   ██║██████╔╝██████╔╝██║   ██║
        ██║   ██║██╔══██╗██╔══██╗██║   ██║
        ╚██████╔╝██║  ██║██████╔╝██║   ██║
         ╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚═╝   ╚═╝\(ANSI.reset)

          \(ANSI.dim)Model\(ANSI.reset)            \(model)
          \(ANSI.dim)Provider\(ANSI.reset)         \(provider)
          \(ANSI.dim)Project\(ANSI.reset)          \(project)
          \(ANSI.dim)Branch\(ANSI.reset)           \(gitBranch)
          \(ANSI.dim)Directory\(ANSI.reset)        \(cwd)
          \(ANSI.dim)Session\(ANSI.reset)          \(sessionID.prefix(8))
          \(ANSI.dim)MCP Servers\(ANSI.reset)      \(mcpCount)
          \(ANSI.dim)Skills\(ANSI.reset)           \(skillCount)

          Type \(ANSI.bold)/help\(ANSI.reset) for commands
        """
    }

    private static func readGitBranch(cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["branch", "--show-current"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
