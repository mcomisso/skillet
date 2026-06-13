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
            let updateRecord = viewModel.updateRecords[skill.id]
            let isUpdateLocked = viewModel.updatePreferences.isLocked(skillID: skill.id)
            SkillRowView(
                skill: skill,
                updateRecord: updateRecord,
                isUpdateLocked: isUpdateLocked
            )
            .tag(skill.id)
            .contextMenu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([skill.resolvedURL])
                }
                if UpdateService.isUpdatable(skill) {
                    Divider()
                    if updateRecord?.status == .available {
                        Button("Ignore This Update", systemImage: "eye.slash") {
                            viewModel.send(.ignoreUpdate(skill.id))
                        }
                    }
                    if updateRecord?.status == .ignored {
                        Button("Show This Update", systemImage: "eye") {
                            viewModel.send(.showIgnoredUpdate(skill.id))
                        }
                    }
                    Button(
                        isUpdateLocked ? "Unlock Update Checks" : "Lock Update Checks",
                        systemImage: isUpdateLocked ? "lock.open" : "lock"
                    ) {
                        viewModel.send(.setUpdateChecksLocked(skill.id, !isUpdateLocked))
                    }
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
                if viewModel.isCheckingUpdates || viewModel.isApplyingAllUpdates {
                    ProgressView()
                        .controlSize(.small)
                        .help(viewModel.isCheckingUpdates
                              ? "Checking skills against their upstream repositories…"
                              : "Applying skill updates…")
                } else {
                    Button("Check Updates", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        viewModel.send(.checkAllUpdates)
                    }
                    .help(viewModel.updateCheckSummary ?? "Compare repo-tracked skills with their upstreams")
                }
            }
            ToolbarItem {
                Button("Update All", systemImage: "arrow.down.circle") {
                    viewModel.send(.applyAllUpdates)
                }
                .disabled(
                    viewModel.updateBadgeCount == 0
                        || viewModel.isCheckingUpdates
                        || viewModel.isApplyingAllUpdates
                )
                .help(viewModel.updateBadgeCount > 0
                      ? "Apply all available skill updates"
                      : "No skill updates available")
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
    var updateRecord: SkillUpdateRecord?
    var isUpdateLocked = false

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
                SkillUpdateStatusIcon(
                    record: updateRecord,
                    isLocked: isUpdateLocked
                )
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

struct SkillUpdateStatusIcon: View {
    let record: SkillUpdateRecord?
    let isLocked: Bool

    var body: some View {
        if let display {
            Image(systemName: display.systemImage)
                .font(.caption)
                .foregroundStyle(display.color)
                .help(display.help)
        }
    }

    private var display: (systemImage: String, color: Color, help: String)? {
        if isLocked {
            return (
                "lock.fill",
                .secondary,
                "Update checks are locked for this skill"
            )
        }

        guard let record else { return nil }
        switch record.status {
        case .available:
            return (
                "arrow.down.circle.fill",
                .blue,
                "Update available from \(record.repository ?? "upstream")"
            )
        case .ignored:
            return (
                "eye.slash",
                .secondary,
                "This update is ignored"
            )
        case .failed(let message):
            return (
                "exclamationmark.triangle.fill",
                .red,
                "Update check failed: \(message)"
            )
        case .locked:
            return (
                "lock.fill",
                .secondary,
                "Update checks are locked for this skill"
            )
        case .upToDate:
            return nil
        }
    }
}
