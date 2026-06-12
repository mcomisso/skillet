import SwiftUI
import UniformTypeIdentifiers

/// Toolbar menu with backup/restore entry points; presents the panels and
/// routes the chosen URLs into the feature.
struct BackupMenu: View {
    let viewModel: ViewModel<AppFeature>

    var body: some View {
        Menu {
            Button("Back Up All Skills…", systemImage: "archivebox") {
                runSavePanel()
            }
            Button("Restore from Backup…", systemImage: "arrow.counterclockwise") {
                runOpenPanel()
            }
        } label: {
            Label("Backup", systemImage: "externaldrive")
        }
        .disabled(viewModel.backup.isWorking)
        .help("Back up or restore skills as a zip archive")
    }

    private func runSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "skills-backup-\(stamp).zip"
        panel.title = "Back Up Skills"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.send(.backup(to: url))
        }
    }

    private func runOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.title = "Restore Skills from Backup"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.send(.restoreInspect(archive: url))
        }
    }
}

/// Sheet shown after a backup archive has been inspected: pick which skills
/// to restore and whether existing ones may be overwritten.
struct RestoreSheet: View {
    let viewModel: ViewModel<AppFeature>
    let preview: RestorePreview

    var body: some View {
        let selection = viewModel.backup.restoreSelection

        VStack(alignment: .leading, spacing: 12) {
            Text("Restore Skills")
                .font(.title3.weight(.semibold))
            Text("Backup from \(preview.manifest.createdAt.formatted()) · \(preview.manifest.skillCount) skills")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(preview.manifest.skills) { entry in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { selection.contains(entry.id) },
                            set: { isOn in
                                var updated = selection
                                if isOn { updated.insert(entry.id) } else { updated.remove(entry.id) }
                                viewModel.send(.restoreSelectionChanged(updated))
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(entry.name)
                                    if exists(entry) {
                                        Text("already installed")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.orange.opacity(0.15), in: Capsule())
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Text("\(entry.rootKind.displayName) · \(entry.originLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 260)

            Toggle(
                "Overwrite skills that already exist",
                isOn: viewModel.binding(\.backup.restoreOverwrite, send: { .restoreOverwriteChanged($0) })
            )

            HStack {
                Button("Select All") {
                    viewModel.send(.restoreSelectionChanged(Set(preview.manifest.skills.map(\.id))))
                }
                Button("Select Missing Only") {
                    viewModel.send(.restoreSelectionChanged(
                        Set(preview.manifest.skills.filter { !exists($0) }.map(\.id))
                    ))
                }
                Spacer()
                Button("Cancel") {
                    viewModel.send(.restoreCancelled)
                }
                .keyboardShortcut(.cancelAction)
                Button("Restore \(selection.count) Skills") {
                    viewModel.send(.restoreConfirmed)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || viewModel.backup.isWorking)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }

    private func exists(_ entry: BackupManifest.Entry) -> Bool {
        FileManager.default.fileExists(
            atPath: BackupService().destinationDirectory(for: entry).path
        )
    }
}
