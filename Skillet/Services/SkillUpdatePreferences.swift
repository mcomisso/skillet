import Foundation

/// User choices that affect skill update checks.
struct SkillUpdatePreferences: Sendable, Equatable {
    static let lockedSkillIDsDefaultsKey = "lockedUpdateSkillIDs"
    static let ignoredHeadsDefaultsKey = "ignoredUpdateHeadsBySkillID"

    var lockedSkillIDs: Set<Skill.ID> = []
    var ignoredHeadsBySkillID: [Skill.ID: String] = [:]

    static func load(defaults: UserDefaults = .standard) -> SkillUpdatePreferences {
        SkillUpdatePreferences(
            lockedSkillIDs: Set(
                defaults.stringArray(forKey: lockedSkillIDsDefaultsKey) ?? []
            ),
            ignoredHeadsBySkillID: defaults.dictionary(
                forKey: ignoredHeadsDefaultsKey
            ) as? [Skill.ID: String] ?? [:]
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(
            lockedSkillIDs.sorted(),
            forKey: Self.lockedSkillIDsDefaultsKey
        )
        defaults.set(
            ignoredHeadsBySkillID,
            forKey: Self.ignoredHeadsDefaultsKey
        )
    }

    func isLocked(skillID: Skill.ID) -> Bool {
        lockedSkillIDs.contains(skillID)
    }

    func isIgnored(skillID: Skill.ID, headCommit: String?) -> Bool {
        guard let headCommit else { return false }
        return ignoredHeadsBySkillID[skillID] == headCommit
    }

    mutating func setLocked(_ locked: Bool, skillID: Skill.ID) {
        if locked {
            lockedSkillIDs.insert(skillID)
        } else {
            lockedSkillIDs.remove(skillID)
        }
    }

    mutating func ignore(skillID: Skill.ID, headCommit: String) {
        ignoredHeadsBySkillID[skillID] = headCommit
    }

    mutating func clearIgnored(skillID: Skill.ID) {
        ignoredHeadsBySkillID.removeValue(forKey: skillID)
    }
}
