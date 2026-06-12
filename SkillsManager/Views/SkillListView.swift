import SwiftUI

struct SkillListView: View {
    let viewModel: ViewModel<AppFeature>
    @State private var pendingDelete: Skill?

    var body: some View {
        let skills = AppFeature.filteredSkills(
            snapshot: viewModel.snapshot,
            sidebar: viewModel.sidebarSelection,
            search: viewModel.searchText
        )

        List(
            skills,
            selection: viewModel.binding(\.selectedSkillID, send: { .skillSelected($0) })
        ) { skill in
            SkillRowView(
                skill: skill,
                updateAvailable: viewModel.updatesAvailable.contains(skill.id)
            )
            .tag(skill.id)
            .contextMenu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([skill.resolvedURL])
                }
                Divider()
                Button("Move to Trash…", role: .destructive) {
                    pendingDelete = skill
                }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { skill in
            Button("Move to Trash", role: .destructive) {
                viewModel.send(.deleteSkill(skill.id))
            }
        } message: { skill in
            Text(deleteMessage(for: skill))
        }
        .toolbar {
            ToolbarItem {
                if viewModel.isCheckingUpdates {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Check Updates", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        viewModel.send(.checkAllUpdates)
                    }
                    .help(viewModel.updateCheckSummary ?? "Compare repo-tracked skills with their upstreams")
                }
            }
        }
        .searchable(
            text: viewModel.binding(\.searchText, send: { .searchChanged($0) }),
            placement: .toolbar,
            prompt: "Search skills"
        )
        .overlay {
            if skills.isEmpty, !viewModel.isScanning {
                ContentUnavailableView(
                    viewModel.searchText.isEmpty ? "No Skills Found" : "No Matches",
                    systemImage: "magnifyingglass"
                )
            }
        }
        .navigationTitle(listTitle)
    }

    private func deleteMessage(for skill: Skill) -> String {
        var message = "A checkpoint is recorded first, so the content stays recoverable from the snapshot history."
        switch skill.origin {
        case .localDev:
            message += " Only the symlink is trashed — the checkout it points to is untouched."
        case .openskills:
            message += " The openskills lockfile entry is left in place; run `openskills uninstall \(skill.slug)` to clean it up."
        case .plugin:
            message = "This skill ships inside a plugin — deleting it here only lasts until the plugin updates."
        case .gstack, .unmanaged:
            break
        }
        return message
    }

    private var listTitle: String {
        switch viewModel.sidebarSelection {
        case .all, .none:
            "All Skills"
        case .root(let id):
            viewModel.snapshot.sections.first { $0.root.id == id }?.root.name ?? "Skills"
        }
    }
}

struct SkillRowView: View {
    let skill: Skill
    var updateAvailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.name)
                    .font(.headline)
                    .lineLimit(1)
                if skill.isSymlinked {
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Symlinked")
                }
                if updateAvailable {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .help("Differs from upstream")
                }
                Spacer()
                OriginBadge(origin: skill.origin)
            }
            if let description = skill.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(Format.abbreviatedPath(skill.resolvedURL.path))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(skill.resolvedURL.path)
        }
        .padding(.vertical, 3)
    }
}
