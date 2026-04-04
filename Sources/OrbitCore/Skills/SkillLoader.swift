import Foundation

/// A loaded skill definition.
public struct Skill: Codable, Sendable {
    public let name: String
    public let description: String
    public let triggerPatterns: [String]
    public let content: String
    public let requiredMCPs: [String]
    public let requiredTools: [String]

    public init(
        name: String,
        description: String = "",
        triggerPatterns: [String] = [],
        content: String,
        requiredMCPs: [String] = [],
        requiredTools: [String] = []
    ) {
        self.name = name
        self.description = description
        self.triggerPatterns = triggerPatterns
        self.content = content
        self.requiredMCPs = requiredMCPs
        self.requiredTools = requiredTools
    }
}

/// Loads skill files from the skill directories.
///
/// Skills are organized as:
/// ```
/// ~/.orbit/skills/
/// ├── _global/           # Applies to all projects
/// │   └── brand-voice.md
/// └── {project}/
///     └── daily-brief.md
/// ```
///
/// Each skill is a markdown file. The first line starting with `# ` is the title.
/// YAML-style frontmatter (between `---` lines) can specify metadata.
public struct SkillLoader: Sendable {
    private let skillsDir: URL

    public init(skillsDir: URL? = nil) {
        self.skillsDir = skillsDir ?? ConfigLoader.orbitHome.appendingPathComponent("skills")
    }

    /// Load all skills for a project (global + project-specific).
    public func loadSkills(project: String) -> [Skill] {
        var skills: [Skill] = []
        skills.append(contentsOf: loadSkillsFromDir(skillsDir.appendingPathComponent("_global")))
        skills.append(contentsOf: loadSkillsFromDir(skillsDir.appendingPathComponent(project)))
        return skills
    }

    /// Load skills matching any of the given trigger patterns.
    public func matchSkills(project: String, query: String) -> [Skill] {
        let allSkills = loadSkills(project: project)
        let queryLower = query.lowercased()

        return allSkills.filter { skill in
            skill.triggerPatterns.contains { pattern in
                queryLower.contains(pattern.lowercased())
            }
        }
    }

    private func loadSkillsFromDir(_ dir: URL) -> [Skill] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        let files: [String]
        do {
            files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasSuffix(".md") }
                .sorted()
        } catch {
            return []
        }

        return files.compactMap { filename in
            let path = dir.appendingPathComponent(filename)
            guard let data = FileManager.default.contents(atPath: path.path),
                  let content = String(data: data, encoding: .utf8) else {
                return nil
            }

            return parseSkillFile(filename: filename, content: content)
        }
    }

    func parseSkillFile(filename: String, content: String) -> Skill {
        let name = String(filename.dropLast(3)) // Remove .md
        var body = content
        var description = ""
        var triggerPatterns: [String] = []
        var requiredMCPs: [String] = []
        var requiredTools: [String] = []

        // Parse YAML frontmatter if present
        if content.hasPrefix("---\n") {
            let parts = content.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 3 {
                let frontmatter = String(parts[1])
                body = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)

                for line in frontmatter.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("description:") {
                        description = trimmed.dropFirst("description:".count)
                            .trimmingCharacters(in: .whitespaces)
                    } else if trimmed.hasPrefix("triggers:") {
                        let val = trimmed.dropFirst("triggers:".count)
                            .trimmingCharacters(in: .whitespaces)
                        triggerPatterns = val.components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    } else if trimmed.hasPrefix("mcps:") {
                        let val = trimmed.dropFirst("mcps:".count)
                            .trimmingCharacters(in: .whitespaces)
                        requiredMCPs = val.components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    } else if trimmed.hasPrefix("tools:") {
                        let val = trimmed.dropFirst("tools:".count)
                            .trimmingCharacters(in: .whitespaces)
                        requiredTools = val.components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                }
            }
        }

        // If no description from frontmatter, use first heading
        if description.isEmpty {
            for line in body.components(separatedBy: "\n") {
                if line.hasPrefix("# ") {
                    description = String(line.dropFirst(2))
                    break
                }
            }
        }

        return Skill(
            name: name,
            description: description,
            triggerPatterns: triggerPatterns,
            content: body,
            requiredMCPs: requiredMCPs,
            requiredTools: requiredTools
        )
    }
}
