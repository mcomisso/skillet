import SwiftUI

/// Working-copy diff against the latest checkpoint plus snapshot history
/// with restore.
struct SkillChangesTab: View {
    let viewModel: ViewModel<SkillDetailFeature>
    @State private var checkpointMessage = ""
    @State private var pendingRestore: SnapshotCommit?

    var body: some View {
        let changes = viewModel.changes

        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Checkpoint message", text: $checkpointMessage)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { checkpoint() }
                    Button("Checkpoint", systemImage: "camera") {
                        checkpoint()
                    }
                    .help("Record the current state as a restore point")
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        viewModel.send(.refreshChanges)
                    }
                    .labelStyle(.iconOnly)
                    .help("Re-compare the skill with its latest checkpoint")
                    if viewModel.aiAvailable, !changes.working.isEmpty {
                        Button("Summarize", systemImage: "sparkles") {
                            viewModel.send(.summarizeWorkingDiff)
                        }
                        .disabled(changes.isSummarizing)
                        .help("Summarize the pending changes with Apple Intelligence")
                    }
                }
                .padding(8)
                Divider()

                if changes.isSummarizing || changes.aiSummary != nil {
                    AISummaryBar(
                        summary: changes.aiSummary,
                        isWorking: changes.isSummarizing
                    )
                    Divider()
                }

                if changes.isLoading, !changes.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let selectedID = changes.selectedCommitID,
                          changes.history.contains(where: { $0.id == selectedID }) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Changes since the selected checkpoint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Back to current changes") {
                                viewModel.send(.commitSelected(nil))
                            }
                            .controlSize(.small)
                        }
                        .padding(8)
                        Divider()
                        DiffView(files: changes.commitDiff)
                    }
                } else {
                    DiffView(files: changes.working)
                }

                if let error = changes.error {
                    Divider()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity)

            historyPane
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
        }
        .confirmationDialog(
            "Restore “\(viewModel.skill.name)”?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            presenting: pendingRestore
        ) { commit in
            Button("Restore from \(commit.shortHash)", role: .destructive) {
                viewModel.send(.restore(commit.id))
            }
        } message: { commit in
            Text("The skill's files will be replaced with the checkpoint from \(commit.date.formatted()). The current state is checkpointed first, so this can be undone.")
        }
    }

    private var historyPane: some View {
        let changes = viewModel.changes
        return List(
            changes.history,
            selection: viewModel.binding(\.changes.selectedCommitID, send: { .commitSelected($0) })
        ) { commit in
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(.callout)
                    .lineLimit(2)
                HStack {
                    Text(commit.shortHash)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Text(Format.relativeDate(commit.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .tag(commit.id)
            .contextMenu {
                Button("Restore This Checkpoint…") {
                    pendingRestore = commit
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if changes.history.isEmpty, changes.hasLoaded {
                ContentUnavailableView(
                    "No Checkpoints",
                    systemImage: "clock",
                    description: Text("Snapshots appear here as you edit or checkpoint.")
                )
            }
        }
    }

    private func checkpoint() {
        viewModel.send(.checkpoint(message: checkpointMessage))
        checkpointMessage = ""
    }
}
