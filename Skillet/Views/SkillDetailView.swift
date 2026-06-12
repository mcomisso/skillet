import SwiftUI

struct SkillDetailView: View {
    @State private var viewModel: ViewModel<SkillDetailFeature>

    init(skill: Skill, dependencies: AppDependencies) {
        _viewModel = State(initialValue: ViewModel<SkillDetailFeature>(
            state: SkillDetailFeature.State(skill: skill),
            dependencies: dependencies
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { viewModel.send(.task) }
        .toolbar {
            ToolbarItemGroup {
                Picker("Section", selection: viewModel.binding(\.tab, send: { .tabSelected($0) })) {
                    ForEach(SkillDetailFeature.Tab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .help(tab.help)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        let skill = viewModel.skill
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(skill.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                if skill.isSymlinked {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                        .help("Symlinked")
                }
                OriginBadge(origin: skill.origin)
                Spacer()
            }
            if let description = skill.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            PathRow(url: skill.resolvedURL)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var content: some View {
        let tab = viewModel.tab
        ZStack {
            Group {
                switch tab {
                case .overview:
                    SkillOverviewTab(viewModel: viewModel)
                case .editor:
                    SkillEditorTab(viewModel: viewModel)
                case .changes:
                    SkillChangesTab(viewModel: viewModel)
                case .upstream:
                    SkillUpstreamTab(viewModel: viewModel)
                case .files:
                    SkillFilesTab(viewModel: viewModel)
                case .terminal:
                    Color.clear
                }
            }
            // The terminal is kept alive (hidden, not destroyed) once opened
            // so its shell session survives tab switches.
            if viewModel.hasOpenedTerminal {
                SkillTerminalTab(skill: viewModel.skill)
                    .opacity(tab == .terminal ? 1 : 0)
                    .allowsHitTesting(tab == .terminal)
            }
        }
    }
}

// MARK: - Overview

private struct SkillOverviewTab: View {
    let viewModel: ViewModel<SkillDetailFeature>

    var body: some View {
        let skill = viewModel.skill
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Details") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        detailRow("Source", skill.root.name)
                        detailRow("Origin", skill.origin.label)
                        if let repo = skill.origin.repositoryURL {
                            GridRow {
                                Text("Repository")
                                    .gridColumnAlignment(.trailing)
                                    .foregroundStyle(.secondary)
                                if let url = URL(string: repo) {
                                    Link(repo, destination: url)
                                        .font(.callout)
                                } else {
                                    Text(repo)
                                }
                            }
                        }
                        if case .openskills(let entry) = skill.origin {
                            detailRow("Installed", entry.installedAt.flatMap(Self.formatISODate))
                            detailRow("Updated", entry.updatedAt.flatMap(Self.formatISODate))
                        }
                        if case .plugin(let provenance) = skill.origin {
                            detailRow("Plugin", "\(provenance.pluginName) (\(provenance.marketplace))")
                            detailRow("Version", provenance.version)
                            if let projectPath = provenance.projectPath {
                                detailRow("Enabled in", Format.abbreviatedPath(projectPath))
                            } else {
                                detailRow("Scope", provenance.scope)
                            }
                        }
                        if skill.root.kind == .project, let project = skill.root.projectDirectory {
                            detailRow("Project", Format.abbreviatedPath(project.path))
                        }
                        if case .gstack(let bundlePath) = skill.origin {
                            detailRow("Bundle", bundlePath)
                        }
                        if case .localDev(let repoRoot) = skill.origin {
                            detailRow("Checkout", repoRoot)
                        }
                        detailRow("Files", "\(skill.fileCount) (\(Format.bytes(skill.totalSize)))")
                        detailRow("Modified", skill.modifiedAt.map(Format.relativeDate))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                let extraFields = skill.frontmatter.filter {
                    $0.key != "name" && $0.key != "description"
                }
                if !extraFields.isEmpty {
                    GroupBox("Frontmatter") {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(extraFields.keys.sorted(), id: \.self) { key in
                                detailRow(key, extraFields[key])
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                if !viewModel.skillBody.isEmpty {
                    GroupBox("SKILL.md") {
                        Text(viewModel.skillBody)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label)
                    .gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
            }
            .font(.callout)
        }
    }

    private static func formatISODate(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso)
            ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Files

private struct SkillFilesTab: View {
    let viewModel: ViewModel<SkillDetailFeature>

    var body: some View {
        Group {
            if viewModel.isLoadingFiles, viewModel.files.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.files) { file in
                    HStack {
                        Image(systemName: file.isDirectory ? "folder" : iconName(for: file))
                            .foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
                        Text(file.name)
                        Spacer()
                        if !file.isDirectory {
                            Text(Format.bytes(file.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.leading, CGFloat(file.depth) * 16)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        NSWorkspace.shared.open(file.url)
                    }
                    .contextMenu {
                        Button("Open") { NSWorkspace.shared.open(file.url) }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file.url])
                        }
                    }
                }
            }
        }
    }

    private func iconName(for file: SkillFile) -> String {
        switch (file.relativePath as NSString).pathExtension.lowercased() {
        case "md": "doc.text"
        case "sh", "bash", "zsh": "terminal"
        case "py", "js", "ts", "swift": "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg": "photo"
        default: "doc"
        }
    }
}
