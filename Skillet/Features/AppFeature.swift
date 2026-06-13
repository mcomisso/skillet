import Foundation

/// Sidebar entries: the aggregate view plus one entry per scanned root.
enum SidebarItem: Hashable, Sendable {
    case all
    case root(String)
}

struct SkillUpdateRecord: Identifiable, Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case available
        case ignored
        case upToDate
        case locked
        case failed(String)
    }

    var id: Skill.ID { skillID }
    var skillID: Skill.ID
    var upstreamID: SkillUpstreamReference.ID?
    var repository: String?
    var headCommit: String?
    var checkedAt: Date?
    var status: Status

    var countsInBadge: Bool {
        status == .available
    }

    var canApply: Bool {
        status == .available
    }

    init(
        skillID: Skill.ID,
        upstreamID: SkillUpstreamReference.ID?,
        info: SkillUpdateInfo,
        status: Status
    ) {
        self.skillID = skillID
        self.upstreamID = upstreamID
        self.repository = info.repository
        self.headCommit = info.headCommit
        self.checkedAt = info.checkedAt
        self.status = status
    }

    static func locked(skill: Skill) -> SkillUpdateRecord {
        SkillUpdateRecord(
            skillID: skill.id,
            upstreamID: UpdateService.upstreamReference(for: skill)?.id,
            repository: skill.origin.repositoryURL,
            headCommit: nil,
            checkedAt: nil,
            status: .locked
        )
    }

    static func failed(skill: Skill, error: Error) -> SkillUpdateRecord {
        SkillUpdateRecord(
            skillID: skill.id,
            upstreamID: UpdateService.upstreamReference(for: skill)?.id,
            repository: skill.origin.repositoryURL,
            headCommit: nil,
            checkedAt: Date(),
            status: .failed(error.localizedDescription)
        )
    }

    private init(
        skillID: Skill.ID,
        upstreamID: SkillUpstreamReference.ID?,
        repository: String?,
        headCommit: String?,
        checkedAt: Date?,
        status: Status
    ) {
        self.skillID = skillID
        self.upstreamID = upstreamID
        self.repository = repository
        self.headCommit = headCommit
        self.checkedAt = checkedAt
        self.status = status
    }
}

protocol AppFeatureDependencies: Sendable {
    var scanner: any SkillScanning { get }
    var snapshots: SnapshotStore { get }
    var updates: UpdateService { get }
    var backups: BackupService { get }
}

extension AppDependencies: AppFeatureDependencies {}

struct AppFeature: Feature {
    struct State: Sendable {
        var snapshot = ScanSnapshot()
        var isScanning = false
        var sidebarSelection: SidebarItem? = .all
        var selectedSkillID: Skill.ID?
        var searchText = ""
        var extraRoots: [SkillRoot] = []
        var updateRecords: [Skill.ID: SkillUpdateRecord] = [:]
        var updatesAvailable: Set<Skill.ID> = []
        var updatePreferences = SkillUpdatePreferences()
        var updateBadgeCount = 0
        var isCheckingUpdates = false
        var isApplyingAllUpdates = false
        var updateCheckSummary: String?
        var backup = BackupState()
    }

    struct BackupState: Sendable {
        var isWorking = false
        var statusMessage: String?
        var errorMessage: String?
        var restorePreview: RestorePreview?
        var restoreSelection: Set<BackupManifest.Entry.ID> = []
        var restoreOverwrite = false
    }

    enum Action: Sendable {
        case task
        case refresh
        case sidebarSelected(SidebarItem?)
        case skillSelected(Skill.ID?)
        case searchChanged(String)
        case checkAllUpdates
        case applyAllUpdates
        case ignoreUpdate(Skill.ID)
        case showIgnoredUpdate(Skill.ID)
        case setUpdateChecksLocked(Skill.ID, Bool)
        case skillCreated(path: String)
        case deleteSkill(Skill.ID)
        // Backup / restore
        case backup(to: URL)
        case restoreInspect(archive: URL)
        case restoreSelectionChanged(Set<BackupManifest.Entry.ID>)
        case restoreOverwriteChanged(Bool)
        case restoreConfirmed
        case restoreCancelled
        case backupStatusDismissed
    }

    typealias Dependencies = AppFeatureDependencies

    @MainActor
    func handle(state: Mutable<State>, action: Action, dependencies: Dependencies) async {
        switch action {
        case .task:
            guard state.snapshot.scannedAt == .distantPast else { return }
            state.updatePreferences = SkillUpdatePreferences.load()
            await rescan(state: state, dependencies: dependencies)
            await checkAllUpdates(state: state, dependencies: dependencies)

        case .refresh:
            await rescan(state: state, dependencies: dependencies)

        case .sidebarSelected(let item):
            state.sidebarSelection = item
            // Drop the skill selection when it falls outside the new scope.
            if let id = state.selectedSkillID,
               let skill = state.snapshot.skill(id: id),
               !Self.scopeContains(item, skill: skill) {
                state.selectedSkillID = nil
            }

        case .skillSelected(let id):
            state.selectedSkillID = id

        case .searchChanged(let text):
            state.searchText = text

        case .checkAllUpdates:
            await checkAllUpdates(state: state, dependencies: dependencies)

        case .applyAllUpdates:
            await applyAllUpdates(state: state, dependencies: dependencies)

        case .ignoreUpdate(let id):
            guard var record = state.updateRecords[id],
                  record.status == .available,
                  let headCommit = record.headCommit else { return }
            state.updatePreferences.ignore(skillID: id, headCommit: headCommit)
            state.updatePreferences.save()
            record.status = .ignored
            state.updateRecords[id] = record
            Self.syncUpdateDerivedState(state)

        case .showIgnoredUpdate(let id):
            state.updatePreferences.clearIgnored(skillID: id)
            state.updatePreferences.save()
            if var record = state.updateRecords[id], record.status == .ignored {
                record.status = .available
                state.updateRecords[id] = record
            }
            Self.syncUpdateDerivedState(state)

        case .setUpdateChecksLocked(let id, let locked):
            state.updatePreferences.setLocked(locked, skillID: id)
            state.updatePreferences.clearIgnored(skillID: id)
            state.updatePreferences.save()
            if locked, let skill = state.snapshot.skill(id: id) {
                state.updateRecords[id] = .locked(skill: skill)
            } else {
                state.updateRecords.removeValue(forKey: id)
            }
            Self.syncUpdateDerivedState(state)

        case .deleteSkill(let id):
            guard let skill = state.snapshot.skill(id: id) else { return }
            // Checkpoint first so an accidental delete is recoverable even
            // after the Trash is emptied.
            _ = try? await dependencies.snapshots.snapshot(
                skill: skill,
                message: "Before delete of \(skill.slug)"
            )
            do {
                // Trashing the entry as found removes a symlink without
                // touching the dev checkout it points to.
                try FileManager.default.trashItem(
                    at: skill.directoryURL, resultingItemURL: nil
                )
                if state.selectedSkillID == id {
                    state.selectedSkillID = nil
                }
                await rescan(state: state, dependencies: dependencies)
            } catch {
                state.backup.errorMessage = "Delete failed: \(error.localizedDescription)"
            }

        case .skillCreated(let path):
            await rescan(state: state, dependencies: dependencies)
            if let skill = state.snapshot.allSkills.first(where: { $0.directoryURL.path == path }) {
                state.sidebarSelection = .root(skill.root.id)
                state.selectedSkillID = skill.id
            }

        case .backup(let destination):
            guard !state.backup.isWorking else { return }
            state.backup.isWorking = true
            state.backup.errorMessage = nil
            do {
                let count = try await dependencies.backups.export(
                    skills: state.snapshot.allSkills,
                    to: destination
                )
                state.backup.statusMessage = "Backed up \(count) skills to \(destination.lastPathComponent)"
            } catch {
                state.backup.errorMessage = error.localizedDescription
            }
            state.backup.isWorking = false

        case .restoreInspect(let archive):
            guard !state.backup.isWorking else { return }
            state.backup.isWorking = true
            state.backup.errorMessage = nil
            do {
                let preview = try await dependencies.backups.inspect(archive: archive)
                state.backup.restorePreview = preview
                // Preselect entries whose target directory doesn't exist yet.
                let backups = dependencies.backups
                state.backup.restoreSelection = Set(
                    preview.manifest.skills
                        .filter {
                            !FileManager.default.fileExists(
                                atPath: backups.destinationDirectory(for: $0).path
                            )
                        }
                        .map(\.id)
                )
                state.backup.restoreOverwrite = false
            } catch {
                state.backup.errorMessage = "Could not read backup: \(error.localizedDescription)"
            }
            state.backup.isWorking = false

        case .restoreSelectionChanged(let selection):
            state.backup.restoreSelection = selection

        case .restoreOverwriteChanged(let overwrite):
            state.backup.restoreOverwrite = overwrite

        case .restoreConfirmed:
            guard let preview = state.backup.restorePreview, !state.backup.isWorking else { return }
            state.backup.isWorking = true
            let summary = await dependencies.backups.restore(
                preview: preview,
                selection: state.backup.restoreSelection,
                overwriteExisting: state.backup.restoreOverwrite
            )
            state.backup.restorePreview = nil
            state.backup.statusMessage = "Restore finished: \(summary.message)"
            state.backup.isWorking = false
            await rescan(state: state, dependencies: dependencies)

        case .restoreCancelled:
            if let preview = state.backup.restorePreview {
                try? FileManager.default.removeItem(at: preview.stagingDirectory)
            }
            state.backup.restorePreview = nil

        case .backupStatusDismissed:
            state.backup.statusMessage = nil
            state.backup.errorMessage = nil
        }
    }

    static let customRootsDefaultsKey = "customSkillRoots"

    private struct UpdateCheckGroupKey: Hashable {
        var upstreamID: SkillUpstreamReference.ID
        var resolvedPath: String
    }

    private struct UpdateCheckGroup {
        var key: UpdateCheckGroupKey
        var skills: [Skill]

        var representative: Skill {
            skills[0]
        }
    }

    @MainActor
    private func checkAllUpdates(
        state: Mutable<State>,
        dependencies: Dependencies
    ) async {
        guard !state.isCheckingUpdates, !state.isApplyingAllUpdates else { return }
        state.isCheckingUpdates = true
        state.updateCheckSummary = nil

        let skills = state.snapshot.allSkills
        pruneUpdateRecords(state: state, installedSkills: skills)

        let updatableSkills = skills.filter { dependencies.updates.isUpdatable($0) }
        var records = state.updateRecords
        let lockedSkills = updatableSkills.filter {
            state.updatePreferences.isLocked(skillID: $0.id)
        }
        for skill in lockedSkills {
            records[skill.id] = .locked(skill: skill)
        }

        var checked = 0
        var failures = 0
        let groups = Self.updateCheckGroups(
            skills: updatableSkills,
            preferences: state.updatePreferences
        )

        for group in groups {
            do {
                if let info = try await dependencies.updates.check(skill: group.representative) {
                    for skill in group.skills {
                        let status = Self.updateStatus(
                            for: info,
                            skillID: skill.id,
                            preferences: state.updatePreferences
                        )
                        records[skill.id] = SkillUpdateRecord(
                            skillID: skill.id,
                            upstreamID: group.key.upstreamID,
                            info: info,
                            status: status
                        )
                    }
                    checked += group.skills.count
                }
            } catch {
                failures += group.skills.count
                for skill in group.skills {
                    records[skill.id] = .failed(skill: skill, error: error)
                }
            }
        }

        state.updateRecords = records
        Self.syncUpdateDerivedState(state)
        state.updateCheckSummary = Self.updateCheckSummary(
            checked: checked,
            available: state.updatesAvailable.count,
            ignored: state.updateRecords.values.filter { $0.status == .ignored }.count,
            locked: lockedSkills.count,
            failures: failures
        )
        state.isCheckingUpdates = false
    }

    @MainActor
    private func applyAllUpdates(
        state: Mutable<State>,
        dependencies: Dependencies
    ) async {
        guard !state.isApplyingAllUpdates, !state.isCheckingUpdates else { return }
        let targets = state.snapshot.allSkills.filter { skill in
            state.updateRecords[skill.id]?.canApply == true
                && !state.updatePreferences.isLocked(skillID: skill.id)
        }
        guard !targets.isEmpty else { return }

        state.isApplyingAllUpdates = true
        state.updateCheckSummary = nil
        var applied = 0
        var failures = 0

        for skill in targets {
            do {
                try await dependencies.updates.apply(skill: skill)
                applied += 1
                state.updatePreferences.clearIgnored(skillID: skill.id)
                if var record = state.updateRecords[skill.id] {
                    record.status = .upToDate
                    record.checkedAt = Date()
                    state.updateRecords[skill.id] = record
                }
                Self.syncUpdateDerivedState(state)
            } catch {
                failures += 1
                state.updateRecords[skill.id] = .failed(skill: skill, error: error)
                Self.syncUpdateDerivedState(state)
            }
        }

        state.updatePreferences.save()
        state.updateCheckSummary = failures > 0
            ? "Updated \(applied), \(failures) failed"
            : "Updated \(applied) skills"

        if applied > 0 {
            await rescan(state: state, dependencies: dependencies)
        }
        state.isApplyingAllUpdates = false
    }

    @MainActor
    private func rescan(state: Mutable<State>, dependencies: Dependencies) async {
        guard !state.isScanning else { return }
        state.isScanning = true
        state.extraRoots = (UserDefaults.standard
            .stringArray(forKey: Self.customRootsDefaultsKey) ?? [])
            .map { path in
                SkillRoot(
                    kind: .custom,
                    url: URL(filePath: (path as NSString).expandingTildeInPath),
                    name: (path as NSString).lastPathComponent
                )
            }
        let snapshot = await dependencies.scanner.scan(extraRoots: state.extraRoots)
        state.snapshot = snapshot
        pruneUpdateRecords(state: state, installedSkills: snapshot.allSkills)
        if state.snapshot.skill(id: state.selectedSkillID) == nil {
            state.selectedSkillID = nil
        }
        state.isScanning = false
        // Give every indexed skill a baseline checkpoint so later diffs and
        // restores have something to compare against.
        await dependencies.snapshots.ensureBaselines(for: snapshot.allSkills)
    }

    @MainActor
    private func pruneUpdateRecords(state: Mutable<State>, installedSkills: [Skill]) {
        let updatableIDs = Set(
            installedSkills
                .filter(UpdateService.isUpdatable)
                .map(\.id)
        )
        state.updateRecords = state.updateRecords.filter { updatableIDs.contains($0.key) }
        Self.syncUpdateDerivedState(state)
    }

    static func scopeContains(_ item: SidebarItem?, skill: Skill) -> Bool {
        switch item {
        case .all, .none: true
        case .root(let id): skill.root.id == id
        }
    }

    static func updateStatus(
        for info: SkillUpdateInfo,
        skillID: Skill.ID,
        preferences: SkillUpdatePreferences
    ) -> SkillUpdateRecord.Status {
        guard info.hasChanges else { return .upToDate }
        if preferences.isIgnored(skillID: skillID, headCommit: info.headCommit) {
            return .ignored
        }
        return .available
    }

    private static func updateCheckGroups(
        skills: [Skill],
        preferences: SkillUpdatePreferences
    ) -> [UpdateCheckGroup] {
        var groups: [UpdateCheckGroupKey: [Skill]] = [:]
        var orderedKeys: [UpdateCheckGroupKey] = []

        for skill in skills where !preferences.isLocked(skillID: skill.id) {
            guard let upstream = UpdateService.upstreamReference(for: skill) else { continue }
            let key = UpdateCheckGroupKey(
                upstreamID: upstream.id,
                resolvedPath: skill.resolvedURL.path
            )
            if groups[key] == nil {
                orderedKeys.append(key)
                groups[key] = []
            }
            groups[key]?.append(skill)
        }

        return orderedKeys.compactMap { key in
            guard let skills = groups[key], !skills.isEmpty else { return nil }
            return UpdateCheckGroup(key: key, skills: skills)
        }
    }

    @MainActor
    private static func syncUpdateDerivedState(_ state: Mutable<State>) {
        let available = state.updateRecords.values.filter(\.countsInBadge)
        state.updatesAvailable = Set(available.map(\.skillID))
        state.updateBadgeCount = available.count
    }

    private static func updateCheckSummary(
        checked: Int,
        available: Int,
        ignored: Int,
        locked: Int,
        failures: Int
    ) -> String {
        var parts = ["\(checked) checked", "\(available) available"]
        if ignored > 0 {
            parts.append("\(ignored) ignored")
        }
        if locked > 0 {
            parts.append("\(locked) locked")
        }
        if failures > 0 {
            parts.append("\(failures) failed")
        }
        return parts.joined(separator: ", ")
    }

    /// Pure list filter — called from views with the stored fields they
    /// already read, so observation stays granular.
    static func filteredSkills(
        snapshot: ScanSnapshot,
        sidebar: SidebarItem?,
        search: String
    ) -> [Skill] {
        var skills: [Skill]
        switch sidebar {
        case .all, .none:
            skills = snapshot.allSkills
        case .root(let id):
            skills = snapshot.sections.first { $0.root.id == id }?.skills ?? []
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            skills = skills.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.slug.localizedCaseInsensitiveContains(query)
                    || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return skills
    }
}
