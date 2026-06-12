import Foundation

/// The customization memory: a shadow git repository in Application Support
/// that mirrors every indexed skill. Baselines are committed on first
/// sight; edits made through the app (or checkpointed manually) become
/// commits, so diffing, history, and restore all fall out of git.
actor SnapshotStore {
    private let git: GitService
    private let repositoryURL: URL
    private var isReady = false

    init(git: GitService, repositoryURL: URL? = nil) {
        self.git = git
        self.repositoryURL = repositoryURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Skillet/snapshots")
    }

    /// Stable mirror path of a skill inside the shadow repository.
    nonisolated static func mirrorPath(for skill: Skill) -> String {
        switch skill.origin {
        case .plugin(let provenance):
            return "plugins/\(sanitize(provenance.marketplace))/\(sanitize(provenance.pluginName))/\(sanitize(skill.slug))"
        default:
            switch skill.root.kind {
            case .claudeUser: return "claude/\(sanitize(skill.slug))"
            case .openskills: return "openskills/\(sanitize(skill.slug))"
            case .plugins: return "plugins/\(sanitize(skill.slug))"
            case .project, .custom:
                let rootKey = String(skill.root.url.path.hashValue.magnitude, radix: 36)
                return "custom/\(rootKey)/\(sanitize(skill.slug))"
            }
        }
    }

    private nonisolated static func sanitize(_ component: String) -> String {
        component.replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - Lifecycle

    func ensureReady() async throws {
        guard !isReady else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: repositoryURL.appending(path: ".git").path) {
            try fm.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
            try await git.initRepository(at: repositoryURL)
            try "Skillet snapshot repository.\n".write(
                to: repositoryURL.appending(path: "README.md"),
                atomically: true,
                encoding: .utf8
            )
            try await git.commitIfChanged(
                repository: repositoryURL,
                path: nil,
                message: "Initialize snapshot repository"
            )
        }
        isReady = true
    }

    /// Creates baseline snapshots for skills that have never been mirrored.
    func ensureBaselines(for skills: [Skill]) async {
        guard (try? await ensureReady()) != nil else { return }
        for skill in skills {
            let path = Self.mirrorPath(for: skill)
            let mirror = repositoryURL.appending(path: path)
            guard !FileManager.default.fileExists(atPath: mirror.path) else { continue }
            _ = try? await snapshot(skill: skill, message: "Baseline for \(skill.slug)")
        }
    }

    // MARK: - Snapshots

    /// Syncs the mirror with the live skill directory and commits when
    /// something changed. Returns true if a checkpoint was created.
    @discardableResult
    func snapshot(skill: Skill, message: String) async throws -> Bool {
        try await ensureReady()
        try syncMirror(of: skill)
        return try await git.commitIfChanged(
            repository: repositoryURL,
            path: Self.mirrorPath(for: skill),
            message: message
        )
    }

    /// Checkpoint history for a skill, newest first.
    func history(for skill: Skill) async -> [SnapshotCommit] {
        guard (try? await ensureReady()) != nil else { return [] }
        return (try? await git.log(
            repository: repositoryURL,
            path: Self.mirrorPath(for: skill)
        )) ?? []
    }

    /// Unified diff of the live skill directory vs the latest checkpoint.
    func workingDiff(for skill: Skill) async throws -> String {
        try await ensureReady()
        try syncMirror(of: skill)
        return try await git.diffWorkingTree(
            repository: repositoryURL,
            path: Self.mirrorPath(for: skill)
        )
    }

    /// Files changed in the live directory vs the latest checkpoint.
    func changedFiles(for skill: Skill) async throws -> [String] {
        try await ensureReady()
        try syncMirror(of: skill)
        let prefix = Self.mirrorPath(for: skill) + "/"
        return try await git.changedFiles(
            repository: repositoryURL,
            path: Self.mirrorPath(for: skill)
        ).map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
    }

    /// Diff between a checkpoint and the current live content.
    func diff(for skill: Skill, since commit: SnapshotCommit) async throws -> String {
        try await ensureReady()
        try syncMirror(of: skill)
        try await git.run(["add", "-A", "--", Self.mirrorPath(for: skill)], in: repositoryURL)
        let result = try await git.run(
            ["diff", "--cached", "--no-color", commit.hash, "--", Self.mirrorPath(for: skill)],
            in: repositoryURL
        )
        return result.stdout
    }

    /// Restores the live skill directory to its state at `commit`, then
    /// records the restore as a new checkpoint (history stays linear).
    func restore(skill: Skill, to commit: SnapshotCommit) async throws {
        try await ensureReady()
        let path = Self.mirrorPath(for: skill)
        try await git.checkout(repository: repositoryURL, commit: commit.hash, path: path)
        let mirror = repositoryURL.appending(path: path)
        try Self.copyContents(from: mirror, to: skill.resolvedURL, followSourceSymlinks: false)
        try await git.commitIfChanged(
            repository: repositoryURL,
            path: path,
            message: "Restore \(skill.slug) from \(commit.shortHash)"
        )
    }

    // MARK: - Mirror sync

    /// Replaces the mirror contents with the live skill directory.
    private func syncMirror(of skill: Skill) throws {
        let mirror = repositoryURL.appending(path: Self.mirrorPath(for: skill))
        let fm = FileManager.default
        if fm.fileExists(atPath: mirror.path) {
            try fm.removeItem(at: mirror)
        }
        try fm.createDirectory(at: mirror, withIntermediateDirectories: true)
        try Self.copyContents(from: skill.resolvedURL, to: mirror, followSourceSymlinks: true)
    }

    /// Recursive copy. Going live→mirror, symlinked files are resolved so
    /// the snapshot captures content (gstack skills symlink SKILL.md).
    /// Going mirror→live, an existing symlink at the destination is written
    /// through rather than replaced, preserving the link structure.
    static func copyContents(from source: URL, to destination: URL, followSourceSymlinks: Bool) throws {
        let fm = FileManager.default
        let skipped: Set<String> = [".git", ".DS_Store"]
        let entries = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // Remove destination entries that no longer exist in source
        // (write-through restores keep symlinks, so only prune real files).
        if let existing = try? fm.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) {
            let sourceNames = Set(entries.map(\.lastPathComponent))
            for entry in existing {
                let name = entry.lastPathComponent
                guard !skipped.contains(name), !sourceNames.contains(name) else { continue }
                let isLink = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                    .isSymbolicLink ?? false
                if !isLink {
                    try? fm.removeItem(at: entry)
                }
            }
        }

        for entry in entries {
            let name = entry.lastPathComponent
            guard !skipped.contains(name) else { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let target = destination.appending(path: name)
            let resolved = entry.resolvingSymlinksInPath()

            if values.isSymbolicLink == true, followSourceSymlinks {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    try copyContents(from: resolved, to: target, followSourceSymlinks: true)
                } else {
                    try replaceFile(at: target, withContentsOf: resolved)
                }
            } else if values.isDirectory == true,
                      values.isSymbolicLink != true || followSourceSymlinks {
                try copyContents(from: entry, to: target, followSourceSymlinks: followSourceSymlinks)
            } else {
                try replaceFile(at: target, withContentsOf: entry)
            }
        }
    }

    private static func replaceFile(at destination: URL, withContentsOf source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            // Write through file symlinks so gstack/dev links stay intact.
            let isLink = (try? fm.attributesOfItem(atPath: destination.path)[.type]
                as? FileAttributeType) == .typeSymbolicLink
            if isLink {
                let resolved = destination.resolvingSymlinksInPath()
                let data = try Data(contentsOf: source)
                try data.write(to: resolved, options: .atomic)
                return
            }
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }
}
