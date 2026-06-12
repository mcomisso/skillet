import SwiftUI

/// File picker + plain-text editor; every save becomes a snapshot commit.
struct SkillEditorTab: View {
    let viewModel: ViewModel<SkillDetailFeature>

    var body: some View {
        HSplitView {
            fileList
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            editorPane
                .frame(minWidth: 380, maxWidth: .infinity)
        }
    }

    private var fileList: some View {
        List(
            viewModel.files.filter { !$0.isDirectory },
            selection: viewModel.binding(\.editor.selectedFileID, send: { .fileSelected($0) })
        ) { file in
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(file.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .tag(file.id)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var editorPane: some View {
        let editor = viewModel.editor
        let isDirty = editor.content != editor.savedContent

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if viewModel.skill.isManagedExternally || viewModel.skill.isSymlinked {
                    Label(
                        "Edits write through to the managed source",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Spacer()
                if let error = editor.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                if isDirty {
                    Button("Revert") { viewModel.send(.revertFile) }
                    Button("Save") { viewModel.send(.saveFile) }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(editor.isSaving)
                } else {
                    Text(editor.isSaving ? "Saving…" : "Saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            Divider()

            if editor.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if editor.isBinary {
                ContentUnavailableView(
                    "Binary File",
                    systemImage: "doc.zipper",
                    description: Text("This file can't be edited as text.")
                )
            } else if editor.selectedFileID == nil {
                ContentUnavailableView(
                    "No File Selected",
                    systemImage: "doc.text",
                    description: Text("Choose a file to edit. Saves are checkpointed automatically.")
                )
            } else {
                TextEditor(text: viewModel.binding(\.editor.content, send: { .contentEdited($0) }))
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
        }
    }
}
