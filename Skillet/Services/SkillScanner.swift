import Foundation

protocol SkillScanning: Sendable {
    /// Scans the standard roots plus `extraRoots` (project/custom locations).
    func scan(extraRoots: [SkillRoot]) async -> ScanSnapshot
}

/// Discovers installed skills across the supported ecosystems:
/// ~/.claude/skills (Claude Code user skills, including gstack-managed and
/// dev-symlinked ones), ~/.agents/skills (openskills), ~/.codex/skills, and
/// skills bundled inside installed Claude Code plugins.
struct SkillScanner: SkillScanning {
    var homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    func scan(extraRoots: [SkillRoot]) async -> ScanSnapshot {
        let home = homeDirectory
        let task = Task.detached(priority: .userInitiated) { () -> ScanSnapshot in
            var sections: [ScanSnapshot.Section] = []

            let claudeRoot = SkillRoot.claudeUser(home: home)
            sections.append(ScanSnapshot.Section(
                root: claudeRoot,
                skills: Self.scanDirectoryRoot(claudeRoot)
            ))

            let agentsRoot = SkillRoot.openskills(home: home)
            let lock = OpenSkillsLock.load(agentsDirectory: home.appending(path: ".agents"))
            sections.append(ScanSnapshot.Section(
                root: agentsRoot,
                skills: Self.scanDirectoryRoot(agentsRoot, lock: lock)
            ))

            // Codex can expose skills already installed in ~/.agents/skills
            // through symlinks. Keep the managed ~/.agents appearance so its
            // provenance/update metadata wins, and only show Codex-unique
            // physical directories in the Codex section.
            let existingDirectoryPaths = Set(
                sections.flatMap(\.skills).map(Self.canonicalDirectoryPath)
            )
            var seenDirectoryPaths = existingDirectoryPaths
            let codexRoot = SkillRoot.codexUser(home: home)
            let codexSkills = Self.scanDirectoryRoot(codexRoot).filter {
                seenDirectoryPaths.insert(Self.canonicalDirectoryPath($0)).inserted
            }
            sections.append(ScanSnapshot.Section(root: codexRoot, skills: codexSkills))

            let registry = PluginRegistry.load(
                pluginsDirectory: home.appending(path: ".claude/plugins")
            )

            let pluginsRoot = SkillRoot.plugins(home: home)
            sections.append(ScanSnapshot.Section(
                root: pluginsRoot,
                skills: Self.scanGlobalPlugins(root: pluginsRoot, registry: registry)
            ))

            sections.append(contentsOf: Self.scanProjects(home: home, registry: registry))

            for root in extraRoots {
                sections.append(ScanSnapshot.Section(
                    root: root,
                    skills: Self.scanDirectoryRoot(root)
                ))
            }

            return ScanSnapshot(sections: sections, scannedAt: Date())
        }
        return await task.value
    }

    // MARK: - Directory roots (one subdirectory per skill)

    private static func canonicalDirectoryPath(_ skill: Skill) -> String {
        skill.resolvedURL.standardizedFileURL.path
    }

    private static func scanDirectoryRoot(
        _ root: SkillRoot,
        lock: OpenSkillsLock? = nil
    ) -> [Skill] {
        let fm = FileManager()
        guard let entries = try? fm.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var skills: [Skill] = []
        for entry in entries {
            guard let skill = makeSkill(directory: entry, root: root, lock: lock, fm: fm) else {
                continue
            }
            skills.append(skill)
        }
        return skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func makeSkill(
        directory: URL,
        root: SkillRoot,
        lock: OpenSkillsLock?,
        fm: FileManager
    ) -> Skill? {
        let dirIsSymlink = isSymlink(directory, fm: fm)
        let resolvedDir = directory.resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolvedDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let skillFile = directory.appending(path: "SKILL.md")
        let skillFileIsSymlink = isSymlink(skillFile, fm: fm)
        let resolvedSkillFile = skillFile.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: resolvedSkillFile.path) else { return nil }

        let slug = directory.lastPathComponent
        let contents = (try? String(contentsOf: resolvedSkillFile, encoding: .utf8)) ?? ""
        let parsed = FrontmatterParser.parse(contents)

        let origin = detectOrigin(
            slug: slug,
            root: root,
            directory: directory,
            resolvedDir: resolvedDir,
            dirIsSymlink: dirIsSymlink,
            skillFileIsSymlink: skillFileIsSymlink,
            resolvedSkillFile: resolvedSkillFile,
            lock: lock,
            fm: fm
        )

        let stats = directoryStats(resolvedDir, fm: fm)
        let skillFileDate = (try? resolvedSkillFile.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        return Skill(
            slug: slug,
            name: parsed.fields["name"] ?? slug,
            description: parsed.fields["description"],
            frontmatter: parsed.fields,
            bodyPreview: String(parsed.body.prefix(300)),
            directoryURL: directory,
            resolvedURL: resolvedDir,
            skillFileURL: resolvedSkillFile,
            isSymlinked: dirIsSymlink || skillFileIsSymlink,
            origin: origin,
            root: root,
            fileCount: stats.count,
            totalSize: stats.size,
            modifiedAt: skillFileDate
        )
    }

    private static func detectOrigin(
        slug: String,
        root: SkillRoot,
        directory: URL,
        resolvedDir: URL,
        dirIsSymlink: Bool,
        skillFileIsSymlink: Bool,
        resolvedSkillFile: URL,
        lock: OpenSkillsLock?,
        fm: FileManager
    ) -> SkillOrigin {
        if root.kind == .openskills, let entry = lock?.skills[slug] {
            return .openskills(entry)
        }
        if dirIsSymlink {
            return .localDev(repoRoot: gitRoot(of: resolvedDir, fm: fm)?.path)
        }
        if skillFileIsSymlink {
            let targetDir = resolvedSkillFile.deletingLastPathComponent()
            // gstack publishes wrapper dirs whose SKILL.md links into a
            // bundle directory that lives alongside them in the same root.
            if targetDir.deletingLastPathComponent().path.hasPrefix(root.url.path) {
                return .gstack(bundlePath: targetDir.path)
            }
            return .localDev(repoRoot: gitRoot(of: targetDir, fm: fm)?.path)
        }
        return .unmanaged
    }

    // MARK: - Plugins

    /// Skills from user-scoped (globally enabled) plugin installs.
    private static func scanGlobalPlugins(root: SkillRoot, registry: PluginRegistry) -> [Skill] {
        var seenPaths = Set<String>()
        let installs = registry.installs.filter {
            $0.install.scope != "project" && seenPaths.insert($0.installPath).inserted
        }
        return pluginSkills(installs: installs, root: root)
    }

    private static func pluginSkills(
        installs: [PluginRegistry.PluginInstall],
        root: SkillRoot
    ) -> [Skill] {
        let fm = FileManager()
        var skills: [Skill] = []

        for install in installs {
            let skillsDir = URL(filePath: install.installPath).appending(path: "skills")
            guard let entries = try? fm.contentsOfDirectory(
                at: skillsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let provenance = PluginProvenance(
                pluginName: install.pluginName,
                marketplace: install.marketplace,
                version: install.install.version,
                scope: install.install.scope,
                projectPath: install.install.projectPath,
                installPath: install.installPath,
                gitCommitSha: install.install.gitCommitSha,
                marketplaceRepo: nil
            )

            for entry in entries {
                guard var skill = makeSkill(directory: entry, root: root, lock: nil, fm: fm) else {
                    continue
                }
                skill.origin = .plugin(provenance)
                // Disambiguate identically named skills across plugins.
                skill.name = skill.name == skill.slug
                    ? "\(install.pluginName):\(skill.slug)"
                    : skill.name
                skills.append(skill)
            }
        }
        return skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Projects

    /// One section per project that has project-local skills
    /// (`<project>/.claude/skills`) or project-scoped plugin installs.
    /// Candidate projects come from Claude Code's ~/.claude.json and the
    /// plugin registry; stale paths drop out via the existence checks.
    private static func scanProjects(home: URL, registry: PluginRegistry) -> [ScanSnapshot.Section] {
        let fm = FileManager()

        var candidates = Set<String>()
        if let data = try? Data(contentsOf: home.appending(path: ".claude.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = json["projects"] as? [String: Any] {
            candidates.formUnion(projects.keys)
        }
        let projectInstalls = registry.installs.filter {
            $0.install.scope == "project" && $0.install.projectPath != nil
        }
        candidates.formUnion(projectInstalls.compactMap(\.install.projectPath))

        var sections: [ScanSnapshot.Section] = []
        for projectPath in candidates.sorted() {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let projectURL = URL(filePath: projectPath)
            let root = SkillRoot(
                kind: .project,
                url: projectURL.appending(path: ".claude/skills"),
                name: projectURL.lastPathComponent
            )

            var skills = scanDirectoryRoot(root)
            let installs = projectInstalls.filter { $0.install.projectPath == projectPath }
            skills.append(contentsOf: pluginSkills(installs: installs, root: root))

            guard !skills.isEmpty else { continue }
            sections.append(ScanSnapshot.Section(
                root: root,
                skills: skills.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            ))
        }
        return sections
    }

    // MARK: - Filesystem helpers

    private static func isSymlink(_ url: URL, fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }

    /// Walks up from `url` looking for a .git entry; returns the repo root.
    static func gitRoot(of url: URL, fm: FileManager) -> URL? {
        var current = url
        while current.path != "/" {
            if fm.fileExists(atPath: current.appending(path: ".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    private static func directoryStats(_ url: URL, fm: FileManager) -> (count: Int, size: Int64) {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var count = 0
        var size: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            count += 1
            size += Int64(values.fileSize ?? 0)
        }
        return (count, size)
    }
}
