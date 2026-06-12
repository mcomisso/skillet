import SwiftUI
import SwiftTerm

/// Bridge between SwiftUI buttons and the AppKit terminal view. A plain
/// class rather than view @State: the representable assigns `view` inside
/// makeNSView, and writing SwiftUI state during a view update is discarded
/// — a class property write is not.
@MainActor
final class TerminalSession {
    fileprivate(set) weak var view: LocalProcessTerminalView?

    /// Types `text` into the shell and gives the terminal keyboard focus.
    func send(_ text: String) {
        guard let view else { return }
        view.send(txt: text)
        view.window?.makeFirstResponder(view)
    }
}

/// An interactive shell rooted in the skill directory, for trying skills
/// out (e.g. launching `claude` right where the skill lives).
struct SkillTerminalTab: View {
    let skill: Skill
    @State private var session = TerminalSession()

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
                    // Pre-fill the command; the user completes the prompt
                    // and hits return.
                    session.send("claude \"Use the \(skill.slug) skill: \"")
                }
                .help("Type a claude invocation for this skill into the terminal — finish the prompt and press return")
                Button("List Files", systemImage: "list.bullet") {
                    session.send("ls -la\n")
                }
                .help("Run ls -la in the skill directory")
            }
            .padding(8)
            Divider()
            TerminalHostView(directory: skill.resolvedURL, session: session)
        }
    }
}

/// Hosts SwiftTerm's LocalProcessTerminalView and spawns an interactive
/// login shell in `directory`. The shell lives as long as the view does.
struct TerminalHostView: NSViewRepresentable {
    let directory: URL
    let session: TerminalSession

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
        session.view = view
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        session.view = nsView
    }
}
