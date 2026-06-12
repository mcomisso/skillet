import Foundation
import Testing
@testable import SkillsManager

struct DiffParserTests {
    @Test func parsesModifiedFile() {
        let diff = """
        diff --git a/claude/x/SKILL.md b/claude/x/SKILL.md
        index 1111111..2222222 100644
        --- a/claude/x/SKILL.md
        +++ b/claude/x/SKILL.md
        @@ -1,3 +1,3 @@
         ---
        -name: old
        +name: new
         ---
        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 1)
        #expect(files[0].path == "claude/x/SKILL.md")
        #expect(files[0].kind == .modified)
        #expect(files[0].additions == 1)
        #expect(files[0].deletions == 1)
        let lines = files[0].hunks[0].lines
        #expect(lines.count == 4)
        #expect(lines[1].kind == .deletion)
        #expect(lines[1].oldNumber == 2)
        #expect(lines[2].kind == .addition)
        #expect(lines[2].newNumber == 2)
    }

    @Test func parsesNewFile() {
        let diff = """
        diff --git a/claude/x/extra.md b/claude/x/extra.md
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/claude/x/extra.md
        @@ -0,0 +1,2 @@
        +hello
        +world
        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 1)
        #expect(files[0].kind == .added)
        #expect(files[0].additions == 2)
    }
}

struct SnapshotStoreTests {
    private func makeSkill(home: URL, slug: String) throws -> Skill {
        let dir = home.appending(path: ".claude/skills/\(slug)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: \(slug)
        ---
        Original body
        """.write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return Skill(
            slug: slug,
            name: slug,
            description: nil,
            frontmatter: ["name": slug],
            bodyPreview: "",
            directoryURL: dir,
            resolvedURL: dir,
            skillFileURL: dir.appending(path: "SKILL.md"),
            isSymlinked: false,
            origin: .unmanaged,
            root: .claudeUser(home: home),
            fileCount: 1,
            totalSize: 10,
            modifiedAt: Date()
        )
    }

    @Test func snapshotDiffRestoreRoundtrip() async throws {
        let base = URL(filePath: NSTemporaryDirectory())
            .appending(path: "snapshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let store = SnapshotStore(
            git: GitService(),
            repositoryURL: base.appending(path: "repo")
        )
        let skill = try makeSkill(home: base, slug: "roundtrip")

        // Baseline.
        let createdBaseline = try await store.snapshot(skill: skill, message: "Baseline")
        #expect(createdBaseline)

        // No drift right after baseline.
        let cleanDiff = try await store.workingDiff(for: skill)
        #expect(cleanDiff.isEmpty)

        // Customize the skill on disk.
        try """
        ---
        name: roundtrip
        ---
        Customized body
        """.write(to: skill.skillFileURL, atomically: true, encoding: .utf8)

        let diff = try await store.workingDiff(for: skill)
        #expect(diff.contains("-Original body"))
        #expect(diff.contains("+Customized body"))

        // Checkpoint the customization.
        let checkpointed = try await store.snapshot(skill: skill, message: "Customized")
        #expect(checkpointed)

        let history = await store.history(for: skill)
        #expect(history.count == 2)
        #expect(history.first?.subject == "Customized")

        // Restore the baseline.
        let baseline = try #require(history.last)
        try await store.restore(skill: skill, to: baseline)
        let restored = try String(contentsOf: skill.skillFileURL, encoding: .utf8)
        #expect(restored.contains("Original body"))

        // The restore itself is recorded, keeping history linear.
        let afterRestore = await store.history(for: skill)
        #expect(afterRestore.count == 3)
    }

    @Test func snapshotResolvesSymlinkedSkillFiles() async throws {
        let base = URL(filePath: NSTemporaryDirectory())
            .appending(path: "snapshot-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default

        // gstack-style: wrapper dir with symlinked SKILL.md.
        let bundle = base.appending(path: "bundle")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "real content".write(
            to: bundle.appending(path: "SKILL.md"), atomically: true, encoding: .utf8
        )
        let wrapper = base.appending(path: ".claude/skills/wrapped")
        try fm.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: wrapper.appending(path: "SKILL.md"),
            withDestinationURL: bundle.appending(path: "SKILL.md")
        )

        let skill = Skill(
            slug: "wrapped",
            name: "wrapped",
            description: nil,
            frontmatter: [:],
            bodyPreview: "",
            directoryURL: wrapper,
            resolvedURL: wrapper,
            skillFileURL: bundle.appending(path: "SKILL.md"),
            isSymlinked: true,
            origin: .gstack(bundlePath: bundle.path),
            root: .claudeUser(home: base),
            fileCount: 1,
            totalSize: 12,
            modifiedAt: Date()
        )

        let store = SnapshotStore(
            git: GitService(),
            repositoryURL: base.appending(path: "repo")
        )
        try await store.snapshot(skill: skill, message: "Baseline")

        // The mirror must contain content, not a symlink.
        let mirrored = base.appending(path: "repo/claude/wrapped/SKILL.md")
        let attributes = try fm.attributesOfItem(atPath: mirrored.path)
        let fileType = attributes[.type] as? FileAttributeType
        #expect(fileType == FileAttributeType.typeRegular)
        #expect(try String(contentsOf: mirrored, encoding: .utf8) == "real content")
    }
}
