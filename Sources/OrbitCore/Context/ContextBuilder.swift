import Foundation
import Crypto

/// An instruction file discovered during context assembly.
public struct ContextFile: Sendable, Equatable {
    public let path: URL
    public let content: String

    public init(path: URL, content: String) {
        self.path = path
        self.content = content
    }
}

/// Project-specific context injected into the system prompt.
public struct ProjectContext: Sendable {
    public let projectName: String
    public let projectDescription: String
    public let instructionFiles: [ContextFile]

    public init(
        projectName: String,
        projectDescription: String = "",
        instructionFiles: [ContextFile] = []
    ) {
        self.projectName = projectName
        self.projectDescription = projectDescription
        self.instructionFiles = instructionFiles
    }
}

/// Assembles the system prompt from multiple context sources.
///
/// Assembly order (from Claw Code's `prompt.rs` pattern):
/// 1. Global identity
/// 2. Project context files
/// 3. ORBIT.md instruction files
/// 4. Skills (if any)
/// 5. Memory context (if any)
/// 6. Current date / activity
public struct ContextBuilder: Sendable {
    public static let defaultMaxFileChars = 4_000
    public static let defaultMaxTotalChars = 12_000

    private let identity: String
    private let projectContext: ProjectContext
    private let skillsContext: String?
    private let memoryContext: String?
    private let currentDate: String

    public init(
        identity: String,
        projectContext: ProjectContext,
        skillsContext: String? = nil,
        memoryContext: String? = nil,
        currentDate: String
    ) {
        self.identity = identity
        self.projectContext = projectContext
        self.skillsContext = skillsContext
        self.memoryContext = memoryContext
        self.currentDate = currentDate
    }

    /// Build the complete system prompt.
    public func build() -> String {
        var sections: [String] = []

        // 1. Global identity
        sections.append(identity)

        // 2. Project description
        if !projectContext.projectDescription.isEmpty {
            sections.append("# Project: \(projectContext.projectName)\n\(projectContext.projectDescription)")
        }

        // 3. Instruction files (ORBIT.md)
        for file in projectContext.instructionFiles {
            sections.append(file.content)
        }

        // 4. Skills
        if let skills = skillsContext, !skills.isEmpty {
            sections.append(skills)
        }

        // 5. Memory
        if let memory = memoryContext, !memory.isEmpty {
            sections.append(memory)
        }

        // 6. Date and environment
        sections.append("Today's date: \(currentDate).")

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Instruction File Discovery

    /// Discover ORBIT.md files by walking from `cwd` up to `root`.
    /// Applies per-file and total character limits, and deduplicates by content hash.
    public static func discoverInstructionFiles(
        at cwd: URL,
        root: URL? = nil,
        maxFileChars: Int = defaultMaxFileChars,
        maxTotalChars: Int = defaultMaxTotalChars
    ) -> [ContextFile] {
        let effectiveRoot = root ?? cwd
        var files: [ContextFile] = []
        var seenHashes: Set<String> = []
        var totalChars = 0

        // Walk from cwd up to root, collecting ORBIT.md files
        var paths: [URL] = []
        var current = cwd.standardizedFileURL
        let rootStd = effectiveRoot.standardizedFileURL

        while true {
            let candidate = current.appendingPathComponent("ORBIT.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                paths.append(candidate)
            }
            if current.path == rootStd.path { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break } // filesystem root
            current = parent
        }

        // Process in order from root → cwd (root files first)
        paths.reverse()

        for path in paths {
            guard totalChars < maxTotalChars else { break }

            guard let data = FileManager.default.contents(atPath: path.path),
                  let rawContent = String(data: data, encoding: .utf8) else {
                continue
            }

            // Content hash deduplication
            let hash = contentHash(rawContent)
            guard !seenHashes.contains(hash) else { continue }
            seenHashes.insert(hash)

            // Truncate to per-file limit
            var content = rawContent
            if content.count > maxFileChars {
                content = String(content.prefix(maxFileChars)) + "\n... (truncated)"
            }

            // Respect total limit
            let remaining = maxTotalChars - totalChars
            if content.count > remaining {
                content = String(content.prefix(remaining)) + "\n... (truncated)"
            }

            totalChars += content.count
            files.append(ContextFile(path: path, content: content))
        }

        return files
    }

    // MARK: - Helpers

    private static func contentHash(_ content: String) -> String {
        let digest = SHA256.hash(data: Data(content.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
