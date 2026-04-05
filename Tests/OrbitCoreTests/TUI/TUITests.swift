import Foundation
import Testing
@testable import OrbitCore

@Suite("Screen Buffer")
struct ScreenBufferTests {
    @Test("Initial buffer is all empty cells")
    func initialState() {
        let buffer = ScreenBuffer(width: 10, height: 5)
        #expect(buffer.width == 10)
        #expect(buffer.height == 5)
        #expect(buffer.get(row: 0, col: 0) == .empty)
    }

    @Test("Set cell marks row dirty")
    func setCellDirty() {
        let buffer = ScreenBuffer(width: 10, height: 5)
        _ = buffer.consumeDirtyRows() // Clear initial dirty
        buffer.set(row: 2, col: 3, character: "X")
        let dirty = buffer.consumeDirtyRows()
        #expect(dirty.contains(2))
        #expect(dirty.count == 1)
    }

    @Test("SetString writes characters")
    func setString() {
        let buffer = ScreenBuffer(width: 20, height: 5)
        buffer.setString(row: 0, col: 0, text: "Hello")
        #expect(buffer.get(row: 0, col: 0).character == "H")
        #expect(buffer.get(row: 0, col: 4).character == "o")
    }

    @Test("ClearRow fills with spaces")
    func clearRow() {
        let buffer = ScreenBuffer(width: 10, height: 5)
        buffer.set(row: 1, col: 3, character: "X")
        buffer.clearRow(1)
        #expect(buffer.get(row: 1, col: 3) == .empty)
    }

    @Test("Out-of-bounds access is safe")
    func outOfBounds() {
        let buffer = ScreenBuffer(width: 5, height: 3)
        buffer.set(row: -1, col: 0, character: "X") // Should not crash
        buffer.set(row: 10, col: 0, character: "X") // Should not crash
        #expect(buffer.get(row: -1, col: 0) == .empty)
        #expect(buffer.get(row: 10, col: 0) == .empty)
    }

    @Test("Resize clears buffer")
    func resize() {
        let buffer = ScreenBuffer(width: 10, height: 5)
        buffer.set(row: 0, col: 0, character: "X")
        buffer.resize(newWidth: 20, newHeight: 10)
        #expect(buffer.width == 20)
        #expect(buffer.height == 10)
        #expect(buffer.get(row: 0, col: 0) == .empty)
    }

    @Test("RenderDirtyRows produces ANSI output")
    func renderDirty() {
        let buffer = ScreenBuffer(width: 10, height: 3)
        _ = buffer.consumeDirtyRows() // Clear initial
        buffer.set(row: 1, col: 0, character: "A")
        let output = buffer.renderDirtyRows()
        #expect(output.contains("A"))
    }

    @Test("MarkAllDirty marks every row")
    func markAllDirty() {
        let buffer = ScreenBuffer(width: 5, height: 3)
        _ = buffer.consumeDirtyRows()
        buffer.markAllDirty()
        let dirty = buffer.consumeDirtyRows()
        #expect(dirty.count == 3)
    }
}

@Suite("Input Parser")
struct InputParserTests {
    let parser = InputParser()

    @Test("Parses Enter key")
    func parseEnter() {
        let result = parser.parse(byte: 13, readMore: { nil })
        if case .key(let event) = result {
            #expect(event.key == .enter)
        }
    }

    @Test("Parses Ctrl+C")
    func parseCtrlC() {
        let result = parser.parse(byte: 3, readMore: { nil })
        if case .key(let event) = result {
            #expect(event.key == .ctrlC)
        }
    }

    @Test("Parses printable character")
    func parsePrintable() {
        let result = parser.parse(byte: 65, readMore: { nil }) // 'A'
        if case .key(let event) = result {
            #expect(event.key == .character("A"))
        }
    }

    @Test("Parses up arrow")
    func parseUpArrow() {
        var bytes: [UInt8] = [91, 65] // [ A
        var index = 0
        let result = parser.parse(byte: 27, readMore: {
            guard index < bytes.count else { return nil }
            let b = bytes[index]; index += 1; return b
        })
        if case .key(let event) = result {
            #expect(event.key == .up)
        }
    }

    @Test("Parses Tab")
    func parseTab() {
        let result = parser.parse(byte: 9, readMore: { nil })
        if case .key(let event) = result {
            #expect(event.key == .tab)
        }
    }

    @Test("Parses Backspace")
    func parseBackspace() {
        let result = parser.parse(byte: 127, readMore: { nil })
        if case .key(let event) = result {
            #expect(event.key == .backspace)
        }
    }

    @Test("Parses Escape alone")
    func parseEscape() {
        let result = parser.parse(byte: 27, readMore: { nil })
        if case .key(let event) = result {
            #expect(event.key == .escape)
        }
    }
}

@Suite("Autocomplete Dropdown")
struct AutocompleteDropdownTests {
    @Test("Shows filtered items")
    func showFiltered() {
        var dropdown = AutocompleteDropdown(commands: [
            SlashCommand(name: "help", description: "Show help") { _, _ in .text("") },
            SlashCommand(name: "status", description: "Show status") { _, _ in .text("") },
            SlashCommand(name: "history", description: "Show history") { _, _ in .text("") },
        ])

        dropdown.show(filter: "/h")
        #expect(dropdown.isVisible)
        #expect(dropdown.filtered.count == 2) // help, history
    }

    @Test("Dismiss hides dropdown")
    func dismiss() {
        var dropdown = AutocompleteDropdown(commands: [
            SlashCommand(name: "help", description: "Help") { _, _ in .text("") },
        ])
        dropdown.show(filter: "/")
        #expect(dropdown.isVisible)
        dropdown.dismiss()
        #expect(!dropdown.isVisible)
    }

    @Test("Navigation wraps selection")
    func navigation() {
        var dropdown = AutocompleteDropdown(commands: [
            SlashCommand(name: "a", description: "") { _, _ in .text("") },
            SlashCommand(name: "b", description: "") { _, _ in .text("") },
            SlashCommand(name: "c", description: "") { _, _ in .text("") },
        ])
        dropdown.show(filter: "/")
        #expect(dropdown.selectedIndex == 0)
        dropdown.moveDown()
        #expect(dropdown.selectedIndex == 1)
        dropdown.moveUp()
        #expect(dropdown.selectedIndex == 0)
        dropdown.moveUp() // Should not go below 0
        #expect(dropdown.selectedIndex == 0)
    }

    @Test("Selected item returns name")
    func selectedItem() {
        var dropdown = AutocompleteDropdown(commands: [
            SlashCommand(name: "help", description: "Help") { _, _ in .text("") },
        ])
        dropdown.show(filter: "/")
        #expect(dropdown.selectedItem() == "/help")
    }

    @Test("Empty filter shows nothing")
    func emptyFilter() {
        var dropdown = AutocompleteDropdown(commands: [
            SlashCommand(name: "help", description: "Help") { _, _ in .text("") },
        ])
        dropdown.show(filter: "x")
        #expect(!dropdown.isVisible)
    }
}

@Suite("ANSI Extensions")
struct ANSIExtensionsTests {
    @Test("Strip ANSI codes")
    func stripCodes() {
        let styled = "\u{1B}[31mRed text\u{1B}[0m"
        #expect(ANSI.stripCodes(styled) == "Red text")
    }

    @Test("Visible width excludes ANSI codes")
    func visibleWidth() {
        let styled = "\u{1B}[1m\u{1B}[36mBold Cyan\u{1B}[0m"
        #expect(ANSI.visibleWidth(styled) == 9) // "Bold Cyan"
    }

    @Test("Plain text visible width")
    func plainWidth() {
        #expect(ANSI.visibleWidth("Hello") == 5)
    }

    @Test("MoveTo generates correct sequence")
    func moveTo() {
        #expect(ANSI.moveTo(row: 5, col: 10) == "\u{1B}[5;10H")
    }
}

@Suite("Header Region")
struct HeaderRegionTests {
    @Test("Header renders into buffer")
    func renderHeader() {
        let buffer = ScreenBuffer(width: 80, height: 5)
        let header = HeaderRegion(
            projectName: "TestProject",
            model: "claude-sonnet-4-6",
            provider: "anthropic",
            sessionID: "abc-12345678"
        )
        header.render(into: buffer, rows: RowRange(start: 0, end: 3), width: 80)

        // Check separator on row 2
        #expect(buffer.get(row: 2, col: 0).character == "─")
    }

    @Test("Header updates usage")
    func updateUsage() {
        var header = HeaderRegion(
            projectName: "Test",
            model: "test",
            provider: "test",
            sessionID: "test"
        )
        let cost = CostEstimate(inputCost: 0.01, outputCost: 0.02, cacheCreationCost: 0, cacheReadCost: 0)
        header.updateUsage(TokenUsage(inputTokens: 100, outputTokens: 50), cost: cost)
        #expect(header.tokenUsage.inputTokens == 100)
    }
}

@Suite("Output Region")
struct OutputRegionTests {
    @Test("Append lines increases count")
    func appendLines() {
        let region = OutputRegion()
        region.appendLine("Hello")
        region.appendLine("World")
        #expect(region.lineCount == 2)
    }

    @Test("Scrolling changes offset")
    func scrolling() {
        let region = OutputRegion()
        for i in 0..<50 {
            region.appendLine("Line \(i)")
        }
        #expect(region.isFollowing)
        region.scrollUp(5)
        #expect(!region.isFollowing)
        region.scrollToBottom()
        #expect(region.isFollowing)
    }

    @Test("Render into buffer")
    func renderIntoBuffer() {
        let buffer = ScreenBuffer(width: 40, height: 10)
        let region = OutputRegion()
        region.appendLine("Test line")
        region.render(into: buffer, rows: RowRange(start: 0, end: 5), width: 40)
        // Should have rendered something
        #expect(buffer.get(row: 0, col: 0).character == "T")
    }
}

@Suite("Input Region")
struct InputRegionTests {
    @Test("Character input appends to buffer")
    func characterInput() {
        let input = InputRegion()
        _ = input.handleKey(KeyEvent(key: .character("H")))
        _ = input.handleKey(KeyEvent(key: .character("i")))
        #expect(input.text == "Hi")
        #expect(input.cursorPos == 2)
    }

    @Test("Backspace deletes character")
    func backspace() {
        let input = InputRegion()
        _ = input.handleKey(KeyEvent(key: .character("A")))
        _ = input.handleKey(KeyEvent(key: .character("B")))
        _ = input.handleKey(KeyEvent(key: .backspace))
        #expect(input.text == "A")
    }

    @Test("Enter submits and clears")
    func submit() {
        let input = InputRegion()
        _ = input.handleKey(KeyEvent(key: .character("H")))
        _ = input.handleKey(KeyEvent(key: .character("i")))
        let action = input.handleKey(KeyEvent(key: .enter))
        if case .submit(let text, _) = action {
            #expect(text == "Hi")
        }
        #expect(input.text == "")
    }

    @Test("Ctrl+C on empty returns eof")
    func ctrlCEmpty() {
        let input = InputRegion()
        let action = input.handleKey(KeyEvent(key: .ctrlC))
        #expect(action == .eof)
    }

    @Test("Slash triggers autocomplete")
    func slashAutocomplete() {
        let input = InputRegion()
        let action = input.handleKey(KeyEvent(key: .character("/")))
        if case .showAutocomplete(let filter) = action {
            #expect(filter == "/")
        }
    }

    @Test("Home moves cursor to start")
    func homeKey() {
        let input = InputRegion()
        _ = input.handleKey(KeyEvent(key: .character("A")))
        _ = input.handleKey(KeyEvent(key: .character("B")))
        _ = input.handleKey(KeyEvent(key: .home))
        #expect(input.cursorPos == 0)
    }
}

// Make InputAction Equatable for testing
extension InputAction: Equatable {
    public static func == (lhs: InputAction, rhs: InputAction) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.cancel, .cancel), (.eof, .eof),
             (.clearScreen, .clearScreen), (.projectSwitcher, .projectSwitcher),
             (.pageUp, .pageUp), (.pageDown, .pageDown),
             (.dismissAutocomplete, .dismissAutocomplete),
             (.selectAutocomplete, .selectAutocomplete):
            return true
        case (.submit(let a, _), .submit(let b, _)):
            return a == b
        case (.scrollUp(let a), .scrollUp(let b)):
            return a == b
        case (.scrollDown(let a), .scrollDown(let b)):
            return a == b
        case (.showAutocomplete(let a), .showAutocomplete(let b)):
            return a == b
        default:
            return false
        }
    }
}
