import Foundation

/// Animated braille spinner for terminal status updates.
///
/// Uses cursor save/restore to update in-place without scrolling.
/// Matching Claw Code's spinner pattern from `render.rs`.
public struct Spinner: Sendable {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var frameIndex: Int = 0
    private let theme: ColorTheme

    public init(theme: ColorTheme = .default) {
        self.theme = theme
    }

    /// Render the next spinner frame with a label. Overwrites current line.
    public mutating func tick(label: String) {
        let frame = Self.frames[frameIndex % Self.frames.count]
        frameIndex += 1
        let line = "\(ANSI.moveToColumn0)\(ANSI.clearLine)\(theme.spinnerActive)\(frame)\(ANSI.reset) \(label)"
        print(line, terminator: "")
        fflush(stdout)
    }

    /// Finish the spinner with a success indicator.
    public func finish(label: String) {
        let line = "\(ANSI.moveToColumn0)\(ANSI.clearLine)\(theme.spinnerDone)✓\(ANSI.reset) \(label)"
        print(line)
        fflush(stdout)
    }

    /// Finish the spinner with a failure indicator.
    public func fail(label: String) {
        let line = "\(ANSI.moveToColumn0)\(ANSI.clearLine)\(theme.spinnerFailed)✗\(ANSI.reset) \(label)"
        print(line)
        fflush(stdout)
    }

    /// Finish the spinner with a skip/cancel indicator.
    public func skip(label: String) {
        let line = "\(ANSI.moveToColumn0)\(ANSI.clearLine)\(ANSI.darkGray)⊘\(ANSI.reset) \(label)"
        print(line)
        fflush(stdout)
    }
}
