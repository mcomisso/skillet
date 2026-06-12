import SwiftUI

struct NewSkillSheet: View {
    @State private var viewModel: ViewModel<NewSkillFeature>
    @Environment(\.dismiss) private var dismiss

    init(dependencies: AppDependencies, onCreated: @Sendable @MainActor @escaping (URL) -> Void) {
        _viewModel = State(initialValue: ViewModel<NewSkillFeature>(
            state: NewSkillFeature.State(),
            dependencies: NewSkillDependencyBag(
                ai: dependencies.ai,
                snapshots: dependencies.snapshots,
                onCreated: onCreated
            )
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Skill")
                .font(.title3.weight(.semibold))

            if viewModel.aiAvailable {
                GroupBox {
                    HStack(alignment: .top, spacing: 8) {
                        TextField(
                            "Describe what the skill should do, and the on-device model drafts it…",
                            text: viewModel.binding(\.intent, send: { .intentChanged($0) }),
                            axis: .vertical
                        )
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        Button {
                            viewModel.send(.generateDraft)
                        } label: {
                            if viewModel.isGenerating {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Draft", systemImage: "sparkles")
                            }
                        }
                        .disabled(viewModel.isGenerating || viewModel.intent.isEmpty)
                    }
                    .padding(4)
                } label: {
                    Label("Draft with Apple Intelligence", systemImage: "sparkles")
                        .font(.caption)
                }
            } else if let reason = viewModel.aiUnavailabilityReason {
                Label(reason, systemImage: "sparkles.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("my-skill-name", text: viewModel.binding(\.slug, send: { .slugChanged($0) }))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("Description").foregroundStyle(.secondary)
                    TextField(
                        "Use when …",
                        text: viewModel.binding(\.skillDescription, send: { .descriptionChanged($0) })
                    )
                    .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Location").foregroundStyle(.secondary)
                    Picker("", selection: viewModel.binding(\.target, send: { .targetChanged($0) })) {
                        ForEach(NewSkillFeature.TargetLocation.allCases) { target in
                            Text(target.rawValue).tag(target)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                }
            }

            Text("SKILL.md body")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: viewModel.binding(\.body, send: { .bodyChanged($0) }))
                .font(.callout.monospaced())
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Skill") { viewModel.send(.create) }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isCreating || viewModel.slug.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 520)
        .task { viewModel.send(.task) }
        .onChange(of: viewModel.created) { _, created in
            if created { dismiss() }
        }
    }
}
