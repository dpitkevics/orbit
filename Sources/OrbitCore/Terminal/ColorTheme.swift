import Foundation

/// Terminal color theme matching Claw Code's aesthetic.
public struct ColorTheme: Sendable {
    public let heading: String
    public let emphasis: String
    public let strong: String
    public let inlineCode: String
    public let codeBlockBorder: String
    public let link: String
    public let quote: String
    public let tableBorder: String
    public let listBullet: String
    public let spinnerActive: String
    public let spinnerDone: String
    public let spinnerFailed: String
    public let toolName: String
    public let prompt: String
    public let dim: String

    public init(
        heading: String = ANSI.cyan,
        emphasis: String = ANSI.magenta,
        strong: String = ANSI.yellow,
        inlineCode: String = ANSI.green,
        codeBlockBorder: String = ANSI.darkGray,
        link: String = ANSI.blue,
        quote: String = ANSI.darkGray,
        tableBorder: String = ANSI.darkGray,
        listBullet: String = ANSI.cyan,
        spinnerActive: String = ANSI.blue,
        spinnerDone: String = ANSI.green,
        spinnerFailed: String = ANSI.red,
        toolName: String = ANSI.cyan,
        prompt: String = ANSI.green,
        dim: String = ANSI.dim
    ) {
        self.heading = heading
        self.emphasis = emphasis
        self.strong = strong
        self.inlineCode = inlineCode
        self.codeBlockBorder = codeBlockBorder
        self.link = link
        self.quote = quote
        self.tableBorder = tableBorder
        self.listBullet = listBullet
        self.spinnerActive = spinnerActive
        self.spinnerDone = spinnerDone
        self.spinnerFailed = spinnerFailed
        self.toolName = toolName
        self.prompt = prompt
        self.dim = dim
    }

    /// Default theme.
    public static let `default` = ColorTheme()
}
