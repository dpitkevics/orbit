import Foundation

/// Configuration for session compaction thresholds.
public struct CompactionConfig: Sendable {
    /// Number of recent messages to preserve after compaction.
    public var preserveRecentMessages: Int
    /// Token estimate threshold above which compaction triggers.
    public var maxEstimatedTokens: Int

    public init(preserveRecentMessages: Int = 4, maxEstimatedTokens: Int = 10_000) {
        self.preserveRecentMessages = preserveRecentMessages
        self.maxEstimatedTokens = maxEstimatedTokens
    }
}

/// Result of a compaction operation.
public struct CompactionResult: Sendable {
    public let summary: String
    public let formattedSummary: String
    public let compactedSession: Session
    public let removedMessageCount: Int
}

/// Engine that compacts sessions by summarizing older messages
/// and preserving the most recent tail.
///
/// Ported from Claw Code's `compact.rs` algorithm.
public enum CompactionEngine {
    private static let continuationPreamble =
        "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.\n\n"
    private static let recentMessagesNote =
        "Recent messages are preserved verbatim."
    private static let directResumeInstruction =
        "Continue the conversation from where it left off without asking the user any further questions. Resume directly — do not acknowledge the summary, do not recap what was happening, and do not preface with continuation text."

    /// Check whether a session needs compaction.
    public static func shouldCompact(session: Session, config: CompactionConfig) -> Bool {
        let startIndex = existingSummaryPrefixLength(session)
        let compactable = Array(session.messages[startIndex...])

        return compactable.count > config.preserveRecentMessages
            && compactable.reduce(0, { $0 + $1.estimatedTokens }) >= config.maxEstimatedTokens
    }

    /// Compact a session by summarizing older messages and keeping the recent tail.
    public static func compact(session: Session, config: CompactionConfig) -> CompactionResult {
        guard shouldCompact(session: session, config: config) else {
            return CompactionResult(
                summary: "",
                formattedSummary: "",
                compactedSession: session,
                removedMessageCount: 0
            )
        }

        let existingSummary = extractExistingSummary(session)
        let compactedPrefixLen = existingSummary != nil ? 1 : 0

        let keepFrom = max(
            compactedPrefixLen,
            session.messages.count - config.preserveRecentMessages
        )

        let removed = Array(session.messages[compactedPrefixLen..<keepFrom])
        let preserved = Array(session.messages[keepFrom...])

        let newSummary = summarizeMessages(removed)
        let mergedSummary = mergeSummaries(existing: existingSummary, new: newSummary)
        let formattedSummary = formatCompactSummary(mergedSummary)

        let continuation = buildContinuationMessage(
            summary: mergedSummary,
            hasPreservedMessages: !preserved.isEmpty
        )

        var continuationMessage = ChatMessage.system(continuation)
        continuationMessage.usage = nil

        var compactedMessages = [continuationMessage]
        compactedMessages.append(contentsOf: preserved)

        var compactedSession = session
        compactedSession.messages = compactedMessages
        compactedSession.recordCompaction(summary: mergedSummary, removedCount: removed.count)

        return CompactionResult(
            summary: mergedSummary,
            formattedSummary: formattedSummary,
            compactedSession: compactedSession,
            removedMessageCount: removed.count
        )
    }

    /// Format a raw summary for user-facing display.
    public static func formatCompactSummary(_ summary: String) -> String {
        var result = stripTagBlock(summary, tag: "analysis")

        if let content = extractTagContent(result, tag: "summary") {
            result = result.replacingOccurrences(
                of: "<summary>\(content)</summary>",
                with: "Summary:\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }

        return collapseBlankLines(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internal

    private static func existingSummaryPrefixLength(_ session: Session) -> Int {
        guard let first = session.messages.first,
              first.role == .system,
              first.textContent.contains("continued from a previous conversation") else {
            return 0
        }
        return 1
    }

    private static func extractExistingSummary(_ session: Session) -> String? {
        guard existingSummaryPrefixLength(session) > 0 else { return nil }
        return session.messages.first?.textContent
    }

    private static func summarizeMessages(_ messages: [ChatMessage]) -> String {
        var parts: [String] = []
        for msg in messages {
            let roleLabel = switch msg.role {
            case .user: "User"
            case .assistant: "Assistant"
            case .system: "System"
            case .tool: "Tool"
            }

            let text = msg.textContent
            if !text.isEmpty {
                let truncated = text.count > 200 ? String(text.prefix(200)) + "..." : text
                parts.append("\(roleLabel): \(truncated)")
            }

            for use in msg.toolUses {
                parts.append("Tool call: \(use.name)")
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func mergeSummaries(existing: String?, new: String) -> String {
        guard let existing else { return new }
        return "\(existing)\n\n--- Continued ---\n\n\(new)"
    }

    private static func buildContinuationMessage(
        summary: String,
        hasPreservedMessages: Bool
    ) -> String {
        var message = continuationPreamble + formatCompactSummary(summary)

        if hasPreservedMessages {
            message += "\n\n" + recentMessagesNote
        }

        message += "\n" + directResumeInstruction

        return message
    }

    // MARK: - Text Processing

    private static func stripTagBlock(_ text: String, tag: String) -> String {
        let pattern = "<\(tag)>[\\s\\S]*?</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    private static func extractTagContent(_ text: String, tag: String) -> String? {
        let pattern = "<\(tag)>([\\s\\S]*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func collapseBlankLines(_ text: String) -> String {
        let pattern = "\n{3,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "\n\n"
        )
    }
}
