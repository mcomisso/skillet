import SwiftUI

struct RootView: View {
    @State private var viewModel: ViewModel<AppFeature>
    @State private var showNewSkill = false
    private let dependencies: AppDependencies

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _viewModel = State(initialValue: ViewModel<AppFeature>(
            state: AppFeature.State(),
            dependencies: dependencies
        ))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            SkillListView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let skill = viewModel.snapshot.skill(id: viewModel.selectedSkillID) {
                SkillDetailView(skill: skill, dependencies: dependencies)
                    .id(skill.id)
            } else {
                ContentUnavailableView(
                    "No Skill Selected",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Select a skill to inspect, edit, or try it out.")
                )
            }
        }
        .task { viewModel.send(.task) }
        .navigationTitle("Skillet")
        .dockBadge(count: viewModel.updateBadgeCount)
        .toolbar {
            ToolbarItem {
                Button("New Skill", systemImage: "plus") {
                    showNewSkill = true
                }
                .help("Create a new skill")
            }
            ToolbarItem {
                BackupMenu(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $showNewSkill) {
            NewSkillSheet(dependencies: dependencies) { [viewModel] url in
                viewModel.send(.skillCreated(path: url.path))
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.backup.restorePreview != nil },
            set: { if !$0 { viewModel.send(.restoreCancelled) } }
        )) {
            if let preview = viewModel.backup.restorePreview {
                RestoreSheet(viewModel: viewModel, preview: preview)
            }
        }
        .alert(
            "Backup",
            isPresented: Binding(
                get: {
                    viewModel.backup.statusMessage != nil
                        || viewModel.backup.errorMessage != nil
                },
                set: { if !$0 { viewModel.send(.backupStatusDismissed) } }
            )
        ) {
            Button("OK") { viewModel.send(.backupStatusDismissed) }
        } message: {
            Text(viewModel.backup.statusMessage ?? viewModel.backup.errorMessage ?? "")
        }
    }
}
