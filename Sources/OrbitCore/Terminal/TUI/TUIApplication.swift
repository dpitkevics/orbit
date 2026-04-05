import Foundation

/// Application state machine.
public enum TUIState: Sendable {
    case idle        // Waiting for user input
    case streaming   // Consuming LLM output
    case confirming  // Permission prompt
}

/// Full-screen TUI orchestrator.
///
/// Manages the event loop, dispatches events to regions,
/// and coordinates screen rendering.
public final class TUIApplication: @unchecked Sendable {
    // Screen
    private let screen: ScreenManager
    private let eventLoop: EventLoop

    // Regions
    private var header: HeaderRegion
    private var output: OutputRegion
    private var input: InputRegion
    private var autocomplete: AutocompleteDropdown

    // Region layout
    private var headerRows: RowRange = RowRange(start: 0, end: 3)
    private var outputRows: RowRange = RowRange(start: 3, end: 20)
    private var inputRows: RowRange = RowRange(start: 20, end: 22)

    // State
    private var state: TUIState = .idle
    private var spinner = TUISpinner()

    // Rendering
    private let renderer: TerminalRenderer
    private var streamState: MarkdownStreamState

    // Dependencies
    private let provider: any LLMProvider
    private let toolPool: ToolPool
    private let policy: PermissionPolicy
    private let commandRegistry: SlashCommandRegistry
    private let sessionStore: FileSessionStore
    private let memoryStore: SQLiteMemory?

    // Session state
    private var session: Session
    private var messages: [ChatMessage] = []
    private var totalUsage: TokenUsage = .zero
    private let systemPrompt: String
    private let projectSlug: String
    private var currentModel: String

    public init(
        provider: any LLMProvider,
        toolPool: ToolPool,
        policy: PermissionPolicy,
        commandRegistry: SlashCommandRegistry = .default,
        sessionStore: FileSessionStore = FileSessionStore(),
        memoryStore: SQLiteMemory? = nil,
        session: Session = Session(),
        systemPrompt: String,
        projectName: String,
        projectSlug: String,
        model: String,
        providerName: String,
        theme: ColorTheme = .default
    ) {
        self.screen = ScreenManager()
        self.eventLoop = EventLoop(screen: screen)
        self.renderer = TerminalRenderer(theme: theme)
        self.streamState = MarkdownStreamState(renderer: renderer)

        self.header = HeaderRegion(
            projectName: projectName,
            model: model,
            provider: providerName,
            sessionID: session.sessionID,
            theme: theme
        )
        self.output = OutputRegion(theme: theme)
        self.input = InputRegion(
            historyPath: ConfigLoader.orbitHome.appendingPathComponent("history").path,
            theme: theme
        )
        self.autocomplete = AutocompleteDropdown(
            commands: commandRegistry.allCommands(),
            theme: theme
        )

        self.provider = provider
        self.toolPool = toolPool
        self.policy = policy
        self.commandRegistry = commandRegistry
        self.sessionStore = sessionStore
        self.memoryStore = memoryStore
        self.session = session
        self.systemPrompt = systemPrompt
        self.projectSlug = projectSlug
        self.currentModel = model
    }

    /// Run the TUI main loop.
    public func run() async throws {
        screen.activate()
        defer { screen.deactivate() }

        allocateRegions()
        renderAll()
        screen.flush()

        // Welcome message
        output.appendText("\(ANSI.dim)Type a message to start, /help for commands.\(ANSI.reset)")
        renderOutput()
        screen.flush()

        let events = eventLoop.start()

        for await event in events {
            switch event {
            case .keyPress(let keyEvent):
                await handleKeyPress(keyEvent)

            case .paste(let text):
                input.handlePaste(text)
                renderInput()

            case .pasteImage(let block):
                input.handlePasteImage(block)
                output.appendLine("\(ANSI.cyan)[image attached from clipboard]\(ANSI.reset)")
                renderInput()
                renderOutput()

            case .streamEvent(let turnEvent):
                await handleStreamEvent(turnEvent)

            case .resize:
                allocateRegions()
                renderAll()

            case .tick:
                if state == .streaming {
                    // Update spinner in header
                    let frame = spinner.tick()
                    header.setStreaming(true)
                    renderHeader()
                    _ = frame // Spinner frame could be shown somewhere
                }
            }

            // Show cursor at input position when idle
            if state == .idle {
                let cursorRow = inputRows.start + 1 + 1 // separator + prompt row (1-based)
                let cursorCol = input.cursorColumn()
                screen.showCursorAt(row: cursorRow, col: cursorCol)
            } else {
                screen.hideCursor()
            }

            screen.flush()
        }
    }

    // MARK: - Event Handlers

    private func handleKeyPress(_ keyEvent: KeyEvent) async {
        // If autocomplete is visible, handle navigation
        if autocomplete.isVisible {
            switch keyEvent.key {
            case .up:
                autocomplete.moveUp()
                renderAutocomplete()
                return
            case .down:
                autocomplete.moveDown()
                renderAutocomplete()
                return
            case .enter, .tab:
                if let selected = autocomplete.selectedItem() {
                    input.buffer = Array(selected + " ")
                    input.cursorPos = input.buffer.count
                    autocomplete.dismiss()
                    renderInput()
                    renderOutput() // Clear overlay
                    return
                }
            case .escape:
                autocomplete.dismiss()
                renderOutput() // Clear overlay
                renderInput()
                return
            default:
                break
            }
        }

        let action = input.handleKey(keyEvent)

        switch action {
        case .none:
            renderInput()

        case .submit(let text, let attachments):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                renderInput()
                return
            }

            autocomplete.dismiss()

            // Check for slash commands
            let (cmdName, cmdArgs) = SlashCommandParser.parse(trimmed)
            if let cmdName, let cmd = commandRegistry.find(cmdName) {
                await handleSlashCommand(cmd, args: cmdArgs)
                input.resetHistoryIndex()
                renderInput()
                return
            }

            // Send to LLM
            await sendToLLM(text: trimmed, attachments: attachments)
            input.resetHistoryIndex()
            renderInput()

        case .cancel:
            autocomplete.dismiss()
            renderInput()
            renderOutput()

        case .eof:
            await saveAndExit()
            eventLoop.stop()

        case .scrollUp(let n):
            output.scrollUp(n)
            renderOutput()

        case .scrollDown(let n):
            output.scrollDown(n)
            renderOutput()

        case .pageUp:
            output.pageUp(visibleHeight: outputRows.count)
            renderOutput()

        case .pageDown:
            output.pageDown(visibleHeight: outputRows.count)
            renderOutput()

        case .showAutocomplete(let filter):
            autocomplete.updateFilter(filter)
            renderInput()
            if autocomplete.isVisible {
                renderAutocomplete()
            } else {
                renderOutput() // Clear any previous overlay
            }

        case .dismissAutocomplete:
            autocomplete.dismiss()
            renderOutput()
            renderInput()

        case .selectAutocomplete:
            if let selected = autocomplete.selectedItem() {
                input.buffer = Array(selected + " ")
                input.cursorPos = input.buffer.count
                autocomplete.dismiss()
            }
            renderOutput()
            renderInput()

        case .clearScreen:
            output = OutputRegion(theme: renderer.theme)
            renderAll()

        case .projectSwitcher:
            output.appendLine("\(ANSI.dim)Project switching: use /project <slug> or orbit chat <slug>\(ANSI.reset)")
            renderOutput()
        }
    }

    private func handleStreamEvent(_ event: TurnEvent) async {
        switch event {
        case .textDelta(let text):
            if let rendered = streamState.push(text) {
                output.appendText(rendered)
                output.scrollToBottom()
                renderOutput()
            }

        case .toolCallStart(_, let name):
            // Flush pending markdown
            if let remaining = streamState.flush() {
                output.appendText(remaining)
            }
            let toolInput: JSONValue = .object([:])
            output.appendText(ToolCallDisplay.formatStart(name: name, input: toolInput))
            renderOutput()

        case .toolCallEnd(_, let name, let result):
            if result.isError {
                output.appendText(ToolCallDisplay.formatFailure(name: name, error: result.output))
            } else {
                output.appendText(ToolCallDisplay.formatSuccess(name: name, output: result.output))
            }
            renderOutput()

        case .toolDenied(let name, let reason):
            output.appendText(ToolCallDisplay.formatDenied(name: name, reason: reason))
            renderOutput()

        case .usageUpdate(let usage):
            totalUsage += usage
            let cost = provider.estimateCost(usage: totalUsage)
            header.updateUsage(totalUsage, cost: cost)
            renderHeader()

        case .turnComplete(let summary):
            // Flush remaining markdown
            if let remaining = streamState.flush() {
                output.appendText(remaining)
            }
            streamState = MarkdownStreamState(renderer: renderer)

            state = .idle
            header.setStreaming(false)
            spinner.reset()

            if summary.toolCallCount > 0 {
                output.appendLine(ANSI.colored(
                    "[\(summary.iterations) turn\(summary.iterations == 1 ? "" : "s"), \(summary.toolCallCount) tool call\(summary.toolCallCount == 1 ? "" : "s")]",
                    ANSI.dim
                ))
            }

            output.appendBlank()
            renderAll()

            // Save session
            try? sessionStore.save(session, project: projectSlug)
        }
    }

    // MARK: - LLM Interaction

    private func sendToLLM(text: String, attachments: [ContentBlock]) async {
        state = .streaming
        header.setStreaming(true)
        renderHeader()

        output.appendLine("\(ANSI.green)> \(ANSI.reset)\(text)")
        if !attachments.isEmpty {
            let labels = attachments.map { block -> String in
                switch block {
                case .image: return "[image]"
                case .document(let name, _, _): return "[\(name)]"
                default: return "[attachment]"
                }
            }
            output.appendLine("\(ANSI.dim)  Attachments: \(labels.joined(separator: " "))\(ANSI.reset)")
        }
        output.appendBlank()
        renderOutput()

        var userBlocks: [ContentBlock] = [.text(text)]
        userBlocks.append(contentsOf: attachments)
        let userMsg = ChatMessage(role: .user, blocks: userBlocks)
        messages.append(userMsg)
        session.appendMessage(userMsg)

        let engine = QueryEngine(
            provider: provider,
            toolPool: toolPool,
            policy: policy,
            config: QueryEngineConfig(maxTurns: 8)
        )

        let stream = engine.run(messages: &messages, systemPrompt: systemPrompt)
        eventLoop.attachStream(stream)
    }

    // MARK: - Slash Commands

    private func handleSlashCommand(_ cmd: SlashCommand, args: String?) async {
        let ctx = SlashCommandContext(
            sessionID: session.sessionID,
            model: currentModel,
            provider: header.provider,
            project: projectSlug,
            messageCount: messages.count,
            sessionUsage: totalUsage
        )
        let result = cmd.execute(args: args, context: ctx)

        if !result.output.isEmpty {
            output.appendText(result.output)
        }

        switch result.action {
        case .exit:
            await saveAndExit()
            eventLoop.stop()

        case .clearConversation:
            messages.removeAll()
            session = Session()
            totalUsage = .zero
            output = OutputRegion(theme: renderer.theme)
            output.appendLine("\(ANSI.dim)Conversation cleared.\(ANSI.reset)")

        case .compact:
            let config = CompactionConfig()
            let compResult = CompactionEngine.compact(session: session, config: config)
            if compResult.removedMessageCount > 0 {
                session = compResult.compactedSession
                messages = session.messages
                output.appendLine("Compacted: removed \(compResult.removedMessageCount) messages.")
            } else {
                output.appendLine("Nothing to compact.")
            }

        case .switchModel(let newModel):
            currentModel = newModel
            header.model = newModel
            output.appendLine("Model switched to \(newModel).")

        case .dream:
            if let store = memoryStore {
                do {
                    let report = try await DreamEngine.dream(store: store, project: projectSlug)
                    output.appendLine("Dream: \(report.observationsExtracted) observations, \(report.topicsCreated) created, \(report.topicsUpdated) updated")
                } catch {
                    output.appendLine("Dream failed: \(error.localizedDescription)")
                }
            }

        case .deep(let prompt):
            let task = DeepTask(name: "Deep Analysis", prompt: prompt, projects: [projectSlug])
            let runner = DeepTaskRunner(provider: provider)
            do {
                let completed = try await runner.run(task)
                if let text = completed.result { output.appendText(text) }
            } catch {
                output.appendLine("Deep task failed: \(error.localizedDescription)")
            }

        case .memory:
            if let store = memoryStore {
                let topics = (try? await store.listTopics(project: projectSlug)) ?? []
                if topics.isEmpty {
                    output.appendLine("No memory topics.")
                } else {
                    output.appendLine("Memory topics (\(topics.count)):")
                    for t in topics { output.appendLine("  \(t.slug) — \(t.title)") }
                }
            }

        case .export:
            let transcript = messages.map { "\(($0.role.rawValue.capitalized)): \($0.textContent)" }.joined(separator: "\n\n")
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("orbit-export-\(session.sessionID.prefix(8)).md")
            try? transcript.write(to: path, atomically: true, encoding: .utf8)
            output.appendLine("Exported to \(path.path)")

        case .resume(let sid):
            if let sid {
                if let loaded = try? sessionStore.load(id: sid, project: projectSlug) {
                    session = loaded
                    messages = loaded.messages
                    totalUsage = .zero
                    output.appendLine("Resumed session \(sid.prefix(8)) (\(messages.count) messages)")
                } else {
                    output.appendLine("Session not found: \(sid)")
                }
            } else {
                let list = (try? sessionStore.list(project: projectSlug, limit: 10)) ?? []
                if list.isEmpty {
                    output.appendLine("No previous sessions.")
                } else {
                    output.appendLine("Recent sessions:")
                    for s in list {
                        output.appendLine("  \(s.sessionID.prefix(8)) — \(s.messageCount) msgs")
                    }
                }
            }

        case .attach(let path):
            // Load file or image
            let expanded = (path as NSString).expandingTildeInPath
            if let data = FileManager.default.contents(atPath: expanded) {
                let ext = (expanded as NSString).pathExtension.lowercased()
                let imageExts = ["png", "jpg", "jpeg", "gif", "webp"]
                if imageExts.contains(ext) {
                    input.handlePasteImage(.image(source: .base64(mediaType: "image/\(ext)", data: data.base64EncodedString())))
                    output.appendLine("\(ANSI.cyan)[image attached: \(path)]\(ANSI.reset)")
                } else if let text = String(data: data, encoding: .utf8) {
                    let truncated = text.count > 50_000 ? String(text.prefix(50_000)) + "..." : text
                    let name = (expanded as NSString).lastPathComponent
                    input.handlePasteImage(.document(name: name, mediaType: "text/plain", content: truncated))
                    output.appendLine("\(ANSI.cyan)[file attached: \(name)]\(ANSI.reset)")
                }
            } else {
                output.appendLine("Could not read: \(path)")
            }

        case .switchProject(let newProject):
            output.appendLine("Restart with: orbit chat \(newProject)")

        case .none:
            break
        }

        output.appendBlank()
        renderAll()
    }

    // MARK: - Save & Exit

    private func saveAndExit() async {
        if let store = memoryStore, !messages.isEmpty {
            let transcript = messages.map { "\($0.role.rawValue): \($0.textContent)" }.joined(separator: "\n")
            try? await store.storeTranscript(sessionID: session.sessionID, content: transcript, project: projectSlug)
        }
        try? sessionStore.save(session, project: projectSlug)
    }

    // MARK: - Rendering

    private func allocateRegions() {
        let (h, o, i) = screen.allocateRegions(headerHeight: 3, inputHeight: 2)
        headerRows = h
        outputRows = o
        inputRows = i
    }

    private func renderAll() {
        header.render(into: screen.buffer, rows: headerRows, width: screen.width)
        output.render(into: screen.buffer, rows: outputRows, width: screen.width)
        input.render(into: screen.buffer, rows: inputRows, width: screen.width)
    }

    private func renderHeader() {
        header.render(into: screen.buffer, rows: headerRows, width: screen.width)
    }

    private func renderOutput() {
        output.render(into: screen.buffer, rows: outputRows, width: screen.width)
        if autocomplete.isVisible {
            renderAutocomplete()
        }
    }

    private func renderInput() {
        input.render(into: screen.buffer, rows: inputRows, width: screen.width)
    }

    private func renderAutocomplete() {
        autocomplete.render(into: screen.buffer, bottomRow: outputRows.end - 1, width: screen.width)
    }
}
