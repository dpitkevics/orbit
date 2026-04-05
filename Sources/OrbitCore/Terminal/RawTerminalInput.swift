import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Result of reading a line from the terminal.
public enum InputResult: Sendable {
    /// User submitted text (possibly with attachments).
    case submit(String, attachments: [ContentBlock])
    /// User cancelled current input (Ctrl+C with content).
    case cancel
    /// User wants to exit (Ctrl+D or Ctrl+C on empty line).
    case eof
}

/// Raw terminal input handler with full line editing, history,
/// tab completion, bracketed paste, and clipboard image support.
///
/// This replaces LineNoise with a custom implementation that can
/// detect image paste from the macOS clipboard (like Claude Code).
public final class RawTerminalInput: @unchecked Sendable {
    private var history: [String] = []
    private var historyIndex: Int = 0
    private let historyPath: String?
    private let maxHistory: Int
    private var completions: [String] = []
    private var completionCallback: ((_ buffer: String) -> [String])?

    // Terminal state
    private var origTermios: termios?
    private let theme: ColorTheme

    public init(
        historyPath: String? = nil,
        maxHistory: Int = 500,
        theme: ColorTheme = .default
    ) {
        self.historyPath = historyPath
        self.maxHistory = maxHistory
        self.theme = theme
        loadHistory()
    }

    deinit {
        restoreTerminal()
    }

    /// Set the tab completion callback.
    public func setCompletionCallback(_ callback: @escaping (_ buffer: String) -> [String]) {
        self.completionCallback = callback
    }

    /// Read a line of input with the given prompt.
    public func readLine(prompt: String) -> InputResult {
        var buffer: [Character] = []
        var cursorPos: Int = 0
        var savedLine: String?
        historyIndex = history.count
        var pendingAttachments: [ContentBlock] = []

        enableRawMode()
        defer { restoreTerminal() }

        writePrompt(prompt)

        while true {
            guard let byte = readByte() else {
                return .eof
            }

            switch byte {
            // Enter — submit
            case 13: // CR
                write("\n")
                let text = String(buffer)
                if !text.isEmpty {
                    addHistory(text)
                }
                return .submit(text, attachments: pendingAttachments)

            // Ctrl+C — cancel or exit
            case 3:
                if buffer.isEmpty {
                    write("\n")
                    return .eof
                }
                write("^C\n")
                return .cancel

            // Ctrl+D — exit
            case 4:
                if buffer.isEmpty {
                    write("\n")
                    return .eof
                }
                // Delete char at cursor (like forward delete)
                if cursorPos < buffer.count {
                    buffer.remove(at: cursorPos)
                    refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                }

            // Ctrl+A — home
            case 1:
                cursorPos = 0
                refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)

            // Ctrl+E — end
            case 5:
                cursorPos = buffer.count
                refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)

            // Ctrl+K — kill to end of line
            case 11:
                buffer.removeSubrange(cursorPos...)
                refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)

            // Ctrl+U — kill to start of line
            case 21:
                buffer.removeSubrange(..<cursorPos)
                cursorPos = 0
                refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)

            // Ctrl+W — delete word backward
            case 23:
                while cursorPos > 0 && buffer[cursorPos - 1] == " " {
                    buffer.remove(at: cursorPos - 1)
                    cursorPos -= 1
                }
                while cursorPos > 0 && buffer[cursorPos - 1] != " " {
                    buffer.remove(at: cursorPos - 1)
                    cursorPos -= 1
                }
                refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)

            // Ctrl+L — clear screen
            case 12:
                write("\u{1B}[2J\u{1B}[H")
                refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)

            // Ctrl+J — insert newline (multi-line)
            case 10:
                buffer.insert("\n", at: cursorPos)
                cursorPos += 1
                refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)

            // Tab — completion
            case 9:
                if let callback = completionCallback {
                    let candidates = callback(String(buffer))
                    if candidates.count == 1 {
                        buffer = Array(candidates[0])
                        cursorPos = buffer.count
                        refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                    } else if candidates.count > 1 {
                        write("\n")
                        for c in candidates {
                            write("  \(c)\n")
                        }
                        refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                    }
                }

            // Backspace
            case 127, 8:
                if cursorPos > 0 {
                    buffer.remove(at: cursorPos - 1)
                    cursorPos -= 1
                    refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                }

            // Ctrl+V — paste from clipboard (including images)
            case 22:
                let result = readClipboard()
                if let imageBlock = result.image {
                    pendingAttachments.append(imageBlock)
                    // Show indicator
                    write("\(ANSI.cyan)[image attached]\(ANSI.reset) ")
                }
                if let text = result.text {
                    for ch in text {
                        buffer.insert(ch, at: cursorPos)
                        cursorPos += 1
                    }
                    refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                }

            // Escape sequences (arrows, etc.)
            case 27:
                guard let seq1 = readByte() else { continue }
                if seq1 == 91 { // [
                    guard let seq2 = readByte() else { continue }
                    switch seq2 {
                    // Up arrow — history prev
                    case 65:
                        if historyIndex > 0 {
                            if historyIndex == history.count {
                                savedLine = String(buffer)
                            }
                            historyIndex -= 1
                            buffer = Array(history[historyIndex])
                            cursorPos = buffer.count
                            refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                        }
                    // Down arrow — history next
                    case 66:
                        if historyIndex < history.count {
                            historyIndex += 1
                            if historyIndex == history.count {
                                buffer = Array(savedLine ?? "")
                            } else {
                                buffer = Array(history[historyIndex])
                            }
                            cursorPos = buffer.count
                            refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                        }
                    // Right arrow
                    case 67:
                        if cursorPos < buffer.count {
                            cursorPos += 1
                            refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                        }
                    // Left arrow
                    case 68:
                        if cursorPos > 0 {
                            cursorPos -= 1
                            refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                        }
                    // Home
                    case 72:
                        cursorPos = 0
                        refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                    // End
                    case 70:
                        cursorPos = buffer.count
                        refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                    // Delete
                    case 51:
                        _ = readByte() // consume ~
                        if cursorPos < buffer.count {
                            buffer.remove(at: cursorPos)
                            refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                        }
                    // Bracketed paste start: ESC[200~
                    case 50:
                        if readByte() == 48, readByte() == 48, readByte() == 126 {
                            // Read pasted content until ESC[201~
                            var pasted = ""
                            while true {
                                guard let ch = readByte() else { break }
                                if ch == 27 {
                                    // Check for end of bracketed paste
                                    if readByte() == 91, readByte() == 50, readByte() == 48, readByte() == 49, readByte() == 126 {
                                        break
                                    }
                                }
                                pasted.append(Character(UnicodeScalar(ch)))
                            }
                            for ch in pasted {
                                buffer.insert(ch, at: cursorPos)
                                cursorPos += 1
                            }
                            refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                        }
                    default:
                        break
                    }
                }

            // Regular printable character
            default:
                if byte >= 32 {
                    let scalar = UnicodeScalar(byte)
                    buffer.insert(Character(scalar), at: cursorPos)
                    cursorPos += 1
                    refreshLine(prompt: prompt, buffer: buffer, cursorPos: cursorPos)
                }
            }
        }
    }

    // MARK: - Terminal Raw Mode

    private func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        origTermios = raw

        // Disable canonical mode, echo, signals
        raw.c_lflag &= ~(UInt(ECHO | ICANON | ISIG | IEXTEN))
        raw.c_iflag &= ~(UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP))
        raw.c_oflag &= ~(UInt(OPOST))
        raw.c_cflag |= UInt(CS8)

        // Enable bracketed paste mode
        write("\u{1B}[?2004h")

        // Min bytes = 1, timeout = 0
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 0 // VTIME

        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    private func restoreTerminal() {
        // Disable bracketed paste mode
        write("\u{1B}[?2004l")

        if var orig = origTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
            origTermios = nil
        }
    }

    // MARK: - I/O

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let n = read(STDIN_FILENO, &byte, 1)
        return n == 1 ? byte : nil
    }

    private func write(_ text: String) {
        text.withCString { ptr in
            _ = Darwin.write(STDOUT_FILENO, ptr, strlen(ptr))
        }
    }

    private func writePrompt(_ prompt: String) {
        write(prompt)
    }

    private func refreshLine(prompt: String, buffer: [Character], cursorPos: Int) {
        let text = String(buffer)
        // Move to start of line, clear it, write prompt + buffer, position cursor
        write("\r\(ANSI.clearLine)\(prompt)\(text)")
        // Move cursor to correct position
        let totalLen = prompt.count + buffer.count
        let cursorTarget = prompt.count + cursorPos
        if cursorTarget < totalLen {
            write("\r")
            if cursorTarget > 0 {
                write("\u{1B}[\(cursorTarget)C")
            }
        }
    }

    // MARK: - Clipboard

    private struct ClipboardContent {
        var text: String?
        var image: ContentBlock?
    }

    private func readClipboard() -> ClipboardContent {
        var result = ClipboardContent()

        // Check for image in clipboard first (via osascript)
        if let imageData = readClipboardImage() {
            result.image = imageData
        }

        // Also get text content via pbpaste
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            // If we have an image, don't also paste the text (it's likely a file path or empty)
            if result.image == nil {
                result.text = text
            }
        }

        return result
    }

    private func readClipboardImage() -> ContentBlock? {
        // Use osascript to check if clipboard has image data and export it
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit_clipboard_\(ProcessInfo.processInfo.processIdentifier).png").path

        let script = """
        try
            set imgData to the clipboard as «class PNGf»
            set filePath to POSIX file "\(tempPath)"
            set fileRef to open for access filePath with write permission
            write imgData to fileRef
            close access fileRef
            return "ok"
        on error
            return "no_image"
        end try
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard output == "ok",
              let data = FileManager.default.contents(atPath: tempPath) else {
            return nil
        }

        // Clean up temp file
        try? FileManager.default.removeItem(atPath: tempPath)

        let base64 = data.base64EncodedString()
        return .image(source: .base64(mediaType: "image/png", data: base64))
    }

    // MARK: - History

    public func addHistory(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Remove duplicate if last entry is the same
        if history.last == trimmed { return }
        history.append(trimmed)
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
        saveHistory()
    }

    private func loadHistory() {
        guard let path = historyPath else { return }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        history = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        if history.count > maxHistory {
            history = Array(history.suffix(maxHistory))
        }
    }

    private func saveHistory() {
        guard let path = historyPath else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? history.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
