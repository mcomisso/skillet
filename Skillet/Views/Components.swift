import SwiftUI

struct OriginBadge: View {
    let origin: SkillOrigin

    var body: some View {
        Text(origin.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch origin {
        case .openskills: .blue
        case .gstack: .purple
        case .localDev: .orange
        case .plugin: .teal
        case .unmanaged: .gray
        }
    }
}

/// A labeled monospaced path with copy + reveal-in-Finder affordances.
struct PathRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 6) {
            Text(url.path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy path")
            Button("Reveal", systemImage: "arrow.right.circle") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
    }
}

/// Inline bar showing an Apple Intelligence summary (or progress).
struct AISummaryBar: View {
    let summary: String?
    let isWorking: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
                .padding(.top, 2)
            if isWorking {
                Text("Summarizing changes…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
            } else if let summary {
                Text(summary)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(10)
        .background(.purple.opacity(0.06))
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Replaces the home directory prefix with "~".
    static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

private struct DockBadgeModifier: ViewModifier {
    let count: Int

    func body(content: Content) -> some View {
        content
            .onAppear { setDockBadge(count) }
            .onChange(of: count) { _, newCount in
                setDockBadge(newCount)
            }
    }

    @MainActor
    private func setDockBadge(_ count: Int) {
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}

extension View {
    func dockBadge(count: Int) -> some View {
        modifier(DockBadgeModifier(count: count))
    }
}
