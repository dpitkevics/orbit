import Foundation

/// A single character cell in the screen buffer.
public struct Cell: Equatable, Sendable {
    public var character: Character
    public var style: String // ANSI style prefix (empty for default)

    public init(character: Character = " ", style: String = "") {
        self.character = character
        self.style = style
    }

    public static let empty = Cell()
}

/// Double-buffered character cell grid for efficient differential rendering.
///
/// Maintains a front buffer (what's displayed) and supports dirty row tracking.
/// The `diff` method returns only changed cells, allowing minimal ANSI output.
public class ScreenBuffer: @unchecked Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    private var cells: [[Cell]]
    private var dirtyRows: Set<Int>

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.cells = Array(repeating: Array(repeating: Cell.empty, count: width), count: height)
        self.dirtyRows = Set(0..<height)
    }

    // MARK: - Cell Operations

    /// Set a single cell. Marks the row dirty.
    public func set(row: Int, col: Int, character: Character, style: String = "") {
        guard row >= 0, row < height, col >= 0, col < width else { return }
        let cell = Cell(character: character, style: style)
        if cells[row][col] != cell {
            cells[row][col] = cell
            dirtyRows.insert(row)
        }
    }

    /// Write a styled string at a position. Handles ANSI codes by applying them as cell styles.
    public func setString(row: Int, col: Int, text: String, style: String = "") {
        var c = col
        let stripped = ANSI.stripCodes(text)
        for char in stripped {
            guard c < width else { break }
            set(row: row, col: c, character: char, style: style)
            c += 1
        }
    }

    /// Write a raw ANSI-styled string at a position, preserving inline styles.
    public func setStyledString(row: Int, col: Int, text: String) {
        var c = col
        var currentStyle = ""

        var i = text.startIndex
        while i < text.endIndex {
            // Check for ANSI escape sequence
            if text[i] == "\u{1B}", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "[" {
                // Read the full escape sequence
                var seqEnd = text.index(i, offsetBy: 2)
                while seqEnd < text.endIndex && !text[seqEnd].isLetter {
                    seqEnd = text.index(after: seqEnd)
                }
                if seqEnd < text.endIndex {
                    seqEnd = text.index(after: seqEnd) // include the letter
                    let seq = String(text[i..<seqEnd])
                    if seq == ANSI.reset {
                        currentStyle = ""
                    } else {
                        currentStyle = seq
                    }
                    i = seqEnd
                    continue
                }
            }

            if text[i] != "\n" {
                guard c < width else { break }
                set(row: row, col: c, character: text[i], style: currentStyle)
                c += 1
            }
            i = text.index(after: i)
        }
    }

    /// Clear a row (fill with spaces).
    public func clearRow(_ row: Int) {
        guard row >= 0, row < height else { return }
        for col in 0..<width {
            cells[row][col] = .empty
        }
        dirtyRows.insert(row)
    }

    /// Clear a range of rows.
    public func clearRegion(fromRow: Int, toRow: Int) {
        for row in fromRow...min(toRow, height - 1) {
            clearRow(row)
        }
    }

    /// Get cell at position.
    public func get(row: Int, col: Int) -> Cell {
        guard row >= 0, row < height, col >= 0, col < width else { return .empty }
        return cells[row][col]
    }

    // MARK: - Dirty Tracking

    /// Get all dirty rows and reset the dirty set.
    public func consumeDirtyRows() -> Set<Int> {
        let dirty = dirtyRows
        dirtyRows.removeAll()
        return dirty
    }

    /// Mark all rows as dirty (for full redraw).
    public func markAllDirty() {
        dirtyRows = Set(0..<height)
    }

    /// Check if any rows are dirty.
    public var hasDirtyRows: Bool { !dirtyRows.isEmpty }

    // MARK: - Rendering

    /// Generate the ANSI string to render all dirty rows.
    public func renderDirtyRows() -> String {
        let dirty = consumeDirtyRows()
        guard !dirty.isEmpty else { return "" }

        var output = ""
        for row in dirty.sorted() {
            output += ANSI.moveTo(row: row + 1, col: 1) // 1-based
            output += ANSI.clearLine

            var lastStyle = ""
            for col in 0..<width {
                let cell = cells[row][col]
                if cell.style != lastStyle {
                    if !lastStyle.isEmpty { output += ANSI.reset }
                    output += cell.style
                    lastStyle = cell.style
                }
                output.append(cell.character)
            }
            if !lastStyle.isEmpty { output += ANSI.reset }
        }

        return output
    }

    // MARK: - Resize

    /// Resize the buffer, clearing content.
    public func resize(newWidth: Int, newHeight: Int) {
        width = newWidth
        height = newHeight
        cells = Array(repeating: Array(repeating: Cell.empty, count: newWidth), count: newHeight)
        dirtyRows = Set(0..<newHeight)
    }
}

/// A range of rows in the screen.
public struct RowRange: Sendable {
    public let start: Int
    public let end: Int // exclusive

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var count: Int { end - start }
}
