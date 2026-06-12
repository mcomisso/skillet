import Foundation

/// One snapshot checkpoint of a skill in the shadow repository.
struct SnapshotCommit: Identifiable, Hashable, Sendable {
    var hash: String
    var date: Date
    var subject: String

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
}

/// Thin async wrapper over the system git binary.
struct GitService: Sendable {
    var executable: String = "/usr/bin/git"

    @discardableResult
    func run(_ arguments: [String], in repository: URL?) async throws -> ProcessResult {
        let result = try await ProcessRunner.run(
            executable,
            arguments,
            currentDirectory: repository,
            environment: [
                // Keep the shadow repo deterministic and independent of the
                // user's git identity/config.
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_TERMINAL_PROMPT": "0",
            ]
        )
        guard result.succeeded else {
            throw ProcessError.failed(
                command: "git " + arguments.joined(separator: " "),
                code: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result
    }

    func isAvailable() async -> Bool {
        (try? await run(["--version"], in: nil)) != nil
    }

    /// Initializes a repository with snapshot-friendly local identity.
    func initRepository(at url: URL) async throws {
        try await run(["init", "--initial-branch=main", url.path], in: nil)
        try await run(["config", "user.name", "Skillet"], in: url)
        try await run(["config", "user.email", "skillet@local"], in: url)
        try await run(["config", "commit.gpgsign", "false"], in: url)
    }

    /// Stages `path` (or everything) and commits if anything changed.
    /// Returns true when a commit was created.
    @discardableResult
    func commitIfChanged(repository: URL, path: String?, message: String) async throws -> Bool {
        try await run(["add", "-A", "--", path ?? "."], in: repository)
        let status = try await run(
            ["status", "--porcelain", "--", path ?? "."],
            in: repository
        )
        guard !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        try await run(["commit", "-m", message, "--", path ?? "."], in: repository)
        return true
    }

    func log(repository: URL, path: String?) async throws -> [SnapshotCommit] {
        var arguments = ["log", "--format=%H%x09%ct%x09%s"]
        if let path {
            arguments += ["--", path]
        }
        guard let result = try? await run(arguments, in: repository) else {
            return [] // No commits yet.
        }
        return result.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let timestamp = TimeInterval(parts[1]) else { return nil }
            return SnapshotCommit(
                hash: String(parts[0]),
                date: Date(timeIntervalSince1970: timestamp),
                subject: String(parts[2])
            )
        }
    }

    /// Unified diff of the working tree (including staged/new files) vs HEAD.
    func diffWorkingTree(repository: URL, path: String?) async throws -> String {
        try await run(["add", "-A", "--", path ?? "."], in: repository)
        let result = try await run(
            ["diff", "--cached", "--no-color", "HEAD", "--"] + (path.map { [$0] } ?? ["."]),
            in: repository
        )
        return result.stdout
    }

    /// Unified diff between two commits limited to `path`.
    func diff(repository: URL, from: String, to: String, path: String?) async throws -> String {
        let result = try await run(
            ["diff", "--no-color", from, to, "--"] + (path.map { [$0] } ?? ["."]),
            in: repository
        )
        return result.stdout
    }

    /// Files changed in the working tree relative to HEAD, porcelain format.
    func changedFiles(repository: URL, path: String?) async throws -> [String] {
        try await run(["add", "-A", "--", path ?? "."], in: repository)
        let result = try await run(
            ["status", "--porcelain", "--", path ?? "."],
            in: repository
        )
        return result.stdout.split(separator: "\n").map {
            String($0.dropFirst(3))
        }
    }

    /// Restores `path` in the working tree to its content at `commit`.
    func checkout(repository: URL, commit: String, path: String) async throws {
        // Clear current state first so files added after `commit` disappear.
        try await run(["rm", "-r", "-f", "--ignore-unmatch", "--cached", "--", path], in: repository)
        let workingPath = repository.appending(path: path)
        if FileManager.default.fileExists(atPath: workingPath.path) {
            try FileManager.default.removeItem(at: workingPath)
        }
        try await run(["checkout", commit, "--", path], in: repository)
    }
}
