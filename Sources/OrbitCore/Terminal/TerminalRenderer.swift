import Foundation

/// Renders markdown text as ANSI-colored terminal output.
///
/// Handles: headings, bold, italic, code blocks with language hints,
/// inline code, links, lists, blockquotes, tables, and horizontal rules.
public struct TerminalRenderer: Sendable {
    public let theme: ColorTheme
    public let width: Int

    public init(theme: ColorTheme = .default, width: Int = TerminalDetector.width) {
        self.theme = theme
        self.width = width
    }

    /// Render complete markdown to ANSI-styled string.
    public func render(_ markdown: String) -> String {
        var output = ""
        var inCodeBlock = false
        var codeBlockLang = ""
        var codeBuffer = ""

        for line in markdown.components(separatedBy: "\n") {
            // Code block fences
            if line.hasPrefix("```") {
                if inCodeBlock {
                    // Close code block
                    output += renderCodeBlock(code: codeBuffer, language: codeBlockLang)
                    codeBuffer = ""
                    codeBlockLang = ""
                    inCodeBlock = false
                } else {
                    // Open code block
                    codeBlockLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                if !codeBuffer.isEmpty { codeBuffer += "\n" }
                codeBuffer += line
                continue
            }

            output += renderLine(line) + "\n"
        }

        // Handle unclosed code block
        if inCodeBlock && !codeBuffer.isEmpty {
            output += renderCodeBlock(code: codeBuffer, language: codeBlockLang)
        }

        return output
    }

    // MARK: - Line Rendering

    private func renderLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Empty line
        if trimmed.isEmpty { return "" }

        // Horizontal rule
        if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && trimmed.count >= 3 {
            return theme.tableBorder + String(repeating: "─", count: min(width - 2, 60)) + ANSI.reset
        }

        // Headings
        if trimmed.hasPrefix("######") { return renderHeading(trimmed.dropFirst(6), level: 6) }
        if trimmed.hasPrefix("#####") { return renderHeading(trimmed.dropFirst(5), level: 5) }
        if trimmed.hasPrefix("####") { return renderHeading(trimmed.dropFirst(4), level: 4) }
        if trimmed.hasPrefix("###") { return renderHeading(trimmed.dropFirst(3), level: 3) }
        if trimmed.hasPrefix("##") { return renderHeading(trimmed.dropFirst(2), level: 2) }
        if trimmed.hasPrefix("#") { return renderHeading(trimmed.dropFirst(1), level: 1) }

        // Blockquote
        if trimmed.hasPrefix(">") {
            let content = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return "\(theme.quote)│ \(renderInlineStyles(content))\(ANSI.reset)"
        }

        // Unordered list
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            let content = String(trimmed.dropFirst(2))
            let indent = String(repeating: " ", count: line.count - line.drop(while: { $0 == " " }).count)
            return "\(indent)\(theme.listBullet)•\(ANSI.reset) \(renderInlineStyles(content))"
        }

        // Ordered list
        if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            let number = trimmed[match].trimmingCharacters(in: .whitespaces)
            let content = String(trimmed[match.upperBound...])
            return "\(theme.listBullet)\(number)\(ANSI.reset)\(renderInlineStyles(content))"
        }

        // Table row
        if trimmed.contains("|") && trimmed.hasPrefix("|") {
            return renderTableRow(trimmed)
        }

        // Regular paragraph
        return renderInlineStyles(trimmed)
    }

    // MARK: - Headings

    private func renderHeading(_ text: some StringProtocol, level: Int) -> String {
        let content = text.trimmingCharacters(in: .whitespaces)
        switch level {
        case 1: return "\(ANSI.bold)\(theme.heading)\(content)\(ANSI.reset)\n"
        case 2: return "\(ANSI.bold)\(theme.heading)\(content)\(ANSI.reset)"
        default: return "\(theme.heading)\(content)\(ANSI.reset)"
        }
    }

    // MARK: - Code Blocks

    private func renderCodeBlock(code: String, language: String) -> String {
        let langLabel = language.isEmpty ? "code" : language
        let border = theme.codeBlockBorder
        let topBorder = "\(border)┌─ \(langLabel) \(String(repeating: "─", count: max(0, 40 - langLabel.count)))\(ANSI.reset)\n"
        let bottomBorder = "\(border)└\(String(repeating: "─", count: 44))\(ANSI.reset)\n"

        var rendered = topBorder
        for line in code.components(separatedBy: "\n") {
            rendered += "\(border)│\(ANSI.reset) \(theme.inlineCode)\(line)\(ANSI.reset)\n"
        }
        rendered += bottomBorder
        return rendered
    }

    // MARK: - Tables

    private func renderTableRow(_ line: String) -> String {
        let cells = line.split(separator: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        // Check if it's a separator row (---, :--:, etc.)
        if cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" }) }) {
            return theme.tableBorder + String(repeating: "─", count: min(width - 2, 60)) + ANSI.reset
        }

        let rendered = cells.map { renderInlineStyles($0) }.joined(separator: " \(theme.tableBorder)│\(ANSI.reset) ")
        return "\(theme.tableBorder)│\(ANSI.reset) \(rendered) \(theme.tableBorder)│\(ANSI.reset)"
    }

    // MARK: - Inline Styles

    /// Render inline markdown: **bold**, *italic*, `code`, [links](url), ~~strikethrough~~.
    public func renderInlineStyles(_ text: String) -> String {
        var result = text

        // Bold: **text**
        result = applyPattern(result, pattern: #"\*\*(.+?)\*\*"#) { match in
            "\(ANSI.bold)\(theme.strong)\(match)\(ANSI.reset)"
        }

        // Italic: *text*
        result = applyPattern(result, pattern: #"\*(.+?)\*"#) { match in
            "\(ANSI.italic)\(theme.emphasis)\(match)\(ANSI.reset)"
        }

        // Strikethrough: ~~text~~
        result = applyPattern(result, pattern: #"~~(.+?)~~"#) { match in
            "\(ANSI.strikethrough)\(match)\(ANSI.reset)"
        }

        // Inline code: `code`
        result = applyPattern(result, pattern: #"`(.+?)`"#) { match in
            "\(theme.inlineCode)\(match)\(ANSI.reset)"
        }

        // Links: [text](url)
        result = applyPattern(result, pattern: #"\[(.+?)\]\((.+?)\)"#) { match in
            "\(theme.link)\(ANSI.underline)\(match)\(ANSI.reset)"
        }

        return result
    }

    private func applyPattern(_ text: String, pattern: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        // Process matches in reverse to preserve offsets
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: text),
                  let contentRange = Range(match.range(at: 1), in: text) else { continue }
            let content = String(text[contentRange])
            result.replaceSubrange(fullRange, with: transform(content))
        }

        return result
    }
}
