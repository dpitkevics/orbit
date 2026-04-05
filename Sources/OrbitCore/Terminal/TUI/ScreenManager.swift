import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// File-private reference for signal handlers.
/// Must be nonisolated(unsafe) because signal handlers need access.
nonisolated(unsafe) private var _activeScreenManager: ScreenManager?

/// Manages the terminal lifecycle: alternate screen buffer, raw mode,
/// signal handlers, and buffered screen rendering.
public final class ScreenManager: @unchecked Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    public let buffer: ScreenBuffer
    private var origTermios: termios?
    private var isActive = false
    private var resizeSource: DispatchSourceSignal?

    /// Callback invoked on terminal resize.
    public var onResize: ((Int, Int) -> Void)?

    public init() {
        self.width = TerminalDetector.width
        self.height = TerminalDetector.height
        self.buffer = ScreenBuffer(width: width, height: height)
    }

    // MARK: - Lifecycle

    /// Activate full-screen TUI mode: raw terminal, alternate screen, hidden cursor.
    public func activate() {
        guard !isActive else { return }

        // Save and configure terminal
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        origTermios = raw

        raw.c_lflag &= ~(UInt(ECHO | ICANON | ISIG | IEXTEN))
        raw.c_iflag &= ~(UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP))
        raw.c_oflag &= ~(UInt(OPOST))
        raw.c_cflag |= UInt(CS8)
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 0 // VTIME

        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        // Enter alternate screen, hide cursor, enable bracketed paste
        writeRaw(ANSI.enterAlternateScreen)
        writeRaw(ANSI.hideCursor)
        writeRaw(ANSI.enableBracketedPaste)
        writeRaw(ANSI.clearScreen)

        isActive = true
        _activeScreenManager = self

        installSignalHandlers()
    }

    /// Deactivate TUI: restore terminal, show cursor, exit alternate screen.
    public func deactivate() {
        guard isActive else { return }

        resizeSource?.cancel()
        resizeSource = nil

        writeRaw(ANSI.showCursor)
        writeRaw(ANSI.disableBracketedPaste)
        writeRaw(ANSI.resetScrollRegion)
        writeRaw(ANSI.exitAlternateScreen)

        if var orig = origTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
            origTermios = nil
        }

        isActive = false
        _activeScreenManager = nil
    }

    // MARK: - Rendering

    /// Flush dirty rows from the buffer to the terminal.
    public func flush() {
        guard buffer.hasDirtyRows else { return }
        let output = buffer.renderDirtyRows()
        if !output.isEmpty {
            writeRaw(output)
        }
    }

    /// Show the cursor at a specific position (1-based).
    public func showCursorAt(row: Int, col: Int) {
        writeRaw(ANSI.moveTo(row: row, col: col))
        writeRaw(ANSI.showCursor)
    }

    /// Hide the cursor.
    public func hideCursor() {
        writeRaw(ANSI.hideCursor)
    }

    /// Force a complete redraw.
    public func fullRedraw() {
        buffer.markAllDirty()
        flush()
    }

    // MARK: - Region Allocation

    /// Compute row ranges for the three regions based on terminal size.
    public func allocateRegions(headerHeight: Int = 3, inputHeight: Int = 2) -> (header: RowRange, output: RowRange, input: RowRange) {
        let header = RowRange(start: 0, end: headerHeight)
        let input = RowRange(start: height - inputHeight, end: height)
        let output = RowRange(start: headerHeight, end: height - inputHeight)
        return (header, output, input)
    }

    // MARK: - Resize

    /// Handle terminal resize.
    public func handleResize() {
        width = TerminalDetector.width
        height = TerminalDetector.height
        buffer.resize(newWidth: width, newHeight: height)
        writeRaw(ANSI.clearScreen)
        onResize?(width, height)
    }

    // MARK: - I/O

    /// Read a single byte from stdin (blocking).
    public func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let n = read(STDIN_FILENO, &byte, 1)
        return n == 1 ? byte : nil
    }

    /// Write raw string to stdout.
    public func writeRaw(_ text: String) {
        text.withCString { ptr in
            _ = Darwin.write(STDOUT_FILENO, ptr, strlen(ptr))
        }
    }

    // MARK: - Signal Handlers

    private func installSignalHandlers() {
        // SIGWINCH via DispatchSource for async-safe resize handling
        signal(SIGWINCH, SIG_IGN) // Ignore default handler
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler { [weak self] in
            self?.handleResize()
        }
        source.resume()
        resizeSource = source

        // SIGINT/SIGTERM — clean exit
        signal(SIGINT) { _ in
            _activeScreenManager?.deactivate()
            exit(0)
        }
        signal(SIGTERM) { _ in
            _activeScreenManager?.deactivate()
            exit(0)
        }
    }
}
