import Foundation

/// Multiplexes keyboard input, async stream events, resize signals,
/// and timer ticks into a single AsyncStream<TUIEvent>.
public final class EventLoop: @unchecked Sendable {
    private let screen: ScreenManager
    private let parser = InputParser()
    private var inputTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var continuation: AsyncStream<TUIEvent>.Continuation?

    public init(screen: ScreenManager) {
        self.screen = screen
    }

    /// Start the event loop. Returns a stream of TUI events.
    public func start() -> AsyncStream<TUIEvent> {
        AsyncStream { continuation in
            self.continuation = continuation

            // Install resize callback
            screen.onResize = { [weak self] width, height in
                self?.continuation?.yield(.resize(width: width, height: height))
            }

            // Keyboard input on a dedicated thread (blocking read)
            inputTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    guard let byte = self.screen.readByte() else {
                        self.continuation?.yield(.keyPress(KeyEvent(key: .ctrlD)))
                        break
                    }

                    let result = self.parser.parse(byte: byte) {
                        self.screen.readByte()
                    }

                    switch result {
                    case .key(let keyEvent):
                        // Ctrl+V: check clipboard for image
                        if keyEvent.key == .ctrlV {
                            if let imageBlock = self.readClipboardImage() {
                                self.continuation?.yield(.pasteImage(imageBlock))
                            } else if let text = self.readClipboardText() {
                                self.continuation?.yield(.paste(text))
                            }
                        } else {
                            self.continuation?.yield(.keyPress(keyEvent))
                        }
                    case .paste(let text):
                        self.continuation?.yield(.paste(text))
                    }
                }
            }

            // Timer for spinner animation (~80ms = 12.5 fps)
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    self?.continuation?.yield(.tick)
                }
            }

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    /// Attach a query engine stream to forward events.
    public func attachStream(_ stream: AsyncThrowingStream<TurnEvent, Error>) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            do {
                for try await event in stream {
                    self?.continuation?.yield(.streamEvent(event))
                }
            } catch {
                // Stream error — could yield an error event
            }
        }
    }

    /// Stop all event sources.
    public func stop() {
        inputTask?.cancel()
        streamTask?.cancel()
        timerTask?.cancel()
        continuation?.finish()
    }

    // MARK: - Clipboard

    private func readClipboardImage() -> ContentBlock? {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit_clip_\(ProcessInfo.processInfo.processIdentifier).png").path

        let script = """
        try
            set imgData to the clipboard as «class PNGf»
            set filePath to POSIX file "\(tempPath)"
            set fileRef to open for access filePath with write permission
            write imgData to fileRef
            close access fileRef
            return "ok"
        on error
            return "no"
        end try
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard output == "ok",
              let data = FileManager.default.contents(atPath: tempPath) else {
            return nil
        }
        try? FileManager.default.removeItem(atPath: tempPath)

        return .image(source: .base64(mediaType: "image/png", data: data.base64EncodedString()))
    }

    private func readClipboardText() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}
