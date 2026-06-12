import Foundation

/// Sidebar entries: the aggregate view plus one entry per scanned root.
enum SidebarItem: Hashable, Sendable {
    case all
    case root(String)
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
        var updatesAvailable: Set<Skill.ID> = []
        var isCheckingUpdates = false
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
            await rescan(state: state, dependencies: dependencies)

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
            guard !state.isCheckingUpdates else { return }
            state.isCheckingUpdates = true
            state.updateCheckSummary = nil
            var available: Set<Skill.ID> = []
            var checked = 0
            var failures = 0
            for skill in state.snapshot.allSkills where dependencies.updates.isUpdatable(skill) {
                do {
                    if let info = try await dependencies.updates.check(skill: skill),
                       info.hasChanges {
                        available.insert(skill.id)
                    }
                    checked += 1
                } catch {
                    failures += 1
                }
            }
            state.updatesAvailable = available
            state.updateCheckSummary = failures > 0
                ? "\(checked) checked, \(available.count) differ, \(failures) failed"
                : "\(checked) checked, \(available.count) differ from upstream"
            state.isCheckingUpdates = false

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
        if state.snapshot.skill(id: state.selectedSkillID) == nil {
            state.selectedSkillID = nil
        }
        state.isScanning = false
        // Give every indexed skill a baseline checkpoint so later diffs and
        // restores have something to compare against.
        await dependencies.snapshots.ensureBaselines(for: snapshot.allSkills)
    }

    static func scopeContains(_ item: SidebarItem?, skill: Skill) -> Bool {
        switch item {
        case .all, .none: true
        case .root(let id): skill.root.id == id
        }
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
