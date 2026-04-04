import Foundation

/// Resolve a path relative to a workspace root.
/// If the path is already absolute, returns it as-is.
func resolvePath(_ rawPath: String, workspace: URL) -> String {
    let expanded = (rawPath as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return expanded
    }
    return workspace.appendingPathComponent(rawPath).path
}

/// Shell-quote a string for safe use in shell commands.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Create a standard set of built-in tools.
public func builtinTools() -> [any Tool] {
    [
        BashTool(),
        FileReadTool(),
        FileWriteTool(),
        FileEditTool(),
        GlobSearchTool(),
        GrepSearchTool(),
    ]
}
