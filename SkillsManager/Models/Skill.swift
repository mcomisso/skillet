import Foundation

/// A single installed skill: a directory containing a SKILL.md, discovered
/// in one of the scanned roots.
struct Skill: Identifiable, Hashable, Sendable {
    /// Stable identity: root + the on-disk path of the skill directory as
    /// found (before symlink resolution). Including the root keeps ids
    /// unique when the same physical skill appears in several groups
    /// (e.g. a plugin skill enabled in multiple projects).
    var id: String { "\(root.id)|\(directoryURL.path)" }

    /// Directory name on disk (installation name).
    var slug: String
    /// Display name from frontmatter, falling back to the slug.
    var name: String
    var description: String?
    /// All frontmatter fields, flattened ("metadata.type" for nested keys).
    var frontmatter: [String: String]
    /// First few lines of the body after frontmatter, for previews.
    var bodyPreview: String

    /// The skill directory as found in the root (may be a symlink).
    var directoryURL: URL
    /// Fully resolved skill directory.
    var resolvedURL: URL
    /// Resolved SKILL.md location.
    var skillFileURL: URL

    /// True when the directory itself or its SKILL.md is a symlink.
    var isSymlinked: Bool
    var origin: SkillOrigin
    var root: SkillRoot

    var fileCount: Int
    var totalSize: Int64
    var modifiedAt: Date?

    /// True when editing files in place affects a shared/managed location.
    var isManagedExternally: Bool {
        switch origin {
        case .gstack, .plugin: true
        case .openskills, .localDev, .unmanaged: false
        }
    }
}

/// How the skill got onto disk, and what upstream (if any) it maps to.
enum SkillOrigin: Hashable, Sendable {
    /// Installed by the openskills CLI; lock entry carries the GitHub source.
    case openskills(OpenSkillsLockEntry)
    /// Wrapper directory whose SKILL.md symlinks into a tool-managed bundle
    /// (e.g. ~/.claude/skills/gstack/<name>/SKILL.md).
    case gstack(bundlePath: String)
    /// Symlink into a local development checkout; repoRoot is the enclosing
    /// git repository if one was found.
    case localDev(repoRoot: String?)
    /// Shipped inside an installed Claude Code plugin.
    case plugin(PluginProvenance)
    /// A plain directory nobody claims to manage.
    case unmanaged

    var label: String {
        switch self {
        case .openskills: "openskills"
        case .gstack: "gstack"
        case .localDev: "local dev"
        case .plugin: "plugin"
        case .unmanaged: "unmanaged"
        }
    }

    /// URL of the upstream repository, when known.
    var repositoryURL: String? {
        switch self {
        case .openskills(let entry): entry.sourceUrl
        case .plugin(let provenance): provenance.marketplaceRepo
        case .gstack, .localDev, .unmanaged: nil
        }
    }
}

struct PluginProvenance: Hashable, Sendable {
    var pluginName: String
    var marketplace: String
    var version: String?
    var scope: String?
    /// For project-scoped installs, the project the plugin is enabled in.
    var projectPath: String?
    var installPath: String
    var gitCommitSha: String?
    var marketplaceRepo: String?
}
