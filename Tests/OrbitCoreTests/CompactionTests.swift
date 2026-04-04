import Foundation
import Testing
@testable import OrbitCore

@Suite("Session Compaction")
struct CompactionTests {
    // MARK: - Token Estimation

    @Test("Token estimation uses ~4 chars per token heuristic")
    func tokenEstimation() {
        // "hello world" = 11 chars → ~3 tokens
        let msg = ChatMessage.userText("hello world")
        #expect(msg.estimatedTokens >= 2)
        #expect(msg.estimatedTokens <= 4)
    }

    @Test("Session estimated tokens sums all messages")
    func sessionTokenEstimation() {
        var session = Session()
        session.appendMessage(.userText("hello"))        // ~2 tokens
        session.appendMessage(.assistantText("world"))   // ~2 tokens
        #expect(session.estimatedTokens >= 2)
    }

    // MARK: - Should Compact

    @Test("shouldCompact returns false for short sessions")
    func shouldCompactShortSession() {
        var session = Session()
        session.appendMessage(.userText("hi"))
        session.appendMessage(.assistantText("hello"))

        let config = CompactionConfig()
        #expect(!CompactionEngine.shouldCompact(session: session, config: config))
    }

    @Test("shouldCompact returns false when under token threshold")
    func shouldCompactUnderThreshold() {
        var session = Session()
        for i in 0..<10 {
            session.appendMessage(.userText("msg \(i)"))
            session.appendMessage(.assistantText("reply \(i)"))
        }

        // 20 short messages — well under 10,000 token threshold
        let config = CompactionConfig()
        #expect(!CompactionEngine.shouldCompact(session: session, config: config))
    }

    @Test("shouldCompact returns true for long sessions over token threshold")
    func shouldCompactLongSession() {
        var session = Session()
        let longText = String(repeating: "a", count: 5000) // ~1250 tokens
        for _ in 0..<12 {
            session.appendMessage(.userText(longText))
            session.appendMessage(.assistantText(longText))
        }

        let config = CompactionConfig(preserveRecentMessages: 4, maxEstimatedTokens: 10_000)
        #expect(CompactionEngine.shouldCompact(session: session, config: config))
    }

    // MARK: - Compact Session

    @Test("compact preserves N recent messages")
    func compactPreservesRecent() {
        var session = Session()
        let longText = String(repeating: "x", count: 5000)
        for i in 0..<10 {
            session.appendMessage(.userText("user \(i) \(longText)"))
            session.appendMessage(.assistantText("assistant \(i) \(longText)"))
        }

        let config = CompactionConfig(preserveRecentMessages: 4, maxEstimatedTokens: 100)
        let result = CompactionEngine.compact(session: session, config: config)

        // Should have: 1 summary message + 4 preserved
        #expect(result.compactedSession.messages.count == 5)
        #expect(result.removedMessageCount > 0)

        // Last 4 messages should be the most recent
        let lastMsg = result.compactedSession.messages.last
        #expect(lastMsg?.textContent.contains("assistant 9") == true)
    }

    @Test("compact returns unchanged session when not needed")
    func compactNoOp() {
        var session = Session()
        session.appendMessage(.userText("hi"))
        session.appendMessage(.assistantText("hello"))

        let config = CompactionConfig()
        let result = CompactionEngine.compact(session: session, config: config)

        #expect(result.removedMessageCount == 0)
        #expect(result.compactedSession.messages.count == session.messages.count)
    }

    @Test("compact generates continuation message as first message")
    func compactContinuationMessage() {
        var session = Session()
        let longText = String(repeating: "y", count: 5000)
        for i in 0..<10 {
            session.appendMessage(.userText("user \(i) \(longText)"))
            session.appendMessage(.assistantText("assistant \(i) \(longText)"))
        }

        let config = CompactionConfig(preserveRecentMessages: 4, maxEstimatedTokens: 100)
        let result = CompactionEngine.compact(session: session, config: config)

        let firstMsg = result.compactedSession.messages.first
        #expect(firstMsg?.role == .system)
        #expect(firstMsg?.textContent.contains("continued from a previous conversation") == true)
    }

    @Test("compact records compaction metadata on session")
    func compactRecordsMetadata() {
        var session = Session()
        let longText = String(repeating: "z", count: 5000)
        for i in 0..<10 {
            session.appendMessage(.userText("user \(i) \(longText)"))
            session.appendMessage(.assistantText("assistant \(i) \(longText)"))
        }

        let config = CompactionConfig(preserveRecentMessages: 4, maxEstimatedTokens: 100)
        let result = CompactionEngine.compact(session: session, config: config)

        #expect(result.compactedSession.compaction != nil)
        #expect(result.compactedSession.compaction?.count == 1)
        #expect(result.compactedSession.compaction?.removedMessageCount ?? 0 > 0)
    }

    @Test("compact merges with existing summary on re-compaction")
    func compactMergesExistingSummary() {
        // First compaction
        var session = Session()
        let longText = String(repeating: "a", count: 5000)
        for i in 0..<10 {
            session.appendMessage(.userText("user \(i) \(longText)"))
            session.appendMessage(.assistantText("assistant \(i) \(longText)"))
        }

        let config = CompactionConfig(preserveRecentMessages: 4, maxEstimatedTokens: 100)
        let firstResult = CompactionEngine.compact(session: session, config: config)

        // Add more messages to the compacted session
        var session2 = firstResult.compactedSession
        for i in 10..<20 {
            session2.appendMessage(.userText("user \(i) \(longText)"))
            session2.appendMessage(.assistantText("assistant \(i) \(longText)"))
        }

        // Second compaction
        let secondResult = CompactionEngine.compact(session: session2, config: config)

        #expect(secondResult.compactedSession.compaction?.count == 2)
        // The continuation message should contain context from both compactions
        let firstMsg = secondResult.compactedSession.messages.first
        #expect(firstMsg?.role == .system)
    }

    // MARK: - Format Summary

    @Test("formatCompactSummary strips analysis tags")
    func formatSummaryStripsAnalysis() {
        let raw = "Before <analysis>hidden analysis</analysis> After"
        let formatted = CompactionEngine.formatCompactSummary(raw)
        #expect(!formatted.contains("<analysis>"))
        #expect(!formatted.contains("hidden analysis"))
        #expect(formatted.contains("Before"))
        #expect(formatted.contains("After"))
    }

    @Test("formatCompactSummary reformats summary tags")
    func formatSummaryReformatsSummaryTags() {
        let raw = "<summary>This is the summary content</summary>"
        let formatted = CompactionEngine.formatCompactSummary(raw)
        #expect(formatted.contains("Summary:"))
        #expect(formatted.contains("This is the summary content"))
        #expect(!formatted.contains("<summary>"))
    }

    // MARK: - CompactionConfig Defaults

    @Test("CompactionConfig defaults")
    func compactionConfigDefaults() {
        let config = CompactionConfig()
        #expect(config.preserveRecentMessages == 4)
        #expect(config.maxEstimatedTokens == 10_000)
    }
}

@Suite("Session Persistence")
struct SessionPersistenceTests {
    let testDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbit-session-test-\(UUID().uuidString.prefix(8))")

    @Test("Session save and load roundtrip")
    func sessionRoundtrip() throws {
        let store = FileSessionStore(baseDir: testDir)

        var session = Session()
        session.appendMessage(.userText("hello"))
        session.appendMessage(.assistantText("world"))

        try store.save(session, project: "test")
        let loaded = try store.load(id: session.sessionID, project: "test")

        #expect(loaded.sessionID == session.sessionID)
        #expect(loaded.messages.count == 2)
        #expect(loaded.messages[0].textContent == "hello")
        #expect(loaded.messages[1].textContent == "world")
    }

    @Test("Session list returns summaries")
    func sessionList() throws {
        let store = FileSessionStore(baseDir: testDir)

        var s1 = Session()
        s1.appendMessage(.userText("first"))
        try store.save(s1, project: "test")

        var s2 = Session()
        s2.appendMessage(.userText("second"))
        try store.save(s2, project: "test")

        let list = try store.list(project: "test", limit: 10)
        #expect(list.count == 2)
    }

    @Test("Session delete removes file")
    func sessionDelete() throws {
        let store = FileSessionStore(baseDir: testDir)

        var session = Session()
        session.appendMessage(.userText("temp"))
        try store.save(session, project: "test")

        try store.delete(id: session.sessionID, project: "test")

        #expect(throws: SessionStoreError.self) {
            try store.load(id: session.sessionID, project: "test")
        }
    }

    @Test("Session load nonexistent throws")
    func sessionLoadNotFound() {
        let store = FileSessionStore(baseDir: testDir)
        #expect(throws: SessionStoreError.self) {
            try store.load(id: "nonexistent", project: "test")
        }
    }

    @Test("Session fork preserves messages and records provenance")
    func sessionFork() {
        var session = Session()
        session.appendMessage(.userText("original"))

        let forked = session.fork(branchName: "experiment")
        #expect(forked.fork?.parentSessionID == session.sessionID)
        #expect(forked.fork?.branchName == "experiment")
        #expect(forked.messages.count == 1)
        #expect(forked.sessionID != session.sessionID)
    }

    @Test("Session list empty project returns empty array")
    func sessionListEmpty() throws {
        let store = FileSessionStore(baseDir: testDir)
        let list = try store.list(project: "empty-project", limit: 10)
        #expect(list.isEmpty)
    }
}
