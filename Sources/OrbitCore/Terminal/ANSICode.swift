import Foundation

/// ANSI escape code helpers for terminal styling.
public enum ANSI {
    public static let escape = "\u{1B}["
    public static let reset = "\(escape)0m"

    // MARK: - Colors (Foreground)

    public static let black = "\(escape)30m"
    public static let red = "\(escape)31m"
    public static let green = "\(escape)32m"
    public static let yellow = "\(escape)33m"
    public static let blue = "\(escape)34m"
    public static let magenta = "\(escape)35m"
    public static let cyan = "\(escape)36m"
    public static let white = "\(escape)37m"
    public static let darkGray = "\(escape)90m"

    // MARK: - Styles

    public static let bold = "\(escape)1m"
    public static let dim = "\(escape)2m"
    public static let italic = "\(escape)3m"
    public static let underline = "\(escape)4m"
    public static let strikethrough = "\(escape)9m"

    // MARK: - Cursor Control

    public static let saveCursor = "\(escape)s"
    public static let restoreCursor = "\(escape)u"
    public static let clearLine = "\(escape)2K"
    public static let moveToColumn0 = "\(escape)0G"
    public static let moveUp = "\(escape)1A"

    // MARK: - Helpers

    public static func fg(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\(escape)38;2;\(r);\(g);\(b)m"
    }

    public static func bg(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\(escape)48;2;\(r);\(g);\(b)m"
    }

    public static func styled(_ text: String, _ codes: String...) -> String {
        codes.joined() + text + reset
    }

    public static func colored(_ text: String, _ color: String) -> String {
        color + text + reset
    }
}
