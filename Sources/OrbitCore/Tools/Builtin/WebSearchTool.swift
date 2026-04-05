import Foundation

/// Search the web using a shell-based search approach.
/// Uses `curl` to query DuckDuckGo's HTML lite interface.
public struct WebSearchTool: Tool, Sendable {
    public let name = "web_search"
    public let description = "Search the web and return results. Returns titles, URLs, and snippets."
    public let category: ToolCategory = .network
    public let requiredPermission: PermissionMode = .readOnly

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "query": .object([
                "type": "string",
                "description": "The search query.",
            ]),
            "max_results": .object([
                "type": "integer",
                "description": "Maximum results to return (default: 5).",
                "minimum": 1,
            ]),
        ]),
        "required": .array(["query"]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let query = input["query"]?.stringValue else {
            return .error("Missing required parameter: 'query'")
        }

        let maxResults = input["max_results"]?.intValue ?? 5

        // Use DuckDuckGo HTML lite for no-JS search
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return .error("Cannot encode query.")
        }

        let urlString = "https://html.duckduckgo.com/html/?q=\(encodedQuery)"
        guard let url = URL(string: urlString) else {
            return .error("Invalid search URL.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Orbit/0.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .error("Search failed: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return .error("Search request failed.")
        }

        guard let html = String(data: data, encoding: .utf8) else {
            return .error("Cannot decode search results.")
        }

        let results = parseSearchResults(html: html, limit: maxResults)

        if results.isEmpty {
            return .success("No results found for '\(query)'.")
        }

        let formatted = results.enumerated().map { index, result in
            "\(index + 1). \(result.title)\n   \(result.url)\n   \(result.snippet)"
        }.joined(separator: "\n\n")

        return .success(formatted)
    }

    private struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    private func parseSearchResults(html: String, limit: Int) -> [SearchResult] {
        var results: [SearchResult] = []

        // Parse DuckDuckGo HTML lite results
        // Links are in <a class="result__a" href="...">Title</a>
        // Snippets are in <a class="result__snippet" ...>text</a>
        let linkPattern = try? NSRegularExpression(pattern: "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>([^<]+)</a>")
        let snippetPattern = try? NSRegularExpression(pattern: "<a[^>]*class=\"result__snippet\"[^>]*>([^<]+)</a>")

        let linkMatches = linkPattern?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []
        let snippetMatches = snippetPattern?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []

        for i in 0..<min(linkMatches.count, limit) {
            let linkMatch = linkMatches[i]
            guard let urlRange = Range(linkMatch.range(at: 1), in: html),
                  let titleRange = Range(linkMatch.range(at: 2), in: html) else { continue }

            var urlStr = String(html[urlRange])
            // DuckDuckGo wraps URLs in redirect — extract actual URL
            if urlStr.contains("uddg="), let decoded = urlStr.removingPercentEncoding {
                if let param = URLComponents(string: decoded)?.queryItems?.first(where: { $0.name == "uddg" })?.value {
                    urlStr = param
                }
            }

            let title = String(html[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            var snippet = ""

            if i < snippetMatches.count {
                let snippetMatch = snippetMatches[i]
                if let snippetRange = Range(snippetMatch.range(at: 1), in: html) {
                    snippet = String(html[snippetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            results.append(SearchResult(title: title, url: urlStr, snippet: snippet))
        }

        return results
    }
}
