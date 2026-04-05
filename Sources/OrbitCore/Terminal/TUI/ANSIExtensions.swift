import Foundation

/// ANSI extensions for full-screen TUI: alternate screen buffer,
/// scroll regions, and absolute cursor positioning.
extension ANSI {
    // MARK: - Alternate Screen Buffer

    /// Enter alternate screen buffer (saves main screen).
    public static let enterAlternateScreen = "\u{1B}[?1049h"
    /// Exit alternate screen buffer (restores main screen).
    public static let exitAlternateScreen = "\u{1B}[?1049l"

    // MARK: - Cursor Visibility

    /// Hide the cursor.
    public static let hideCursor = "\u{1B}[?25l"
    /// Show the cursor.
    public static let showCursor = "\u{1B}[?25h"

    // MARK: - Absolute Positioning

    /// Move cursor to absolute row and column (1-based).
    public static func moveTo(row: Int, col: Int) -> String {
        "\u{1B}[\(row);\(col)H"
    }

    /// Move cursor to the start of a specific row (1-based).
    public static func moveToRow(_ row: Int) -> String {
        "\u{1B}[\(row);1H"
    }

    // MARK: - Scroll Regions

    /// Set the scrollable region (1-based, inclusive).
    public static func setScrollRegion(top: Int, bottom: Int) -> String {
        "\u{1B}[\(top);\(bottom)r"
    }

    /// Reset scroll region to full screen.
    public static let resetScrollRegion = "\u{1B}[r"

    // MARK: - Screen Clearing

    /// Clear the entire screen.
    public static let clearScreen = "\u{1B}[2J"
    /// Clear from cursor to end of screen.
    public static let clearFromCursor = "\u{1B}[J"
    /// Clear from cursor to end of line.
    public static let clearToEndOfLine = "\u{1B}[K"

    // MARK: - Scrolling

    /// Scroll the scroll region up by N lines.
    public static func scrollUp(_ n: Int = 1) -> String {
        "\u{1B}[\(n)S"
    }

    /// Scroll the scroll region down by N lines.
    public static func scrollDown(_ n: Int = 1) -> String {
        "\u{1B}[\(n)T"
    }

    // MARK: - Bracketed Paste

    /// Enable bracketed paste mode.
    public static let enableBracketedPaste = "\u{1B}[?2004h"
    /// Disable bracketed paste mode.
    public static let disableBracketedPaste = "\u{1B}[?2004l"

    // MARK: - Helpers

    /// Strip all ANSI escape sequences from a string.
    public static func stripCodes(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]") else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    /// Calculate the visible width of a string (excluding ANSI codes).
    public static func visibleWidth(_ text: String) -> Int {
        stripCodes(text).count
    }
}
