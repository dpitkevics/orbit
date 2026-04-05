import Foundation
import Testing
@testable import OrbitCore

@Suite("Slash Commands")
struct SlashCommandTests {
    @Test("Parse slash command from input")
    func parseCommand() {
        let (name, args) = SlashCommandParser.parse("/help")
        #expect(name == "help")
        #expect(args == nil)
    }

    @Test("Parse slash command with arguments")
    func parseCommandWithArgs() {
        let (name, args) = SlashCommandParser.parse("/model claude-opus-4-6")
        #expect(name == "model")
        #expect(args == "claude-opus-4-6")
    }

    @Test("Non-slash input returns nil")
    func parseNonSlash() {
        let (name, args) = SlashCommandParser.parse("hello world")
        #expect(name == nil)
        #expect(args == nil)
    }

    @Test("Empty slash returns nil")
    func parseEmptySlash() {
        let (name, args) = SlashCommandParser.parse("/")
        #expect(name == nil)
        #expect(args == nil)
    }

    @Test("Command registry finds commands")
    func registryFind() {
        let registry = SlashCommandRegistry.default
        #expect(registry.find("help") != nil)
        #expect(registry.find("cost") != nil)
        #expect(registry.find("nonexistent") == nil)
    }

    @Test("Command registry lists all commands")
    func registryList() {
        let registry = SlashCommandRegistry.default
        let commands = registry.allCommands()
        #expect(commands.count >= 8) // At least the core set
        #expect(commands.contains { $0.name == "help" })
        #expect(commands.contains { $0.name == "exit" })
    }

    @Test("/help command produces output")
    func helpCommand() {
        let registry = SlashCommandRegistry.default
        let cmd = registry.find("help")!
        let result = cmd.execute(args: nil, context: makeContext())
        #expect(result.output.contains("/help"))
        #expect(result.output.contains("/exit"))
    }

    @Test("/cost command shows usage")
    func costCommand() {
        var ctx = makeContext()
        ctx.sessionUsage = TokenUsage(inputTokens: 1000, outputTokens: 500)
        ctx.model = "claude-sonnet-4-6"

        let registry = SlashCommandRegistry.default
        let cmd = registry.find("cost")!
        let result = cmd.execute(args: nil, context: ctx)
        #expect(result.output.contains("1000"))
        #expect(result.output.contains("500"))
    }

    @Test("/clear command signals clear")
    func clearCommand() {
        let registry = SlashCommandRegistry.default
        let cmd = registry.find("clear")!
        let result = cmd.execute(args: nil, context: makeContext())
        #expect(result.action == .clearConversation)
    }

    @Test("/exit command signals exit")
    func exitCommand() {
        let registry = SlashCommandRegistry.default
        let cmd = registry.find("exit")!
        let result = cmd.execute(args: nil, context: makeContext())
        #expect(result.action == .exit)
    }

    @Test("/compact command signals compact")
    func compactCommand() {
        let registry = SlashCommandRegistry.default
        let cmd = registry.find("compact")!
        let result = cmd.execute(args: nil, context: makeContext())
        #expect(result.action == .compact)
    }

    @Test("/model command with no args shows current")
    func modelShowCurrent() {
        var ctx = makeContext()
        ctx.model = "claude-sonnet-4-6"

        let registry = SlashCommandRegistry.default
        let cmd = registry.find("model")!
        let result = cmd.execute(args: nil, context: ctx)
        #expect(result.output.contains("claude-sonnet-4-6"))
    }

    @Test("/model command with arg signals switch")
    func modelSwitch() {
        let registry = SlashCommandRegistry.default
        let cmd = registry.find("model")!
        let result = cmd.execute(args: "claude-opus-4-6", context: makeContext())
        #expect(result.action == .switchModel("claude-opus-4-6"))
    }

    @Test("/status command shows session info")
    func statusCommand() {
        var ctx = makeContext()
        ctx.messageCount = 10
        ctx.sessionID = "abc-123"

        let registry = SlashCommandRegistry.default
        let cmd = registry.find("status")!
        let result = cmd.execute(args: nil, context: ctx)
        #expect(result.output.contains("10"))
        #expect(result.output.contains("abc-123"))
    }

    @Test("/export signals export")
    func exportCommand() {
        let registry = SlashCommandRegistry.default
        let cmd = registry.find("export")!
        let result = cmd.execute(args: nil, context: makeContext())
        #expect(result.action == .export)
    }

    private func makeContext() -> SlashCommandContext {
        SlashCommandContext(
            sessionID: "test-session",
            model: "claude-sonnet-4-6",
            provider: "anthropic",
            project: "default",
            messageCount: 0,
            sessionUsage: .zero
        )
    }
}
