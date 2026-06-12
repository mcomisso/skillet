import SwiftUI

/// App settings: additional folders to scan for skills (e.g. a project's
/// .claude/skills directory or a custom skills checkout).
struct SettingsView: View {
    @State private var customRoots: [String] = UserDefaults.standard
        .stringArray(forKey: AppFeature.customRootsDefaultsKey) ?? []
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(customRoots, id: \.self) { path in
                        Label(path, systemImage: "folder")
                            .font(.callout.monospaced())
                            .tag(path)
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    Button("Add Folder…", systemImage: "plus") {
                        addFolder()
                    }
                    Button("Remove", systemImage: "minus") {
                        if let selection {
                            customRoots.removeAll { $0 == selection }
                            persist()
                        }
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
            } header: {
                Text("Additional Skill Folders")
            } footer: {
                Text("Each folder is scanned for subdirectories containing a SKILL.md. Takes effect on the next rescan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose a folder containing skills"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            if !customRoots.contains(path) {
                customRoots.append(path)
                persist()
            }
        }
    }

    private func persist() {
        UserDefaults.standard.set(customRoots, forKey: AppFeature.customRootsDefaultsKey)
    }
}
