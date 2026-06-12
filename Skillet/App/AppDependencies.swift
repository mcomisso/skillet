import SwiftUI

/// Composition root: one instance owns every service, created at app launch.
/// Feature dependency protocols are satisfied by retroactive conformances
/// declared next to each feature.
struct AppDependencies: Sendable {
    var scanner: any SkillScanning
    var git: GitService
    var snapshots: SnapshotStore
    var updates: UpdateService
    var backups: BackupService
    var ai: AIAssistant

    init() {
        Self.migrateLegacyAppSupport()
        let git = GitService()
        let snapshots = SnapshotStore(git: git)
        self.scanner = SkillScanner()
        self.git = git
        self.snapshots = snapshots
        self.updates = UpdateService(
            git: git,
            cache: UpstreamCache(git: git),
            snapshots: snapshots
        )
        self.backups = BackupService()
        self.ai = AIAssistant()
    }

    /// Builds prior to the Skillet rename stored snapshots and upstream
    /// clones under "SkillsManager"; move the whole folder once so
    /// checkpoint history survives the rename.
    private static func migrateLegacyAppSupport() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = appSupport.appending(path: "SkillsManager")
        let current = appSupport.appending(path: "Skillet")
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
    }
}

// MARK: - Environment plumbing

private struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue = AppDependencies()
}

extension EnvironmentValues {
    var dependencies: AppDependencies {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
}
