import Foundation

/// Parses raw terminal bytes into typed KeyEvent values.
///
/// Handles ANSI escape sequences, Ctrl+letter combinations,
/// bracketed paste, and multi-byte UTF-8 characters.
public struct InputParser: Sendable {

    public init() {}

    /// Parse a byte into a KeyEvent. May consume additional bytes via `readMore`.
    /// Returns nil if the byte is part of an incomplete sequence.
    public func parse(byte: UInt8, readMore: () -> UInt8?) -> ParseResult {
        switch byte {
        // Ctrl+letter (1-26)
        case 1: return .key(KeyEvent(key: .ctrlA))
        case 2: return .key(KeyEvent(key: .ctrlB))
        case 3: return .key(KeyEvent(key: .ctrlC))
        case 4: return .key(KeyEvent(key: .ctrlD))
        case 5: return .key(KeyEvent(key: .ctrlE))
        case 6: return .key(KeyEvent(key: .ctrlF))
        case 9: return .key(KeyEvent(key: .tab))
        case 10: return .key(KeyEvent(key: .ctrlJ)) // Ctrl+J / newline
        case 11: return .key(KeyEvent(key: .ctrlK))
        case 12: return .key(KeyEvent(key: .ctrlL))
        case 13: return .key(KeyEvent(key: .enter))
        case 14: return .key(KeyEvent(key: .ctrlN))
        case 16: return .key(KeyEvent(key: .ctrlP))
        case 21: return .key(KeyEvent(key: .ctrlU))
        case 22: return .key(KeyEvent(key: .ctrlV))
        case 23: return .key(KeyEvent(key: .ctrlW))

        // Backspace
        case 127, 8: return .key(KeyEvent(key: .backspace))

        // Escape sequences
        case 27: return parseEscapeSequence(readMore: readMore)

        // Printable ASCII
        default:
            if byte >= 32 && byte < 127 {
                return .key(KeyEvent(key: .character(Character(UnicodeScalar(byte)))))
            }
            // UTF-8 multi-byte start
            if byte >= 0xC0 {
                return parseUTF8(firstByte: byte, readMore: readMore)
            }
            return .key(KeyEvent(key: .unknown(byte)))
        }
    }

    // MARK: - Escape Sequences

    private func parseEscapeSequence(readMore: () -> UInt8?) -> ParseResult {
        guard let seq1 = readMore() else {
            return .key(KeyEvent(key: .escape))
        }

        // CSI sequences: ESC [
        if seq1 == 91 { // [
            guard let seq2 = readMore() else {
                return .key(KeyEvent(key: .escape))
            }

            switch seq2 {
            case 65: return .key(KeyEvent(key: .up))
            case 66: return .key(KeyEvent(key: .down))
            case 67: return .key(KeyEvent(key: .right))
            case 68: return .key(KeyEvent(key: .left))
            case 72: return .key(KeyEvent(key: .home))
            case 70: return .key(KeyEvent(key: .end))

            // Extended sequences: ESC [ N ~
            case 51: // Delete
                _ = readMore() // consume ~
                return .key(KeyEvent(key: .delete))
            case 53: // Page Up
                _ = readMore() // consume ~
                return .key(KeyEvent(key: .pageUp))
            case 54: // Page Down
                _ = readMore() // consume ~
                return .key(KeyEvent(key: .pageDown))

            // Modified arrows: ESC [ 1 ; mod X
            case 49: // 1
                if readMore() == 59 { // ;
                    let mod = readMore() ?? 0
                    let arrow = readMore() ?? 0
                    let modifiers: KeyModifiers = switch mod {
                    case 50: .shift        // ;2
                    case 51: .alt          // ;3
                    case 53: .ctrl         // ;5
                    default: []
                    }
                    let key: Key = switch arrow {
                    case 65: .up
                    case 66: .down
                    case 67: .right
                    case 68: .left
                    default: .unknown(arrow)
                    }
                    return .key(KeyEvent(key: key, modifiers: modifiers))
                }
                return .key(KeyEvent(key: .unknown(49)))

            // Bracketed paste start: ESC [ 2 0 0 ~
            case 50: // 2
                if readMore() == 48, readMore() == 48, readMore() == 126 {
                    return parseBracketedPaste(readMore: readMore)
                }
                return .key(KeyEvent(key: .unknown(50)))

            default:
                return .key(KeyEvent(key: .unknown(seq2)))
            }
        }

        // Alt+key: ESC followed by a character
        if seq1 >= 32 && seq1 < 127 {
            return .key(KeyEvent(
                key: .character(Character(UnicodeScalar(seq1))),
                modifiers: .alt
            ))
        }

        return .key(KeyEvent(key: .escape))
    }

    // MARK: - Bracketed Paste

    private func parseBracketedPaste(readMore: () -> UInt8?) -> ParseResult {
        var pasted = ""
        while true {
            guard let ch = readMore() else { break }
            if ch == 27 { // ESC — check for end sequence
                if readMore() == 91, readMore() == 50, readMore() == 48, readMore() == 49, readMore() == 126 {
                    break // ESC [ 2 0 1 ~
                }
            }
            pasted.append(Character(UnicodeScalar(ch)))
        }
        return .paste(pasted)
    }

    // MARK: - UTF-8

    private func parseUTF8(firstByte: UInt8, readMore: () -> UInt8?) -> ParseResult {
        var bytes = [firstByte]
        let expectedLen: Int
        if firstByte & 0xE0 == 0xC0 { expectedLen = 2 }
        else if firstByte & 0xF0 == 0xE0 { expectedLen = 3 }
        else if firstByte & 0xF8 == 0xF0 { expectedLen = 4 }
        else { return .key(KeyEvent(key: .unknown(firstByte))) }

        for _ in 1..<expectedLen {
            guard let next = readMore() else { break }
            bytes.append(next)
        }

        if let str = String(bytes: bytes, encoding: .utf8), let char = str.first {
            return .key(KeyEvent(key: .character(char)))
        }
        return .key(KeyEvent(key: .unknown(firstByte)))
    }
}

/// Result from parsing input bytes.
public enum ParseResult: Sendable {
    case key(KeyEvent)
    case paste(String)
}
