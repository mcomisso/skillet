import Foundation

protocol NewSkillDependencies: Sendable {
    var ai: AIAssistant { get }
    var snapshots: SnapshotStore { get }
    /// Called with the new skill directory after a successful creation.
    var onCreated: @Sendable @MainActor (URL) -> Void { get }
}

struct NewSkillDependencyBag: NewSkillDependencies {
    var ai: AIAssistant
    var snapshots: SnapshotStore
    var onCreated: @Sendable @MainActor (URL) -> Void
}

/// Creates a new skill on disk, optionally drafted by the on-device model.
struct NewSkillFeature: Feature {
    static let bodyTemplate = """
    ## When to Use

    Describe the situations where an agent should reach for this skill.

    ## Instructions

    1. First step.
    2. Second step.
    """

    enum TargetLocation: String, Sendable, CaseIterable, Identifiable {
        case claudeUser = "Claude Code (~/.claude/skills)"
        case openskills = "OpenSkills (~/.agents/skills)"

        var id: String { rawValue }

        func directory(home: URL, slug: String) -> URL {
            switch self {
            case .claudeUser: home.appending(path: ".claude/skills/\(slug)")
            case .openskills: home.appending(path: ".agents/skills/\(slug)")
            }
        }
    }

    struct State: Sendable {
        var slug = ""
        var skillDescription = ""
        var body = NewSkillFeature.bodyTemplate
        var target: TargetLocation = .claudeUser
        var intent = ""
        var isGenerating = false
        var isCreating = false
        var created = false
        var error: String?
        var aiAvailable = false
        var aiUnavailabilityReason: String?
    }

    enum Action: Sendable {
        case task
        case slugChanged(String)
        case descriptionChanged(String)
        case bodyChanged(String)
        case targetChanged(TargetLocation)
        case intentChanged(String)
        case generateDraft
        case create
    }

    typealias Dependencies = NewSkillDependencies

    @MainActor
    func handle(state: Mutable<State>, action: Action, dependencies: Dependencies) async {
        switch action {
        case .task:
            state.aiAvailable = dependencies.ai.isAvailable
            state.aiUnavailabilityReason = dependencies.ai.unavailabilityReason

        case .slugChanged(let slug):
            state.slug = slug

        case .descriptionChanged(let description):
            state.skillDescription = description

        case .bodyChanged(let body):
            state.body = body

        case .targetChanged(let target):
            state.target = target

        case .intentChanged(let intent):
            state.intent = intent

        case .generateDraft:
            let intent = state.intent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !intent.isEmpty, !state.isGenerating else { return }
            state.isGenerating = true
            state.error = nil
            do {
                let draft = try await dependencies.ai.draftSkill(intent: intent)
                state.slug = Self.sanitizeSlug(draft.slug)
                state.skillDescription = draft.skillDescription
                state.body = draft.body
            } catch {
                state.error = "Generation failed: \(error.localizedDescription)"
            }
            state.isGenerating = false

        case .create:
            guard !state.isCreating else { return }
            let slug = state.slug
            guard Self.isValidSlug(slug) else {
                state.error = "The name must be kebab-case: lowercase letters, digits, and dashes."
                return
            }
            let description = state.skillDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else {
                state.error = "Add a one-line description — it's what triggers the skill."
                return
            }
            state.isCreating = true
            state.error = nil

            let home = FileManager.default.homeDirectoryForCurrentUser
            let directory = state.target.directory(home: home, slug: slug)
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                state.error = "A skill named “\(slug)” already exists there."
                state.isCreating = false
                return
            }

            let contents = """
            ---
            name: \(slug)
            description: \(description)
            ---

            \(state.body)
            """
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                try contents.write(
                    to: directory.appending(path: "SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
                dependencies.onCreated(directory)
                state.created = true
            } catch {
                state.error = error.localizedDescription
                state.isCreating = false
            }
        }
    }

    static func isValidSlug(_ slug: String) -> Bool {
        slug.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil
    }

    static func sanitizeSlug(_ raw: String) -> String {
        let lowered = raw.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        return String(lowered.unicodeScalars.filter {
            CharacterSet.lowercaseLetters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || $0 == "-"
        })
    }
}
