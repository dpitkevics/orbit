import Foundation

/// Fetch a URL and return its text content.
public struct WebFetchTool: Tool, Sendable {
    public let name = "web_fetch"
    public let description = "Fetch a URL and return its content as text. Useful for reading web pages, APIs, or downloading data."
    public let category: ToolCategory = .network
    public let requiredPermission: PermissionMode = .readOnly

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "url": .object([
                "type": "string",
                "description": "The URL to fetch.",
            ]),
            "headers": .object([
                "type": "object",
                "description": "Optional HTTP headers as key-value pairs.",
            ]),
        ]),
        "required": .array(["url"]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let urlString = input["url"]?.stringValue else {
            return .error("Missing required parameter: 'url'")
        }

        guard let url = URL(string: urlString) else {
            return .error("Invalid URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Orbit/0.1.0", forHTTPHeaderField: "User-Agent")

        // Add custom headers
        if let headers = input["headers"]?.objectValue {
            for (key, value) in headers {
                if let v = value.stringValue {
                    request.setValue(v, forHTTPHeaderField: key)
                }
            }
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .error("Fetch failed: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .error("Invalid response type.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            return .error("HTTP \(httpResponse.statusCode): \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return .error("Response is not UTF-8 text (\(data.count) bytes).")
        }

        // Strip HTML tags for readability (simple approach)
        let cleaned = stripHTMLTags(text)

        // Truncate very large responses
        if cleaned.count > 50_000 {
            return .success(String(cleaned.prefix(50_000)) + "\n... (truncated, \(cleaned.count) total chars)")
        }

        return .success(cleaned)
    }

    private func stripHTMLTags(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return html }
        let range = NSRange(html.startIndex..., in: html)
        var result = regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        // Collapse whitespace
        if let wsRegex = try? NSRegularExpression(pattern: "\\s{3,}") {
            let resultRange = NSRange(result.startIndex..., in: result)
            result = wsRegex.stringByReplacingMatches(in: result, range: resultRange, withTemplate: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
