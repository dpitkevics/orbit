import Foundation

/// Summary of a git commit.
public struct CommitSummary: Sendable {
    public let hash: String
    public let message: String
    public let author: String
    public let date: String

    public init(hash: String, message: String, author: String, date: String) {
        self.hash = hash
        self.message = message
        self.author = author
        self.date = date
    }
}

/// High-level view of a repository structure.
public struct RepoStructure: Sendable {
    public let topLevelDirs: [String]
    public let topLevelFiles: [String]
    public let totalFiles: Int
    public let languages: [String: Int] // extension → count

    public init(topLevelDirs: [String], topLevelFiles: [String], totalFiles: Int, languages: [String: Int]) {
        self.topLevelDirs = topLevelDirs
        self.topLevelFiles = topLevelFiles
        self.totalFiles = totalFiles
        self.languages = languages
    }
}

/// Read-only awareness of codebases — Orbit doesn't edit code,
/// but understands repo structure and recent activity.
public struct CodingAwareness: Sendable {

    /// Read recent git commits for a repository.
    public static func recentCommits(repo: URL, days: Int = 7, limit: Int = 20) -> [CommitSummary] {
        let sinceArg = "--since=\(days) days ago"
        let output = runGit(
            args: ["log", "--oneline", "--format=%H|%s|%an|%ad", "--date=short", sinceArg, "-n", "\(limit)"],
            at: repo
        )

        guard let output, !output.isEmpty else { return [] }

        return output.components(separatedBy: "\n").compactMap { line -> CommitSummary? in
            let parts = line.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count >= 4 else { return nil }
            return CommitSummary(hash: parts[0], message: parts[1], author: parts[2], date: parts[3])
        }
    }

    /// Get high-level repo structure.
    public static func repoStructure(repo: URL) -> RepoStructure {
        let fm = FileManager.default
        let contents: [String]
        do {
            contents = try fm.contentsOfDirectory(atPath: repo.path)
                .filter { !$0.hasPrefix(".") }
                .sorted()
        } catch {
            return RepoStructure(topLevelDirs: [], topLevelFiles: [], totalFiles: 0, languages: [:])
        }

        var dirs: [String] = []
        var files: [String] = []
        for item in contents {
            var isDir: ObjCBool = false
            let path = repo.appendingPathComponent(item).path
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                dirs.append(item)
            } else {
                files.append(item)
            }
        }

        // Count files by extension (using git ls-files if available)
        let gitFiles = runGit(args: ["ls-files"], at: repo)
        var languages: [String: Int] = [:]
        var totalFiles = 0
        if let gitFiles {
            let allFiles = gitFiles.components(separatedBy: "\n").filter { !$0.isEmpty }
            totalFiles = allFiles.count
            for file in allFiles {
                let ext = (file as NSString).pathExtension
                if !ext.isEmpty {
                    languages[ext, default: 0] += 1
                }
            }
        }

        return RepoStructure(
            topLevelDirs: dirs,
            topLevelFiles: files,
            totalFiles: totalFiles,
            languages: languages
        )
    }

    /// Read a specific file from a repo (for operational context).
    public static func readFile(path: String, repo: URL) -> String? {
        let fullPath = repo.appendingPathComponent(path).path
        return try? String(contentsOfFile: fullPath, encoding: .utf8)
    }

    /// Format commits as context string for the system prompt.
    public static func formatCommitsContext(commits: [CommitSummary]) -> String {
        guard !commits.isEmpty else { return "" }
        let lines = commits.prefix(10).map { "\($0.hash.prefix(7)) \($0.message) (\($0.author), \($0.date))" }
        return "Recent git activity:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Git Helpers

    private static func runGit(args: [String], at repo: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
