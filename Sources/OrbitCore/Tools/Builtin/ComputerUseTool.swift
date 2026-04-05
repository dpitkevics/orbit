import Foundation

/// Desktop GUI interaction — screenshot, mouse, keyboard control.
/// Uses macOS CoreGraphics and AppleScript for automation.
public struct ComputerUseTool: Tool, Sendable {
    public let name = "computer_use"
    public let description = "Control the desktop — take screenshots, move the mouse, click, and type text. For automating desktop applications."
    public let category: ToolCategory = .desktop
    public let requiredPermission: PermissionMode = .dangerFullAccess

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "action": .object([
                "type": "string",
                "description": "Action: 'screenshot', 'mouse_move', 'mouse_click', 'type_text', 'key_press'.",
            ]),
            "x": .object([
                "type": "integer",
                "description": "X coordinate (for mouse actions).",
            ]),
            "y": .object([
                "type": "integer",
                "description": "Y coordinate (for mouse actions).",
            ]),
            "text": .object([
                "type": "string",
                "description": "Text to type (for 'type_text' action).",
            ]),
            "key": .object([
                "type": "string",
                "description": "Key to press (for 'key_press' action, e.g., 'return', 'tab', 'escape').",
            ]),
            "output_path": .object([
                "type": "string",
                "description": "Screenshot output path (default: /tmp/orbit_screenshot.png).",
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
        case "screenshot":
            let outputPath = input["output_path"]?.stringValue ?? "/tmp/orbit_screenshot.png"
            return takeScreenshot(outputPath: outputPath)

        case "mouse_move":
            guard let x = input["x"]?.intValue, let y = input["y"]?.intValue else {
                return .error("'mouse_move' requires 'x' and 'y' parameters.")
            }
            return moveMouse(x: x, y: y)

        case "mouse_click":
            let x = input["x"]?.intValue
            let y = input["y"]?.intValue
            return mouseClick(x: x, y: y)

        case "type_text":
            guard let text = input["text"]?.stringValue else {
                return .error("'type_text' requires 'text' parameter.")
            }
            return typeText(text)

        case "key_press":
            guard let key = input["key"]?.stringValue else {
                return .error("'key_press' requires 'key' parameter.")
            }
            return keyPress(key)

        default:
            return .error("Unknown action '\(action)'. Use: screenshot, mouse_move, mouse_click, type_text, key_press.")
        }
    }

    // MARK: - Desktop Actions

    private func takeScreenshot(outputPath: String) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", outputPath]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputPath) {
                return .success("Screenshot saved to \(outputPath)")
            }
            return .error("Screenshot failed.")
        } catch {
            return .error("Screenshot failed: \(error.localizedDescription)")
        }
    }

    private func moveMouse(x: Int, y: Int) -> ToolResult {
        let script = """
        tell application "System Events"
            set position of mouse to {\(x), \(y)}
        end tell
        """
        return runAppleScript(script, successMessage: "Mouse moved to (\(x), \(y))")
    }

    private func mouseClick(x: Int?, y: Int?) -> ToolResult {
        var script = ""
        if let x, let y {
            script = """
            do shell script "cliclick m:\(x),\(y) c:."
            """
        } else {
            script = """
            do shell script "cliclick c:."
            """
        }

        // Fallback to AppleScript if cliclick not available
        let fallback = """
        tell application "System Events"
            click at {\(x ?? 0), \(y ?? 0)}
        end tell
        """

        let result = runAppleScript(script, successMessage: "Clicked at (\(x ?? 0), \(y ?? 0))")
        if result.isError {
            return runAppleScript(fallback, successMessage: "Clicked at (\(x ?? 0), \(y ?? 0))")
        }
        return result
    }

    private func typeText(_ text: String) -> ToolResult {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
            keystroke "\(escaped)"
        end tell
        """
        return runAppleScript(script, successMessage: "Typed \(text.count) characters")
    }

    private func keyPress(_ key: String) -> ToolResult {
        let keyCode: String = switch key.lowercased() {
        case "return", "enter": "return"
        case "tab": "tab"
        case "escape", "esc": "escape"
        case "delete", "backspace": "delete"
        case "space": "space"
        case "up": "up arrow"
        case "down": "down arrow"
        case "left": "left arrow"
        case "right": "right arrow"
        default: key
        }

        let simpleScript = """
        tell application "System Events"
            keystroke \"\(keyCode)\"
        end tell
        """

        let result = runAppleScript(simpleScript, successMessage: "Pressed key: \(key)")
        return result
    }

    private func runAppleScript(_ script: String, successMessage: String) -> ToolResult {
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
                return .success(successMessage)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let error = String(data: data, encoding: .utf8) ?? "Unknown error"
            return .error("Action failed: \(error)")
        } catch {
            return .error("Action failed: \(error.localizedDescription)")
        }
    }
}
