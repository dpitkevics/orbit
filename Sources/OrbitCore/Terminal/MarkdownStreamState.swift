import Foundation

/// Accumulates streaming markdown deltas and renders incrementally.
///
/// Finds "safe boundaries" (blank lines, closed code fences) before flushing
/// rendered output, avoiding partial markdown re-parsing.
/// Matches Claw Code's `MarkdownStreamState` pattern from `render.rs`.
public struct MarkdownStreamState: Sendable {
    private var pending: String = ""
    private var flushedUpTo: Int = 0
    private let renderer: TerminalRenderer
    private var inCodeBlock: Bool = false

    public init(renderer: TerminalRenderer = TerminalRenderer()) {
        self.renderer = renderer
    }

    /// Push a new streaming delta. Returns rendered output if a safe boundary is found.
    public mutating func push(_ delta: String) -> String? {
        pending += delta

        guard let boundary = findSafeBoundary() else {
            return nil
        }

        let flushable = String(pending.prefix(boundary))
        pending = String(pending.dropFirst(boundary))

        return renderer.render(flushable)
    }

    /// Flush any remaining content (call when stream ends).
    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let remaining = pending
        pending = ""
        return renderer.render(remaining)
    }

    /// Check if there's pending content waiting to be rendered.
    public var hasPending: Bool { !pending.isEmpty }

    // MARK: - Safe Boundary Detection

    /// Find a position in the pending buffer where it's safe to flush.
    /// Safe boundaries: blank lines, closed code fences.
    private mutating func findSafeBoundary() -> Int? {
        let lines = pending.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }

        var pos = 0
        var lastSafe: Int?

        for (index, line) in lines.enumerated() {
            pos += line.count + 1 // +1 for \n

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Track code fence state
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                if !inCodeBlock {
                    // Just closed a code fence — safe to flush here
                    lastSafe = pos
                }
                continue
            }

            // Don't flush inside code blocks
            if inCodeBlock { continue }

            // Blank line is always a safe boundary
            if trimmed.isEmpty && index > 0 {
                lastSafe = pos
            }

            // End of a complete paragraph (next line starts a new block)
            if index + 1 < lines.count {
                let nextTrimmed = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if nextTrimmed.hasPrefix("#") || nextTrimmed.hasPrefix("```") || nextTrimmed.hasPrefix(">") || nextTrimmed.hasPrefix("- ") || nextTrimmed.hasPrefix("* ") {
                    lastSafe = pos
                }
            }
        }

        return lastSafe
    }
}
