import SwiftUI

/// Renders a parsed unified diff, GitHub-style.
struct DiffView: View {
    let files: [DiffFile]

    var body: some View {
        if files.isEmpty {
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("This skill matches its latest checkpoint.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(files) { file in
                        DiffFileView(file: file)
                    }
                }
                .padding()
            }
        }
    }
}

private struct DiffFileView: View {
    let file: DiffFile
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: kindIcon)
                        .foregroundStyle(kindColor)
                    Text(file.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if file.additions > 0 {
                        Text("+\(file.additions)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text("−\(file.deletions)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                if file.kind == .binary {
                    Text("Binary file changed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ForEach(file.hunks) { hunk in
                        DiffHunkView(hunk: hunk)
                    }
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private var kindIcon: String {
        switch file.kind {
        case .modified: "pencil"
        case .added: "plus.circle"
        case .deleted: "minus.circle"
        case .renamed: "arrow.right"
        case .binary: "doc"
        }
    }

    private var kindColor: Color {
        switch file.kind {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .binary: .secondary
        }
    }
}

private struct DiffHunkView: View {
    let hunk: DiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))

            ForEach(hunk.lines) { line in
                HStack(spacing: 0) {
                    Text(line.oldNumber.map(String.init) ?? "")
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(.tertiary)
                    Text(line.newNumber.map(String.init) ?? "")
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(.tertiary)
                    Text(prefix(for: line.kind))
                        .frame(width: 16)
                        .foregroundStyle(color(for: line.kind))
                    Text(line.text.isEmpty ? " " : line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(line.kind == .context ? .primary : color(for: line.kind))
                }
                .font(.caption.monospaced())
                .padding(.vertical, 1)
                .background(background(for: line.kind))
                .textSelection(.enabled)
            }
        }
    }

    private func prefix(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: " "
        case .addition: "+"
        case .deletion: "−"
        }
    }

    private func color(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: .secondary
        case .addition: .green
        case .deletion: .red
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .addition: .green.opacity(0.12)
        case .deletion: .red.opacity(0.12)
        }
    }
}
