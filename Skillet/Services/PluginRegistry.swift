import Foundation

/// Reader for Claude Code's ~/.claude/plugins/installed_plugins.json.
struct PluginRegistry: Sendable {
    struct Install: Codable, Hashable, Sendable {
        var scope: String?
        var projectPath: String?
        var installPath: String?
        var version: String?
        var installedAt: String?
        var lastUpdated: String?
        var gitCommitSha: String?
    }

    private struct File: Codable {
        var version: Int?
        var plugins: [String: [Install]]
    }

    /// One unique on-disk plugin install that may contain skills.
    struct PluginInstall: Hashable, Sendable {
        var pluginName: String
        var marketplace: String
        var installPath: String
        var install: Install
    }

    var installs: [PluginInstall]

    static func load(pluginsDirectory: URL) -> PluginRegistry {
        let url = pluginsDirectory.appending(path: "installed_plugins.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return PluginRegistry(installs: [])
        }

        var seen = Set<String>()
        var result: [PluginInstall] = []
        for (key, installs) in file.plugins.sorted(by: { $0.key < $1.key }) {
            // Key format: "<plugin>@<marketplace>".
            let parts = key.split(separator: "@", maxSplits: 1)
            let pluginName = parts.first.map(String.init) ?? key
            let marketplace = parts.count > 1 ? String(parts[1]) : ""
            for install in installs {
                guard let path = install.installPath else { continue }
                let dedupeKey = "\(path)|\(install.scope ?? "")|\(install.projectPath ?? "")"
                guard seen.insert(dedupeKey).inserted else { continue }
                result.append(PluginInstall(
                    pluginName: pluginName,
                    marketplace: marketplace,
                    installPath: path,
                    install: install
                ))
            }
        }
        return PluginRegistry(installs: result)
    }
}
