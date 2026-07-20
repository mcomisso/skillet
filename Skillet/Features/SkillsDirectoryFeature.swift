import Foundation

protocol SkillsDirectoryDependencies: Sendable {
    var directory: any SkillsDirectoryServing { get }
    var onInstalled: @Sendable @MainActor () -> Void { get }
}

struct SkillsDirectoryDependencyBag: SkillsDirectoryDependencies {
    var directory: any SkillsDirectoryServing
    var onInstalled: @Sendable @MainActor () -> Void
}

struct SkillsDirectoryFeature: Feature {
    struct State: Sendable {
        var query = ""
        var results: [SkillsDirectorySkill] = []
        var isSearching = false
        var installingID: SkillsDirectorySkill.ID?
        var installedIDs: Set<SkillsDirectorySkill.ID> = []
        var error: String?
    }

    enum Action: Sendable {
        case queryChanged(String)
        case search
        case install(SkillsDirectorySkill)
    }

    typealias Dependencies = SkillsDirectoryDependencies

    @MainActor
    func handle(state: Mutable<State>, action: Action, dependencies: Dependencies) async {
        switch action {
        case .queryChanged(let query):
            state.query = query

        case .search:
            let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count >= 2, !state.isSearching else { return }
            state.isSearching = true
            state.error = nil
            do {
                state.results = try await dependencies.directory.search(query: query)
            } catch {
                state.results = []
                state.error = "Search failed: \(error.localizedDescription)"
            }
            state.isSearching = false

        case .install(let skill):
            guard state.installingID == nil, !state.installedIDs.contains(skill.id) else { return }
            state.installingID = skill.id
            state.error = nil
            do {
                try await dependencies.directory.install(skill)
                state.installedIDs.insert(skill.id)
                dependencies.onInstalled()
            } catch {
                state.error = "Installation failed: \(error.localizedDescription)"
            }
            state.installingID = nil
        }
    }
}
