import Foundation

/// A location that gets scanned for skills.
struct SkillRoot: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable, Codable {
        case claudeUser
        case codexUser
        case openskills
        case plugins
        case project
        case custom

        var displayName: String {
            switch self {
            case .claudeUser: "Claude Code"
            case .codexUser: "Codex"
            case .openskills: "OpenSkills"
            case .plugins: "Plugins"
            case .project: "Project"
            case .custom: "Custom"
            }
        }

        var systemImage: String {
            switch self {
            case .claudeUser: "person.crop.circle"
            case .codexUser: "terminal"
            case .openskills: "shippingbox"
            case .plugins: "puzzlepiece.extension"
            case .project: "folder.badge.gearshape"
            case .custom: "folder"
            }
        }
    }

    var id: String { "\(kind.rawValue):\(url.path)" }
    var kind: Kind
    var url: URL
    var name: String

    /// For project roots, the project directory itself
    /// (url is `<project>/.claude/skills`).
    var projectDirectory: URL? {
        guard kind == .project else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }

    static func claudeUser(home: URL) -> SkillRoot {
        SkillRoot(
            kind: .claudeUser,
            url: home.appending(path: ".claude/skills"),
            name: "Claude Code"
        )
    }

    static func openskills(home: URL) -> SkillRoot {
        SkillRoot(
            kind: .openskills,
            url: home.appending(path: ".agents/skills"),
            name: "OpenSkills"
        )
    }

    static func codexUser(home: URL) -> SkillRoot {
        SkillRoot(
            kind: .codexUser,
            url: home.appending(path: ".codex/skills"),
            name: "Codex"
        )
    }

    static func plugins(home: URL) -> SkillRoot {
        SkillRoot(
            kind: .plugins,
            url: home.appending(path: ".claude/plugins"),
            name: "Plugins"
        )
    }
}

/// Result of a full scan: skills grouped per root, in sidebar order.
struct ScanSnapshot: Sendable, Equatable {
    struct Section: Sendable, Equatable, Identifiable {
        var id: String { root.id }
        var root: SkillRoot
        var skills: [Skill]
    }

    var sections: [Section] = []
    var scannedAt: Date = .distantPast

    var allSkills: [Skill] { sections.flatMap(\.skills) }
    var totalCount: Int { sections.reduce(0) { $0 + $1.skills.count } }

    func skill(id: Skill.ID?) -> Skill? {
        guard let id else { return nil }
        for section in sections {
            if let match = section.skills.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }
}
