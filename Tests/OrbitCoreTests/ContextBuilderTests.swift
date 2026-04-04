import Foundation
import Testing
@testable import OrbitCore

@Suite("Context Builder")
struct ContextBuilderTests {
    let testDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbit-ctx-test-\(UUID().uuidString.prefix(8))")

    init() throws {
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    // MARK: - ORBIT.md Discovery

    @Test("Discovers ORBIT.md in current directory")
    func discoversOrbitMd() throws {
        try "Project instructions here.".write(
            to: testDir.appendingPathComponent("ORBIT.md"),
            atomically: true, encoding: .utf8
        )

        let files = ContextBuilder.discoverInstructionFiles(at: testDir)
        #expect(files.count == 1)
        #expect(files[0].content == "Project instructions here.")
    }

    @Test("Discovers ORBIT.md walking up directory tree")
    func discoversOrbitMdWalkingUp() throws {
        let subDir = testDir.appendingPathComponent("src/components")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        try "Root instructions.".write(
            to: testDir.appendingPathComponent("ORBIT.md"),
            atomically: true, encoding: .utf8
        )
        try "Component instructions.".write(
            to: subDir.appendingPathComponent("ORBIT.md"),
            atomically: true, encoding: .utf8
        )

        let files = ContextBuilder.discoverInstructionFiles(at: subDir, root: testDir)
        #expect(files.count == 2)
    }

    @Test("Returns empty when no ORBIT.md files exist")
    func noOrbitMd() throws {
        let emptyDir = testDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let files = ContextBuilder.discoverInstructionFiles(at: emptyDir, root: emptyDir)
        #expect(files.isEmpty)
    }

    // MARK: - Character Limits

    @Test("Truncates individual files to maxFileChars")
    func truncatesLargeFiles() throws {
        let longContent = String(repeating: "a", count: 6000) // > 4000 default limit
        try longContent.write(
            to: testDir.appendingPathComponent("ORBIT.md"),
            atomically: true, encoding: .utf8
        )

        let files = ContextBuilder.discoverInstructionFiles(at: testDir, maxFileChars: 4000)
        #expect(files[0].content.count <= 4000 + 50) // allow for truncation suffix
    }

    @Test("Respects total chars limit across all files")
    func totalCharsLimit() throws {
        let dir = testDir.appendingPathComponent("total-limit")
        let subDir = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let mediumContent = String(repeating: "b", count: 3000)
        try mediumContent.write(
            to: dir.appendingPathComponent("ORBIT.md"),
            atomically: true, encoding: .utf8
        )
        try mediumContent.write(
            to: subDir.appendingPathComponent("ORBIT.md"),
            atomically: true, encoding: .utf8
        )

        let files = ContextBuilder.discoverInstructionFiles(
            at: subDir,
            root: dir,
            maxFileChars: 4000,
            maxTotalChars: 5000
        )

        let totalChars = files.reduce(0) { $0 + $1.content.count }
        #expect(totalChars <= 5000)
    }

    // MARK: - Content Hash Deduplication

    @Test("Deduplicates identical content at different paths")
    func deduplicatesContent() throws {
        let dir = testDir.appendingPathComponent("dedup")
        let subDir = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let sameContent = "Identical instructions."
        try sameContent.write(
            to: dir.appendingPathComponent("ORBIT.md"),
            atomically: true, encoding: .utf8
        )
        try sameContent.write(
            to: subDir.appendingPathComponent("ORBIT.md"),
            atomically: true, encoding: .utf8
        )

        let files = ContextBuilder.discoverInstructionFiles(at: subDir, root: dir)
        #expect(files.count == 1) // Deduped to single entry
    }

    // MARK: - Context Assembly

    @Test("Assembles context with all sections in correct order")
    func assemblesContext() throws {
        try "Project-specific instructions.".write(
            to: testDir.appendingPathComponent("ORBIT.md"),
            atomically: true, encoding: .utf8
        )

        let builder = ContextBuilder(
            identity: "You are Orbit.",
            projectContext: ProjectContext(
                projectName: "TestProject",
                projectDescription: "A test.",
                instructionFiles: ContextBuilder.discoverInstructionFiles(at: testDir)
            ),
            memoryContext: "Memory: User prefers concise output.",
            currentDate: "2026-04-04"
        )

        let prompt = builder.build()

        // Check order: identity first
        let identityPos = prompt.range(of: "You are Orbit.")
        let instructionPos = prompt.range(of: "Project-specific instructions.")
        let memoryPos = prompt.range(of: "User prefers concise output.")
        let datePos = prompt.range(of: "2026-04-04")

        #expect(identityPos != nil)
        #expect(instructionPos != nil)
        #expect(memoryPos != nil)
        #expect(datePos != nil)

        // Identity should come before instructions
        if let ip = identityPos, let instp = instructionPos {
            #expect(ip.lowerBound < instp.lowerBound)
        }
    }

    @Test("Assembles context without optional sections")
    func assemblesMinimalContext() {
        let builder = ContextBuilder(
            identity: "You are Orbit.",
            projectContext: ProjectContext(projectName: "default"),
            currentDate: "2026-04-04"
        )

        let prompt = builder.build()
        #expect(prompt.contains("You are Orbit."))
        #expect(prompt.contains("2026-04-04"))
    }

    // MARK: - ContextFile

    @Test("ContextFile stores path and content")
    func contextFileBasics() {
        let file = ContextFile(
            path: URL(fileURLWithPath: "/test/ORBIT.md"),
            content: "Instructions."
        )
        #expect(file.content == "Instructions.")
    }
}
