// FleetSidebarView.swift
// Studio.92 — Command Center

import SwiftUI
import SwiftData
import AppKit

// MARK: - Selection Model

enum SidebarSelection: Equatable {
    case project(UUID)
    case session(UUID)
}

// MARK: - Fleet Sidebar (Pane 1)

/// Left sidebar: sorted list of active projects with risk labels.
struct FleetSidebar: View {

    let projects: [AppProject]
    let jobs: [AgentSession]
    let repositoryState: GitRepositoryState
    let isRefreshingRepository: Bool
    let activeProject: AppProject?
    let activeGoal: String?
    let isPipelineRunning: Bool
    let currentWorkspacePath: String
    let recentWorkspacePaths: [String]
    let selectedProjectID: UUID?
    let selectedSessionID: UUID?
    let persistedThreads: [PersistedThread]
    let resumeThread: PersistedThread?
    let threadProjectIDs: Set<UUID>
    let onSelectProject: (UUID) -> Void
    let onSelectSession: (UUID) -> Void
    let onSelectThread: (PersistedThread) -> Void
    let onSelectWorkspacePath: (String) -> Void
    let onOpenWorkspace: () -> Void
    let onDeleteProject: (UUID) -> Void
    let onDeleteThread: (PersistedThread) -> Void
    let onNewThread: () -> Void
    let onCollapseSidebar: () -> Void

    @Environment(\.openSettings) private var openSettings

    @State private var areWorkspacesExpanded = true
    @State private var areJobsExpanded = true
    @State private var isProjectsExpanded = true
    @State private var isRecentExpanded = true
    @State private var localSelection: SidebarSelection?

    private var visibleWorkspacePaths: [String] {
        Array(recentWorkspacePaths.prefix(5))
    }

    private var activeJobs: [AgentSession] {
        jobs.filter { session in
            switch session.status {
            case .queued, .preparing, .running, .reviewing:
                return true
            case .completed, .failed, .cancelled:
                return false
            }
        }
    }

    /// Last 5 threads, excluding any whose projectID matches a visible project
    /// (those are already represented by the project row).
    private var recentThreads: [PersistedThread] {
        Array(persistedThreads.prefix(5))
    }

    private var sidebarInsights: [Insight] {
        let activeNames = Set(activeJobs.map(\.branchName))
        return StudioInsightEngine.evaluate(
            projects: projects,
            activeJobProjectNames: activeNames
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(onNewThread: onNewThread, onCollapseSidebar: onCollapseSidebar)

            SidebarSearchPill()
                .padding(.top, StudioSpacing.md)
                .padding(.trailing, StudioSidebarLayout.inset)

            if let resume = resumeThread {
                SidebarResumeRow(thread: resume) {
                    onSelectThread(resume)
                }
                .padding(.top, StudioSpacing.md)
                .padding(.bottom, StudioSpacing.xs)
            }

            SidebarCollapsibleSectionHeader(
                title: "Projects",
                isExpanded: $isProjectsExpanded,
                showAddButton: true
            )

            if isProjectsExpanded {
                SidebarAttentionBadge(
                    count: sidebarInsights.count,
                    highPriorityCount: sidebarInsights.filter { $0.priority == .high }.count
                )
                .animation(StudioMotion.softFade, value: sidebarInsights.count)

                if isRefreshingRepository && projects.isEmpty {
                    SidebarIndexingRow()
                        .transition(.studioFadeLift)
                } else if projects.isEmpty {
                    HStack(spacing: StudioSpacing.sm) {
                        Image(systemName: "plus.circle.dashed")
                            .font(StudioTypography.captionMedium)
                        Text("No projects yet")
                            .font(StudioTypography.footnote)
                    }
                    .foregroundStyle(StudioTextColor.tertiary)
                    .padding(.vertical, StudioSpacing.md)
                }

                VStack(spacing: StudioSidebarLayout.rowSpacing) {
                    ForEach(projects) { project in
                        SidebarProjectRow(
                            project: project,
                            isSelected: localSelection == .project(project.id),
                            isAffiliated: isProjectAffiliated(project),
                            isActive: isProjectActive(project),
                            hasRecentThread: threadProjectIDs.contains(project.id),
                            onTap: {
                                applySelection(.project(project.id))
                            },
                            onDelete: {
                                onDeleteProject(project.id)
                            }
                        )
                    }
                }
            }

            if !activeJobs.isEmpty {
                SidebarSectionLabel(title: "Active")

                VStack(spacing: StudioSidebarLayout.rowSpacing) {
                    ForEach(activeJobs) { job in
                        Button {
                            applySelection(.session(job.id))
                        } label: {
                            FleetJobRow(
                                session: job,
                                isSelected: localSelection == .session(job.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !recentThreads.isEmpty {
                SidebarCollapsibleSectionHeader(
                    title: "Recent",
                    isExpanded: $isRecentExpanded
                )

                if isRecentExpanded {
                    VStack(spacing: StudioSidebarLayout.rowSpacing) {
                        ForEach(recentThreads) { thread in
                            SidebarThreadRow(
                                thread: thread,
                                onTap: { onSelectThread(thread) },
                                onDelete: { onDeleteThread(thread) }
                            )
                        }
                    }
                    .opacity(0.85)
                }
            }

            Spacer()

            SidebarWorkspaceFooter(
                workspacePath: currentWorkspacePath,
                onOpenWorkspace: onOpenWorkspace,
                onOpenSettings: {
                    openSettings()
                }
            )
        }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            moveSelection(direction)
        }
        .onAppear {
            syncSelectionFromInputs()
        }
        .onChange(of: selectedProjectID) { _, _ in
            syncSelectionFromInputs()
        }
        .onChange(of: selectedSessionID) { _, _ in
            syncSelectionFromInputs()
        }
        .onChange(of: activeJobs) { old, new in
            let wasRunning = Set(old.filter { $0.status == .running }.map(\.id))
            if let runner = new.first(where: { $0.status == .running && !wasRunning.contains($0.id) }) {
                applySelection(.session(runner.id))
            }
        }
        .padding(.leading, StudioSidebarLayout.inset)
        .studioSurface(.sidebar)
        .overlay(alignment: .trailing) {
            StudioSeparator.subtle
                .frame(width: 1.0 / (NSScreen.main?.backingScaleFactor ?? 2.0))
                .allowsHitTesting(false)
        }
    }

    // Status color logic
    private func statusColor(for project: AppProject) -> Color {
        if project.confidenceScore < 40 {
            return StudioStatusColor.danger
        } else if project.confidenceScore < 70 {
            return StudioStatusColor.warning
        } else {
            return StudioTextColor.secondary
        }
    }

    // Active processing logic
    private func isProjectActive(_ project: AppProject) -> Bool {
        for job in jobs {
            if job.branchName == project.name && (job.status == .running || job.status == .preparing) {
                return true
            }
        }
        return false
    }

    // MARK: - Selection Helpers

    private var selectableItems: [SidebarSelection] {
        projects.map { .project($0.id) } + activeJobs.map { .session($0.id) }
    }

    private func isProjectAffiliated(_ project: AppProject) -> Bool {
        guard case .session(let sessionID) = localSelection,
              let job = jobs.first(where: { $0.id == sessionID }) else { return false }
        return job.branchName == project.name
    }

    private func syncSelectionFromInputs() {
        if let id = selectedSessionID {
            localSelection = .session(id)
        } else if let id = selectedProjectID {
            localSelection = .project(id)
        } else {
            localSelection = nil
        }
    }

    private func applySelection(_ sel: SidebarSelection) {
        StudioFeedback.select()
        localSelection = sel
        switch sel {
        case .project(let id): onSelectProject(id)
        case .session(let id): onSelectSession(id)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let items = selectableItems
        guard !items.isEmpty else { return }
        if let current = localSelection, let idx = items.firstIndex(of: current) {
            switch direction {
            case .up:   applySelection(items[max(0, idx - 1)])
            case .down: applySelection(items[min(items.count - 1, idx + 1)])
            default: break
            }
        } else {
            applySelection(items[0])
        }
    }

    private func revealInfrastructurePath(relativePath: String) {
        let targetURL = URL(fileURLWithPath: currentWorkspacePath, isDirectory: true)
            .appendingPathComponent(relativePath)
            .standardizedFileURL

        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: currentWorkspacePath, isDirectory: true))
            return
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            NSWorkspace.shared.open(targetURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([targetURL])
        }
    }
}

struct SidebarProjectRow: View {
    let project: AppProject
    let isSelected: Bool
    let isAffiliated: Bool
    let isActive: Bool
    let hasRecentThread: Bool
    let onTap: () -> Void
    var onDelete: (() -> Void)? = nil
    @State private var isHovered = false
    @State private var isAnimating = false

    var body: some View {
        SidebarRow(action: onTap) {
            HStack(spacing: StudioSidebarLayout.iconTextSpacing) {
                // Status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .frame(width: StudioSidebarLayout.iconSize)

                VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                    Text(project.name)
                        .font(StudioTypography.subheadlineSemibold)
                        .foregroundStyle(StudioTextColor.primary)
                        .lineLimit(1)

                    if isActive {
                        HStack(spacing: StudioSpacing.sm) {
                            Circle()
                                .fill(StudioStatusColor.success)
                                .frame(width: 6, height: 6)
                                .scaleEffect(isAnimating ? 1.2 : 0.8)
                                .animation(StudioMotion.statusPulse, value: isAnimating)

                            Text("Running…")
                                .font(StudioTypography.micro)
                                .foregroundStyle(StudioTextColor.secondary)
                        }
                        .onAppear { isAnimating = true }
                        .onDisappear { isAnimating = false }
                    } else {
                        Text(project.displayGoal ?? project.primaryRiskLabel ?? project.secondaryRiskDetail ?? project.latestCriticVerdict ?? "")
                            .font(StudioTypography.micro)
                            .foregroundStyle(StudioTextColor.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)

                if isHovered, let onDelete {
                    Button(action: {
                        StudioFeedback.destructive()
                        onDelete()
                    }) {
                        Image(systemName: "trash")
                            .font(StudioTypography.captionMedium)
                            .foregroundStyle(StudioTextColor.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .help("Delete project")
                }
            }
        }
        .background(
            SidebarSelectableRowBackground(
                isSelected: isSelected,
                isHovered: isHovered
            )
        )
        .overlay {
            if isAffiliated && !isSelected {
                RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                    .fill(StudioAccentColor.primary.opacity(0.07))
            } else if hasRecentThread && !isSelected && !isActive {
                RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                    .fill(StudioAccentColor.primary.opacity(0.035))
            }
        }
        .onHover { isHovered = $0 }
    }

    private var statusColor: Color {
        if project.confidenceScore < 40 {
            return StudioStatusColor.danger
        } else if project.confidenceScore < 70 {
            return StudioStatusColor.warning
        } else {
            return StudioTextColor.secondary
        }
    }
}

// MARK: - Resume Row

struct SidebarResumeRow: View {
    let thread: PersistedThread
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        SidebarRow(action: onTap) {
            HStack(spacing: StudioSidebarLayout.iconTextSpacing) {
                Circle()
                    .fill(StudioAccentColor.primary)
                    .frame(width: 6, height: 6)
                    .frame(width: StudioSidebarLayout.iconSize)

                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title)
                        .font(StudioTypography.footnoteMedium)
                        .foregroundStyle(StudioTextColor.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(thread.updatedAt, style: .relative)
                        .font(StudioTypography.micro)
                        .foregroundStyle(StudioTextColor.tertiary)
                }
                Spacer(minLength: 0)

                Text("Resume")
                    .font(StudioTypography.microMedium)
                    .foregroundStyle(StudioAccentColor.primary.opacity(isHovered ? 1.0 : 0.7))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                .fill(isHovered ? StudioAccentColor.primary.opacity(0.06) : StudioAccentColor.primary.opacity(0.03))
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Thread Row

struct SidebarThreadRow: View {
    let thread: PersistedThread
    let onTap: () -> Void
    var onDelete: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        SidebarRow(action: onTap) {
            HStack(spacing: StudioSidebarLayout.iconTextSpacing) {
                Image(systemName: "text.bubble")
                    .font(StudioTypography.caption)
                    .foregroundStyle(StudioTextColor.tertiary)
                    .frame(width: StudioSidebarLayout.iconSize)

                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title)
                        .font(StudioTypography.footnote)
                        .foregroundStyle(StudioTextColor.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(thread.updatedAt, style: .relative)
                        .font(StudioTypography.micro)
                        .foregroundStyle(StudioTextColor.tertiary)
                }
                Spacer(minLength: 0)

                if isHovered, let onDelete {
                    Button(action: {
                        StudioFeedback.destructive()
                        onDelete()
                    }) {
                        Image(systemName: "trash")
                            .font(StudioTypography.captionMedium)
                            .foregroundStyle(StudioTextColor.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .help("Delete chat")
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                .fill(isHovered ? StudioSurfaceGrouped.secondary.opacity(0.036) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Layout Constants

// MARK: - Base Row

struct SidebarRow<Content: View>: View {
    let content: Content
    let action: () -> Void

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioSidebarLayout.iconTextSpacing) {
                content
                Spacer(minLength: 0)
            }
            .frame(height: StudioSidebarLayout.rowHeight)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Folder Row

struct SidebarFolderRow: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        SidebarRow(action: action) {
            HStack(spacing: StudioSpacing.sm) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .frame(width: 10)

                Image(systemName: "folder")
                    .frame(width: StudioSidebarLayout.iconSize)
            }
            .frame(width: 28, alignment: .leading)

            Text(title)
                .font(StudioTypography.subheadlineSemibold)
        }
    }
}

// MARK: - Item Row

struct SidebarItemRow: View {
    let title: String

    var body: some View {
        SidebarRow(action: {}) {
            Circle()
                .frame(width: 6, height: 6)
                .frame(width: StudioSidebarLayout.iconSize)

            Text(title)
                .font(StudioTypography.subheadline)
        }
    }
}

// MARK: - Header

struct SidebarHeader: View {
    let onNewThread: () -> Void
    let onCollapseSidebar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.lg) {
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: 0) {
                    Text("Studio")
                        .foregroundStyle(StudioTextColor.primary)
                    Text(".92")
                        .foregroundStyle(StudioAccentColor.primary)
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .tracking(-0.3)

                Spacer()

                Button(action: onCollapseSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(StudioTypography.captionMedium)
                        .foregroundStyle(StudioTextColor.tertiary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Hide Sidebar (⌃⌘S)")
            }
            .padding(.trailing, StudioSidebarLayout.inset + 4)

            SidebarRow(action: onNewThread) {
                Image(systemName: "square.and.pencil")
                    .frame(width: StudioSidebarLayout.iconSize)

                Text("Start new")
                    .font(StudioTypography.subheadline)
            }
        }
    }
}

// MARK: - Section Label

struct SidebarSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(StudioTypography.captionSemibold)
            .kerning(0.5)
            .foregroundStyle(StudioTextColor.secondary)
            .padding(.top, StudioSpacing.section)
            .padding(.bottom, StudioSpacing.md)
    }
}

// MARK: - Collapsible Section Header

struct SidebarCollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    var showAddButton: Bool = false

    @State private var isRowHovered = false
    @State private var isPlusHovered = false

    var body: some View {
        HStack(spacing: StudioSpacing.xs) {
            Button {
                withAnimation(StudioMotion.standardSpring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isRowHovered ? StudioTextColor.secondary : StudioTextColor.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(StudioMotion.fastSpring, value: isExpanded)

                    Text(title.uppercased())
                        .font(StudioTypography.captionSemibold)
                        .kerning(0.5)
                        .foregroundStyle(isRowHovered ? StudioTextColor.primary : StudioTextColor.secondary)
                }
            }
            .buttonStyle(.plain)
            .onHover { isRowHovered = $0 }

            Spacer(minLength: 0)

            if showAddButton {
                Button {
                    // project creation flow — future implementation
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isPlusHovered ? .white : StudioTextColor.tertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isPlusHovered = $0 }
                .animation(StudioMotion.fastSpring, value: isPlusHovered)
                .opacity(isRowHovered || isPlusHovered ? 1 : 0.5)
            }
        }
        .padding(.top, StudioSpacing.section)
        .padding(.bottom, StudioSpacing.md)
        .padding(.trailing, StudioSidebarLayout.inset)
        .animation(StudioMotion.softFade, value: isRowHovered)
    }
}

// MARK: - Search Pill

struct SidebarSearchPill: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            // Forward to the focused composer via ⌘K — wired by keyboardShortcut below
        } label: {
            HStack(spacing: StudioSpacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovered ? StudioTextColor.secondary : StudioTextColor.tertiary)
                    .padding(.leading, 4)

                Text("Search")
                    .font(StudioTypography.footnote)
                    .foregroundStyle(isHovered ? StudioTextColor.secondary : StudioTextColor.tertiary)

                Spacer(minLength: 0)

                Text("⌘K")
                    .font(StudioTypography.dataMicroSemibold)
                    .foregroundStyle(StudioTextColor.tertiary.opacity(0.55))
            }
            .padding(.horizontal, StudioSpacing.lg)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .fill(StudioSurface.searchPill)
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                            .stroke(Color.white.opacity(isHovered ? 0.10 : 0.06), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .frame(maxWidth: .infinity)
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fastSpring, value: isHovered)
    }
}

// MARK: - Footer

struct SidebarFooter: View {
    let onOpenWorkspace: () -> Void
    let currentWorkspacePath: String
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            footerButton(icon: "gearshape", label: "Settings", action: onOpenSettings)

            Spacer()

            footerButton(icon: "lightbulb", label: "Skills") {
                reveal(relativePath: ".agents/skills")
            }

            Spacer()

            footerButton(icon: "list.bullet.clipboard", label: "Rules") {
                reveal(relativePath: ".studio92/rules/default.rules")
            }
        }
        .foregroundStyle(StudioTextColor.secondary)
        .padding(.trailing, StudioSidebarLayout.inset)
        .padding(.bottom, StudioSpacing.section)
    }

    private func footerButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        SidebarFooterButton(icon: icon, label: label, action: action)
    }

    private func reveal(relativePath: String) {
        let targetURL = URL(fileURLWithPath: currentWorkspacePath, isDirectory: true)
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                NSWorkspace.shared.open(targetURL)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([targetURL])
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: currentWorkspacePath, isDirectory: true))
        }
    }
}

// MARK: - Workspace Footer

struct SidebarWorkspaceFooter: View {
    let workspacePath: String
    let onOpenWorkspace: () -> Void
    let onOpenSettings: () -> Void

    @State private var isWorkspaceHovered = false
    @State private var showMenu = false

    private var workspaceName: String {
        let name = URL(fileURLWithPath: workspacePath).lastPathComponent
        return name.isEmpty ? "Workspace" : name
    }

    var body: some View {
        VStack(spacing: 0) {
            // Thin separator
            Color.white.opacity(0.06)
                .frame(height: 0.5)
                .padding(.trailing, StudioSidebarLayout.inset)
                .padding(.bottom, StudioSpacing.md)

            // User identity block — single clean row, no redundant icon row
            Button {
                showMenu = true
            } label: {
                HStack(spacing: StudioSpacing.md) {
                    // Initials avatar
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.white.opacity(0.11), lineWidth: 0.5)
                        )
                        .overlay(
                            Text("TJ")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(StudioTextColor.secondary)
                        )
                        .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("TJ's Workspace")
                            .font(StudioTypography.footnoteSemibold)
                            .foregroundStyle(isWorkspaceHovered ? .white : StudioTextColor.secondary)
                            .lineLimit(1)

                        Text(workspaceName)
                            .font(StudioTypography.micro)
                            .foregroundStyle(StudioTextColor.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(StudioTextColor.tertiary.opacity(isWorkspaceHovered ? 0.9 : 0.4))
                }
                .padding(.vertical, StudioSpacing.md)
            }
            .buttonStyle(.plain)
            .padding(.trailing, StudioSidebarLayout.inset)
            .onHover { isWorkspaceHovered = $0 }
            .animation(StudioMotion.fastSpring, value: isWorkspaceHovered)
            .padding(.bottom, StudioSpacing.sm)
            .popover(isPresented: $showMenu, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    workspaceMenuItem(icon: "gearshape", label: "Settings", action: onOpenSettings)
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 1)
                        .padding(.vertical, 2)
                    workspaceMenuItem(icon: "lightbulb", label: "Skills") {
                        revealPath(".agents/skills", in: workspacePath)
                    }
                    workspaceMenuItem(icon: "list.bullet.clipboard", label: "Rules") {
                        revealPath(".studio92/rules/default.rules", in: workspacePath)
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 1)
                        .padding(.vertical, 2)
                    workspaceMenuItem(icon: "folder", label: "Open Workspace", action: onOpenWorkspace)
                }
                .padding(.vertical, StudioSpacing.xs)
                .frame(minWidth: 188)
                .background(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 8)
                .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func workspaceMenuItem(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { showMenu = false; action() }) {
            HStack(spacing: StudioSpacing.lg) {
                Image(systemName: icon)
                    .font(StudioTypography.footnote)
                    .frame(width: 16)
                Text(label)
                    .font(StudioTypography.footnote)
                Spacer()
            }
            .foregroundStyle(StudioTextColor.primary)
            .padding(.horizontal, StudioSpacing.xl)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func revealPath(_ relativePath: String, in root: String) {
        let targetURL = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                NSWorkspace.shared.open(targetURL)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([targetURL])
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: root, isDirectory: true))
        }
    }
}

private struct SidebarFooterButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: StudioSpacing.xxsPlus) {
                Image(systemName: icon)
                    .font(StudioTypography.captionMedium)
                Text(label)
                    .font(StudioTypography.badgeSmall)
                    .foregroundStyle(isHovered ? StudioTextColor.secondary : StudioTextColor.tertiary)
            }
            .frame(height: 32)
            .foregroundStyle(isHovered ? StudioTextColor.primary : StudioTextColor.secondary)
            .scaleEffect(isHovered ? StudioMotion.hoverScaleSmall : 1.0)
            .animation(StudioMotion.fastSpring, value: isHovered)
        }
        .buttonStyle(.plain)
        .help(label)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Settings Sheet

struct SidebarSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.section) {
            HStack {
                Text("Settings")
                    .font(StudioTypography.titleLarge)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("Configure API keys, models, and preferences.")
                .font(StudioTypography.footnote)
                .foregroundStyle(StudioTextColor.secondary)
        }
        .padding(StudioSpacing.sectionGap)
        .frame(width: 420)
    }
}

// MARK: - Sidebar

struct CleanSidebar: View {

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            SidebarHeader(onNewThread: {}, onCollapseSidebar: {})

            SidebarSectionLabel(title: "Projects")

            VStack(spacing: StudioSidebarLayout.rowSpacing) {

                SidebarFolderRow(
                    title: "Studio.92",
                    isExpanded: expanded
                ) {
                    withAnimation(StudioMotion.standardSpring) {
                        expanded.toggle()
                    }
                }

                if expanded {
                    VStack(spacing: StudioSidebarLayout.rowSpacing) {
                        SidebarItemRow(title: "Sidebar redesign")
                        SidebarItemRow(title: "Blender asset pipeline")
                    }
                    .padding(.leading, StudioSpacing.section)
                }

                SidebarFolderRow(title: "PocketProducer", isExpanded: false) {}
                SidebarFolderRow(title: "Kno", isExpanded: false) {}
                SidebarFolderRow(title: "RediM8", isExpanded: false) {}
            }

            Spacer()

            SidebarFooter(
                onOpenWorkspace: {},
                currentWorkspacePath: "",
                onOpenSettings: {}
            )
        }
        .padding(.leading, StudioSidebarLayout.inset)
    }
}

struct SidebarCommandButton: View {

    let action: () -> Void
    var isPipelineRunning: Bool = false
    @State private var isHovered = false
    @State private var isActivated = false
    @State private var activationTask: Task<Void, Never>?

    private var isEngaged: Bool {
        isHovered || isActivated
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                pulseActivation()
                action()
            } label: {
                HStack(spacing: StudioSpacing.lg) {
                    Image(systemName: StudioSymbol.resolve("rectangle.badge.sparkles.fill", "sparkles.rectangle.stack", "magnifyingglass"))
                        .font(StudioTypography.captionSemibold)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(isEngaged ? StudioTextColor.primary : StudioTextColor.secondary)
                        .frame(width: 18, height: 18)

                    Text("Search or Command")
                        .font(StudioTypography.footnoteMedium)
                        .foregroundStyle(isEngaged ? StudioTextColor.primary : StudioTextColor.secondary)

                    Spacer(minLength: 8)

                    Text("⌘K")
                        .font(StudioTypography.dataMicroSemibold)
                        .foregroundStyle(isEngaged ? StudioTextColor.secondary : StudioTextColor.tertiary)
                }
                .padding(.horizontal, StudioSpacing.xl)
                .padding(.vertical, StudioSpacing.lg)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)

            if isPipelineRunning {
                Rectangle()
                    .fill(StudioSeparator.subtle)
                    .frame(height: 1)
                    .padding(.horizontal, StudioSpacing.lg)

                HStack(spacing: StudioSpacing.sm) {
                    Image(systemName: "bolt.fill")
                        .font(StudioTypography.microSemibold)
                        .frame(width: 18, height: 18)

                    Text("Running")
                        .font(StudioTypography.captionMedium)

                    Spacer(minLength: 0)
                }
                .foregroundStyle(StudioTextColor.secondary.opacity(0.7))
                .padding(.horizontal, StudioSpacing.xl)
                .padding(.vertical, StudioSpacing.md)
            }
        }
        .background(
            SidebarRecessedFieldBackground(
                cornerRadius: StudioRadius.xl,
                isHovered: isHovered,
                isFocused: isEngaged
            )
        )
        .onHover { isHovered = $0 }
        .onDisappear {
            activationTask?.cancel()
        }
        .animation(StudioMotion.fastSpring, value: isHovered)
        .animation(StudioMotion.fastSpring, value: isActivated)
    }

    private func pulseActivation() {
        activationTask?.cancel()
        isActivated = true
        activationTask = Task {
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isActivated = false
            }
        }
    }
}

struct WorkspaceRailRow: View {

    let path: String
    let branchName: String?
    let isCurrent: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var displayName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private var subtitle: String {
        if let branchName, !branchName.isEmpty {
            return branchName
        }
        return path
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: StudioSpacing.lg) {
                Circle()
                    .fill(isCurrent ? StudioTextColor.primary.opacity(0.64) : StudioTextColor.tertiary)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus) {
                    Text(displayName)
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(StudioTextColor.primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(StudioTypography.dataMicro)
                        .foregroundStyle(StudioTextColor.secondary.opacity(0.82))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, StudioSpacing.lg)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SidebarSelectableRowBackground(
                    isSelected: isCurrent,
                    isHovered: isHovered
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fastSpring, value: isHovered)
    }
}

struct SidebarActiveThreadCard: View {

    let project: AppProject?
    let activeGoal: String?
    let isPipelineRunning: Bool

    private var title: String {
        if let project {
            return project.name
        }

        if let activeGoal {
            let trimmed = activeGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return "No active session"
    }

    private var subtitle: String {
        if let project, let verdict = project.latestCriticVerdict, !verdict.isEmpty {
            return verdict
        }

        if let project, let detail = project.displayGoal, !detail.isEmpty {
            return detail
        }

        if isPipelineRunning {
            return "Processing…"
        }

        return "Start a conversation to begin."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.sm) {
            HStack(spacing: StudioSpacing.sm) {
                Circle()
                    .fill(isPipelineRunning ? StudioStatusColor.success : StudioTextColor.tertiary)
                    .frame(width: 7, height: 7)

                Text(isPipelineRunning ? "Running" : "Session")
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(StudioTextColor.tertiary)

                Spacer(minLength: 0)
            }

            Text(title)
                .font(StudioTypography.subheadlineSemibold)
                .foregroundStyle(StudioTextColor.primary)
                .lineLimit(2)

            Text(subtitle)
                .font(StudioTypography.caption)
                .foregroundStyle(StudioTextColor.secondary.opacity(0.86))
                .lineLimit(2)
        }
        .padding(.horizontal, StudioSpacing.xxs)
        .padding(.vertical, StudioSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfrastructureRailButton: View {

    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            InfrastructureRailLabel(
                title: title,
                systemImage: systemImage
            )
        }
        .buttonStyle(.plain)
    }
}

struct InfrastructureRailLabel: View {

    let title: String
    let systemImage: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: StudioSpacing.lg) {
            Image(systemName: systemImage)
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(isHovered ? StudioTextColor.primary : StudioTextColor.secondary)
                .frame(width: 18, height: 18)

            Text(title)
                .font(StudioTypography.footnoteMedium)
                .foregroundStyle(isHovered ? StudioTextColor.primary : StudioTextColor.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SidebarSelectableRowBackground(
                isSelected: false,
                isHovered: isHovered,
                cornerRadius: StudioRadius.md
            )
        )
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fastSpring, value: isHovered)
    }
}

struct FleetSectionHeader: View {

    let title: String

    var body: some View {
        Text(title)
            .font(StudioTypography.captionMedium)
            .foregroundStyle(StudioTextColor.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}


struct WorkspaceRepositoryStatusStrip: View {

    let repositoryState: GitRepositoryState
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: StudioSpacing.lg) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                Text(title)
                    .font(StudioTypography.microSemibold)
                    .tracking(0.3)
                    .foregroundStyle(StudioTextColor.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(StudioTypography.badgeSmallMono)
                    .foregroundStyle(StudioTextColor.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, 9)
    }

    private var title: String {
        switch repositoryState.phase {
        case .ready:
            return repositoryState.branchDisplayName
        case .loading:
            return "Reading Git state"
        case .notRepository:
            return "Git unavailable"
        case .missingWorkspace:
            return "Workspace missing"
        case .failed:
            return "Git check failed"
        }
    }

    private var subtitle: String {
        switch repositoryState.phase {
        case .ready:
            let summary = repositoryState.changeSummary
            if summary.totalCount == 0 {
                return repositoryState.repositoryDisplayName
            }
            return "\(summary.totalCount) pending change\(summary.totalCount == 1 ? "" : "s")"
        case .loading:
            return repositoryState.workspaceDisplayName
        case .notRepository, .missingWorkspace, .failed:
            return repositoryState.workspaceDisplayName
        }
    }

    private var statusColor: Color {
        switch repositoryState.phase {
        case .ready:
            return repositoryState.changeSummary.totalCount == 0 ? StudioStatusColor.success : StudioStatusColor.warning
        case .loading:
            return StudioTextColor.secondary
        case .notRepository, .failed, .missingWorkspace:
            return StudioStatusColor.warning
        }
    }
}



struct FleetCompactEmptyState: View {

    var title: String = "No threads yet"
    var subtitle: String = "Open a workspace or start from the composer."

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            Text(title)
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(StudioTextColor.primary)

            Text(subtitle)
                .font(StudioTypography.micro)
                .foregroundStyle(StudioTextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, StudioSpacing.xl)
    }
}

struct StudioPillFlowLayout: Layout {

    var horizontalSpacing: CGFloat = 12
    var verticalSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layoutFrames(for: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = layoutFrames(
            for: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )

        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func layoutFrames(for proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard !subviews.isEmpty else { return (.zero, []) }

        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var frames: [CGRect] = []
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var usedHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if cursorX > 0, cursorX + size.width > maxWidth {
                cursorX = 0
                cursorY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            let frame = CGRect(x: cursorX, y: cursorY, width: size.width, height: size.height)
            frames.append(frame)

            usedWidth = max(usedWidth, frame.maxX)
            usedHeight = max(usedHeight, frame.maxY)
            cursorX = frame.maxX + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return (CGSize(width: usedWidth, height: usedHeight), frames)
    }
}

/// A single row in the Fleet sidebar.
struct FleetRow: View {

    let project: AppProject
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: StudioSpacing.md) {
            Circle()
                .fill(isSelected ? StudioTextColor.primary.opacity(0.72) : riskColor(for: project.confidenceScore))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus) {
                Text(project.name)
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColor.primary)
                    .lineLimit(1)

                Text(projectRowSubtitle)
                    .font(StudioTypography.micro)
                    .foregroundStyle(StudioTextColor.secondary.opacity(0.84))
                    .lineLimit(2)
            }

            Spacer(minLength: 6)
        }
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SidebarSelectableRowBackground(
                isSelected: isSelected,
                isHovered: isHovered
            )
        )
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fastSpring, value: isHovered)
    }

    private var projectRowSubtitle: String {
        if let archetype = project.dominantArchetype, !archetype.isEmpty {
            return archetype
        }
        if let risk = project.primaryRiskLabel, !risk.isEmpty {
            return risk
        }
        if let detail = project.secondaryRiskDetail, !detail.isEmpty {
            return detail
        }
        return "Ready"
    }

    private func riskIcon(for risk: String) -> String {
        switch risk {
        case "HIG Violation":  return "exclamationmark.triangle.fill"
        case "Drift Alert":    return "arrow.triangle.swap"
        case "Budget Critical": return "gauge.with.dots.needle.67percent"
        default:               return "exclamationmark.circle"
        }
    }

    private func riskColor(for score: Int) -> Color {
        if score >= 70 { return StudioTextColor.secondary }
        if score >= 40 { return StudioStatusColor.warning }
        return StudioStatusColor.danger
    }
}

struct FleetJobRow: View {

    let session: AgentSession
    let isSelected: Bool
    @State private var isHovered = false
    @ObservedObject private var commandApproval = CommandApprovalController.shared

    private var statusColor: Color {
        switch session.status {
        case .queued:
            return StudioStatusColor.success.opacity(0.72)
        case .preparing, .running, .reviewing:
            return StudioStatusColor.success
        case .completed:
            return StudioStatusColor.success
        case .failed, .cancelled:
            return StudioStatusColor.danger
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: StudioSpacing.md) {
            VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus) {
                HStack(spacing: StudioSpacing.md) {
                    SidebarJobActivityIndicator(
                        color: statusColor,
                        isAnimating: true
                    )

                    Text(session.branchName)
                        .font(StudioTypography.dataMicroSemibold)
                        .foregroundStyle(StudioTextColor.secondary.opacity(0.82))
                        .lineLimit(1)
                }

                Text(session.progressSummary)
                    .font(StudioTypography.micro)
                    .foregroundStyle(StudioTextColor.secondary.opacity(0.82))
                    .lineLimit(2)

                Text(session.displayTitle)
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColor.primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)
        }
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SidebarSelectableRowBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                railColor: isSelected && commandApproval.pendingRequest != nil
                ? Color(hex: "#FFB340")
                : (session.status == .failed ? Color(hex: "#FF7373") : StudioAccentColor.primary)
            )
        )
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fastSpring, value: isHovered)
    }
}

struct SidebarSelectableRowBackground: View {

    let isSelected: Bool
    let isHovered: Bool
    var cornerRadius: CGFloat = 8
    var railColor: Color = StudioAccentColor.primary

    private var isEngaged: Bool {
        isSelected || isHovered
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(backgroundColor)
            .overlay {
                if isEngaged {
                    SidebarNativeGlassLayer(
                        cornerRadius: cornerRadius,
                        tint: glassTint,
                        useClearGlass: !isSelected,
                        interactive: isHovered,
                        opacity: glassOpacity,
                        fallbackFillOpacity: fallbackGlassFillOpacity
                    )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: borderOpacity > 0 ? 1 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: 1)
                    .stroke(innerHighlightColor, lineWidth: innerHighlightOpacity > 0 ? 1 : 0)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(railColor)
                        .frame(width: 2)
                        .padding(.vertical, StudioSpacing.xs)
                        .shadow(color: railColor.opacity(0.5), radius: 4)
                }
            }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.white.opacity(isHovered ? 0.055 : 0.04)
        }

        if isHovered {
            return Color.white.opacity(0.025)
        }

        return Color.clear
    }

    private var glassTint: Color {
        if isSelected {
            return StudioSurfaceGrouped.secondary.opacity(isHovered ? 0.10 : 0.08)
        }

        return StudioSurfaceGrouped.secondary.opacity(0.05)
    }

    private var glassOpacity: Double {
        if isSelected {
            return isHovered ? 0.90 : 0.82
        }

        return 0.72
    }

    private var fallbackGlassFillOpacity: Double {
        if isSelected {
            return isHovered ? 0.05 : 0.04
        }

        return 0.022
    }

    private var borderColor: Color {
        StudioSurfaceGrouped.secondary.opacity(borderOpacity)
    }

    private var borderOpacity: Double {
        if isSelected {
            return isHovered ? 0.12 : 0.09
        }

        if isHovered {
            return 0.06
        }

        return 0
    }

    private var innerHighlightColor: Color {
        StudioTextColor.primary.opacity(innerHighlightOpacity)
    }

    private var innerHighlightOpacity: Double {
        if isSelected {
            return 0.04
        }

        if isHovered {
            return 0.022
        }

        return 0
    }
}

struct SidebarRecessedFieldBackground: View {

    let cornerRadius: CGFloat
    let isHovered: Bool
    let isFocused: Bool

    private var isEngaged: Bool {
        isHovered || isFocused
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFillColor)
            .overlay {
                if isEngaged {
                    SidebarNativeGlassLayer(
                        cornerRadius: cornerRadius,
                        tint: glassTint,
                        useClearGlass: false,
                        interactive: true,
                        opacity: isFocused ? 0.96 : 0.82,
                        fallbackFillOpacity: isFocused ? 0.075 : 0.05
                    )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: 1)
                    .stroke(innerHighlightColor, lineWidth: innerHighlightOpacity > 0 ? 1 : 0)
            )
    }

    private var baseFillColor: Color {
        if isFocused {
            return StudioSurfaceGrouped.secondary.opacity(0.060)
        }

        if isHovered {
            return StudioSurfaceGrouped.secondary.opacity(0.045)
        }

        return StudioSurfaceGrouped.secondary.opacity(0.032)
    }

    private var glassTint: Color {
        if isFocused {
            return StudioSurfaceGrouped.secondary.opacity(0.12)
        }

        return StudioSurfaceGrouped.secondary.opacity(0.07)
    }

    private var borderColor: Color {
        if isFocused {
            return StudioSurfaceGrouped.secondary.opacity(0.14)
        }

        if isHovered {
            return StudioSurfaceGrouped.secondary.opacity(0.10)
        }

        return StudioSurfaceGrouped.secondary.opacity(0.07)
    }

    private var innerHighlightColor: Color {
        StudioTextColor.primary.opacity(innerHighlightOpacity)
    }

    private var innerHighlightOpacity: Double {
        if isFocused {
            return 0.08
        }

        if isHovered {
            return 0.04
        }

        return 0
    }
}

struct SidebarNativeGlassLayer: View {

    let cornerRadius: CGFloat
    let tint: Color
    let useClearGlass: Bool
    let interactive: Bool
    let opacity: Double
    let fallbackFillOpacity: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Group {
            if #available(macOS 26.0, *) {
                shape
                    .fill(tint.opacity(fallbackFillOpacity * 1.6))
                    .glassEffect(configuredGlass, in: shape)
                    .opacity(opacity)
            } else {
                shape
                    .fill(tint.opacity(fallbackFillOpacity * 1.4))
                    .opacity(opacity)
            }
        }
    }

    @available(macOS 26.0, *)
    private var configuredGlass: Glass {
        let base = useClearGlass ? Glass.clear : Glass.regular
        return base
            .tint(tint)
            .interactive(interactive)
    }
}

struct SidebarJobActivityIndicator: View {

    let color: Color
    let isAnimating: Bool

    @ViewBuilder
    var body: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: "circle.dashed")
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(color)
                .symbolEffect(.rotate.byLayer, options: .repeating, isActive: isAnimating)
        } else {
            Image(systemName: "circle.dashed")
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating, isActive: isAnimating)
        }
    }
}

// MARK: - Sidebar Indexing Row

private struct SidebarIndexingRow: View {

    @State private var shimmerPhase: CGFloat = -1.0

    var body: some View {
        HStack(spacing: StudioSpacing.sm) {
            // Animated spinner
            Image(systemName: "circle.dotted")
                .font(StudioTypography.captionMedium)
                .foregroundStyle(Color(hex: "#7E8794"))
                .symbolEffect(.pulse.wholeSymbol, options: .repeating)

            // Label
            Text("Indexing workspace\u{2026}")
                .font(StudioTypography.footnote)
                .foregroundStyle(Color(hex: "#7E8794"))

            Spacer(minLength: 0)
        }
        .padding(.vertical, StudioSpacing.md)
        // Shimmer overlay — horizontal sweep across the row
        .overlay(
            GeometryReader { geo in
                LinearGradient(
                    colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.09),
                        Color.white.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.45)
                .offset(x: shimmerPhase * (geo.size.width + geo.size.width * 0.45))
            }
            .clipped()
            .allowsHitTesting(false)
        )
        .onAppear {
            withAnimation(
                Animation.linear(duration: 1.6).repeatForever(autoreverses: false)
            ) {
                shimmerPhase = 1.0
            }
        }
    }
}



