import Foundation

/// What we know about a skill's upstream after refreshing its repository.
struct SkillUpdateInfo: Sendable, Equatable {
    var repository: String
    var headCommit: String
    var checkedAt: Date
    /// Unified diff local → upstream, with repo-relative paths.
    var diffText: String
    var hasChanges: Bool { !diffText.isEmpty }
}

/// The upstream source and in-repository folder for one installable skill.
struct SkillUpstreamReference: Identifiable, Sendable, Hashable {
    var source: String
    var cloneURL: String
    var relativePath: String

    var id: String { "\(source)|\(cloneURL)|\(relativePath)" }
}

/// Maintains shallow clones of upstream skill repositories under
/// Application Support, one per "owner/repo" source.
actor UpstreamCache {
    private let git: GitService
    private let rootURL: URL
    /// Sources refreshed during this app session (avoid refetching per skill).
    private var refreshedSources: Set<String> = []

    init(git: GitService, rootURL: URL? = nil) {
        self.git = git
        self.rootURL = rootURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Skillet/upstreams")
    }

    struct Checkout: Sendable {
        var repositoryURL: URL
        var headCommit: String
    }

    /// Clones or fast-forwards the cached checkout for a source.
    func checkout(source: String, cloneURL: String, forceRefresh: Bool = false) async throws -> Checkout {
        let directory = rootURL.appending(path: Self.directoryName(for: source))
        let fm = FileManager.default

        if fm.fileExists(atPath: directory.appending(path: ".git").path) {
            if forceRefresh || !refreshedSources.contains(source) {
                try await git.run(["fetch", "--depth", "1", "origin", "HEAD"], in: directory)
                try await git.run(["reset", "--hard", "FETCH_HEAD"], in: directory)
                refreshedSources.insert(source)
            }
        } else {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try? fm.removeItem(at: directory)
            try await git.run(
                ["clone", "--depth", "1", cloneURL, directory.path],
                in: nil
            )
            refreshedSources.insert(source)
        }

        let head = try await git.run(["rev-parse", "HEAD"], in: directory)
        return Checkout(
            repositoryURL: directory,
            headCommit: head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func directoryName(for source: String) -> String {
        source.replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: ":", with: "_")
    }
}

/// Update detection and application for skills with a known upstream
/// (currently openskills-managed skills, whose lockfile records the repo).
struct UpdateService: Sendable {
    var git: GitService
    var cache: UpstreamCache
    var snapshots: SnapshotStore

    /// The upstream directory a skill maps to, when its origin records one.
    static func upstreamRelativePath(for skill: Skill) -> String? {
        guard case .openskills(let entry) = skill.origin else { return nil }
        if let skillPath = entry.skillPath {
            // skillPath points at SKILL.md; the folder above it is the skill.
            return (skillPath as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Full upstream identity, when the skill origin has enough information
    /// to clone a source repository and find the skill folder inside it.
    static func upstreamReference(for skill: Skill) -> SkillUpstreamReference? {
        guard case .openskills(let entry) = skill.origin,
              let cloneURL = entry.sourceUrl,
              let relativePath = Self.upstreamRelativePath(for: skill) else { return nil }

        return SkillUpstreamReference(
            source: entry.source,
            cloneURL: cloneURL,
            relativePath: relativePath
        )
    }

    static func isUpdatable(_ skill: Skill) -> Bool {
        upstreamReference(for: skill) != nil
    }

    func isUpdatable(_ skill: Skill) -> Bool {
        Self.isUpdatable(skill)
    }

    /// Refreshes the upstream clone and diffs the local skill against it.
    func check(skill: Skill, forceRefresh: Bool = false) async throws -> SkillUpdateInfo? {
        guard let upstream = Self.upstreamReference(for: skill) else { return nil }

        let checkout = try await cache.checkout(
            source: upstream.source,
            cloneURL: upstream.cloneURL,
            forceRefresh: forceRefresh
        )
        let upstreamDir = Self.upstreamDirectory(
            checkout: checkout.repositoryURL,
            relativePath: upstream.relativePath
        )
        guard FileManager.default.fileExists(atPath: upstreamDir.path) else {
            throw ProcessError.failed(
                command: "update-check",
                code: 1,
                stderr: "Upstream repository no longer contains \(upstream.relativePath)"
            )
        }

        let diff = try await diffNoIndex(local: skill.resolvedURL, upstream: upstreamDir)
        return SkillUpdateInfo(
            repository: upstream.source,
            headCommit: checkout.headCommit,
            checkedAt: Date(),
            diffText: diff
        )
    }

    /// Overwrites the local skill with upstream content. The current state
    /// is checkpointed first, so customizations stay recoverable.
    func apply(skill: Skill) async throws {
        guard let upstream = Self.upstreamReference(for: skill) else {
            throw ProcessError.failed(
                command: "update-apply", code: 1,
                stderr: "This skill has no recorded upstream repository."
            )
        }
        try await snapshots.snapshot(skill: skill, message: "Before update of \(skill.slug)")
        let checkout = try await cache.checkout(
            source: upstream.source,
            cloneURL: upstream.cloneURL
        )
        let upstreamDir = Self.upstreamDirectory(
            checkout: checkout.repositoryURL,
            relativePath: upstream.relativePath
        )
        try SnapshotStore.copyContents(
            from: upstreamDir,
            to: skill.resolvedURL,
            followSourceSymlinks: true
        )
        try await snapshots.snapshot(
            skill: skill,
            message: "Update \(skill.slug) to \(String(checkout.headCommit.prefix(7)))"
        )
    }

    /// `git diff --no-index` between two directories, exit code 1 tolerated,
    /// absolute paths rewritten to repo-relative ones for display.
    private func diffNoIndex(local: URL, upstream: URL) async throws -> String {
        let result = try await ProcessRunner.run(
            git.executable,
            ["-c", "core.quotepath=false", "diff", "--no-color", "--no-index",
             local.path, upstream.path],
            currentDirectory: nil
        )
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw ProcessError.failed(
                command: "git diff --no-index",
                code: result.exitCode,
                stderr: result.stderr
            )
        }
        return result.stdout
            .replacingOccurrences(of: local.path + "/", with: "")
            .replacingOccurrences(of: upstream.path + "/", with: "")
    }

    private static func upstreamDirectory(checkout: URL, relativePath: String) -> URL {
        relativePath.isEmpty ? checkout : checkout.appending(path: relativePath)
    }
}
