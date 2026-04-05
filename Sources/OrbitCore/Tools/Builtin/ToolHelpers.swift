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

/// Create the standard set of built-in tools (without agent tool, which needs a provider).
public func builtinTools() -> [any Tool] {
    [
        BashTool(),
        FileReadTool(),
        FileWriteTool(),
        FileEditTool(),
        GlobSearchTool(),
        GrepSearchTool(),
        WebFetchTool(),
        WebSearchTool(),
        GitLogTool(),
        StructuredOutputTool(),
        SendNotificationTool(),
    ]
}

/// Create the full tool set including the agent tool (requires provider).
public func allTools(provider: any LLMProvider, policy: PermissionPolicy) -> [any Tool] {
    var tools = builtinTools()
    let agentToolPool = ToolPool(tools: builtinTools()) // agent gets basic tools
    tools.append(AgentTool(provider: provider, toolPool: agentToolPool, policy: policy))
    return tools
}
