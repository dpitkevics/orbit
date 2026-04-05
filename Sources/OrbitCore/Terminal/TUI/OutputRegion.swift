import Foundation

/// Scrollable output area displaying LLM responses, tool calls, and command output.
public class OutputRegion: @unchecked Sendable {
    /// A line in the output buffer.
    public struct OutputLine: Sendable {
        public let text: String      // ANSI-styled
        public let visibleWidth: Int  // Width without ANSI codes

        public init(_ text: String) {
            self.text = text
            self.visibleWidth = ANSI.visibleWidth(text)
        }
    }

    private var lines: [OutputLine] = []
    private var scrollOffset: Int = 0  // 0 = at bottom
    private let maxLines: Int = 10_000
    private let theme: ColorTheme

    public var isFollowing: Bool { scrollOffset == 0 }

    public init(theme: ColorTheme = .default) {
        self.theme = theme
    }

    // MARK: - Content

    /// Append a line of rendered text.
    public func appendLine(_ text: String) {
        lines.append(OutputLine(text))
        trimBuffer()
        if isFollowing { scrollOffset = 0 }
    }

    /// Append multi-line text (splits on newlines).
    public func appendText(_ text: String) {
        for line in text.components(separatedBy: "\n") {
            appendLine(line)
        }
    }

    /// Append a blank line.
    public func appendBlank() {
        appendLine("")
    }

    /// Total line count.
    public var lineCount: Int { lines.count }

    // MARK: - Scrolling

    public func scrollUp(_ count: Int = 1) {
        scrollOffset = min(scrollOffset + count, max(0, lines.count - 1))
    }

    public func scrollDown(_ count: Int = 1) {
        scrollOffset = max(0, scrollOffset - count)
    }

    public func scrollToBottom() {
        scrollOffset = 0
    }

    public func pageUp(visibleHeight: Int) {
        scrollUp(visibleHeight - 1)
    }

    public func pageDown(visibleHeight: Int) {
        scrollDown(visibleHeight - 1)
    }

    // MARK: - Rendering

    /// Render the visible portion into the screen buffer.
    public func render(into buffer: ScreenBuffer, rows: RowRange, width: Int) {
        let visibleHeight = rows.count

        // Clear the region
        buffer.clearRegion(fromRow: rows.start, toRow: rows.end - 1)

        // Calculate which lines are visible
        let totalLines = lines.count
        let bottomIndex = totalLines - scrollOffset
        let topIndex = max(0, bottomIndex - visibleHeight)

        // Word-wrap and render visible lines
        var screenRow = rows.start
        for lineIdx in topIndex..<bottomIndex {
            guard screenRow < rows.end else { break }
            let line = lines[lineIdx]

            // Simple word wrap: split by visible width
            let wrapped = wrapLine(line.text, width: width)
            for wrappedLine in wrapped {
                guard screenRow < rows.end else { break }
                buffer.setStyledString(row: screenRow, col: 0, text: wrappedLine)
                screenRow += 1
            }
        }

        // Show scroll indicator if scrolled up
        if scrollOffset > 0 {
            let indicator = " ── \(scrollOffset) line\(scrollOffset == 1 ? "" : "s") below ──"
            let indicatorRow = rows.end - 1
            buffer.clearRow(indicatorRow)
            let startCol = max(0, (width - ANSI.visibleWidth(indicator)) / 2)
            buffer.setStyledString(row: indicatorRow, col: startCol, text: "\(ANSI.dim)\(indicator)\(ANSI.reset)")
        }
    }

    // MARK: - Word Wrapping

    /// Wrap an ANSI-styled line to fit within the given width.
    private func wrapLine(_ text: String, width: Int) -> [String] {
        let visWidth = ANSI.visibleWidth(text)
        if visWidth <= width { return [text] }

        // Simple wrap: break at width boundaries
        // Track ANSI state across breaks
        var result: [String] = []
        var currentLine = ""
        var currentWidth = 0
        var activeStyle = ""
        var i = text.startIndex

        while i < text.endIndex {
            // Detect ANSI escape sequence
            if text[i] == "\u{1B}" {
                var seqEnd = text.index(after: i)
                if seqEnd < text.endIndex && text[seqEnd] == "[" {
                    seqEnd = text.index(after: seqEnd)
                    while seqEnd < text.endIndex && !text[seqEnd].isLetter {
                        seqEnd = text.index(after: seqEnd)
                    }
                    if seqEnd < text.endIndex {
                        seqEnd = text.index(after: seqEnd)
                        let seq = String(text[i..<seqEnd])
                        currentLine += seq
                        if seq == ANSI.reset {
                            activeStyle = ""
                        } else {
                            activeStyle = seq
                        }
                        i = seqEnd
                        continue
                    }
                }
            }

            // Regular character
            currentWidth += 1
            if currentWidth > width {
                // Wrap: close style, start new line, reopen style
                if !activeStyle.isEmpty { currentLine += ANSI.reset }
                result.append(currentLine)
                currentLine = activeStyle
                currentWidth = 1
            }
            currentLine.append(text[i])
            i = text.index(after: i)
        }

        if !currentLine.isEmpty {
            result.append(currentLine)
        }

        return result.isEmpty ? [""] : result
    }

    private func trimBuffer() {
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}
