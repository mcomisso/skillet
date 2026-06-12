# Skills Manager

A native macOS app for managing AI agent skills — the `SKILL.md` instruction
bundles used by Claude Code, [openskills](https://github.com/numman-ali/openskills),
and plugin ecosystems. One window to index, inspect, customize, diff, update,
back up, and try out every skill installed on your machine.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

## What it does

- **Indexes every skill ecosystem on your Mac**
  - `~/.claude/skills` — Claude Code user skills, including gstack-managed
    bundles (symlinked `SKILL.md`) and skills symlinked to local dev checkouts
  - `~/.agents/skills` — openskills installs, matched to their GitHub source
    repositories via `.skill-lock.json`
  - `~/.claude/plugins` — skills bundled inside installed Claude Code plugins
  - Any custom folder you add in Settings
- **Customize and remember it.** Every skill gets a baseline checkpoint in a
  shadow git repository (`~/Library/Application Support/SkillsManager/snapshots`).
  Edit any file in the built-in editor — each save becomes a commit. The
  Changes tab shows a live git diff against the last checkpoint, full history,
  and one-click restore to any point.
- **Update with a real diff.** Skills with a known upstream are compared
  against a fresh shallow clone of their repository. Review the unified diff,
  then apply the upstream version — your customizations are checkpointed
  first, so nothing is ever lost.
- **Back up and restore.** Export all skills (symlinks resolved to real
  content) into a portable zip with a manifest; restore selectively on any
  machine.
- **Try skills in a built-in terminal.** Every skill has a Terminal tab with
  a shell rooted in its directory — launch `claude` right there to exercise it.
- **Create skills with on-device AI.** The New Skill wizard can draft the
  slug, trigger description, and body from a natural-language intent using
  Apple's FoundationModels (Apple Intelligence) — fully on-device. The model
  also summarizes diffs in plain language.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 + [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build
- `git` (ships with Xcode Command Line Tools)
- Apple Intelligence enabled (optional — only for the AI features)

## Building

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project SkillsManager.xcodeproj -scheme SkillsManager build
```

`project.yml` is the source of truth — never edit the `.xcodeproj` directly.
The app is **not sandboxed**: it manages files in `~/.claude` and `~/.agents`,
runs `git`, and hosts a real shell, which the sandbox would prohibit.

## Architecture

SwiftUI + a lightweight unidirectional architecture (`UnidirectionalKit`,
vendored): stateless `Feature` structs process actions against `Mutable<State>`
owned by a generic `ViewModel`, with granular per-field observation. Views are
read-only by construction; all mutations flow through actions.

| Layer | Pieces |
|-------|--------|
| Services | `SkillScanner`, `GitService`, `SnapshotStore`, `UpdateService`, `BackupService`, `AIAssistant`, `ProcessRunner` |
| Features | `AppFeature`, `SkillDetailFeature`, `NewSkillFeature` |
| Views | `NavigationSplitView` shell, detail tabs (Overview / Editor / Changes / Upstream / Files / Terminal) |

The embedded terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
Persistence is files + git — no database.

## License

MIT — see [LICENSE](LICENSE).
