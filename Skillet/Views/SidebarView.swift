import SwiftUI

struct SidebarView: View {
    let viewModel: ViewModel<AppFeature>

    var body: some View {
        List(selection: viewModel.binding(\.sidebarSelection, send: { .sidebarSelected($0) })) {
            Section("Library") {
                Label("All Skills", systemImage: "square.grid.2x2")
                    .badge(viewModel.snapshot.totalCount)
                    .tag(SidebarItem.all)
            }
            let sections = viewModel.snapshot.sections
            let sources = sections.filter { $0.root.kind != .project }
            let projects = sections.filter { $0.root.kind == .project }

            Section("Sources") {
                ForEach(sources) { section in
                    Label(section.root.name, systemImage: section.root.kind.systemImage)
                        .badge(section.skills.count)
                        .tag(SidebarItem.root(section.root.id))
                }
            }
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects) { section in
                        Label(section.root.name, systemImage: section.root.kind.systemImage)
                            .badge(section.skills.count)
                            .tag(SidebarItem.root(section.root.id))
                            .help(section.root.projectDirectory?.path ?? section.root.url.path)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                if viewModel.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .help("Scanning skill locations…")
                } else {
                    Button("Rescan", systemImage: "arrow.clockwise") {
                        viewModel.send(.refresh)
                    }
                    .help("Rescan all skill locations")
                }
            }
        }
    }
}
