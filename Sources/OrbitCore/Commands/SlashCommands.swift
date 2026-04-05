import Foundation

/// Context passed to slash commands for rendering output.
public struct SlashCommandContext: Sendable {
    public var sessionID: String
    public var model: String
    public var provider: String
    public var project: String
    public var messageCount: Int
    public var sessionUsage: TokenUsage

    public init(
        sessionID: String = "",
        model: String = "",
        provider: String = "",
        project: String = "",
        messageCount: Int = 0,
        sessionUsage: TokenUsage = .zero
    ) {
        self.sessionID = sessionID
        self.model = model
        self.provider = provider
        self.project = project
        self.messageCount = messageCount
        self.sessionUsage = sessionUsage
    }
}

/// Action a slash command can request the REPL to perform.
public enum SlashCommandAction: Sendable, Equatable {
    case none
    case exit
    case clearConversation
    case compact
    case switchModel(String)
    case export
    case resume(String?)
    case dream
    case deep(String)
    case memory
}

/// Result from executing a slash command.
public struct SlashCommandResult: Sendable {
    public let output: String
    public let action: SlashCommandAction

    public init(output: String, action: SlashCommandAction = .none) {
        self.output = output
        self.action = action
    }

    public static func text(_ output: String) -> SlashCommandResult {
        SlashCommandResult(output: output)
    }

    public static func action(_ action: SlashCommandAction, output: String = "") -> SlashCommandResult {
        SlashCommandResult(output: output, action: action)
    }
}

/// A registered slash command.
public struct SlashCommand: Sendable {
    public let name: String
    public let description: String
    public let handler: @Sendable (String?, SlashCommandContext) -> SlashCommandResult

    public init(
        name: String,
        description: String,
        handler: @escaping @Sendable (String?, SlashCommandContext) -> SlashCommandResult
    ) {
        self.name = name
        self.description = description
        self.handler = handler
    }

    public func execute(args: String?, context: SlashCommandContext) -> SlashCommandResult {
        handler(args, context)
    }
}

/// Parses user input to detect slash commands.
public enum SlashCommandParser {
    /// Parse input into (commandName, args). Returns (nil, nil) for non-slash input.
    public static func parse(_ input: String) -> (name: String?, args: String?) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else {
            return (nil, nil)
        }

        let withoutSlash = String(trimmed.dropFirst())
        let parts = withoutSlash.split(separator: " ", maxSplits: 1)

        guard let first = parts.first, !first.isEmpty else {
            return (nil, nil)
        }

        let name = String(first)
        let args = parts.count > 1 ? String(parts[1]) : nil
        return (name, args)
    }
}

/// Registry of available slash commands.
public struct SlashCommandRegistry: Sendable {
    private let commands: [String: SlashCommand]

    public init(commands: [SlashCommand]) {
        var dict: [String: SlashCommand] = [:]
        for cmd in commands {
            dict[cmd.name] = cmd
        }
        self.commands = dict
    }

    public func find(_ name: String) -> SlashCommand? {
        commands[name]
    }

    public func allCommands() -> [SlashCommand] {
        commands.values.sorted { $0.name < $1.name }
    }

    /// Default registry with all built-in commands.
    public static let `default`: SlashCommandRegistry = {
        let commands = builtinSlashCommands()
        return SlashCommandRegistry(commands: commands)
    }()
}

private func builtinSlashCommands() -> [SlashCommand] {
    let commandList = [
        ("help", "Show available commands"),
        ("status", "Current session status"),
        ("cost", "Show session token usage and cost"),
        ("model", "Show or switch active model"),
        ("memory", "Show memory topics for current project"),
        ("dream", "Trigger memory consolidation"),
        ("deep", "Launch a deep analysis task"),
        ("trace", "Show agent trace for current session"),
        ("permissions", "Show current permission mode"),
        ("compact", "Manually compact conversation history"),
        ("resume", "Resume a previous session"),
        ("export", "Export conversation transcript"),
        ("clear", "Clear conversation history"),
        ("exit", "Exit the session"),
    ]

    return [
        SlashCommand(name: "help", description: "Show available commands") { _, _ in
            let lines = commandList.map { "  /\($0.0) — \($0.1)" }
            return .text("Available commands:\n" + lines.joined(separator: "\n"))
        },

        SlashCommand(name: "status", description: "Current session status") { _, ctx in
            var lines: [String] = []
            lines.append("Session: \(ctx.sessionID)")
            lines.append("Project: \(ctx.project)")
            lines.append("Model:   \(ctx.model)")
            lines.append("Provider: \(ctx.provider)")
            lines.append("Messages: \(ctx.messageCount)")
            if ctx.sessionUsage.totalTokens > 0 {
                lines.append("Tokens:  \(ctx.sessionUsage.totalTokens)")
            }
            return .text(lines.joined(separator: "\n"))
        },

        SlashCommand(name: "cost", description: "Show session token usage and cost") { _, ctx in
            let cost = ctx.sessionUsage.estimateCost(pricing: ModelPricing.forModel(ctx.model))
            var lines: [String] = []
            lines.append("Input tokens:  \(ctx.sessionUsage.inputTokens)")
            lines.append("Output tokens: \(ctx.sessionUsage.outputTokens)")
            if ctx.sessionUsage.cacheReadInputTokens > 0 {
                lines.append("Cache read:    \(ctx.sessionUsage.cacheReadInputTokens)")
            }
            if ctx.sessionUsage.cacheCreationInputTokens > 0 {
                lines.append("Cache create:  \(ctx.sessionUsage.cacheCreationInputTokens)")
            }
            lines.append("Total cost:    \(cost.formattedUSD)")
            return .text(lines.joined(separator: "\n"))
        },

        SlashCommand(name: "model", description: "Show or switch active model") { args, ctx in
            if let newModel = args?.trimmingCharacters(in: .whitespaces), !newModel.isEmpty {
                return .action(.switchModel(newModel), output: "Switching to \(newModel)")
            }
            return .text("Current model: \(ctx.model)")
        },

        SlashCommand(name: "dream", description: "Trigger memory consolidation") { _, _ in
            .action(.dream, output: "Starting autoDream consolidation...")
        },

        SlashCommand(name: "deep", description: "Launch a deep analysis task") { args, _ in
            let prompt = args ?? "Analyze the current state of the project."
            return .action(.deep(prompt), output: "Launching deep task...")
        },

        SlashCommand(name: "memory", description: "Show memory topics for current project") { _, ctx in
            .action(.memory, output: "Loading memory for \(ctx.project)...")
        },

        SlashCommand(name: "trace", description: "Show agent trace for current session") { _, ctx in
            .text("Session: \(ctx.sessionID)\nMessages: \(ctx.messageCount)\nTokens: \(ctx.sessionUsage.totalTokens)")
        },

        SlashCommand(name: "permissions", description: "Show current permission mode") { _, _ in
            .text("Permission mode: danger-full-access (default for REPL)")
        },

        SlashCommand(name: "compact", description: "Manually compact conversation history") { _, _ in
            .action(.compact, output: "Compacting conversation...")
        },

        SlashCommand(name: "resume", description: "Resume a previous session") { args, _ in
            .action(.resume(args), output: "")
        },

        SlashCommand(name: "export", description: "Export conversation transcript") { _, _ in
            .action(.export, output: "Exporting transcript...")
        },

        SlashCommand(name: "clear", description: "Clear conversation history") { _, _ in
            .action(.clearConversation, output: "Conversation cleared.")
        },

        SlashCommand(name: "exit", description: "Exit the session") { _, _ in
            .action(.exit)
        },
    ]
}
