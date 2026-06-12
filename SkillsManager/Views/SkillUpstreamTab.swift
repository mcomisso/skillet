import SwiftUI

/// Compares the local skill with its upstream repository and applies updates.
struct SkillUpstreamTab: View {
    let viewModel: ViewModel<SkillDetailFeature>
    @State private var confirmApply = false

    var body: some View {
        let upstream = viewModel.upstream
        let skill = viewModel.skill

        if case .openskills = skill.origin {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let info = upstream.info {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.repository)
                                .font(.callout.weight(.medium))
                            Text("HEAD \(String(info.headCommit.prefix(7))) · checked \(Format.relativeDate(info.checkedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(skill.origin.repositoryURL ?? "Upstream")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if upstream.isChecking || upstream.isApplying {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        viewModel.send(.checkUpstream(forceRefresh: true))
                    }
                    .disabled(upstream.isChecking || upstream.isApplying)
                    if viewModel.aiAvailable, upstream.info?.hasChanges == true {
                        Button("Summarize", systemImage: "sparkles") {
                            viewModel.send(.summarizeUpstreamDiff)
                        }
                        .disabled(upstream.isSummarizing)
                        .help("Summarize the upstream differences with Apple Intelligence")
                    }
                    if upstream.info?.hasChanges == true {
                        Button("Apply Upstream Version") {
                            confirmApply = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(upstream.isApplying)
                    }
                }
                .padding(8)
                Divider()

                if upstream.isSummarizing || upstream.aiSummary != nil {
                    AISummaryBar(
                        summary: upstream.aiSummary,
                        isWorking: upstream.isSummarizing
                    )
                    Divider()
                }

                if let error = upstream.error {
                    ContentUnavailableView(
                        "Upstream Check Failed",
                        systemImage: "wifi.exclamationmark",
                        description: Text(error)
                    )
                } else if upstream.isChecking, upstream.info == nil {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Fetching upstream repository…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let info = upstream.info, !info.hasChanges {
                    ContentUnavailableView(
                        "Up to Date",
                        systemImage: "checkmark.seal",
                        description: Text("The local skill matches \(info.repository).")
                    )
                } else {
                    VStack(spacing: 0) {
                        Text("Differences between the local skill and upstream (− local, + upstream)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Divider()
                        DiffView(files: upstream.diff)
                    }
                }
            }
            .confirmationDialog(
                "Apply upstream version of “\(skill.name)”?",
                isPresented: $confirmApply
            ) {
                Button("Apply Update", role: .destructive) {
                    viewModel.send(.applyUpdate)
                }
            } message: {
                Text("Local files will be replaced with the upstream version. The current state is checkpointed first, so customizations can be restored from the Changes tab.")
            }
        } else {
            ContentUnavailableView(
                "No Tracked Upstream",
                systemImage: "questionmark.folder",
                description: Text(unsupportedReason(for: skill))
            )
        }
    }

    private func unsupportedReason(for skill: Skill) -> String {
        switch skill.origin {
        case .gstack:
            "This skill is managed by gstack. Update it with the gstack CLI."
        case .plugin:
            "This skill ships inside a Claude Code plugin and is updated with the plugin."
        case .localDev(let repo):
            repo != nil
                ? "This skill is symlinked to a local checkout — pull that repository to update it."
                : "This skill is symlinked to a local folder."
        case .unmanaged:
            "No repository is recorded for this skill, so there is nothing to compare against."
        case .openskills:
            "" // Handled above.
        }
    }
}
