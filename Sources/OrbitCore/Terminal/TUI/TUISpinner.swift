import Foundation

/// Position-aware spinner for TUI regions (doesn't write to stdout directly).
public struct TUISpinner: Sendable {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var frameIndex: Int = 0

    public init() {}

    /// Advance and return the next frame character.
    public mutating func tick() -> String {
        let frame = Self.frames[frameIndex % Self.frames.count]
        frameIndex += 1
        return frame
    }

    /// Reset the spinner.
    public mutating func reset() {
        frameIndex = 0
    }
}
