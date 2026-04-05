import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Detect terminal capabilities and dimensions.
public struct TerminalDetector: Sendable {
    /// Check if stdout is connected to an interactive terminal.
    public static var isInteractive: Bool {
        isatty(STDOUT_FILENO) != 0 && isatty(STDIN_FILENO) != 0
    }

    /// Get the terminal width in columns.
    public static var width: Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
            return Int(ws.ws_col)
        }
        // Fallback: check COLUMNS env
        if let cols = ProcessInfo.processInfo.environment["COLUMNS"],
           let width = Int(cols) {
            return width
        }
        return 80
    }

    /// Get the terminal height in rows.
    public static var height: Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
            return Int(ws.ws_row)
        }
        if let rows = ProcessInfo.processInfo.environment["LINES"],
           let height = Int(rows) {
            return height
        }
        return 24
    }

    /// Check if the terminal supports ANSI colors.
    public static var supportsColor: Bool {
        guard isInteractive else { return false }
        let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
        let colorTerms = ["xterm", "xterm-256color", "screen", "screen-256color",
                          "tmux", "tmux-256color", "rxvt", "linux", "vt100",
                          "xterm-kitty", "alacritty"]
        return colorTerms.contains(where: { term.contains($0) })
            || ProcessInfo.processInfo.environment["COLORTERM"] != nil
    }
}
