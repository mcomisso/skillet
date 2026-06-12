import SwiftUI
import SwiftTerm

/// An interactive shell rooted in the skill directory, for trying skills
/// out (e.g. launching `claude` right where the skill lives).
struct SkillTerminalTab: View {
    let skill: Skill
    @State private var terminal: LocalProcessTerminalView?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(skill.resolvedURL.path, systemImage: "folder")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Try in Claude", systemImage: "sparkles") {
                    // Pre-fill the command; the user reviews and hits return.
                    terminal?.send(txt: "claude \"Use the \(skill.slug) skill: \"")
                }
                .help("Type a claude invocation that exercises this skill")
                Button("List Files", systemImage: "list.bullet") {
                    terminal?.send(txt: "ls -la\n")
                }
            }
            .padding(8)
            Divider()
            TerminalHostView(directory: skill.resolvedURL) { view in
                terminal = view
            }
        }
    }
}

/// Hosts SwiftTerm's LocalProcessTerminalView and spawns an interactive
/// login shell in `directory`. The shell lives as long as the view does.
struct TerminalHostView: NSViewRepresentable {
    let directory: URL
    var onReady: (LocalProcessTerminalView) -> Void

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor.textBackgroundColor
        view.nativeForegroundColor = NSColor.textColor

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let escapedPath = directory.path.replacingOccurrences(of: "'", with: "'\\''")

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        // GUI apps inherit a minimal PATH; include the usual CLI locations
        // so `claude`, `git`, and friends resolve.
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        let envStrings = environment.map { "\($0.key)=\($0.value)" }

        view.startProcess(
            executable: "/bin/zsh",
            args: ["-c", "cd '\(escapedPath)' && exec \(shell) -il"],
            environment: envStrings
        )
        onReady(view)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
