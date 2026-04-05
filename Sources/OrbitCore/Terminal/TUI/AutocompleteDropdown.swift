import Foundation

/// Live autocomplete dropdown that appears above the input area
/// when the user types `/`.
public struct AutocompleteDropdown: Sendable {
    public struct Item: Sendable {
        public let name: String
        public let description: String
    }

    public private(set) var isVisible: Bool = false
    public private(set) var items: [Item] = []
    public private(set) var filtered: [Item] = []
    public private(set) var selectedIndex: Int = 0
    private let maxVisible: Int = 8
    private let theme: ColorTheme

    public init(commands: [SlashCommand] = [], theme: ColorTheme = .default) {
        self.theme = theme
        self.items = commands.map { Item(name: "/\($0.name)", description: $0.description) }
    }

    // MARK: - Show/Hide

    /// Show the dropdown, filtering by the current input.
    public mutating func show(filter: String) {
        let lowerFilter = filter.lowercased()
        filtered = items.filter { $0.name.lowercased().hasPrefix(lowerFilter) }
        selectedIndex = 0
        isVisible = !filtered.isEmpty
    }

    /// Update the filter as the user types.
    public mutating func updateFilter(_ text: String) {
        let lowerFilter = text.lowercased()
        filtered = items.filter { $0.name.lowercased().hasPrefix(lowerFilter) }
        selectedIndex = min(selectedIndex, max(0, filtered.count - 1))
        isVisible = !filtered.isEmpty
    }

    /// Dismiss the dropdown.
    public mutating func dismiss() {
        isVisible = false
        selectedIndex = 0
    }

    // MARK: - Navigation

    public mutating func moveUp() {
        if selectedIndex > 0 { selectedIndex -= 1 }
    }

    public mutating func moveDown() {
        if selectedIndex < filtered.count - 1 { selectedIndex += 1 }
    }

    /// Get the selected item's name (for insertion).
    public func selectedItem() -> String? {
        guard isVisible, filtered.indices.contains(selectedIndex) else { return nil }
        return filtered[selectedIndex].name
    }

    // MARK: - Rendering

    /// Render the dropdown into the screen buffer as an overlay.
    /// Renders upward from `bottomRow`.
    public func render(into buffer: ScreenBuffer, bottomRow: Int, width: Int) {
        guard isVisible, !filtered.isEmpty else { return }

        let visibleCount = min(filtered.count, maxVisible)
        let startIndex = max(0, min(selectedIndex - maxVisible / 2, filtered.count - visibleCount))

        for i in 0..<visibleCount {
            let itemIndex = startIndex + i
            let item = filtered[itemIndex]
            let row = bottomRow - visibleCount + i

            guard row >= 0 else { continue }

            buffer.clearRow(row)

            let isSelected = itemIndex == selectedIndex
            let nameWidth = ANSI.visibleWidth(item.name)
            let descWidth = min(width - nameWidth - 5, item.description.count)
            let desc = descWidth > 0 ? String(item.description.prefix(descWidth)) : ""

            if isSelected {
                // Highlighted: white on blue
                let line = " \(item.name)  \(desc)"
                for (col, char) in line.enumerated() {
                    guard col < width else { break }
                    buffer.set(row: row, col: col, character: char, style: ANSI.fg(255, 255, 255) + ANSI.bg(60, 60, 180))
                }
                // Fill remaining width
                for col in ANSI.visibleWidth(line)..<width {
                    buffer.set(row: row, col: col, character: " ", style: ANSI.bg(60, 60, 180))
                }
            } else {
                let nameStyled = "\(ANSI.cyan)\(item.name)\(ANSI.reset)"
                let descStyled = "\(ANSI.dim)\(desc)\(ANSI.reset)"
                buffer.setStyledString(row: row, col: 0, text: " \(nameStyled)  \(descStyled)")
                // Dark background
                for col in 0..<width {
                    let cell = buffer.get(row: row, col: col)
                    if cell.style.isEmpty {
                        buffer.set(row: row, col: col, character: cell.character, style: ANSI.bg(30, 30, 30))
                    }
                }
            }
        }
    }
}
