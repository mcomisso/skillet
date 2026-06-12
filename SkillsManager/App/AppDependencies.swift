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
