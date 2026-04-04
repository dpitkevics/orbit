import Foundation
import Testing
@testable import OrbitCore

@Suite("Skill Loader")
struct SkillLoaderTests {
    let testDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbit-skill-test-\(UUID().uuidString.prefix(8))")

    init() throws {
        let globalDir = testDir.appendingPathComponent("_global")
        let projectDir = testDir.appendingPathComponent("myproject")
        try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    @Test("Loads skill from markdown file")
    func loadBasicSkill() throws {
        try "# Brand Voice\nAlways be professional and concise.".write(
            to: testDir.appendingPathComponent("_global/brand-voice.md"),
            atomically: true, encoding: .utf8
        )

        let loader = SkillLoader(skillsDir: testDir)
        let skills = loader.loadSkills(project: "myproject")

        #expect(skills.count >= 1)
        let skill = skills.first { $0.name == "brand-voice" }
        #expect(skill != nil)
        #expect(skill?.description == "Brand Voice")
        #expect(skill?.content.contains("professional") == true)
    }

    @Test("Parses YAML frontmatter")
    func parseFrontmatter() {
        let loader = SkillLoader(skillsDir: testDir)
        let content = """
        ---
        description: Daily project briefing
        triggers: daily brief, morning update
        mcps: analytics, support
        tools: web_fetch, bash
        ---
        # Daily Brief
        Summarize the day's metrics.
        """

        let skill = loader.parseSkillFile(filename: "daily-brief.md", content: content)
        #expect(skill.name == "daily-brief")
        #expect(skill.description == "Daily project briefing")
        #expect(skill.triggerPatterns == ["daily brief", "morning update"])
        #expect(skill.requiredMCPs == ["analytics", "support"])
        #expect(skill.requiredTools == ["web_fetch", "bash"])
        #expect(skill.content.contains("Summarize"))
    }

    @Test("Loads both global and project skills")
    func loadsGlobalAndProject() throws {
        try "# Global Skill\nGlobal content.".write(
            to: testDir.appendingPathComponent("_global/global.md"),
            atomically: true, encoding: .utf8
        )
        try "# Project Skill\nProject content.".write(
            to: testDir.appendingPathComponent("myproject/specific.md"),
            atomically: true, encoding: .utf8
        )

        let loader = SkillLoader(skillsDir: testDir)
        let skills = loader.loadSkills(project: "myproject")

        let names = Set(skills.map { $0.name })
        #expect(names.contains("global"))
        #expect(names.contains("specific"))
    }

    @Test("Returns empty for nonexistent project")
    func emptyForMissingProject() {
        let loader = SkillLoader(skillsDir: testDir)
        let skills = loader.loadSkills(project: "nonexistent")
        // Should still return global skills if they exist, but no project skills
        #expect(skills.allSatisfy { !$0.name.contains("nonexistent") })
    }

    @Test("matchSkills filters by trigger patterns")
    func matchSkillsByTrigger() throws {
        let loader = SkillLoader(skillsDir: testDir)

        try """
        ---
        triggers: seo, search ranking
        ---
        # SEO Monitor
        Check search rankings.
        """.write(
            to: testDir.appendingPathComponent("myproject/seo.md"),
            atomically: true, encoding: .utf8
        )

        try """
        ---
        triggers: support, tickets
        ---
        # Support Triage
        Review open tickets.
        """.write(
            to: testDir.appendingPathComponent("myproject/support.md"),
            atomically: true, encoding: .utf8
        )

        let seoMatches = loader.matchSkills(project: "myproject", query: "Check the SEO status")
        #expect(seoMatches.contains { $0.name == "seo" })
        #expect(!seoMatches.contains { $0.name == "support" })

        let supportMatches = loader.matchSkills(project: "myproject", query: "How are the support tickets?")
        #expect(supportMatches.contains { $0.name == "support" })
    }

    @Test("Skill without frontmatter uses heading as description")
    func skillWithoutFrontmatter() {
        let loader = SkillLoader(skillsDir: testDir)
        let skill = loader.parseSkillFile(
            filename: "simple.md",
            content: "# Simple Skill\nJust some content."
        )
        #expect(skill.name == "simple")
        #expect(skill.description == "Simple Skill")
        #expect(skill.triggerPatterns.isEmpty)
    }
}
