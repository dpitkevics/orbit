import Foundation

/// Action returned from the input region after handling a key.
public enum InputAction: Sendable {
    case none
    case submit(String, [ContentBlock])
    case cancel
    case eof
    case scrollUp(Int)
    case scrollDown(Int)
    case pageUp
    case pageDown
    case showAutocomplete(String)
    case dismissAutocomplete
    case selectAutocomplete
    case clearScreen
    case projectSwitcher
}

/// Text input area at the bottom of the TUI with full line editing.
public class InputRegion: @unchecked Sendable {
    public var buffer: [Character] = []
    public var cursorPos: Int = 0
    public var pendingAttachments: [ContentBlock] = []

    private var history: [String] = []
    private var historyIndex: Int = 0
    private var savedLine: String?
    private let historyPath: String?
    private let maxHistory: Int = 500

    private let theme: ColorTheme

    public init(historyPath: String? = nil, theme: ColorTheme = .default) {
        self.historyPath = historyPath
        self.theme = theme
        loadHistory()
    }

    /// Handle a keyboard event. Returns the action to take.
    public func handleKey(_ event: KeyEvent) -> InputAction {
        switch event.key {
        case .enter:
            let text = String(buffer)
            if !text.isEmpty { addHistory(text) }
            let attachments = pendingAttachments
            buffer.removeAll()
            cursorPos = 0
            pendingAttachments.removeAll()
            return .submit(text, attachments)

        case .ctrlC:
            if buffer.isEmpty { return .eof }
            buffer.removeAll()
            cursorPos = 0
            return .cancel

        case .ctrlD:
            if buffer.isEmpty { return .eof }
            // Forward delete
            if cursorPos < buffer.count {
                buffer.remove(at: cursorPos)
            }
            return .none

        case .ctrlA, .home: cursorPos = 0
        case .ctrlE, .end: cursorPos = buffer.count

        case .ctrlK: // Kill to end
            buffer.removeSubrange(cursorPos...)

        case .ctrlU: // Kill to start
            buffer.removeSubrange(..<cursorPos)
            cursorPos = 0

        case .ctrlW: // Delete word backward
            while cursorPos > 0 && buffer[cursorPos - 1] == " " {
                buffer.remove(at: cursorPos - 1); cursorPos -= 1
            }
            while cursorPos > 0 && buffer[cursorPos - 1] != " " {
                buffer.remove(at: cursorPos - 1); cursorPos -= 1
            }

        case .ctrlJ: // Insert newline
            buffer.insert("\n", at: cursorPos)
            cursorPos += 1

        case .ctrlL: return .clearScreen
        case .ctrlP: return .projectSwitcher
        case .ctrlV: break // Handled by EventLoop
        case .ctrlN: break

        case .backspace:
            if cursorPos > 0 {
                buffer.remove(at: cursorPos - 1)
                cursorPos -= 1
            }

        case .delete:
            if cursorPos < buffer.count {
                buffer.remove(at: cursorPos)
            }

        case .left:
            if event.modifiers.contains(.shift) { return .none }
            if cursorPos > 0 { cursorPos -= 1 }

        case .right:
            if event.modifiers.contains(.shift) { return .none }
            if cursorPos < buffer.count { cursorPos += 1 }

        case .up:
            if event.modifiers.contains(.shift) { return .scrollUp(1) }
            // History prev
            if historyIndex > 0 {
                if historyIndex == history.count { savedLine = String(buffer) }
                historyIndex -= 1
                buffer = Array(history[historyIndex])
                cursorPos = buffer.count
            }

        case .down:
            if event.modifiers.contains(.shift) { return .scrollDown(1) }
            // History next
            if historyIndex < history.count {
                historyIndex += 1
                if historyIndex == history.count {
                    buffer = Array(savedLine ?? "")
                } else {
                    buffer = Array(history[historyIndex])
                }
                cursorPos = buffer.count
            }

        case .pageUp: return .pageUp
        case .pageDown: return .pageDown

        case .tab:
            let text = String(buffer)
            if text.hasPrefix("/") {
                return .selectAutocomplete
            }

        case .escape:
            return .dismissAutocomplete

        case .character(let ch):
            buffer.insert(ch, at: cursorPos)
            cursorPos += 1

            // Check for autocomplete trigger
            let text = String(buffer)
            if text.hasPrefix("/") {
                return .showAutocomplete(text)
            }

        default: break
        }

        // Check if we should update autocomplete
        let text = String(buffer)
        if text.hasPrefix("/") {
            return .showAutocomplete(text)
        }

        return .none
    }

    /// Handle pasted text.
    public func handlePaste(_ text: String) {
        for ch in text {
            buffer.insert(ch, at: cursorPos)
            cursorPos += 1
        }
    }

    /// Handle pasted image.
    public func handlePasteImage(_ block: ContentBlock) {
        pendingAttachments.append(block)
    }

    /// Current input text.
    public var text: String { String(buffer) }

    // MARK: - Rendering

    /// Render the input area into the screen buffer.
    public func render(into screenBuffer: ScreenBuffer, rows: RowRange, width: Int) {
        // Row 0: Separator
        let sepRow = rows.start
        screenBuffer.clearRow(sepRow)
        for col in 0..<width {
            screenBuffer.set(row: sepRow, col: col, character: "─", style: ANSI.darkGray)
        }

        // Row 1: Input with prompt
        let inputRow = rows.start + 1
        screenBuffer.clearRow(inputRow)

        let prompt = "> "
        screenBuffer.setStyledString(row: inputRow, col: 0, text: "\(ANSI.green)\(prompt)\(ANSI.reset)")

        // Show attachment indicators
        var col = prompt.count
        for attachment in pendingAttachments {
            let indicator: String
            switch attachment {
            case .image: indicator = "\(ANSI.cyan)[image]\(ANSI.reset) "
            case .document(let name, _, _): indicator = "\(ANSI.cyan)[\(name)]\(ANSI.reset) "
            default: continue
            }
            screenBuffer.setStyledString(row: inputRow, col: col, text: indicator)
            col += ANSI.visibleWidth(indicator)
        }

        // Input text
        let inputText = String(buffer)
        screenBuffer.setString(row: inputRow, col: col, text: inputText)
    }

    /// Get the absolute cursor column position for the screen.
    public func cursorColumn() -> Int {
        let prompt = "> "
        var col = prompt.count
        for attachment in pendingAttachments {
            switch attachment {
            case .image: col += 8 // [image] + space
            case .document(let name, _, _): col += name.count + 3 // [name] + space
            default: break
            }
        }
        return col + cursorPos + 1 // 1-based for ANSI
    }

    // MARK: - History

    public func addHistory(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if history.last == trimmed { return }
        history.append(trimmed)
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
        historyIndex = history.count
        saveHistory()
    }

    public func resetHistoryIndex() {
        historyIndex = history.count
        savedLine = nil
    }

    private func loadHistory() {
        guard let path = historyPath else { return }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        history = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        if history.count > maxHistory { history = Array(history.suffix(maxHistory)) }
        historyIndex = history.count
    }

    private func saveHistory() {
        guard let path = historyPath else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? history.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
