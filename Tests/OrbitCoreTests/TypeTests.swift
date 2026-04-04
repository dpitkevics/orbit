import Foundation
import Testing
@testable import OrbitCore

@Suite("Core Types")
struct TypeTests {
    @Test("JSONValue encoding and decoding roundtrip")
    func jsonValueRoundtrip() throws {
        let value: JSONValue = .object([
            "name": .string("test"),
            "count": .int(42),
            "active": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .null,
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("JSONValue literal initialization")
    func jsonValueLiterals() {
        let _: JSONValue = nil
        let _: JSONValue = true
        let _: JSONValue = 42
        let _: JSONValue = 3.14
        let _: JSONValue = "hello"
        let _: JSONValue = [1, 2, 3]
        let _: JSONValue = ["key": "value"]
    }

    @Test("JSONValue subscript access")
    func jsonValueSubscript() {
        let value: JSONValue = .object([
            "name": .string("orbit"),
            "items": .array([.int(1), .int(2)]),
        ])

        #expect(value["name"]?.stringValue == "orbit")
        #expect(value["items"]?[0]?.intValue == 1)
        #expect(value["missing"] == nil)
    }

    @Test("ChatMessage text content extraction")
    func chatMessageTextContent() {
        let msg = ChatMessage(role: .assistant, blocks: [
            .text("Hello "),
            .text("world"),
        ])
        #expect(msg.textContent == "Hello world")
    }

    @Test("ChatMessage tool uses extraction")
    func chatMessageToolUses() {
        let msg = ChatMessage(role: .assistant, blocks: [
            .text("Let me search for that."),
            .toolUse(id: "tool_1", name: "web_search", input: .object(["query": "test"])),
        ])
        #expect(msg.toolUses.count == 1)
        #expect(msg.toolUses[0].name == "web_search")
    }

    @Test("TokenUsage addition")
    func tokenUsageAdd() {
        let a = TokenUsage(inputTokens: 100, outputTokens: 50)
        let b = TokenUsage(inputTokens: 200, outputTokens: 75)
        let sum = a + b
        #expect(sum.inputTokens == 300)
        #expect(sum.outputTokens == 125)
        #expect(sum.totalTokens == 425)
    }

    @Test("Cost estimation")
    func costEstimate() {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000)
        let cost = usage.estimateCost(pricing: .sonnet)
        #expect(cost.inputCost == 3.0)
        #expect(cost.outputCost == 7.5)
        #expect(cost.totalCost == 10.5)
    }

    @Test("ContentBlock coding roundtrip")
    func contentBlockCodable() throws {
        let blocks: [ContentBlock] = [
            .text("hello"),
            .toolUse(id: "t1", name: "bash", input: .object(["command": "ls"])),
            .toolResult(toolUseId: "t1", toolName: "bash", output: "file.txt", isError: false),
        ]

        let data = try JSONEncoder().encode(blocks)
        let decoded = try JSONDecoder().decode([ContentBlock].self, from: data)
        #expect(decoded == blocks)
    }
}

@Suite("Config")
struct ConfigTests {
    @Test("Parse global TOML config")
    func parseGlobalConfig() throws {
        let toml = """
        [defaults]
        provider = "anthropic"
        model = "claude-sonnet-4-6"

        [auth.anthropic]
        mode = "api_key"
        api_key_env = "ANTHROPIC_API_KEY"

        [context]
        max_file_chars = 5000
        max_total_chars = 15000
        """

        let config = try ConfigLoader.parseGlobalConfig(toml, path: "test.toml")
        #expect(config.defaultProvider == "anthropic")
        #expect(config.defaultModel == "claude-sonnet-4-6")
        #expect(config.auth["anthropic"]?.mode == .apiKey)
        #expect(config.auth["anthropic"]?.apiKeyEnv == "ANTHROPIC_API_KEY")
        #expect(config.contextMaxFileChars == 5000)
        #expect(config.contextMaxTotalChars == 15000)
    }

    @Test("Parse project TOML config")
    func parseProjectConfig() throws {
        let toml = """
        [project]
        name = "My Project"
        slug = "my-project"
        description = "A test project"
        repo = "~/Projects/my-project"
        model = "claude-opus-4-6"

        [context]
        files = ["docs/about.md", "docs/brand.md"]
        """

        let config = try ConfigLoader.parseProjectConfig(toml, path: "test.toml")
        #expect(config.name == "My Project")
        #expect(config.slug == "my-project")
        #expect(config.description == "A test project")
        #expect(config.repoPath == "~/Projects/my-project")
        #expect(config.model == "claude-opus-4-6")
        #expect(config.contextFiles.count == 2)
    }

    @Test("Project effective model falls back to global")
    func projectEffectiveModel() {
        let global = OrbitConfig(defaultModel: "claude-sonnet-4-6")
        let project = ProjectConfig(name: "Test", slug: "test")
        #expect(project.effectiveModel(global: global) == "claude-sonnet-4-6")

        let projectWithModel = ProjectConfig(name: "Test", slug: "test", model: "claude-opus-4-6")
        #expect(projectWithModel.effectiveModel(global: global) == "claude-opus-4-6")
    }
}
