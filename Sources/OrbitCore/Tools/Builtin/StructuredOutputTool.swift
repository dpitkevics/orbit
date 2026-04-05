import Foundation

/// Return structured JSON data.
public struct StructuredOutputTool: Tool, Sendable {
    public let name = "structured_output"
    public let description = "Return structured data as JSON. Use when you need to produce machine-readable output."
    public let category: ToolCategory = .planning
    public let requiredPermission: PermissionMode = .readOnly

    public let inputSchema: JSONValue = .object([
        "type": "object",
        "properties": .object([
            "data": .object([
                "type": "object",
                "description": "The structured data to return as JSON.",
            ]),
            "format": .object([
                "type": "string",
                "description": "Output format hint: 'json' (default) or 'markdown_table'.",
            ]),
        ]),
        "required": .array(["data"]),
        "additionalProperties": false,
    ])

    public init() {}

    public func execute(input: JSONValue, context: ToolContext) async throws -> ToolResult {
        guard let data = input["data"] else {
            return .error("Missing required parameter: 'data'")
        }

        let format = input["format"]?.stringValue ?? "json"

        switch format {
        case "markdown_table":
            return .success(jsonToMarkdownTable(data))
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let jsonData = try? encoder.encode(data),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return .error("Failed to encode data as JSON.")
            }
            return .success(jsonString)
        }
    }

    private func jsonToMarkdownTable(_ value: JSONValue) -> String {
        guard case .array(let items) = value, let first = items.first,
              case .object(let firstObj) = first else {
            // Single object — format as key-value
            if case .object(let obj) = value {
                let lines = obj.sorted { $0.key < $1.key }.map { "| \($0.key) | \(formatValue($0.value)) |" }
                return "| Key | Value |\n|-----|-------|\n" + lines.joined(separator: "\n")
            }
            return "\(value)"
        }

        let keys = firstObj.keys.sorted()
        let header = "| " + keys.joined(separator: " | ") + " |"
        let separator = "|" + keys.map { _ in "---" }.joined(separator: "|") + "|"

        let rows = items.compactMap { item -> String? in
            guard case .object(let obj) = item else { return nil }
            let values = keys.map { formatValue(obj[$0] ?? .null) }
            return "| " + values.joined(separator: " | ") + " |"
        }

        return [header, separator].joined(separator: "\n") + "\n" + rows.joined(separator: "\n")
    }

    private func formatValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return "\(i)"
        case .double(let d): return String(format: "%.2f", d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "-"
        default: return "\(value)"
        }
    }
}
