import Foundation
import Testing
@testable import OrbitCore

@Suite("Built-in Tools")
struct BuiltinToolTests {
    let testDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbit-test-\(UUID().uuidString.prefix(8))")

    var context: ToolContext {
        ToolContext(
            workspaceRoot: testDir,
            project: "test",
            enforcer: PermissionEnforcer(
                policy: PermissionPolicy(activeMode: .dangerFullAccess),
                workspaceRoot: testDir.path
            )
        )
    }

    init() throws {
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    // MARK: - Bash Tool

    @Test("BashTool executes simple command")
    func bashBasic() async throws {
        let tool = BashTool()
        let result = try await tool.execute(
            input: .object(["command": "echo hello"]),
            context: context
        )
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(!result.isError)
    }

    @Test("BashTool reports non-zero exit code")
    func bashExitCode() async throws {
        let tool = BashTool()
        let result = try await tool.execute(
            input: .object(["command": "exit 42"]),
            context: context
        )
        #expect(result.isError)
        #expect(result.output.contains("Exit code 42"))
    }

    @Test("BashTool missing command parameter")
    func bashMissingCommand() async throws {
        let tool = BashTool()
        let result = try await tool.execute(
            input: .object([:]),
            context: context
        )
        #expect(result.isError)
        #expect(result.output.contains("command"))
    }

    @Test("BashTool metadata")
    func bashMetadata() {
        let tool = BashTool()
        #expect(tool.name == "bash")
        #expect(tool.category == .execution)
        #expect(tool.requiredPermission == .dangerFullAccess)
    }

    // MARK: - File Read Tool

    @Test("FileReadTool reads file with line numbers")
    func fileReadBasic() async throws {
        let filePath = testDir.appendingPathComponent("test_read.txt")
        try "line one\nline two\nline three".write(to: filePath, atomically: true, encoding: .utf8)

        let tool = FileReadTool()
        let result = try await tool.execute(
            input: .object(["path": .string(filePath.path)]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("1\tline one"))
        #expect(result.output.contains("2\tline two"))
    }

    @Test("FileReadTool with offset and limit")
    func fileReadOffsetLimit() async throws {
        let filePath = testDir.appendingPathComponent("test_offset.txt")
        try "a\nb\nc\nd\ne".write(to: filePath, atomically: true, encoding: .utf8)

        let tool = FileReadTool()
        let result = try await tool.execute(
            input: .object(["path": .string(filePath.path), "offset": 1, "limit": 2]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("2\tb"))
        #expect(result.output.contains("3\tc"))
        #expect(!result.output.contains("1\ta"))
    }

    @Test("FileReadTool file not found")
    func fileReadNotFound() async throws {
        let tool = FileReadTool()
        let result = try await tool.execute(
            input: .object(["path": "/nonexistent/file.txt"]),
            context: context
        )
        #expect(result.isError)
        #expect(result.output.contains("not found"))
    }

    @Test("FileReadTool metadata")
    func fileReadMetadata() {
        let tool = FileReadTool()
        #expect(tool.name == "file_read")
        #expect(tool.category == .fileIO)
        #expect(tool.requiredPermission == .readOnly)
    }

    // MARK: - File Write Tool

    @Test("FileWriteTool creates file")
    func fileWriteBasic() async throws {
        let filePath = testDir.appendingPathComponent("test_write.txt")

        let tool = FileWriteTool()
        let result = try await tool.execute(
            input: .object(["path": .string(filePath.path), "content": "hello world"]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("Wrote"))

        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "hello world")
    }

    @Test("FileWriteTool creates parent directories")
    func fileWriteCreatesParent() async throws {
        let filePath = testDir.appendingPathComponent("sub/dir/test.txt")

        let tool = FileWriteTool()
        let result = try await tool.execute(
            input: .object(["path": .string(filePath.path), "content": "nested"]),
            context: context
        )
        #expect(!result.isError)
        #expect(FileManager.default.fileExists(atPath: filePath.path))
    }

    @Test("FileWriteTool respects workspace boundaries")
    func fileWriteWorkspaceBoundary() async throws {
        let restrictedContext = ToolContext(
            workspaceRoot: testDir,
            project: "test",
            enforcer: PermissionEnforcer(
                policy: PermissionPolicy(activeMode: .workspaceWrite),
                workspaceRoot: testDir.path
            )
        )

        let tool = FileWriteTool()
        let result = try await tool.execute(
            input: .object(["path": "/tmp/outside_workspace.txt", "content": "test"]),
            context: restrictedContext
        )
        #expect(result.isError)
        #expect(result.output.contains("outside workspace"))
    }

    // MARK: - File Edit Tool

    @Test("FileEditTool replaces unique string")
    func fileEditBasic() async throws {
        let filePath = testDir.appendingPathComponent("test_edit.txt")
        try "hello world".write(to: filePath, atomically: true, encoding: .utf8)

        let tool = FileEditTool()
        let result = try await tool.execute(
            input: .object([
                "path": .string(filePath.path),
                "old_string": "world",
                "new_string": "orbit",
            ]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("Replaced 1"))

        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "hello orbit")
    }

    @Test("FileEditTool rejects ambiguous replacement")
    func fileEditAmbiguous() async throws {
        let filePath = testDir.appendingPathComponent("test_ambiguous.txt")
        try "aaa bbb aaa".write(to: filePath, atomically: true, encoding: .utf8)

        let tool = FileEditTool()
        let result = try await tool.execute(
            input: .object([
                "path": .string(filePath.path),
                "old_string": "aaa",
                "new_string": "xxx",
            ]),
            context: context
        )
        #expect(result.isError)
        #expect(result.output.contains("2 times"))
    }

    @Test("FileEditTool replace_all replaces multiple")
    func fileEditReplaceAll() async throws {
        let filePath = testDir.appendingPathComponent("test_replace_all.txt")
        try "aaa bbb aaa".write(to: filePath, atomically: true, encoding: .utf8)

        let tool = FileEditTool()
        let result = try await tool.execute(
            input: .object([
                "path": .string(filePath.path),
                "old_string": "aaa",
                "new_string": "xxx",
                "replace_all": true,
            ]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("Replaced 2"))

        let content = try String(contentsOf: filePath, encoding: .utf8)
        #expect(content == "xxx bbb xxx")
    }

    @Test("FileEditTool old_string not found")
    func fileEditNotFound() async throws {
        let filePath = testDir.appendingPathComponent("test_edit_nf.txt")
        try "hello".write(to: filePath, atomically: true, encoding: .utf8)

        let tool = FileEditTool()
        let result = try await tool.execute(
            input: .object([
                "path": .string(filePath.path),
                "old_string": "missing",
                "new_string": "xxx",
            ]),
            context: context
        )
        #expect(result.isError)
        #expect(result.output.contains("not found"))
    }

    @Test("FileEditTool rejects identical strings")
    func fileEditIdentical() async throws {
        let filePath = testDir.appendingPathComponent("test_edit_id.txt")
        try "hello".write(to: filePath, atomically: true, encoding: .utf8)

        let tool = FileEditTool()
        let result = try await tool.execute(
            input: .object([
                "path": .string(filePath.path),
                "old_string": "hello",
                "new_string": "hello",
            ]),
            context: context
        )
        #expect(result.isError)
        #expect(result.output.contains("identical"))
    }

    // MARK: - Glob Search Tool

    @Test("GlobSearchTool finds files")
    func globSearchBasic() async throws {
        try "test".write(
            to: testDir.appendingPathComponent("a.swift"),
            atomically: true, encoding: .utf8
        )
        try "test".write(
            to: testDir.appendingPathComponent("b.swift"),
            atomically: true, encoding: .utf8
        )
        try "test".write(
            to: testDir.appendingPathComponent("c.txt"),
            atomically: true, encoding: .utf8
        )

        let tool = GlobSearchTool()
        let result = try await tool.execute(
            input: .object(["pattern": "*.swift"]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("a.swift"))
        #expect(result.output.contains("b.swift"))
        #expect(!result.output.contains("c.txt"))
    }

    @Test("GlobSearchTool no matches")
    func globSearchNoMatches() async throws {
        let tool = GlobSearchTool()
        let result = try await tool.execute(
            input: .object(["pattern": "*.nonexistent"]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("No files found"))
    }

    @Test("GlobSearchTool metadata")
    func globSearchMetadata() {
        let tool = GlobSearchTool()
        #expect(tool.name == "glob_search")
        #expect(tool.category == .search)
        #expect(tool.requiredPermission == .readOnly)
    }

    // MARK: - Grep Search Tool

    @Test("GrepSearchTool finds matching content")
    func grepSearchBasic() async throws {
        try "line one\nfoo bar\nline three".write(
            to: testDir.appendingPathComponent("grep_test.txt"),
            atomically: true, encoding: .utf8
        )

        let tool = GrepSearchTool()
        let result = try await tool.execute(
            input: .object(["pattern": "foo"]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("foo bar"))
    }

    @Test("GrepSearchTool no matches")
    func grepSearchNoMatches() async throws {
        try "hello world".write(
            to: testDir.appendingPathComponent("grep_empty.txt"),
            atomically: true, encoding: .utf8
        )

        let tool = GrepSearchTool()
        let result = try await tool.execute(
            input: .object(["pattern": "zzz_nonexistent"]),
            context: context
        )
        #expect(!result.isError)
        #expect(result.output.contains("No matches"))
    }

    @Test("GrepSearchTool metadata")
    func grepSearchMetadata() {
        let tool = GrepSearchTool()
        #expect(tool.name == "grep_search")
        #expect(tool.category == .search)
        #expect(tool.requiredPermission == .readOnly)
    }

    // MARK: - builtinTools()

    @Test("builtinTools returns all 11 tools")
    func builtinToolsCount() {
        let tools = builtinTools()
        #expect(tools.count == 13)

        let names = Set(tools.map { $0.name })
        #expect(names.contains("bash"))
        #expect(names.contains("file_read"))
        #expect(names.contains("file_write"))
        #expect(names.contains("file_edit"))
        #expect(names.contains("glob_search"))
        #expect(names.contains("grep_search"))
        #expect(names.contains("web_fetch"))
        #expect(names.contains("web_search"))
        #expect(names.contains("git_log"))
        #expect(names.contains("structured_output"))
        #expect(names.contains("send_notification"))
    }
}
