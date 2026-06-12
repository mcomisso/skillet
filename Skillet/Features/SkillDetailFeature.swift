import Foundation

protocol SkillDetailDependencies: Sendable {
    var git: GitService { get }
    var snapshots: SnapshotStore { get }
    var updates: UpdateService { get }
    var ai: AIAssistant { get }
}

extension AppDependencies: SkillDetailDependencies {}

/// Per-skill detail state. A fresh ViewModel is created whenever the
/// selected skill changes (the view is identity-keyed by skill id).
struct SkillDetailFeature: Feature {
    enum Tab: String, Sendable, CaseIterable, Identifiable {
        case overview = "Overview"
        case editor = "Editor"
        case changes = "Changes"
        case upstream = "Upstream"
        case files = "Files"
        case terminal = "Terminal"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .overview: "info.circle"
            case .editor: "square.and.pencil"
            case .changes: "clock.arrow.circlepath"
            case .upstream: "arrow.down.circle"
            case .files: "doc.on.doc"
            case .terminal: "terminal"
            }
        }

        /// Hover hint for the icon-only segmented control in the toolbar.
        var help: String {
            switch self {
            case .overview: "Overview — metadata, origin, and SKILL.md preview"
            case .editor: "Editor — edit skill files; every save is checkpointed"
            case .changes: "Changes — diff against the last checkpoint, history, and restore"
            case .upstream: "Upstream — compare with the source repository and apply updates"
            case .files: "Files — browse everything inside the skill"
            case .terminal: "Terminal — shell session in the skill's directory"
            }
        }
    }

    struct EditorState: Sendable {
        var selectedFileID: SkillFile.ID?
        var content: String = ""
        var savedContent: String = ""
        var isBinary = false
        var isLoading = false
        var isSaving = false
        var error: String?
    }

    struct UpstreamState: Sendable {
        var info: SkillUpdateInfo?
        var diff: [DiffFile] = []
        var isChecking = false
        var isApplying = false
        var hasChecked = false
        var error: String?
        var aiSummary: String?
        var isSummarizing = false
    }

    struct ChangesState: Sendable {
        var working: [DiffFile] = []
        var rawWorkingDiff = ""
        var history: [SnapshotCommit] = []
        var selectedCommitID: SnapshotCommit.ID?
        var commitDiff: [DiffFile] = []
        var isLoading = false
        var hasLoaded = false
        var error: String?
        var aiSummary: String?
        var isSummarizing = false
    }

    struct State: Sendable {
        var skill: Skill
        var tab: Tab = .overview
        var files: [SkillFile] = []
        var isLoadingFiles = false
        var skillBody: String = ""
        var editor = EditorState()
        var changes = ChangesState()
        var upstream = UpstreamState()
        /// Once opened, the terminal stays alive across tab switches.
        var hasOpenedTerminal = false
        var aiAvailable = false
    }

    enum Action: Sendable {
        case task
        case tabSelected(Tab)
        // Editor
        case fileSelected(SkillFile.ID?)
        case contentEdited(String)
        case saveFile
        case revertFile
        // Changes
        case refreshChanges
        case checkpoint(message: String)
        case commitSelected(SnapshotCommit.ID?)
        case restore(SnapshotCommit.ID)
        // Upstream
        case checkUpstream(forceRefresh: Bool)
        case applyUpdate
        // AI
        case summarizeWorkingDiff
        case summarizeUpstreamDiff
    }

    typealias Dependencies = SkillDetailDependencies

    @MainActor
    func handle(state: Mutable<State>, action: Action, dependencies: Dependencies) async {
        switch action {
        case .task:
            guard !state.isLoadingFiles else { return }
            state.aiAvailable = dependencies.ai.isAvailable
            state.isLoadingFiles = true
            let skill = state.skill
            async let files = FileTree.list(at: skill.resolvedURL)
            async let body = Self.loadBody(of: skill)
            state.files = await files
            state.skillBody = await body
            state.isLoadingFiles = false
            // Make sure this skill has a baseline checkpoint to diff against.
            await dependencies.snapshots.ensureBaselines(for: [skill])
            // Default the editor to SKILL.md.
            if state.editor.selectedFileID == nil,
               let skillFile = state.files.first(where: { $0.name == "SKILL.md" && $0.depth == 0 }) {
                await selectFile(skillFile.id, state: state)
            }

        case .tabSelected(let tab):
            state.tab = tab
            if tab == .changes, !state.changes.hasLoaded {
                await loadChanges(state: state, dependencies: dependencies)
            }
            if tab == .upstream, !state.upstream.hasChecked {
                await checkUpstream(state: state, dependencies: dependencies, forceRefresh: false)
            }
            if tab == .terminal {
                state.hasOpenedTerminal = true
            }

        case .fileSelected(let id):
            await selectFile(id, state: state)

        case .contentEdited(let text):
            state.editor.content = text

        case .saveFile:
            await saveFile(state: state, dependencies: dependencies)

        case .revertFile:
            state.editor.content = state.editor.savedContent

        case .refreshChanges:
            await loadChanges(state: state, dependencies: dependencies)

        case .checkpoint(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = trimmed.isEmpty ? "Checkpoint \(state.skill.slug)" : trimmed
            do {
                try await dependencies.snapshots.snapshot(skill: state.skill, message: subject)
                await loadChanges(state: state, dependencies: dependencies)
            } catch {
                state.changes.error = error.localizedDescription
            }

        case .commitSelected(let id):
            state.changes.selectedCommitID = id
            state.changes.commitDiff = []
            guard let id,
                  let commit = state.changes.history.first(where: { $0.id == id }) else { return }
            do {
                let diff = try await dependencies.snapshots.diff(for: state.skill, since: commit)
                state.changes.commitDiff = DiffParser.parse(diff)
            } catch {
                state.changes.error = error.localizedDescription
            }

        case .checkUpstream(let forceRefresh):
            await checkUpstream(state: state, dependencies: dependencies, forceRefresh: forceRefresh)

        case .applyUpdate:
            guard !state.upstream.isApplying else { return }
            state.upstream.isApplying = true
            state.upstream.error = nil
            do {
                try await dependencies.updates.apply(skill: state.skill)
                // Live content changed: refresh everything derived from disk.
                state.files = await FileTree.list(at: state.skill.resolvedURL)
                state.skillBody = await Self.loadBody(of: state.skill)
                if let fileID = state.editor.selectedFileID {
                    await selectFile(fileID, state: state)
                }
                state.changes.hasLoaded = false
                await checkUpstream(state: state, dependencies: dependencies, forceRefresh: false)
            } catch {
                state.upstream.error = error.localizedDescription
            }
            state.upstream.isApplying = false

        case .summarizeWorkingDiff:
            guard !state.changes.isSummarizing, !state.changes.rawWorkingDiff.isEmpty else { return }
            state.changes.isSummarizing = true
            do {
                state.changes.aiSummary = try await dependencies.ai
                    .summarizeDiff(state.changes.rawWorkingDiff)
            } catch {
                state.changes.error = "Summary failed: \(error.localizedDescription)"
            }
            state.changes.isSummarizing = false

        case .summarizeUpstreamDiff:
            guard !state.upstream.isSummarizing,
                  let diff = state.upstream.info?.diffText, !diff.isEmpty else { return }
            state.upstream.isSummarizing = true
            do {
                state.upstream.aiSummary = try await dependencies.ai.summarizeDiff(diff)
            } catch {
                state.upstream.error = "Summary failed: \(error.localizedDescription)"
            }
            state.upstream.isSummarizing = false

        case .restore(let id):
            guard let commit = state.changes.history.first(where: { $0.id == id }) else { return }
            do {
                try await dependencies.snapshots.restore(skill: state.skill, to: commit)
                state.changes.selectedCommitID = nil
                // Live content changed: reload files, body, editor, and diffs.
                state.files = await FileTree.list(at: state.skill.resolvedURL)
                state.skillBody = await Self.loadBody(of: state.skill)
                if let fileID = state.editor.selectedFileID {
                    await selectFile(fileID, state: state)
                }
                await loadChanges(state: state, dependencies: dependencies)
            } catch {
                state.changes.error = error.localizedDescription
            }
        }
    }

    // MARK: - Editor helpers

    @MainActor
    private func selectFile(_ id: SkillFile.ID?, state: Mutable<State>) async {
        state.editor.selectedFileID = id
        state.editor.content = ""
        state.editor.savedContent = ""
        state.editor.isBinary = false
        state.editor.error = nil
        guard let id, let file = state.files.first(where: { $0.id == id }), !file.isDirectory else {
            return
        }
        state.editor.isLoading = true
        let url = file.url
        let loaded = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let data = try? Data(contentsOf: url), data.count < 4_000_000 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
        // Bail if the selection moved on while we were reading.
        guard state.editor.selectedFileID == id else { return }
        if let loaded {
            state.editor.content = loaded
            state.editor.savedContent = loaded
        } else {
            state.editor.isBinary = true
        }
        state.editor.isLoading = false
    }

    @MainActor
    private func saveFile(state: Mutable<State>, dependencies: Dependencies) async {
        guard !state.editor.isSaving,
              let id = state.editor.selectedFileID,
              let file = state.files.first(where: { $0.id == id }) else { return }
        state.editor.isSaving = true
        state.editor.error = nil
        let content = state.editor.content
        // Write through symlinks so gstack/dev-linked files update their target.
        let target = file.url.resolvingSymlinksInPath()
        do {
            try await Task.detached(priority: .userInitiated) {
                try content.write(to: target, atomically: true, encoding: .utf8)
            }.value
            state.editor.savedContent = content
            try await dependencies.snapshots.snapshot(
                skill: state.skill,
                message: "Edit \(file.relativePath) in \(state.skill.slug)"
            )
            state.changes.hasLoaded = false
        } catch {
            state.editor.error = error.localizedDescription
        }
        state.editor.isSaving = false
    }

    // MARK: - Upstream helpers

    @MainActor
    private func checkUpstream(
        state: Mutable<State>,
        dependencies: Dependencies,
        forceRefresh: Bool
    ) async {
        guard !state.upstream.isChecking else { return }
        state.upstream.isChecking = true
        state.upstream.error = nil
        do {
            if let info = try await dependencies.updates.check(
                skill: state.skill,
                forceRefresh: forceRefresh
            ) {
                state.upstream.info = info
                state.upstream.diff = DiffParser.parse(info.diffText)
            }
            state.upstream.hasChecked = true
        } catch {
            state.upstream.error = error.localizedDescription
        }
        state.upstream.isChecking = false
    }

    // MARK: - Changes helpers

    @MainActor
    private func loadChanges(state: Mutable<State>, dependencies: Dependencies) async {
        guard !state.changes.isLoading else { return }
        state.changes.isLoading = true
        state.changes.error = nil
        do {
            let diffText = try await dependencies.snapshots.workingDiff(for: state.skill)
            state.changes.working = DiffParser.parse(diffText)
            state.changes.rawWorkingDiff = diffText
            state.changes.aiSummary = nil
            state.changes.history = await dependencies.snapshots.history(for: state.skill)
            state.changes.hasLoaded = true
        } catch {
            state.changes.error = error.localizedDescription
        }
        state.changes.isLoading = false
    }

    private static func loadBody(of skill: Skill) async -> String {
        let url = skill.skillFileURL
        let task = Task.detached(priority: .userInitiated) { () -> String in
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return FrontmatterParser.parse(contents).body
        }
        return await task.value
    }
}
