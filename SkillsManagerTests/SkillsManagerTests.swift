import Foundation
import Testing
@testable import SkillsManager

// MARK: - FrontmatterParser

struct FrontmatterParserTests {
    @Test func parsesSimpleFields() {
        let result = FrontmatterParser.parse("""
        ---
        name: my-skill
        description: Does useful things
        ---
        # Body
        Hello
        """)
        #expect(result.fields["name"] == "my-skill")
        #expect(result.fields["description"] == "Does useful things")
        #expect(result.body.hasPrefix("# Body"))
    }

    @Test func parsesQuotedAndNestedFields() {
        let result = FrontmatterParser.parse("""
        ---
        name: "quoted-name"
        metadata:
          type: project
          author: 'someone'
        ---
        body
        """)
        #expect(result.fields["name"] == "quoted-name")
        #expect(result.fields["metadata.type"] == "project")
        #expect(result.fields["metadata.author"] == "someone")
    }

    @Test func parsesFoldedBlockScalar() {
        let result = FrontmatterParser.parse("""
        ---
        description: >-
          Line one
          line two
        name: x
        ---
        """)
        #expect(result.fields["description"] == "Line one line two")
        #expect(result.fields["name"] == "x")
    }

    @Test func parsesLists() {
        let result = FrontmatterParser.parse("""
        ---
        allowed-tools: [Bash, Read]
        tags:
          - swift
          - macos
        ---
        """)
        #expect(result.fields["allowed-tools"] == "Bash, Read")
        #expect(result.fields["tags"] == "swift, macos")
    }

    @Test func handlesMissingFrontmatter() {
        let result = FrontmatterParser.parse("# Just a body")
        #expect(result.fields.isEmpty)
        #expect(result.body == "# Just a body")
    }
}

// MARK: - SkillScanner

struct SkillScannerTests {
    /// Builds a fake home directory with all three ecosystems populated.
    private func makeFixtureHome() throws -> URL {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "skillsmanager-tests-\(UUID().uuidString)")
        let fm = FileManager.default

        // Claude user skill (plain dir).
        let plain = home.appending(path: ".claude/skills/plain-skill")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        try """
        ---
        name: plain-skill
        description: A plain one
        ---
        Body here
        """.write(to: plain.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        // gstack-style: bundle dir + wrapper with symlinked SKILL.md.
        let bundle = home.appending(path: ".claude/skills/gstack/wrapped")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try """
        ---
        name: wrapped
        description: Managed by gstack
        ---
        """.write(to: bundle.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let wrapper = home.appending(path: ".claude/skills/wrapped")
        try fm.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: wrapper.appending(path: "SKILL.md"),
            withDestinationURL: bundle.appending(path: "SKILL.md")
        )

        // Dev symlink: skill dir is a symlink into a git checkout.
        let checkout = home.appending(path: "Developer/Skills/dev-skill")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: home.appending(path: "Developer/Skills/.git"),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: dev-skill
        ---
        """.write(to: checkout.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            at: home.appending(path: ".claude/skills/dev-skill"),
            withDestinationURL: checkout
        )

        // openskills skill + lock entry.
        let agents = home.appending(path: ".agents/skills/locked-skill")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try """
        ---
        name: locked-skill
        description: From a repo
        ---
        """.write(to: agents.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try """
        {
          "version": 3,
          "skills": {
            "locked-skill": {
              "source": "owner/repo",
              "sourceType": "github",
              "sourceUrl": "https://github.com/owner/repo.git",
              "skillPath": "skills/locked-skill/SKILL.md",
              "skillFolderHash": "abc123"
            }
          }
        }
        """.write(to: home.appending(path: ".agents/.skill-lock.json"), atomically: true, encoding: .utf8)

        // Plugin with one skill: enabled globally and in one project.
        let pluginInstall = home.appending(path: ".claude/plugins/cache/mp/coolplugin/1.0.0")
        let pluginSkill = pluginInstall.appending(path: "skills/cool-skill")
        try fm.createDirectory(at: pluginSkill, withIntermediateDirectories: true)
        try """
        ---
        name: cool-skill
        ---
        """.write(to: pluginSkill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        // A project with a local skill, registered in ~/.claude.json.
        let project = home.appending(path: "Developer/my-project")
        let projectSkill = project.appending(path: ".claude/skills/proj-skill")
        try fm.createDirectory(at: projectSkill, withIntermediateDirectories: true)
        try """
        ---
        name: proj-skill
        description: Project-only skill
        ---
        """.write(to: projectSkill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try """
        { "projects": { "\(project.path)": {}, "/nonexistent/gone": {} } }
        """.write(to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)

        try """
        {
          "version": 2,
          "plugins": {
            "coolplugin@mp": [
              { "scope": "user", "installPath": "\(pluginInstall.path)", "version": "1.0.0" },
              { "scope": "project", "projectPath": "\(project.path)", "installPath": "\(pluginInstall.path)", "version": "1.0.0" }
            ]
          }
        }
        """.write(
            to: home.appending(path: ".claude/plugins/installed_plugins.json"),
            atomically: true, encoding: .utf8
        )

        return home
    }

    @Test func scansAllEcosystems() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let snapshot = await SkillScanner(homeDirectory: home).scan(extraRoots: [])

        let claude = try #require(snapshot.sections.first { $0.root.kind == .claudeUser })
        #expect(claude.skills.count == 3)

        let plain = try #require(claude.skills.first { $0.slug == "plain-skill" })
        #expect(plain.origin == .unmanaged)
        #expect(plain.description == "A plain one")
        #expect(!plain.isSymlinked)

        let wrapped = try #require(claude.skills.first { $0.slug == "wrapped" })
        if case .gstack = wrapped.origin {} else {
            Issue.record("expected gstack origin, got \(wrapped.origin)")
        }
        #expect(wrapped.isSymlinked)

        let dev = try #require(claude.skills.first { $0.slug == "dev-skill" })
        if case .localDev(let repo) = dev.origin {
            #expect(repo?.hasSuffix("Developer/Skills") == true)
        } else {
            Issue.record("expected localDev origin, got \(dev.origin)")
        }

        let agents = try #require(snapshot.sections.first { $0.root.kind == .openskills })
        let locked = try #require(agents.skills.first { $0.slug == "locked-skill" })
        if case .openskills(let entry) = locked.origin {
            #expect(entry.sourceUrl == "https://github.com/owner/repo.git")
            #expect(entry.skillFolderHash == "abc123")
        } else {
            Issue.record("expected openskills origin, got \(locked.origin)")
        }

        let plugins = try #require(snapshot.sections.first { $0.root.kind == .plugins })
        let cool = try #require(plugins.skills.first { $0.slug == "cool-skill" })
        if case .plugin(let provenance) = cool.origin {
            #expect(provenance.pluginName == "coolplugin")
            #expect(provenance.marketplace == "mp")
        } else {
            Issue.record("expected plugin origin, got \(cool.origin)")
        }
    }

    @Test func groupsProjectSkills() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let snapshot = await SkillScanner(homeDirectory: home).scan(extraRoots: [])

        // Exactly one project section: the dead path from .claude.json is
        // skipped, the live project has a local skill + a plugin skill.
        let projects = snapshot.sections.filter { $0.root.kind == .project }
        #expect(projects.count == 1)
        let section = try #require(projects.first)
        #expect(section.root.name == "my-project")
        #expect(section.root.projectDirectory?.lastPathComponent == "my-project")

        let local = try #require(section.skills.first { $0.slug == "proj-skill" })
        #expect(local.description == "Project-only skill")

        let viaPlugin = try #require(section.skills.first { $0.slug == "cool-skill" })
        if case .plugin(let provenance) = viaPlugin.origin {
            #expect(provenance.projectPath?.hasSuffix("my-project") == true)
        } else {
            Issue.record("expected plugin origin, got \(viaPlugin.origin)")
        }

        // The same physical plugin skill appears globally and in the
        // project with distinct ids.
        let global = try #require(
            snapshot.sections.first { $0.root.kind == .plugins }?
                .skills.first { $0.slug == "cool-skill" }
        )
        #expect(global.id != viaPlugin.id)
        let allIDs = snapshot.allSkills.map(\.id)
        #expect(Set(allIDs).count == allIDs.count)
    }

    @Test func ignoresDirectoriesWithoutSkillFile() async throws {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "skillsmanager-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appending(path: ".claude/skills/not-a-skill"),
            withIntermediateDirectories: true
        )

        let snapshot = await SkillScanner(homeDirectory: home).scan(extraRoots: [])
        let claude = snapshot.sections.first { $0.root.kind == .claudeUser }
        #expect(claude?.skills.isEmpty == true)
    }
}
