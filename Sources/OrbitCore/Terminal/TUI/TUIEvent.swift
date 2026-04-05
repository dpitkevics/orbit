import Foundation

/// Keyboard modifier flags.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let ctrl = KeyModifiers(rawValue: 1 << 1)
    public static let alt = KeyModifiers(rawValue: 1 << 2)
}

/// Parsed keyboard key.
public enum Key: Sendable, Equatable {
    case character(Character)
    case enter
    case tab
    case backspace
    case delete
    case escape
    case up, down, left, right
    case home, end
    case pageUp, pageDown
    case ctrlA, ctrlB, ctrlC, ctrlD, ctrlE, ctrlF
    case ctrlJ, ctrlK, ctrlL, ctrlN, ctrlP, ctrlU, ctrlV, ctrlW
    case unknown(UInt8)
}

/// A parsed keyboard event.
public struct KeyEvent: Sendable {
    public let key: Key
    public let modifiers: KeyModifiers

    public init(key: Key, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Unified event type for the TUI event loop.
public enum TUIEvent: Sendable {
    /// Keyboard input.
    case keyPress(KeyEvent)
    /// Pasted text (from bracketed paste).
    case paste(String)
    /// Pasted image from clipboard.
    case pasteImage(ContentBlock)
    /// Event from the LLM query engine stream.
    case streamEvent(TurnEvent)
    /// Terminal was resized.
    case resize(width: Int, height: Int)
    /// Periodic tick for animations (spinners, cursor blink).
    case tick
}
