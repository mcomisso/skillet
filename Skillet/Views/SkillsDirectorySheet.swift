import SwiftUI

struct SkillsDirectorySheet: View {
    @State private var viewModel: ViewModel<SkillsDirectoryFeature>
    @Environment(\.dismiss) private var dismiss

    init(
        directory: any SkillsDirectoryServing,
        onInstalled: @Sendable @MainActor @escaping () -> Void
    ) {
        _viewModel = State(initialValue: ViewModel<SkillsDirectoryFeature>(
            state: SkillsDirectoryFeature.State(),
            dependencies: SkillsDirectoryDependencyBag(
                directory: directory,
                onInstalled: onInstalled
            )
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            SkillsDirectoryHeader(
                query: viewModel.binding(\.query, send: { .queryChanged($0) }),
                isSearching: viewModel.isSearching,
                onSearch: { viewModel.send(.search) }
            )
            Divider()
            SkillsDirectoryResults(
                query: viewModel.query,
                results: viewModel.results,
                isSearching: viewModel.isSearching,
                installingID: viewModel.installingID,
                installedIDs: viewModel.installedIDs,
                onInstall: { viewModel.send(.install($0)) }
            )
            Divider()
            SkillsDirectoryFooter(error: viewModel.error, onDone: { dismiss() })
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

private struct SkillsDirectoryHeader: View {
    @Binding var query: String
    var isSearching: Bool
    var onSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Discover Skills")
                        .font(.title2.weight(.semibold))
                    Text("Search the skills.sh directory and install skills globally.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("Open skills.sh", destination: URL(string: "https://skills.sh")!)
            }
            HStack {
                TextField("Search by name or description", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSearch)
                Button("Search", systemImage: "magnifyingglass", action: onSearch)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || isSearching)
            }
        }
        .padding(20)
    }
}

private struct SkillsDirectoryResults: View {
    var query: String
    var results: [SkillsDirectorySkill]
    var isSearching: Bool
    var installingID: SkillsDirectorySkill.ID?
    var installedIDs: Set<SkillsDirectorySkill.ID>
    var onInstall: (SkillsDirectorySkill) -> Void

    var body: some View {
        if isSearching && results.isEmpty {
            ProgressView("Searching skills.sh…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "Search skills.sh" : "No Skills Found",
                systemImage: "sparkles.rectangle.stack",
                description: Text(
                    query.isEmpty
                        ? "Enter at least two characters to discover community skills."
                        : "Try a different search term."
                )
            )
        } else {
            List(results) { skill in
                SkillsDirectoryRow(
                    name: skill.name,
                    source: skill.source,
                    installs: skill.installs,
                    webpageURL: skill.webpageURL,
                    isInstalling: installingID == skill.id,
                    isInstalled: installedIDs.contains(skill.id),
                    installDisabled: installingID != nil,
                    onInstall: { onInstall(skill) }
                )
            }
            .listStyle(.inset)
        }
    }
}

private struct SkillsDirectoryRow: View {
    var name: String
    var source: String
    var installs: Int
    var webpageURL: URL?
    var isInstalling: Bool
    var isInstalled: Bool
    var installDisabled: Bool
    var onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(source)
                        .font(.caption.monospaced())
                    Text("\(installs, format: .number.notation(.compactName)) installs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let webpageURL {
                Link(destination: webpageURL) {
                    Image(systemName: "safari")
                }
                .help("View on skills.sh")
            }
            Button(action: onInstall) {
                if isInstalling {
                    ProgressView()
                        .controlSize(.small)
                } else if isInstalled {
                    Label("Installed", systemImage: "checkmark")
                } else {
                    Text("Install")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(installDisabled || isInstalled)
        }
        .padding(.vertical, 6)
    }
}

private struct SkillsDirectoryFooter: View {
    var error: String?
    var onDone: () -> Void

    var body: some View {
        HStack {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("Installs use the official skills CLI with anonymous telemetry disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
