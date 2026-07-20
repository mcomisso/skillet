import Foundation

struct BackupManifest: Codable, Sendable {
    struct Entry: Codable, Sendable, Hashable, Identifiable {
        var slug: String
        var name: String
        var rootKind: SkillRoot.Kind
        var originLabel: String
        var repository: String?
        var archivePath: String

        var id: String { archivePath }
    }

    var version: Int = 1
    var createdAt: Date
    var skillCount: Int
    var skills: [Entry]
}

struct RestorePreview: Sendable {
    var manifest: BackupManifest
    var stagingDirectory: URL
}

struct RestoreSummary: Sendable, Equatable {
    var restored: [String] = []
    var skipped: [String] = []
    var failed: [String] = []

    var message: String {
        var parts = ["\(restored.count) restored"]
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        return parts.joined(separator: ", ")
    }
}

/// Zip-archive backup and restore of skill directories, with a manifest
/// describing provenance. Archives are portable across machines.
struct BackupService: Sendable {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

    /// Exports `skills` into a zip at `destination`. Returns the number of
    /// skills archived.
    @discardableResult
    func export(skills: [Skill], to destination: URL) async throws -> Int {
        let staging = URL(filePath: NSTemporaryDirectory())
            .appending(path: "skillsmanager-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        var entries: [BackupManifest.Entry] = []
        for skill in skills {
            let archivePath = "skills/\(skill.root.kind.rawValue)/\(skill.slug)"
            let target = staging.appending(path: archivePath)
            try FileManager.default.createDirectory(
                at: target, withIntermediateDirectories: true
            )
            // Resolve symlinks so the archive carries real content.
            try SnapshotStore.copyContents(
                from: skill.resolvedURL, to: target, followSourceSymlinks: true
            )
            entries.append(BackupManifest.Entry(
                slug: skill.slug,
                name: skill.name,
                rootKind: skill.root.kind,
                originLabel: skill.origin.label,
                repository: skill.origin.repositoryURL,
                archivePath: archivePath
            ))
        }

        let manifest = BackupManifest(
            createdAt: Date(),
            skillCount: entries.count,
            skills: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appending(path: "manifest.json"))

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let result = try await ProcessRunner.run(
            "/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]
        )
        guard result.succeeded else {
            throw ProcessError.failed(
                command: "ditto", code: result.exitCode, stderr: result.stderr
            )
        }
        return entries.count
    }

    /// Unpacks an archive into a staging directory and reads its manifest.
    func inspect(archive: URL) async throws -> RestorePreview {
        let staging = URL(filePath: NSTemporaryDirectory())
            .appending(path: "skillsmanager-restore-\(UUID().uuidString)")
        let result = try await ProcessRunner.run(
            "/usr/bin/ditto",
            ["-x", "-k", archive.path, staging.path]
        )
        guard result.succeeded else {
            throw ProcessError.failed(
                command: "ditto", code: result.exitCode, stderr: result.stderr
            )
        }
        let manifestURL = staging.appending(path: "manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: data)
        return RestorePreview(manifest: manifest, stagingDirectory: staging)
    }

    /// Restores the selected entries into their roots. Plugin-bundled
    /// skills are restored into the Claude Code user root as plain copies.
    func restore(
        preview: RestorePreview,
        selection: Set<BackupManifest.Entry.ID>,
        overwriteExisting: Bool
    ) async -> RestoreSummary {
        var summary = RestoreSummary()
        let fm = FileManager.default

        for entry in preview.manifest.skills where selection.contains(entry.id) {
            let source = preview.stagingDirectory.appending(path: entry.archivePath)
            guard fm.fileExists(atPath: source.path) else {
                summary.failed.append("\(entry.slug): missing from archive")
                continue
            }
            let destination = destinationDirectory(for: entry)
            let exists = fm.fileExists(atPath: destination.path)
            if exists, !overwriteExisting {
                summary.skipped.append(entry.slug)
                continue
            }
            do {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                try SnapshotStore.copyContents(
                    from: source, to: destination, followSourceSymlinks: true
                )
                summary.restored.append(entry.slug)
            } catch {
                summary.failed.append("\(entry.slug): \(error.localizedDescription)")
            }
        }
        try? fm.removeItem(at: preview.stagingDirectory)
        return summary
    }

    func destinationDirectory(for entry: BackupManifest.Entry) -> URL {
        switch entry.rootKind {
        case .openskills:
            homeDirectory.appending(path: ".agents/skills/\(entry.slug)")
        case .codexUser:
            homeDirectory.appending(path: ".codex/skills/\(entry.slug)")
        case .claudeUser, .plugins, .project, .custom:
            homeDirectory.appending(path: ".claude/skills/\(entry.slug)")
        }
    }
}
