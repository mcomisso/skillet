import Foundation

/// Entry in openskills' ~/.agents/.skill-lock.json, keyed by skill slug.
struct OpenSkillsLockEntry: Codable, Hashable, Sendable {
    var source: String
    var sourceType: String?
    var sourceUrl: String?
    var skillPath: String?
    var skillFolderHash: String?
    var installedAt: String?
    var updatedAt: String?
}

struct OpenSkillsLock: Codable, Sendable {
    var version: Int?
    var skills: [String: OpenSkillsLockEntry]

    static func load(agentsDirectory: URL) -> OpenSkillsLock? {
        let url = agentsDirectory.appending(path: ".skill-lock.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OpenSkillsLock.self, from: data)
    }
}
