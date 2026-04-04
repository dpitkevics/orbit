import Foundation
import Testing
@testable import OrbitCore

@Suite("Stream Events")
struct StreamEventTests {
    @Test("StopReason raw values")
    func stopReasonRawValues() {
        #expect(StopReason.endTurn.rawValue == "end_turn")
        #expect(StopReason.toolUse.rawValue == "tool_use")
        #expect(StopReason.maxTokens.rawValue == "max_tokens")
        #expect(StopReason.stopSequence.rawValue == "stop_sequence")
        #expect(StopReason.unknown.rawValue == "unknown")
    }

    @Test("StopReason decodes from string")
    func stopReasonDecode() throws {
        let data = "\"end_turn\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StopReason.self, from: data)
        #expect(decoded == .endTurn)
    }

    @Test("StopReason encodes to string")
    func stopReasonEncode() throws {
        let data = try JSONEncoder().encode(StopReason.toolUse)
        let str = String(data: data, encoding: .utf8)
        #expect(str == "\"tool_use\"")
    }
}
