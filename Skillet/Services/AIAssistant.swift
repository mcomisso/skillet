import Foundation
import FoundationModels

/// A complete skill draft produced by the on-device model.
@Generable(description: "An agent skill definition for a SKILL.md file")
struct SkillDraft {
    @Guide(description: "Short kebab-case identifier for the skill, e.g. 'review-swift-code'")
    var slug: String

    @Guide(description: "One sentence describing when an AI agent should trigger this skill, starting with 'Use when'")
    var skillDescription: String

    @Guide(description: "Markdown body with a '## When to Use' section and a '## Instructions' section that guides the agent step by step. No frontmatter.")
    var body: String
}

/// On-device inference (Apple Intelligence) for skill authoring and
/// change summaries. All calls are availability-guarded; the UI hides
/// AI affordances when the model can't run.
struct AIAssistant: Sendable {
    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    var unavailabilityReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings to use AI assistance."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading."
        case .unavailable:
            return "The on-device model is unavailable."
        }
    }

    /// Drafts a full skill from a natural-language intent.
    func draftSkill(intent: String) async throws -> SkillDraft {
        let session = LanguageModelSession(instructions: """
            You write "skills": reusable instruction documents that tell an \
            AI coding agent how to perform a task. Skills have a kebab-case \
            slug, a one-sentence trigger description, and a markdown body \
            with clear, imperative instructions. Be specific and practical; \
            prefer numbered steps and short sections.
            """)
        let response = try await session.respond(
            to: "Write a skill for the following purpose:\n\(intent)",
            generating: SkillDraft.self
        )
        return response.content
    }

    /// Rewrites a skill description so it triggers reliably.
    func improveDescription(name: String, currentDescription: String, body: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You improve the trigger descriptions of AI agent skills. A good \
            description is one sentence, starts with "Use when", names the \
            concrete situations that should trigger the skill, and avoids \
            vague words. Respond with the improved description only.
            """)
        let prompt = """
            Skill name: \(name)
            Current description: \(currentDescription)
            Skill body (excerpt): \(String(body.prefix(1500)))
            """
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Summarizes a unified diff in plain language.
    func summarizeDiff(_ diff: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You summarize unified diffs of markdown instruction files for a \
            developer. Describe what changed in 2-4 short bullet points, \
            focusing on meaning (what behavior or guidance changed), not \
            line counts. Respond with the bullets only.
            """)
        let response = try await session.respond(
            to: "Summarize this diff:\n\n\(String(diff.prefix(12_000)))"
        )
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
