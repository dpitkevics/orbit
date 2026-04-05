import Foundation

/// Headless browser control for web automation.
/// Uses macOS JavaScript for Automation (JXA) via osascript for basic browser control,
/// and WebKit snapshots for screenshots.
public struct BrowserTool: Tool, Sendable {
    public let name = "browser"
    public let description = "Control a headless browser — navigate to URLs, extract text, take screenshots, click elements. Useful for web scraping and monitoring."
    public let category: ToolCategory = .desktop
    public let requiredPermission: PermissionMode = .dangerFullAccess

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "action": .object([
                "type": "string",
                "description": "Action: 'navigate', 'extract_text', 'screenshot', 'execute_js'.",
            ]),
            "url": .object([
                "type": "string",
                "description": "URL to navigate to (for 'navigate' action).",
            ]),
            "javascript": .object([
                "type": "string",
                "description": "JavaScript to execute (for 'execute_js' action).",
            ]),
            "selector": .object([
                "type": "string",
                "description": "CSS selector to target (for 'extract_text').",
            ]),
            "output_path": .object([
                "type": "string",
                "description": "File path for screenshot output.",
            ]),
        ]),
        "required": .array(["action"]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let action = input["action"]?.stringValue else {
            return .error("Missing required parameter: 'action'")
        }

        switch action {
        case "navigate":
            guard let url = input["url"]?.stringValue else {
                return .error("'navigate' requires 'url' parameter.")
            }
            return await navigateAndExtract(url: url)

        case "extract_text":
            guard let url = input["url"]?.stringValue else {
                return .error("'extract_text' requires 'url' parameter.")
            }
            let selector = input["selector"]?.stringValue
            return await extractText(url: url, selector: selector)

        case "screenshot":
            guard let url = input["url"]?.stringValue else {
                return .error("'screenshot' requires 'url' parameter.")
            }
            let outputPath = input["output_path"]?.stringValue
                ?? context.workspaceRoot.appendingPathComponent("screenshot.png").path
            return await takeScreenshot(url: url, outputPath: outputPath)

        case "execute_js":
            guard let url = input["url"]?.stringValue else {
                return .error("'execute_js' requires 'url' parameter.")
            }
            guard let js = input["javascript"]?.stringValue else {
                return .error("'execute_js' requires 'javascript' parameter.")
            }
            return await executeJavaScript(url: url, script: js)

        default:
            return .error("Unknown action '\(action)'. Use: navigate, extract_text, screenshot, execute_js.")
        }
    }

    // MARK: - Browser Actions

    private func navigateAndExtract(url: String) async -> ToolResult {
        // Use curl + text extraction as a lightweight browser
        let result = await fetchAndExtract(url: url)
        return result
    }

    private func extractText(url: String, selector: String?) async -> ToolResult {
        if let selector {
            // Use JavaScript via osascript to extract specific element
            let js = "document.querySelector('\(selector)')?.innerText || 'Element not found'"
            return await executeJavaScript(url: url, script: js)
        }
        return await fetchAndExtract(url: url)
    }

    private func takeScreenshot(url: String, outputPath: String) async -> ToolResult {
        // Use screencapture with Safari via AppleScript
        let script = """
        tell application "Safari"
            make new document with properties {URL:"\(url)"}
            delay 3
            set bounds of window 1 to {0, 0, 1280, 800}
        end tell
        do shell script "screencapture -l $(osascript -e 'tell app \\"Safari\\" to id of window 1') \(shellQuote(outputPath))"
        tell application "Safari" to close window 1
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return .success("Screenshot saved to \(outputPath)")
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let error = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .error("Screenshot failed: \(error)")
            }
        } catch {
            return .error("Screenshot failed: \(error.localizedDescription)")
        }
    }

    private func executeJavaScript(url: String, script: String) async -> ToolResult {
        let appleScript = """
        tell application "Safari"
            make new document with properties {URL:"\(url)"}
            delay 2
            set jsResult to do JavaScript "\(script.replacingOccurrences(of: "\"", with: "\\\""))" in document 1
            close window 1
            return jsResult
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus == 0 {
                return .success(output)
            } else {
                return .error("JavaScript execution failed: \(output)")
            }
        } catch {
            return .error("Failed to execute JavaScript: \(error.localizedDescription)")
        }
    }

    private func fetchAndExtract(url: String) async -> ToolResult {
        // Lightweight: use curl + HTML stripping
        guard let urlObj = URL(string: url) else {
            return .error("Invalid URL: \(url)")
        }

        var request = URLRequest(url: urlObj)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else {
                return .error("Cannot decode page content.")
            }

            // Strip HTML tags
            guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else {
                return .success(String(html.prefix(50_000)))
            }
            let range = NSRange(html.startIndex..., in: html)
            var text = regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")

            // Collapse whitespace
            if let wsRegex = try? NSRegularExpression(pattern: "\\s{3,}") {
                let textRange = NSRange(text.startIndex..., in: text)
                text = wsRegex.stringByReplacingMatches(in: text, range: textRange, withTemplate: "\n\n")
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 50_000 {
                text = String(text.prefix(50_000)) + "\n... (truncated)"
            }

            return .success(text)
        } catch {
            return .error("Failed to fetch page: \(error.localizedDescription)")
        }
    }
}
