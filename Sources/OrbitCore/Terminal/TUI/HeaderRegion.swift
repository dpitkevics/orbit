import Foundation

/// Persistent header bar at the top of the TUI.
/// Shows project, model, provider, token usage, and cost.
public struct HeaderRegion: Sendable {
    public var projectName: String
    public var model: String
    public var provider: String
    public var sessionID: String
    public var tokenUsage: TokenUsage = .zero
    public var estimatedCost: CostEstimate?
    public var isStreaming: Bool = false

    private let theme: ColorTheme

    public init(
        projectName: String,
        model: String,
        provider: String,
        sessionID: String,
        theme: ColorTheme = .default
    ) {
        self.projectName = projectName
        self.model = model
        self.provider = provider
        self.sessionID = sessionID
        self.theme = theme
    }

    public mutating func updateUsage(_ usage: TokenUsage, cost: CostEstimate) {
        self.tokenUsage = usage
        self.estimatedCost = cost
    }

    public mutating func setStreaming(_ streaming: Bool) {
        self.isStreaming = streaming
    }

    /// Render header into the screen buffer.
    public func render(into buffer: ScreenBuffer, rows: RowRange, width: Int) {
        // Row 0: Project name (left) + Model/Provider (right)
        let leftText = " \(ANSI.bold)Orbit\(ANSI.reset) — \(projectName)"
        let rightText = "\(model) (\(provider)) "
        let row0 = rows.start

        buffer.clearRow(row0)
        buffer.setStyledString(row: row0, col: 0, text: leftText)
        let rightStart = max(0, width - ANSI.visibleWidth(rightText))
        buffer.setStyledString(row: row0, col: rightStart, text: rightText)

        // Row 1: Session + tokens + cost
        let row1 = rows.start + 1
        buffer.clearRow(row1)

        let sessionText = " \(ANSI.dim)Session:\(ANSI.reset) \(sessionID.prefix(8))"
        buffer.setStyledString(row: row1, col: 0, text: sessionText)

        var statusParts: [String] = []
        if tokenUsage.totalTokens > 0 {
            statusParts.append("\(tokenUsage.inputTokens)↑ \(tokenUsage.outputTokens)↓")
        }
        if let cost = estimatedCost {
            statusParts.append(cost.formattedUSD)
        }
        if isStreaming {
            statusParts.append("\(ANSI.blue)streaming...\(ANSI.reset)")
        }

        if !statusParts.isEmpty {
            let statusText = statusParts.joined(separator: " │ ") + " "
            let statusStart = max(0, width - ANSI.visibleWidth(statusText))
            buffer.setStyledString(row: row1, col: statusStart, text: statusText)
        }

        // Row 2: Separator line
        let row2 = rows.start + 2
        buffer.clearRow(row2)
        for col in 0..<width {
            buffer.set(row: row2, col: col, character: "─", style: ANSI.darkGray)
        }
    }
}
