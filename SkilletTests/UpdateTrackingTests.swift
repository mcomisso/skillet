import Foundation
import Testing
@testable import Skillet

struct UpdateTrackingTests {
    @Test func upstreamReferenceUsesLockfileSourceAndSkillFolder() throws {
        let skill = makeOpenSkillsSkill(
            slug: "demo",
            sourceURL: "https://github.com/owner/repo.git",
            skillPath: "skills/demo/SKILL.md"
        )

        let reference = try #require(UpdateService.upstreamReference(for: skill))
        #expect(reference.source == "owner/repo")
        #expect(reference.cloneURL == "https://github.com/owner/repo.git")
        #expect(reference.relativePath == "skills/demo")
        #expect(UpdateService.isUpdatable(skill))
    }

    @Test func upstreamReferenceRequiresURLAndPath() {
        let missingURL = makeOpenSkillsSkill(
            slug: "demo",
            sourceURL: nil,
            skillPath: "skills/demo/SKILL.md"
        )
        let missingPath = makeOpenSkillsSkill(
            slug: "demo",
            sourceURL: "https://github.com/owner/repo.git",
            skillPath: nil
        )

        #expect(UpdateService.upstreamReference(for: missingURL) == nil)
        #expect(UpdateService.upstreamReference(for: missingPath) == nil)
        #expect(!UpdateService.isUpdatable(missingURL))
        #expect(!UpdateService.isUpdatable(missingPath))
    }

    @Test func updatePreferencesPersistLockAndIgnoredHead() throws {
        let suiteName = "SkilletTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences = SkillUpdatePreferences()
        preferences.setLocked(true, skillID: "root|/skills/demo")
        preferences.ignore(skillID: "root|/skills/other", headCommit: "abc123")
        preferences.save(defaults: defaults)

        let loaded = SkillUpdatePreferences.load(defaults: defaults)
        #expect(loaded.isLocked(skillID: "root|/skills/demo"))
        #expect(loaded.isIgnored(skillID: "root|/skills/other", headCommit: "abc123"))
        #expect(!loaded.isIgnored(skillID: "root|/skills/other", headCommit: "def456"))
    }

    @Test func updateStatusHonorsIgnoredHeadOnlyForChangedSkills() {
        let checkedAt = Date()
        let changed = SkillUpdateInfo(
            repository: "owner/repo",
            headCommit: "abc123",
            checkedAt: checkedAt,
            diffText: "diff --git a/SKILL.md b/SKILL.md\n"
        )
        let current = SkillUpdateInfo(
            repository: "owner/repo",
            headCommit: "abc123",
            checkedAt: checkedAt,
            diffText: ""
        )
        var preferences = SkillUpdatePreferences()

        #expect(AppFeature.updateStatus(
            for: changed,
            skillID: "skill",
            preferences: preferences
        ) == .available)

        preferences.ignore(skillID: "skill", headCommit: "abc123")
        #expect(AppFeature.updateStatus(
            for: changed,
            skillID: "skill",
            preferences: preferences
        ) == .ignored)
        #expect(AppFeature.updateStatus(
            for: current,
            skillID: "skill",
            preferences: preferences
        ) == .upToDate)
    }

    private func makeOpenSkillsSkill(
        slug: String,
        sourceURL: String?,
        skillPath: String?
    ) -> Skill {
        let home = URL(filePath: "/tmp/skillet-tests")
        let directory = home.appending(path: ".agents/skills/\(slug)")
        let entry = OpenSkillsLockEntry(
            source: "owner/repo",
            sourceType: "github",
            sourceUrl: sourceURL,
            skillPath: skillPath,
            skillFolderHash: nil,
            installedAt: nil,
            updatedAt: nil
        )

        return Skill(
            slug: slug,
            name: slug,
            description: nil,
            frontmatter: [:],
            bodyPreview: "",
            directoryURL: directory,
            resolvedURL: directory,
            skillFileURL: directory.appending(path: "SKILL.md"),
            isSymlinked: false,
            origin: .openskills(entry),
            root: .openskills(home: home),
            fileCount: 1,
            totalSize: 1,
            modifiedAt: nil
        )
    }
}
