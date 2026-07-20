import Foundation

struct SkillsDirectorySkill: Identifiable, Equatable, Sendable {
    var id: String
    var skillID: String
    var name: String
    var installs: Int
    var source: String

    var webpageURL: URL? {
        URL(string: "https://skills.sh/\(id)")
    }
}

protocol SkillsDirectoryServing: Sendable {
    func search(query: String) async throws -> [SkillsDirectorySkill]
    func install(_ skill: SkillsDirectorySkill) async throws
}

enum SkillsDirectoryError: Error, LocalizedError {
    case invalidResponse
    case cliUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "skills.sh returned an invalid response."
        case .cliUnavailable:
            "Installing requires Node.js and npx. Install Node.js, then try again."
        }
    }
}

/// Searches the skills.sh directory and delegates installation to its official
/// `npx skills` CLI. Installed skills land in the canonical ~/.agents/skills
/// directory that SkillScanner already indexes.
struct SkillsDirectoryService: SkillsDirectoryServing {
    private struct SearchResponse: Decodable {
        var skills: [SearchSkill]
    }

    private struct SearchSkill: Decodable {
        var id: String
        var skillID: String
        var name: String
        var installs: Int
        var source: String

        enum CodingKeys: String, CodingKey {
            case id
            case skillID = "skillId"
            case name
            case installs
            case source
        }
    }

    var homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    func search(query: String) async throws -> [SkillsDirectorySkill] {
        var components = URLComponents(string: "https://skills.sh/api/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let url = components?.url else { throw SkillsDirectoryError.invalidResponse }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SkillsDirectoryError.invalidResponse
        }
        return try Self.decodeSearchResponse(data)
    }

    func install(_ skill: SkillsDirectorySkill) async throws {
        guard let npx = Self.npxURL(homeDirectory: homeDirectory) else {
            throw SkillsDirectoryError.cliUnavailable
        }

        let arguments = Self.installArguments(
            skill: skill,
            homeDirectory: homeDirectory
        )

        let binDirectories = [
            homeDirectory.appending(path: ".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let environment = [
            "PATH": (binDirectories + [inheritedPath]).joined(separator: ":"),
            "CI": "1",
            "DISABLE_TELEMETRY": "1",
            "FORCE_COLOR": "0",
            "NO_COLOR": "1"
        ]
        let result = try await ProcessRunner.run(
            npx.path,
            arguments,
            environment: environment
        )
        guard result.succeeded else {
            if result.exitCode == 127 || result.stderr.contains("node: No such file") {
                throw SkillsDirectoryError.cliUnavailable
            }
            throw ProcessError.failed(
                command: "npx skills add",
                code: result.exitCode,
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }

    static func decodeSearchResponse(_ data: Data) throws -> [SkillsDirectorySkill] {
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return response.skills.map {
            SkillsDirectorySkill(
                id: $0.id,
                skillID: $0.skillID,
                name: $0.name,
                installs: $0.installs,
                source: $0.source
            )
        }
    }

    static func installArguments(
        skill: SkillsDirectorySkill,
        homeDirectory: URL
    ) -> [String] {
        [
            "--yes", "skills", "add", skill.source,
            "--skill", skill.skillID,
            "--global", "--yes", "--agent"
        ] + targetAgents(homeDirectory: homeDirectory)
    }

    private static func npxURL(homeDirectory: URL) -> URL? {
        let candidates = [
            homeDirectory.appending(path: ".local/bin/npx"),
            URL(filePath: "/opt/homebrew/bin/npx"),
            URL(filePath: "/usr/local/bin/npx"),
            URL(filePath: "/usr/bin/npx")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func targetAgents(homeDirectory: URL) -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        if fm.fileExists(atPath: homeDirectory.appending(path: ".claude").path) {
            result.append("claude-code")
        }
        if fm.fileExists(atPath: homeDirectory.appending(path: ".codex").path) {
            result.append("codex")
        }
        return result.isEmpty ? ["claude-code"] : result
    }
}
