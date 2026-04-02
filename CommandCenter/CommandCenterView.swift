// CommandCenterView.swift
// Studio.92 — Command Center
// The 3-pane operator console: Fleet sidebar, Diff Inspector, Auditor.

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

private enum ArtifactCanvasLaunchMode {
    case inspector
    case preview
    case codeDiff
    case deployment
}

enum StudioTheme {
    static let midnight = Color.black
    static let charcoal = Color.black
    static let moss = Color.black
    static let sidebarBackground = Color.black
    static let panelBackground = Color(white: 0.05)
    static let elevatedPanel = Color(white: 0.05)
    static let capsuleTop = Color.black
    static let capsuleBottom = Color.black
    static let terminalBackground = Color(white: 0.04)
    static let primaryText = Color(hex: "#F4F4F0")
    static let secondaryText = primaryText.opacity(0.6)
    static let tertiaryText = primaryText.opacity(0.5)
    static let placeholderText = primaryText.opacity(0.5)
    static let accentBase = Color(hex: "#CBA365")
    static let accent = Color(hex: "#CBA365")
    static let accentHighlight = Color(hex: "#CBA365")
    static let surfaceBare = primaryText.opacity(0.03)
    static let surfaceSoft = primaryText.opacity(0.04)
    static let surfaceEmphasis = primaryText.opacity(0.05)
    static let surfaceHighlight = primaryText.opacity(0.06)
    static let surfaceWarm = Color(white: 0.05)
    static let liftedSurface = Color(white: 0.05)
    static let success = accent.opacity(0.96)
    static let warning = accent.opacity(0.84)
    static let danger = primaryText.opacity(0.88)
    static let successSurface = accent.opacity(0.12)
    static let successStroke = accent.opacity(0.24)
    static let warningSurface = accent.opacity(0.10)
    static let warningStroke = accent.opacity(0.20)
    static let dangerSurface = primaryText.opacity(0.06)
    static let dangerStroke = primaryText.opacity(0.12)
    static let stroke = primaryText.opacity(0.13)
    static let subtleStroke = primaryText.opacity(0.075)
    static let surfaceFill = primaryText.opacity(0.05)
    static let accentSurface = accent.opacity(0.12)
    static let accentSurfaceStrong = accent.opacity(0.18)
    static let accentFill = accent.opacity(0.16)
    static let accentBorder = accent.opacity(0.24)
    static let accentBorderStrong = accent.opacity(0.28)
    static let accentStroke = accent.opacity(0.5)
    static let divider = primaryText.opacity(0.08)
    static let dockFill = Color.black.opacity(0.92)
    static let dockDivider = primaryText.opacity(0.05)
    static let composerFill = panelBackground.opacity(0.96)
    static let composerBorder = accent.opacity(0.32)
    static let softShadow = Color.black.opacity(0.42)
    static let accentShadow = Color.black.opacity(0.28)
    static let creamShadow = Color.black.opacity(0.18)
}

private extension Color {
    init(hex: String) {
        let sanitizedHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitizedHex).scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255

        self.init(red: red, green: green, blue: blue)
    }
}

private enum StudioWordmarkFont {
    static func display(size: CGFloat) -> Font {
        if NSFont(name: "Cochin-Bold", size: size) != nil {
            return .custom("Cochin-Bold", size: size)
        }
        return .system(size: size, weight: .semibold, design: .serif)
    }

    static func body(size: CGFloat) -> Font {
        if NSFont(name: "Cochin", size: size) != nil {
            return .custom("Cochin", size: size)
        }
        return .system(size: size, weight: .medium, design: .serif)
    }
}

private enum CalmChatLayout {
    static let columnMinWidth: CGFloat = 600
    static let columnIdealWidth: CGFloat = 680
    static let columnMaxWidth: CGFloat = 720
    static let columnHorizontalPadding: CGFloat = 24
    static let columnVerticalPadding: CGFloat = 32
    static let messageSpacing: CGFloat = 24
    static let messageInternalSpacing: CGFloat = 12
    static let bodyFontSize: CGFloat = 14
    static let bodyLetterSpacing: CGFloat = -0.2
    static let bodyLineSpacing: CGFloat = 6
    static let headingFontSize: CGFloat = 18
    static let headingTopSpacing: CGFloat = 16
    static let headingBottomSpacing: CGFloat = 8
    static let metaFontSize: CGFloat = 12
    static let composerHeight: CGFloat = 56
    static let composerCornerRadius: CGFloat = 16
    static let composerHorizontalPadding: CGFloat = 16
    static let floatingComposerBottomInset: CGFloat = 64
    static let floatingComposerReserveGap: CGFloat = 18

    static func columnWidth(for totalWidth: CGFloat) -> CGFloat {
        let availableWidth = max(totalWidth - (columnHorizontalPadding * 2), 0)

        if availableWidth >= columnMaxWidth {
            return columnIdealWidth
        }

        if availableWidth >= columnMinWidth {
            return min(availableWidth, columnMaxWidth)
        }

        return availableWidth
    }
}

private struct CalmChatColumn<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct CalmChatMetaCard<Content: View>: View {
    let opacity: Double
    @ViewBuilder let content: () -> Content

    init(opacity: Double = 0.6, @ViewBuilder content: @escaping () -> Content) {
        self.opacity = opacity
        self.content = content
    }

    var body: some View {
        content()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(StudioTheme.surfaceBare)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(StudioTheme.dockDivider, lineWidth: 1)
            )
            .opacity(opacity)
    }
}

private struct StudioBackgroundView: View {

    var body: some View {
        ZStack {
            Color.black

            RadialGradient(
                colors: [
                    StudioTheme.primaryText.opacity(0.04),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 460
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    StudioTheme.panelBackground.opacity(0.42)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct StudioCanvasView: View {

    var body: some View {
        ZStack {
            Color.black

            RadialGradient(
                colors: [
                    StudioTheme.primaryText.opacity(0.035),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 360
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    StudioTheme.panelBackground.opacity(0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct StudioWordmarkView: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text("Studio")
                .foregroundStyle(StudioTheme.primaryText)

            Text(".92")
                .foregroundStyle(StudioTheme.accent)
        }
        .font(.system(size: size, weight: .bold, design: .serif))
        .tracking(0.2)
    }
}

// MARK: - CommandCenterView

/// Root view. Owns all selection state. Drives the NavigationSplitView.
struct CommandCenterView: View {

    @Environment(\.modelContext) private var modelContext
    @AppStorage("packageRoot") private var storedPackageRoot = ""
    @State private var engine = LiveStateEngine()
    @State private var selectedProjectID: UUID?
    @State private var selectedEpochID: UUID?
    @State private var isCanvasOpen = false
    @State private var artifactCanvasMode: ArtifactCanvasLaunchMode = .preview
    @State private var showInspector = false
    @State private var runner: PipelineRunner
    @State private var repositoryMonitor: RepositoryMonitor
    @State private var jobMonitor: JobMonitor
    @State private var conversationStore = ConversationStore()
    @State private var goalText = ""
    @State private var composerAttachments: [ChatAttachment] = []
    @State private var selectedSessionID: UUID?
    @AppStorage("autonomyMode") private var autonomyMode = AutonomyMode.review.rawValue

    init(packageRoot: String) {
        _runner = State(initialValue: PipelineRunner(packageRoot: packageRoot))
        _repositoryMonitor = State(
            initialValue: RepositoryMonitor(
                workspaceURL: URL(fileURLWithPath: packageRoot, isDirectory: true)
            )
        )
        _jobMonitor = State(
            initialValue: JobMonitor(
                workspaceURL: URL(fileURLWithPath: packageRoot, isDirectory: true)
            )
        )
    }

    private var selectedProject: AppProject? {
        guard let id = selectedProjectID else { return nil }
        return engine.project(for: id)
    }

    private var selectedEpoch: Epoch? {
        guard let selectedProjectID, let selectedEpochID else { return nil }
        return engine.epoch(for: selectedEpochID, in: selectedProjectID)
    }

    private var selectedSession: AgentSession? {
        jobMonitor.session(id: selectedSessionID)
    }

    private var sortedProjects: [AppProject] {
        engine.projects.sorted { $0.confidenceScore > $1.confidenceScore }
    }

    private var shouldRenderArtifactCanvas: Bool {
        selectedSession == nil && (
            selectedProject != nil
            || selectedEpoch != nil
            || runner.isRunning
            || runner.deploymentState.isVisible
            || !conversationStore.turns.isEmpty
        )
    }

    private var sidebarContent: some View {
        FleetSidebar(
            projects: sortedProjects,
            jobs: jobMonitor.sessions,
            repositoryState: repositoryMonitor.repositoryState,
            isRefreshingRepository: repositoryMonitor.isRefreshing,
            selectedProjectID: selectedProjectID,
            selectedSessionID: selectedSessionID,
            onSelectProject: selectProject,
            onSelectSession: selectSession,
            onOpenWorkspace: openWorkspacePanel
        )
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
    }

    @ViewBuilder
    private var primaryDetailContent: some View {
        if let selectedSession {
            WorktreeJobDetailPane(session: selectedSession)
        } else {
            DiffInspectorPane(
                project: selectedProject,
                selectedEpochID: $selectedEpochID,
                runner: runner,
                repositoryState: repositoryMonitor.repositoryState,
                isRefreshingRepository: repositoryMonitor.isRefreshing,
                conversationStore: conversationStore,
                goalText: $goalText,
                attachments: $composerAttachments,
                onSubmit: submitGoal,
                onOpenArtifact: openArtifactCanvas,
                onRefreshRepository: refreshRepositoryStatus,
                onInitializeRepository: initializeGitRepository,
                onOpenWorkspace: openWorkspacePanel
            )
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        HStack(spacing: 0) {
            primaryDetailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isCanvasOpen, shouldRenderArtifactCanvas {
                Divider()
                    .overlay(StudioTheme.divider)
                    .transition(.opacity)

                ArtifactCanvasView(
                    epoch: selectedEpoch,
                    turns: conversationStore.turns,
                    deploymentState: runner.deploymentState,
                    packageRoot: runner.packageRoot,
                    initialMode: artifactCanvasMode,
                    onClose: closeArtifactCanvas
                )
                .frame(minWidth: 300, idealWidth: 400, maxWidth: 500, maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioCanvasView())
    }

    var body: some View {
        ZStack {
            StudioBackgroundView()

            NavigationSplitView {
                sidebarContent
            } detail: {
                detailContent
            }
        }
        .tint(StudioTheme.accent)
        .accentColor(StudioTheme.accent)
        .foregroundStyle(StudioTheme.primaryText)
        .preferredColorScheme(.dark)
        .inspector(isPresented: $showInspector) {
            if let project = selectedProject {
                AuditorPane(project: project, selectedEpochID: selectedEpochID, runner: runner)
            } else {
                AuditorEmptyState()
            }
        }
        .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Auditor", systemImage: "sidebar.trailing")
                }
                .help("Toggle the Auditor inspector")
            }
        }
        .onAppear {
            engine.load(from: modelContext)
            repositoryMonitor.start()
            jobMonitor.start()
        }
        .onDisappear {
            repositoryMonitor.stop()
            jobMonitor.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .telemetryIngested)) { notification in
            // Reload when a telemetry file is ingested (from terminal, cron, or anywhere)
            engine.load(from: modelContext)
            if let projectID = notification.userInfo?["projectID"] as? UUID {
                if selectedProjectID == nil {
                    selectedProjectID = projectID
                }

                if let project = engine.project(for: projectID),
                   let latestEpoch = project.epochs.max(by: { $0.index < $1.index }) {
                    if selectedProjectID == projectID {
                        selectedEpochID = latestEpoch.id
                    }
                    runner.attachCompletionIfMatching(epoch: latestEpoch, goal: project.goal)
                }
            }
        }
        .onChange(of: selectedEpochID) { _, newValue in
            guard newValue != nil else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isCanvasOpen = true
            }
        }
        .onChange(of: selectedProjectID) { _, newValue in
            guard newValue != nil else { return }
            selectedSessionID = nil
            artifactCanvasMode = .inspector
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isCanvasOpen = true
            }
        }
        .onChange(of: selectedSessionID) { _, newValue in
            guard newValue != nil else { return }
            selectedProjectID = nil
            selectedEpochID = nil
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                isCanvasOpen = false
            }
        }
        .onChange(of: jobMonitor.sessions) { _, sessions in
            guard let selectedSessionID else { return }
            if sessions.contains(where: { $0.id == selectedSessionID }) == false {
                self.selectedSessionID = nil
            }
        }
        .onChange(of: runner.isRunning) { _, isRunning in
            guard isRunning else { return }
            artifactCanvasMode = .inspector
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isCanvasOpen = true
            }
        }
        .onChange(of: runner.deploymentState.signature) { _, _ in
            guard runner.deploymentState.isVisible else { return }
            artifactCanvasMode = .deployment
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isCanvasOpen = true
            }
        }
    }

    private func submitGoal() {
        let rawGoal = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = composerAttachments
        let hasVisualReference = attachments.contains(where: { $0.isImage })
        let displayGoal = rawGoal.isEmpty && hasVisualReference
            ? "Recreate the attached visual reference in native SwiftUI."
            : rawGoal
        guard !displayGoal.isEmpty else { return }
        let goal = composePipelineGoal(displayGoal: displayGoal, attachments: attachments)
        goalText = ""
        composerAttachments = []

        let apiKey = UserDefaults.standard.string(forKey: "anthropicAPIKey")
        let openAIKey = UserDefaults.standard.string(forKey: "openAIAPIKey")

        Task {
            await runner.run(
                goal: goal,
                displayGoal: displayGoal,
                attachments: attachments,
                apiKey: apiKey,
                openAIKey: openAIKey,
                autonomyMode: selectedAutonomyMode
            )

            if runner.stage == .succeeded,
               let json = runner.approvedPacketJSON,
               let data = json.data(using: .utf8),
               let packet = try? JSONDecoder().decode(PacketSummary.self, from: data) {
                let result = engine.ingestPipelineResult(
                    goal: goal,
                    displayGoal: displayGoal,
                    packet: packet,
                    context: modelContext
                )
                if case .success(let projectID) = result {
                    selectedProjectID = projectID
                    if let latestEpoch = engine.project(for: projectID)?.epochs.max(by: { $0.index < $1.index }) {
                        selectedEpochID = latestEpoch.id
                        runner.attachCompletionIfMatching(epoch: latestEpoch, goal: goal)
                    }
                }
            }
        }
    }

    private var selectedAutonomyMode: AutonomyMode {
        AutonomyMode(rawValue: autonomyMode) ?? .review
    }

    private func composePipelineGoal(displayGoal: String, attachments: [ChatAttachment]) -> String {
        let fileReferences = attachments.filter { !$0.isImage }
        guard !fileReferences.isEmpty else { return displayGoal }

        let references = fileReferences
            .map { "- \($0.url.path)" }
            .joined(separator: "\n")

        return """
        \(displayGoal)

        Reference files:
        \(references)
        """
    }

    private func openArtifactCanvas(
        for epochID: UUID?,
        preferredMode: ArtifactCanvasLaunchMode = .preview
    ) {
        if let epochID {
            selectedEpochID = epochID
        }

        artifactCanvasMode = preferredMode

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isCanvasOpen = true
        }
    }

    private func closeArtifactCanvas() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isCanvasOpen = false
        }
    }

    @MainActor
    private func openWorkspacePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open Workspace"
        panel.message = "Choose the workspace folder Studio.92 should operate on."
        panel.directoryURL = URL(fileURLWithPath: runner.packageRoot, isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectWorkspace(url)
    }

    @MainActor
    private func selectWorkspace(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        storedPackageRoot = normalizedURL.path
        runner.updatePackageRoot(normalizedURL.path)
        repositoryMonitor.updateWorkspace(normalizedURL)
        jobMonitor.updateWorkspace(normalizedURL)
        goalText = ""
        composerAttachments = []
        selectedProjectID = nil
        selectedEpochID = nil
        selectedSessionID = nil
        conversationStore = ConversationStore()
        artifactCanvasMode = .inspector

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isCanvasOpen = false
        }
    }

    @MainActor
    private func selectProject(_ projectID: UUID) {
        selectedSessionID = nil
        selectedProjectID = projectID
    }

    @MainActor
    private func selectSession(_ sessionID: UUID) {
        selectedSessionID = sessionID
    }

    private func refreshRepositoryStatus() {
        repositoryMonitor.refreshNow()
    }

    private func initializeGitRepository() {
        repositoryMonitor.initializeRepository()
    }
}

// MARK: - Fleet Sidebar (Pane 1)

/// Left sidebar: sorted list of active projects with risk labels.
private struct FleetSidebar: View {

    let projects: [AppProject]
    let jobs: [AgentSession]
    let repositoryState: GitRepositoryState
    let isRefreshingRepository: Bool
    let selectedProjectID: UUID?
    let selectedSessionID: UUID?
    let onSelectProject: (UUID) -> Void
    let onSelectSession: (UUID) -> Void
    let onOpenWorkspace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioWordmarkView(size: 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            WorkspaceRepositoryStatusStrip(
                repositoryState: repositoryState,
                isRefreshing: isRefreshingRepository
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Group {
                if projects.isEmpty, jobs.isEmpty {
                    FleetEmptyState(onOpenWorkspace: onOpenWorkspace)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if !projects.isEmpty {
                                FleetSectionHeader(title: "Projects")

                                VStack(spacing: 10) {
                                    ForEach(projects, id: \.id) { project in
                                        Button {
                                            onSelectProject(project.id)
                                        } label: {
                                            FleetRow(
                                                project: project,
                                                isSelected: selectedProjectID == project.id
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            if !jobs.isEmpty {
                                FleetSectionHeader(title: "Jobs")

                                VStack(spacing: 10) {
                                    ForEach(jobs) { job in
                                        Button {
                                            onSelectSession(job.id)
                                        } label: {
                                            FleetJobRow(
                                                session: job,
                                                isSelected: selectedSessionID == job.id
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                        .padding(.top, 8)
                    }
                }
            }
        }
        .background(
            Color.black
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(StudioTheme.dockDivider)
                .frame(width: 1)
        }
    }
}

private struct FleetSectionHeader: View {

    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(StudioTheme.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkspaceRepositoryStatusStrip: View {

    let repositoryState: GitRepositoryState
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(StudioTheme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StudioTheme.surfaceSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
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
            return repositoryState.changeSummary.totalCount == 0 ? StudioTheme.success : StudioTheme.warning
        case .loading:
            return StudioTheme.secondaryText
        case .notRepository, .failed, .missingWorkspace:
            return StudioTheme.warning
        }
    }
}

private struct WorkspaceRepositoryCard: View {

    let repositoryState: GitRepositoryState
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onInitializeGit: () -> Void
    let onOpenWorkspace: () -> Void

    private var summary: GitChangeSummary {
        repositoryState.changeSummary
    }

    private var visibleWorktrees: [GitWorktree] {
        Array(repositoryState.worktrees.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTheme.secondaryText)

                    Text(repositoryState.repositoryDisplayName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StudioTheme.primaryText)
                        .lineLimit(1)

                    Text(repositoryState.workspacePath)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioTheme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(StudioTheme.secondaryText)
                    }

                    WorkspaceRepositoryActionButton(
                        title: "Refresh",
                        systemImage: "arrow.clockwise",
                        action: onRefresh
                    )
                }
            }

            Text(repositoryState.detailMessage)
                .font(.callout)
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            switch repositoryState.phase {
            case .ready:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        WorkspaceRepositoryMetricPill(
                            title: repositoryState.branchDisplayName,
                            systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                        )

                        if repositoryState.aheadCount > 0 || repositoryState.behindCount > 0 {
                            WorkspaceRepositoryMetricPill(
                                title: "↑\(repositoryState.aheadCount) ↓\(repositoryState.behindCount)",
                                systemImage: "arrow.left.arrow.right"
                            )
                        }

                        WorkspaceRepositoryMetricPill(
                            title: "\(repositoryState.worktreeCount) worktree\(repositoryState.worktreeCount == 1 ? "" : "s")",
                            systemImage: "square.split.2x1"
                        )
                    }

                    HStack(spacing: 8) {
                        if summary.totalCount == 0 {
                            WorkspaceRepositoryMetricPill(
                                title: "Clean",
                                systemImage: "checkmark.circle"
                            )
                        } else {
                            if summary.stagedCount > 0 {
                                WorkspaceRepositoryMetricPill(
                                    title: "\(summary.stagedCount) staged",
                                    systemImage: "square.and.arrow.down"
                                )
                            }
                            if summary.unstagedCount > 0 {
                                WorkspaceRepositoryMetricPill(
                                    title: "\(summary.unstagedCount) unstaged",
                                    systemImage: "pencil.line"
                                )
                            }
                            if summary.untrackedCount > 0 {
                                WorkspaceRepositoryMetricPill(
                                    title: "\(summary.untrackedCount) untracked",
                                    systemImage: "questionmark.folder"
                                )
                            }
                            if summary.conflictedCount > 0 {
                                WorkspaceRepositoryMetricPill(
                                    title: "\(summary.conflictedCount) conflicted",
                                    systemImage: "exclamationmark.triangle"
                                )
                            }
                        }
                    }

                    if !visibleWorktrees.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Worktrees")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StudioTheme.secondaryText)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(visibleWorktrees) { worktree in
                                        WorkspaceRepositoryWorktreePill(worktree: worktree)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

            case .notRepository:
                HStack(spacing: 10) {
                    WorkspaceRepositoryActionButton(
                        title: "Initialize Git",
                        systemImage: "shippingbox",
                        action: onInitializeGit
                    )
                    WorkspaceRepositoryActionButton(
                        title: "Open Workspace",
                        systemImage: "folder",
                        action: onOpenWorkspace
                    )
                }

            case .missingWorkspace, .failed:
                WorkspaceRepositoryActionButton(
                    title: "Open Workspace",
                    systemImage: "folder",
                    action: onOpenWorkspace
                )

            case .loading:
                EmptyView()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var borderColor: Color {
        switch repositoryState.phase {
        case .ready:
            return summary.totalCount == 0 ? StudioTheme.successStroke : StudioTheme.warningStroke
        case .loading:
            return StudioTheme.dockDivider
        case .notRepository, .missingWorkspace, .failed:
            return StudioTheme.warningStroke
        }
    }
}

private struct WorkspaceOperatorRoutingCard: View {

    @AppStorage("autonomyMode") private var storedAutonomyMode = AutonomyMode.review.rawValue
    @AppStorage("anthropicAPIKey") private var storedAnthropicAPIKey = ""
    @AppStorage("openAIAPIKey") private var storedOpenAIAPIKey = ""

    private var autonomyMode: AutonomyMode {
        AutonomyMode(rawValue: storedAutonomyMode) ?? .review
    }

    private var activeModel: StudioModelDescriptor {
        StudioModelStrategy.primaryModel(for: autonomyMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Routing")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTheme.secondaryText)

                    Text("\(autonomyMode.title) is using \(activeModel.displayName)")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StudioTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(activeModel.summary)
                        .font(.callout)
                        .foregroundStyle(StudioTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    OperatorStatusPill(
                        title: anthropicReady ? "Anthropic ready" : "Anthropic needed",
                        systemImage: ModelProvider.anthropic.symbolName,
                        isReady: anthropicReady
                    )
                    OperatorStatusPill(
                        title: openAIReady ? "OpenAI ready" : "OpenAI needed",
                        systemImage: ModelProvider.openAI.symbolName,
                        isReady: openAIReady
                    )
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(StudioModelStrategy.all, id: \.id) { model in
                    OperatorModelRow(
                        model: model,
                        isActive: model.id == activeModel.id
                    )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
    }

    private var anthropicReady: Bool {
        StudioModelStrategy.credential(provider: .anthropic, storedValue: storedAnthropicAPIKey) != nil
    }

    private var openAIReady: Bool {
        StudioModelStrategy.credential(provider: .openAI, storedValue: storedOpenAIAPIKey) != nil
    }
}

private struct OperatorStatusPill: View {

    let title: String
    let systemImage: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(isReady ? StudioTheme.primaryText : StudioTheme.secondaryText)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(isReady ? StudioTheme.accentSurface : StudioTheme.surfaceSoft)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isReady ? StudioTheme.accentBorder : StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

private struct OperatorModelRow: View {

    let model: StudioModelDescriptor
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.role.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? StudioTheme.accent : StudioTheme.secondaryText)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.role.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTheme.primaryText)

                    Text(model.displayName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioTheme.secondaryText)
                }

                Text(model.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if isActive {
                Text("Active")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(StudioTheme.accentSurface)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(StudioTheme.accentBorder, lineWidth: 1)
                    )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isActive ? StudioTheme.accentSurfaceStrong : StudioTheme.surfaceSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isActive ? StudioTheme.accentBorderStrong : StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

private struct WorkspaceRepositoryMetricPill: View {

    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(StudioTheme.primaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(StudioTheme.surfaceSoft)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

private struct WorkspaceRepositoryWorktreePill: View {

    let worktree: GitWorktree

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(worktree.isCurrent ? StudioTheme.accent : StudioTheme.secondaryText)
                    .frame(width: 6, height: 6)

                Text(worktree.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                    .lineLimit(1)
            }

            Text(worktree.path)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioTheme.tertiaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(worktree.isCurrent ? StudioTheme.accentSurface : StudioTheme.surfaceSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(worktree.isCurrent ? StudioTheme.accentBorder : StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

private struct WorkspaceRepositoryActionButton: View {

    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(StudioTheme.primaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(StudioTheme.surfaceSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(StudioTheme.dockDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FleetEmptyState: View {

    let onOpenWorkspace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open a workspace")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(StudioTheme.primaryText)

            Text("Choose a folder to give Studio.92 a place to build, inspect, and ship from.")
                .font(.callout)
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            WorkspaceOpenButton(action: onOpenWorkspace)
        }
        .frame(maxWidth: 220, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .background(
            Color.black
        )
    }
}

private struct WorkspaceOpenButton: View {

    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.folder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.primaryText)
                Text("Open Workspace")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(StudioTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? StudioTheme.accentSurfaceStrong : StudioTheme.surfaceFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isHovered ? StudioTheme.accentStroke : StudioTheme.stroke,
                        lineWidth: 1
                    )
            )
            .shadow(color: isHovered ? StudioTheme.accentShadow : StudioTheme.creamShadow.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isHovered)
    }
}

private struct StudioPillFlowLayout: Layout {

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
private struct FleetRow: View {

    let project: AppProject
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(project.name)
                    .font(.headline)
                    .foregroundStyle(StudioTheme.primaryText)
                Spacer()
                ConfidenceBadge(score: project.confidenceScore)
            }

            if let archetype = project.dominantArchetype {
                Text(archetype)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.secondaryText)
            }

            if let risk = project.primaryRiskLabel {
                HStack(spacing: 4) {
                    Image(systemName: riskIcon(for: risk))
                        .foregroundStyle(riskColor(for: project.confidenceScore))
                        .font(.caption)
                    Text("Risk: \(risk)")
                        .font(.caption)
                        .foregroundStyle(riskColor(for: project.confidenceScore))
                }
            }

            if let detail = project.secondaryRiskDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(StudioTheme.tertiaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? StudioTheme.accentSurfaceStrong : StudioTheme.surfaceSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? StudioTheme.accentBorderStrong : StudioTheme.dockDivider, lineWidth: 1)
        )
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
        if score >= 70 { return StudioTheme.secondaryText }
        if score >= 40 { return StudioTheme.warning }
        return StudioTheme.danger
    }
}

private struct FleetJobRow: View {

    let session: AgentSession
    let isSelected: Bool

    private var statusColor: Color {
        switch session.status {
        case .queued:
            return StudioTheme.secondaryText
        case .preparing, .running:
            return StudioTheme.accent
        case .reviewing:
            return StudioTheme.warning
        case .completed:
            return StudioTheme.success
        case .failed, .cancelled:
            return StudioTheme.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.primaryText)
                        .lineLimit(2)

                    Text(session.branchName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Image(systemName: session.status.symbolName)
                    Text(session.status.title)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(statusColor)
            }

            Text(session.progressSummary)
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.secondaryText)
                .lineLimit(2)

            HStack(spacing: 8) {
                ReferenceBadge(
                    title: session.modelDisplayName,
                    systemImage: "brain",
                    style: .tinted
                )

                ReferenceBadge(
                    title: session.worktreeDisplayName,
                    systemImage: "square.split.2x1"
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? StudioTheme.accentSurfaceStrong : StudioTheme.surfaceSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? StudioTheme.accentBorderStrong : StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

/// Compact confidence badge (0–100).
private struct ConfidenceBadge: View {

    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.caption.monospacedDigit().bold())
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    private var badgeColor: Color {
        if score >= 70 { return StudioTheme.accentHighlight }
        if score >= 40 { return StudioTheme.warning }
        return StudioTheme.danger
    }
}

// MARK: - Goal Input Bar

/// Multi-line native prompt bar with attachment support.
private struct GoalInputBar: View {

    @Binding var goalText: String
    @Binding var attachments: [ChatAttachment]
    let runner: PipelineRunner
    let reusedPromptToken: UUID?
    let reusedPromptText: String?
    let onSubmit: () -> Void

    @AppStorage("autonomyMode") private var autonomyMode = AutonomyMode.review.rawValue
    @State private var attachedImage: NSImage?
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var isHoveringAttachButton = false
    @State private var historyIndex: Int = -1
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var visibleReusedPromptText: String?
    @State private var reusedPromptTask: Task<Void, Never>?
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if visibleReusedPromptText != nil || imageAttachment != nil || !nonImageAttachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let visibleReusedPromptText {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle")
                            Text(visibleReusedPromptText)
                                .lineLimit(1)
                        }
                        .font(.system(size: CalmChatLayout.metaFontSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    attachmentShelf
                }
                .padding(.horizontal, CalmChatLayout.composerHorizontalPadding)
                .padding(.top, 10)
            }

            composerRow
                .padding(.horizontal, CalmChatLayout.composerHorizontalPadding)
        }
        .frame(maxWidth: CalmChatLayout.columnMaxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CalmChatLayout.composerCornerRadius, style: .continuous)
                .fill(StudioTheme.composerFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CalmChatLayout.composerCornerRadius, style: .continuous)
                .stroke(StudioTheme.composerBorder, lineWidth: 1)
        )
        .shadow(color: StudioTheme.softShadow, radius: 18, y: 10)
        .frame(maxWidth: .infinity, alignment: .center)
        .dropDestination(
            for: URL.self,
            action: { urls, _ in
                appendAttachments(from: urls)
                return !urls.isEmpty
            },
            isTargeted: { isDropTargeted = $0 }
        )
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            appendAttachments(from: urls)
        }
        .onAppear {
            syncAttachedImage()
        }
        .onChange(of: imageAttachment?.url.path) { _, _ in
            syncAttachedImage()
        }
        .onChange(of: reusedPromptToken) { _, _ in
            presentReusedPromptNoticeIfNeeded()
        }
        .onDisappear {
            reusedPromptTask?.cancel()
            imageLoadTask?.cancel()
        }
    }

    private enum Direction { case up, down }

    private var selectedAutonomyMode: AutonomyMode {
        AutonomyMode(rawValue: autonomyMode) ?? .review
    }

    private var composerActionState: ComposerActionState {
        if runner.isRunning {
            return .cancel
        }
        return canSubmit ? .send : .voice
    }

    private var isInputEmptyState: Bool {
        composerActionState == .voice
    }

    @ViewBuilder
    private var attachmentShelf: some View {
        if imageAttachment != nil || !nonImageAttachments.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let imageAttachment,
                   let previewImage = attachedImage {
                    ImageAttachmentChip(
                        image: previewImage,
                        title: imageAttachment.displayName
                    ) {
                        attachments.removeAll(where: { $0.isImage })
                        attachedImage = nil
                    }
                }

                if !nonImageAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(nonImageAttachments) { attachment in
                                AttachmentChip(attachment: attachment) {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var composerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            attachButton
            promptEditor
            configurationCluster
            submitButton
        }
        .frame(minHeight: CalmChatLayout.composerHeight)
    }

    private var attachButton: some View {
        Button {
            isImporterPresented = true
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioTheme.secondaryText)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(isHoveringAttachButton ? StudioTheme.surfaceFill : Color.clear)
                )
                .scaleEffect(isHoveringAttachButton ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(runner.isRunning)
        .onHover { isHoveringAttachButton = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHoveringAttachButton)
    }

    private var autonomyMenu: some View {
        Menu {
            ForEach(AutonomyMode.allCases, id: \.rawValue) { mode in
                Button {
                    autonomyMode = mode.rawValue
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(mode.title, systemImage: mode.symbolName)
                        Text(mode.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedAutonomyMode.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(selectedAutonomyMode.title)
                    .font(.system(size: CalmChatLayout.metaFontSize, weight: .medium))
            }
            .foregroundStyle(StudioTheme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(StudioTheme.surfaceSoft)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(StudioTheme.dockDivider, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var promptEditor: some View {
        GrowingCommandEditor(
            text: $goalText,
            isDisabled: runner.isRunning,
            placeholder: "Describe the app you want to build...",
            isFocused: $isEditorFocused
        ) {
            cycleHistory(direction: .up)
        } onHistoryDown: {
            cycleHistory(direction: .down)
        } onSubmit: {
            historyIndex = -1
            onSubmit()
        }
    }

    private var configurationCluster: some View {
        HStack(spacing: 8) {
            autonomyMenu
            ActiveOperatorBadge(model: StudioModelStrategy.primaryModel(for: selectedAutonomyMode))
        }
    }

    private var submitButton: some View {
        Button {
            if composerActionState == .cancel {
                Task { @MainActor in runner.cancel() }
            } else if composerActionState == .send {
                onSubmit()
            } else {
                isEditorFocused = true
            }
        } label: {
            Image(systemName: composerActionState.symbolName)
                .font(.system(size: composerActionState.symbolSize, weight: .semibold))
                .scaleEffect(composerActionState == .send ? 1.1 : 1.0)
                .foregroundStyle(sendIconColor)
                .padding(7)
                .background(
                    Circle()
                        .fill(sendButtonFill)
                )
                .overlay(
                    Circle()
                        .stroke(sendButtonStroke, lineWidth: 1)
                )
                .shadow(color: sendButtonShadow, radius: 12, y: 4)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: composerActionState == .voice && !isEditorFocused)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .animation(.snappy, value: composerActionState)
        .sensoryFeedback(.impact, trigger: isInputEmptyState)
    }

    private var imageAttachment: ChatAttachment? {
        attachments.first(where: { $0.isImage })
    }

    private var nonImageAttachments: [ChatAttachment] {
        attachments.filter { !$0.isImage }
    }

    private var canSubmit: Bool {
        !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageAttachment != nil
    }

    private var sendIconColor: Color {
        switch composerActionState {
        case .cancel:
            return StudioTheme.primaryText.opacity(0.92)
        case .send:
            return StudioTheme.primaryText
        case .voice:
            return StudioTheme.secondaryText.opacity(isEditorFocused ? 1.0 : 0.78)
        }
    }

    private var sendButtonFill: Color {
        switch composerActionState {
        case .cancel:
            return StudioTheme.dangerSurface
        case .send:
            return StudioTheme.accent.opacity(0.9)
        case .voice:
            return StudioTheme.surfaceHighlight
        }
    }

    private var sendButtonStroke: Color {
        switch composerActionState {
        case .cancel:
            return StudioTheme.dangerStroke
        case .send:
            return StudioTheme.accent.opacity(0.16)
        case .voice:
            return StudioTheme.dockDivider
        }
    }

    private var sendButtonShadow: Color {
        switch composerActionState {
        case .cancel:
            return .clear
        case .send:
            return StudioTheme.accentShadow
        case .voice:
            return .clear
        }
    }

    private func cycleHistory(direction: Direction) {
        guard !runner.goalHistory.isEmpty, goalText.isEmpty || historyIndex >= 0 else { return }
        switch direction {
        case .up:
            historyIndex = min(historyIndex + 1, runner.goalHistory.count - 1)
        case .down:
            historyIndex = max(historyIndex - 1, -1)
        }
        goalText = historyIndex >= 0 ? runner.goalHistory[historyIndex] : ""
    }

    @MainActor
    private func appendAttachments(from urls: [URL]) {
        let additions = urls.compactMap { url -> ChatAttachment? in
            let normalized = url.standardizedFileURL
            guard normalized.isFileURL else { return nil }
            return ChatAttachment(url: normalized, displayName: normalized.lastPathComponent)
        }

        if let replacementImage = additions.last(where: { $0.isImage }) {
            attachments.removeAll(where: { $0.isImage })
            attachments.append(replacementImage)
        }

        for attachment in additions where !attachments.contains(where: { $0.url == attachment.url }) {
            guard !attachment.isImage else { continue }
            attachments.append(attachment)
        }
    }

    private func syncAttachedImage() {
        imageLoadTask?.cancel()

        guard let imageURL = imageAttachment?.url else {
            attachedImage = nil
            return
        }

        imageLoadTask = Task {
            let loadedImage = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: imageURL)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                attachedImage = loadedImage
            }
        }
    }

    private func presentReusedPromptNoticeIfNeeded() {
        guard let reusedPromptText, reusedPromptToken != nil else { return }

        reusedPromptTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            visibleReusedPromptText = reusedPromptText
        }

        reusedPromptTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.18)) {
                    visibleReusedPromptText = nil
                }
            }
        }
    }

    private enum ComposerActionState: Equatable {
        case voice
        case send
        case cancel

        var symbolName: String {
            switch self {
            case .voice:
                return "mic.fill"
            case .send:
                return "arrow.up.circle.fill"
            case .cancel:
                return "xmark.circle.fill"
            }
        }

        var symbolSize: CGFloat {
            switch self {
            case .voice:
                return 18
            case .send, .cancel:
                return 25
            }
        }
    }
}

private struct ActiveOperatorBadge: View {

    let model: StudioModelDescriptor

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.role.symbolName)
                .font(.system(size: 11, weight: .semibold))
            Text(model.shortName)
                .font(.system(size: CalmChatLayout.metaFontSize, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(StudioTheme.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(StudioTheme.surfaceSoft)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
        .help("\(model.role.title): \(model.displayName)")
    }
}

private struct GrowingCommandEditor: View {

    @Binding var text: String
    let isDisabled: Bool
    let placeholder: String
    let isFocused: FocusState<Bool>.Binding
    let onHistoryUp: () -> Void
    let onHistoryDown: () -> Void
    let onSubmit: () -> Void

    @State private var contentHeight: CGFloat = 28
    @State private var availableWidth: CGFloat = 0

    private let minHeight: CGFloat = 24
    private let maxHeight: CGFloat = 92
    private let editorTopInset: CGFloat = 2
    private let editorLeadingInset: CGFloat = 4

    private var clampedHeight: CGFloat {
        min(max(contentHeight, minHeight), maxHeight)
    }

    private var shouldApplyOverflowMask: Bool {
        contentHeight > maxHeight + 8
    }

    private var measurementText: String {
        if text.isEmpty {
            return " "
        }
        return text + "\n "
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: CalmChatLayout.bodyFontSize, weight: .regular, design: .default))
                .tracking(CalmChatLayout.bodyLetterSpacing)
                .lineSpacing(CalmChatLayout.bodyLineSpacing)
                .foregroundStyle(StudioTheme.primaryText)
                .scrollContentBackground(.hidden)
                .frame(height: clampedHeight)
                .background(Color.clear)
                .disabled(isDisabled)
                .focused(isFocused)
                .onKeyPress(.upArrow) {
                    onHistoryUp()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onHistoryDown()
                    return .handled
                }
                .onKeyPress(.return) {
                    guard !isDisabled else { return .ignored }
                    onSubmit()
                    return .handled
                }

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: CalmChatLayout.bodyFontSize, weight: .regular, design: .default))
                    .tracking(CalmChatLayout.bodyLetterSpacing)
                    .foregroundStyle(StudioTheme.placeholderText)
                    .padding(.top, editorTopInset)
                    .padding(.leading, editorLeadingInset)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .mask {
            if shouldApplyOverflowMask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.1),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Rectangle().fill(.black)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        availableWidth = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        availableWidth = newWidth
                    }
            }
        }
        .background(alignment: .topLeading) {
            if availableWidth > 0 {
                Text(measurementText)
                    .font(.system(size: CalmChatLayout.bodyFontSize, weight: .regular, design: .default))
                    .tracking(CalmChatLayout.bodyLetterSpacing)
                    .lineSpacing(CalmChatLayout.bodyLineSpacing)
                    .padding(.top, editorTopInset)
                    .padding(.horizontal, editorLeadingInset)
                    .frame(width: availableWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: GrowingCommandEditorHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
        }
        .onPreferenceChange(GrowingCommandEditorHeightPreferenceKey.self) { newHeight in
            contentHeight = newHeight
        }
        .animation(.snappy, value: clampedHeight)
        .animation(.easeOut(duration: 0.16), value: text.isEmpty)
        .animation(.easeOut(duration: 0.18), value: shouldApplyOverflowMask)
    }
}

private struct GrowingCommandEditorHeightPreferenceKey: PreferenceKey {

    static var defaultValue: CGFloat = 28

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AttachmentChip: View {

    let attachment: ChatAttachment
    let onRemove: () -> Void

    private var iconName: String {
        switch attachment.url.pathExtension.lowercased() {
        case "swift":
            return "swift"
        case "png", "jpg", "jpeg", "heic":
            return "photo"
        case "json", "yml", "yaml", "toml":
            return "curlybraces.square"
        case "md", "txt":
            return "doc.text"
        default:
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: attachment.url.path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? "folder" : "doc"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
            Text(attachment.displayName)
                .font(.caption)
                .lineLimit(1)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(StudioTheme.surfaceFill)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(StudioTheme.stroke, lineWidth: 1)
        )
    }
}

private struct ImageAttachmentChip: View {

    let image: NSImage
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Visual Reference")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.primaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StudioTheme.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioTheme.stroke, lineWidth: 1)
        )
    }
}

private struct GoalSuggestionsView: View {

    let suggestions: [String]
    let isDisabled: Bool
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onSelect(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule(style: .continuous)
                            .fill(StudioTheme.surfaceFill)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(StudioTheme.stroke, lineWidth: 1)
                    )
                    .disabled(isDisabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(StudioTheme.midnight)
    }
}

private struct AgenticSuggestion: Identifiable, Hashable {
    let id: String
    let title: String
    let prompt: String
    let symbolName: String
}

private struct ThreadEmptyState: View {

    let availableHeight: CGFloat
    let suggestions: [AgenticSuggestion]
    let onSelectSuggestion: (AgenticSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 24) {
                FactoryHeroGraphic()

                VStack(spacing: 10) {
                    Text("Hey TJ, What are we working on?")
                        .font(StudioWordmarkFont.display(size: 34))
                        .foregroundStyle(StudioTheme.primaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    Text("Drop a UI mockup, describe your architecture, or select a workspace to begin.")
                        .font(.system(size: CalmChatLayout.bodyFontSize, weight: .regular, design: .default))
                        .tracking(CalmChatLayout.bodyLetterSpacing)
                        .lineSpacing(CalmChatLayout.bodyLineSpacing)
                        .foregroundStyle(StudioTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 40)

                if !suggestions.isEmpty {
                    VStack(spacing: 10) {
                        Text("Utilities")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudioTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)

                        HStack {
                            Spacer(minLength: 0)

                            StudioPillFlowLayout(horizontalSpacing: 12, verticalSpacing: 12) {
                                ForEach(suggestions) { suggestion in
                                    AgenticSuggestionPill(
                                        suggestion: suggestion,
                                        action: {
                                            onSelectSuggestion(suggestion)
                                        }
                                    )
                                }
                            }

                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 32)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: max(availableHeight - (CalmChatLayout.columnVerticalPadding * 2), 420))
    }
}

private struct FactoryHeroGraphic: View {

    var body: some View {
        ZStack {
            Circle()
                .fill(StudioTheme.surfaceBare)
                .frame(width: 104, height: 104)
                .overlay(
                    Circle()
                        .stroke(StudioTheme.accent.opacity(0.32), lineWidth: 1)
                )

            ZStack {
                Image(systemName: "cpu")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(StudioTheme.accent)

                Image(systemName: "hammer")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(StudioTheme.accent)
                    .offset(x: 23, y: 23)
            }
        }
        .shadow(color: .black, radius: 10, y: 5)
    }
}

private struct AgenticSuggestionPill: View {

    let suggestion: AgenticSuggestion
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: suggestion.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondaryText)

                Text(suggestion.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StudioTheme.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isHovered ? StudioTheme.surfaceEmphasis : StudioTheme.surfaceBare)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(StudioTheme.accent.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovered ? 0.28 : 0.2), radius: 10, y: 5)
            .scaleEffect(isHovered ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
    }
}

// MARK: - Chat Thread

private struct ChatThreadView: View {

    let turns: [ConversationTurn]
    let isPipelineRunning: Bool
    let selectedEpochID: UUID?
    let columnWidth: CGFloat
    let bottomContentInset: CGFloat
    let suggestions: [AgenticSuggestion]
    let onSelectSuggestion: (AgenticSuggestion) -> Void
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onReuseGoal: (String) -> Void
    let onCancelTurn: () -> Void

    @State private var highlightedEpochID: UUID?
    @State private var viewportHeight: CGFloat = 0
    @State private var shouldFollowBottom = true

    private let bottomSentinelID = "chat-thread-bottom"

    private var latestInteractiveTurnID: UUID? {
        turns.last(where: { !$0.isHistorical })?.id
    }

    private var turnAnchorIDs: [UUID] {
        turns.map { $0.epochID ?? $0.id }
    }

    private var turnContentSignature: Int {
        turns.reduce(into: 0) { result, turn in
            result += turn.userGoal.count
            result += turn.response.text.count
            result += turn.response.streamingText.count
            result += turn.toolTraces.count
            result += turn.toolTraces.reduce(into: 0) { subtotal, trace in
                subtotal += trace.title.count
                subtotal += trace.detail?.count ?? 0
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                CalmChatColumn(width: columnWidth) {
                    VStack(alignment: .leading, spacing: 0) {
                        if turns.isEmpty {
                            ThreadEmptyState(
                                availableHeight: max(viewportHeight - bottomContentInset, 0),
                                suggestions: suggestions,
                                onSelectSuggestion: onSelectSuggestion
                            )
                            .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            LazyVStack(alignment: .leading, spacing: CalmChatLayout.messageSpacing) {
                                ForEach(turns) { turn in
                                    ConversationTurnRow(
                                        turn: turn,
                                        isHighlighted: highlightedEpochID.map { turn.epochID == $0 } ?? false,
                                        isPipelineRunning: isPipelineRunning,
                                        onOpenArtifact: onOpenArtifact,
                                        onReuseGoal: onReuseGoal,
                                        isLatestInteractiveTurn: turn.id == latestInteractiveTurnID,
                                        onCancelTurn: onCancelTurn
                                    )
                                    .id(turn.epochID ?? turn.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Color.clear
                            .frame(height: bottomContentInset)

                        Color.clear
                            .frame(height: 1)
                            .id(bottomSentinelID)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: ChatThreadBottomSentinelPreferenceKey.self,
                                        value: proxy.frame(in: .named("chat-thread-scroll")).minY
                                    )
                                }
                            )
                    }
                }
                .padding(.horizontal, CalmChatLayout.columnHorizontalPadding)
                .padding(.vertical, CalmChatLayout.columnVerticalPadding)
            }
            .coordinateSpace(name: "chat-thread-scroll")
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            viewportHeight = proxy.size.height
                        }
                        .onChange(of: proxy.size.height) { _, newValue in
                            viewportHeight = newValue
                        }
                }
            )
            .onPreferenceChange(ChatThreadBottomSentinelPreferenceKey.self) { newValue in
                shouldFollowBottom = newValue <= viewportHeight + 120
            }
            .onAppear {
                scrollToBottom(using: proxy, animated: false)
            }
            .onChange(of: turnAnchorIDs) { _, _ in
                guard selectedEpochID == nil, shouldFollowBottom else { return }
                scrollToBottom(using: proxy, animated: true)
            }
            .onChange(of: turnContentSignature) { _, _ in
                guard selectedEpochID == nil, shouldFollowBottom else { return }
                scrollToBottom(using: proxy, animated: true)
            }
            .onChange(of: selectedEpochID) { _, newValue in
                highlightedEpochID = newValue
                guard let newValue else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(bottomSentinelID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomSentinelID, anchor: .bottom)
        }
    }
}

private struct ChatThreadBottomSentinelPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FloatingComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ConversationTurnRow: View {

    let turn: ConversationTurn
    let isHighlighted: Bool
    let isPipelineRunning: Bool
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onReuseGoal: (String) -> Void
    let isLatestInteractiveTurn: Bool
    let onCancelTurn: () -> Void

    @State private var isHovering = false

    private var trimmedGoal: String {
        turn.userGoal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var responseText: String {
        turn.response.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var toolTracesByTimestamp: [ToolTrace] {
        turn.toolTraces.sorted(by: { $0.timestamp < $1.timestamp })
    }

    private var consoleTraces: [ToolTrace] {
        toolTracesByTimestamp.filter(\.isConsoleTrace)
    }

    private var ledgerTraces: [ToolTrace] {
        toolTracesByTimestamp.filter(\.isFileLedgerTrace)
    }

    private var swarmTraces: [ToolTrace] {
        toolTracesByTimestamp.filter(\.isDelegationTrace)
    }

    private var whisperTraces: [ToolTrace] {
        toolTracesByTimestamp.filter {
            !$0.isConsoleTrace && !$0.isFileLedgerTrace && !$0.isDelegationTrace
        }
    }

    private var responseThinkingText: String? {
        let trimmed = turn.response.thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var shouldShowThinkingState: Bool {
        responseThinkingText == nil
            && responseText.isEmpty
            && (turn.state == .streaming || turn.state == .executing || turn.state == .finalizing)
    }

    private var shouldShowActionRow: Bool {
        if turn.isHistorical {
            return true
        }

        return isLatestInteractiveTurn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CalmChatLayout.messageInternalSpacing) {
            if !trimmedGoal.isEmpty {
                UserGoalBubbleView(
                    goal: trimmedGoal,
                    attachments: turn.userAttachments,
                    isHighlighted: isHighlighted
                )
            }

            VStack(alignment: .leading, spacing: CalmChatLayout.messageInternalSpacing) {
                if let responseThinkingText {
                    ThinkingDisclosureView(
                        text: responseThinkingText,
                        isLive: turn.state == .streaming || turn.state == .executing || turn.state == .finalizing
                    )
                }

                if shouldShowThinkingState {
                    ThinkingMessageRow(label: "Thinking")
                }

                if !ledgerTraces.isEmpty {
                    FileLedgerStreamView(traces: ledgerTraces)
                }

                if !swarmTraces.isEmpty {
                    SwarmLedgerStreamView(traces: swarmTraces)
                }

                if !whisperTraces.isEmpty {
                    ToolTraceListView(traces: whisperTraces)
                }

                if !consoleTraces.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(consoleTraces) { trace in
                            InteractiveTerminalBlock(trace: trace)
                        }
                    }
                }

                if !responseText.isEmpty {
                    AssistantTextView(
                        turn: turn,
                        isPipelineRunning: isPipelineRunning
                    )
                }

                if turn.state == .completed, (turn.metrics != nil || turn.screenshotPath != nil) {
                    TurnArtifactSummary(turn: turn)
                }

                if shouldShowActionRow {
                    ResponseActionRow(
                        turn: turn,
                        onOpenArtifact: onOpenArtifact,
                        onReuseGoal: onReuseGoal,
                        onCancelTurn: onCancelTurn,
                        isLatestInteractiveTurn: isLatestInteractiveTurn,
                        isHighlighted: isHighlighted,
                        isRowHovering: isHovering
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(StudioTheme.accent.opacity(0.32))
                    .frame(width: 2)
                    .offset(x: -14)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: isHighlighted)
        .animation(.easeOut(duration: 0.18), value: isHovering)
    }
}

private struct UserGoalBubbleView: View {

    let goal: String
    let attachments: [ChatAttachment]
    let isHighlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CalmChatLayout.messageInternalSpacing) {
            MarkdownMessageContent(text: goal)

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            ReferenceBadge(
                                title: attachment.displayName,
                                systemImage: attachment.isImage ? "photo" : "paperclip",
                                style: .tinted
                            ) {
                                NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isHighlighted ? StudioTheme.accent.opacity(0.22) : StudioTheme.dockDivider,
                    lineWidth: 1
                )
        )
    }
}

private struct AssistantTextView: View {

    let turn: ConversationTurn
    let isPipelineRunning: Bool

    private var stableText: String {
        turn.response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var liveText: String {
        turn.response.streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CalmChatLayout.messageInternalSpacing) {
            if !stableText.isEmpty {
                MarkdownMessageContent(
                    text: stableText,
                    isStreaming: false,
                    isPipelineRunning: isPipelineRunning
                )
            }

            if !liveText.isEmpty {
                MarkdownMessageContent(
                    text: liveText,
                    isStreaming: true,
                    isPipelineRunning: isPipelineRunning
                )
                .overlay(alignment: .bottomTrailing) {
                    if turn.response.isStreaming {
                        StreamingCursorView()
                            .padding(.trailing, -8)
                            .padding(.bottom, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private struct StreamingCursorView: View {

    @State private var isVisible = true

    var body: some View {
        Capsule(style: .continuous)
            .fill(StudioTheme.primaryText.opacity(0.78))
            .frame(width: 12, height: 3)
            .opacity(isVisible ? 1 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isVisible = false
                }
            }
    }
}

private struct ToolTraceListView: View {

    let traces: [ToolTrace]

    private var visibleTraces: [ToolTrace] {
        let sortedTraces = traces
            .sorted(by: { $0.timestamp < $1.timestamp })
        let activeContext = sortedTraces.filter { $0.isContextTrace && $0.isLive }
        let latestCompletedContext = sortedTraces.last(where: { $0.isContextTrace && !$0.isLive })
        let actionTraces = sortedTraces.filter { trace in
            !trace.isContextTrace
                && !trace.isConsoleTrace
                && !trace.isFileLedgerTrace
                && (trace.isLive || trace.status == .error)
        }

        var visible: [ToolTrace] = []
        visible.append(contentsOf: activeContext.suffix(2))
        if let latestCompletedContext {
            visible.append(latestCompletedContext)
        }
        visible.append(contentsOf: actionTraces.suffix(2))
        return visible.sorted(by: { $0.timestamp < $1.timestamp })
    }

    var body: some View {
        if !visibleTraces.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(visibleTraces) { trace in
                    ToolTraceRow(trace: trace)
                }
            }
            .opacity(0.68)
        }
    }
}

private struct FileLedgerStreamView: View {

    let traces: [ToolTrace]

    private var visibleTraces: [ToolTrace] {
        let sorted = traces.sorted(by: { $0.timestamp < $1.timestamp })
        let live = sorted.filter(\.isLive)
        let latestCompleted = sorted.last(where: { !$0.isLive })

        var visible: [ToolTrace] = []
        visible.append(contentsOf: live.suffix(2))
        if let latestCompleted {
            visible.append(latestCompleted)
        }
        return visible.sorted(by: { $0.timestamp < $1.timestamp })
    }

    var body: some View {
        if !visibleTraces.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleTraces) { trace in
                    FileLedgerPill(trace: trace)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: visibleTraces.map(\.id).joined(separator: "|"))
        }
    }
}

private struct SwarmLedgerStreamView: View {

    let traces: [ToolTrace]

    private var visibleTraces: [ToolTrace] {
        let sorted = traces.sorted(by: { $0.timestamp < $1.timestamp })
        let live = sorted.filter(\.isLive)
        let latestCompleted = sorted.last(where: { !$0.isLive })

        var visible: [ToolTrace] = []
        visible.append(contentsOf: live.suffix(2))
        if let latestCompleted {
            visible.append(latestCompleted)
        }
        return visible.sorted(by: { $0.timestamp < $1.timestamp })
    }

    var body: some View {
        if !visibleTraces.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleTraces) { trace in
                    SwarmLedgerPill(trace: trace)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: visibleTraces.map(\.id).joined(separator: "|"))
        }
    }
}

private struct FileLedgerPill: View {

    let trace: ToolTrace

    private var verb: String {
        switch trace.sourceName {
        case "file_read":
            return "Read"
        case "file_patch":
            return trace.status == .error ? "Edit failed" : "Edited"
        case "file_write":
            return trace.status == .error ? "Write failed" : "Edited"
        default:
            return "Updated"
        }
    }

    private var displayName: String {
        let candidate = trace.filePath ?? trace.title
        let lastComponent = URL(fileURLWithPath: candidate).lastPathComponent
        return lastComponent.isEmpty ? candidate : lastComponent
    }

    private var symbolName: String {
        switch trace.sourceName {
        case "file_read":
            return trace.isLive ? "doc.text" : "doc.text"
        case "file_patch":
            return trace.isLive ? "square.and.pencil" : "square.and.pencil"
        case "file_write":
            return trace.isLive ? "doc.badge.plus" : "square.and.pencil"
        default:
            return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: trace.isLive)
                .shimmer(isActive: trace.isLive)

            Text(verb)
                .foregroundStyle(.secondary)

            Text(displayName)
                .foregroundStyle(StudioTheme.primaryText.opacity(0.86))
                .lineLimit(1)

            if let linesAdded = trace.linesAdded, let linesRemoved = trace.linesRemoved, trace.sourceName != "file_read" {
                HStack(spacing: 0) {
                    Text("(+")
                        .foregroundStyle(.secondary)
                    Text("\(linesAdded)")
                        .foregroundStyle(StudioTheme.accent)
                    Text(" -")
                        .foregroundStyle(.secondary)
                    Text("\(linesRemoved)")
                        .foregroundStyle(StudioTheme.secondaryText)
                    Text(")")
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption, design: .monospaced))
            }

            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(StudioTheme.surfaceFill)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(StudioTheme.stroke, lineWidth: 1)
        )
    }
}

private struct SwarmLedgerPill: View {

    let trace: ToolTrace

    private var symbolName: String {
        switch trace.sourceName {
        case "delegate_to_worktree":
            return trace.isLive ? "square.split.2x1.fill" : "checkmark.circle"
        case "delegate_to_reviewer":
            return trace.isLive ? "checklist.checked" : "checkmark.circle"
        default:
            return trace.isLive ? "person.2.wave.2" : "checkmark.circle"
        }
    }

    private var labelText: String {
        switch trace.sourceName {
        case "delegate_to_worktree":
            return trace.isLive ? "Background Job Running" : "Background Job Ready"
        case "delegate_to_reviewer":
            return trace.isLive ? "Code Reviewer Auditing" : "Code Reviewer Ready"
        default:
            return trace.isLive ? "Workspace Explorer Running" : "Workspace Explorer Ready"
        }
    }

    private var detailText: String {
        switch trace.sourceName {
        case "delegate_to_worktree":
            return trace.title.replacingOccurrences(of: "Background Job: ", with: "")
        case "delegate_to_reviewer":
            return trace.title.replacingOccurrences(of: "Code Reviewer: ", with: "")
        default:
            return trace.title.replacingOccurrences(of: "Workspace Explorer: ", with: "")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: trace.isLive)
                .shimmer(isActive: trace.isLive)

            Text(labelText)
                .foregroundStyle(.secondary)

            Text(detailText)
                .foregroundStyle(StudioTheme.primaryText.opacity(0.82))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(StudioTheme.surfaceFill)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(StudioTheme.stroke, lineWidth: 1)
        )
    }
}

private struct ToolTraceRow: View {

    let trace: ToolTrace

    @State private var isExpanded = false
    @State private var isHovering = false

    private var hasDetail: Bool {
        !(trace.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var canPeekLiveOutput: Bool {
        trace.isLive
            && trace.supportsInlinePeek
            && !trace.liveOutput.isEmpty
    }

    private var isExpandable: Bool {
        canPeekLiveOutput || hasDetail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard isExpandable else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(iconColor)
                        .opacity(iconOpacity)
                        .scaleEffect(iconScale)
                        .symbolEffect(.pulse, options: .repeating, isActive: trace.isLive)
                    Text(trace.title)
                        .foregroundStyle(textColor)
                        .lineLimit(1)

                    if isExpandable {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(chevronColor)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .shimmer(isActive: trace.isLive)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = trace.isLive ? hovering : false
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.74), value: isHovering)

            if canPeekLiveOutput && isExpanded {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(trace.liveOutput.suffix(10).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(StudioTheme.primaryText.opacity(0.62))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.leading, 18)
                    .padding(.top, 2)
                }
                .frame(maxHeight: 96)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if isExpanded, let detail = trace.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var iconName: String {
        switch trace.status {
        case .running:
            return liveIconName
        case .success:
            return trace.isContextTrace ? "checkmark.circle" : "checkmark.circle"
        case .error:
            return "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch trace.status {
        case .running:
            return isHovering ? StudioTheme.primaryText.opacity(0.92) : .secondary
        case .success:
            return StudioTheme.tertiaryText
        case .error:
            return .secondary
        }
    }

    private var textColor: Color {
        switch trace.status {
        case .running:
            return isHovering ? .primary.opacity(0.92) : .secondary
        case .success:
            return StudioTheme.tertiaryText
        case .error:
            return .secondary
        }
    }

    private var chevronColor: Color {
        trace.isLive && isHovering ? .secondary : StudioTheme.primaryText.opacity(0.36)
    }

    private var iconScale: CGFloat {
        guard trace.isLive, isHovering else { return 1.0 }
        return trace.kind == .terminal ? 1.08 : 1.03
    }

    private var iconOpacity: Double {
        guard trace.isLive else { return 1.0 }
        if isHovering {
            return trace.kind == .terminal ? 1.0 : 0.95
        }
        return 0.94
    }

    private var liveIconName: String {
        if trace.isContextTrace {
            return "circle.dashed"
        }

        switch trace.kind {
        case .search:
            return "magnifyingglass"
        case .read:
            return "doc.text"
        case .edit:
            return "square.and.pencil"
        case .write:
            return "doc.badge.plus"
        case .build:
            return "hammer.fill"
        case .terminal:
            return "terminal.fill"
        case .screenshot:
            return "camera.viewfinder"
        case .artifact:
            return "rectangle.split.3x1"
        }
    }
}

private struct InteractiveTerminalBlock: View {

    let trace: ToolTrace

    @State private var isExpanded: Bool

    init(trace: ToolTrace) {
        self.trace = trace
        _isExpanded = State(initialValue: trace.isLive || trace.status == .error)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: trace.isLive ? "terminal.fill" : "chevron.left.slash.chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse, options: .repeating, isActive: trace.isLive)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(summaryTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(summaryText)
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(StudioTheme.primaryText.opacity(0.9))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    if !trace.liveOutput.isEmpty {
                        Text("\(trace.liveOutput.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .overlay(StudioTheme.divider)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if trace.liveOutput.isEmpty {
                                TerminalConsoleLine(text: emptyStateText)
                                    .id(-1)
                            } else {
                                ForEach(Array(trace.liveOutput.enumerated()), id: \.offset) { index, line in
                                    TerminalConsoleLine(text: line)
                                        .id(index)
                                }
                            }
                        }
                        .padding(14)
                    }
                    .frame(minHeight: 118, maxHeight: 240)
                    .background(StudioTheme.terminalBackground)
                    .onAppear {
                        scrollToBottom(using: proxy, animated: false)
                    }
                    .onChange(of: trace.liveOutput.count) { _, _ in
                        scrollToBottom(using: proxy, animated: true)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(0.74)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: trace.status)
        .onChange(of: trace.status) { _, newStatus in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                switch newStatus {
                case .running:
                    isExpanded = true
                case .success:
                    isExpanded = true
                case .error:
                    isExpanded = true
                }
            }
        }
    }

    private var summaryTitle: String {
        switch trace.status {
        case .running:
            return trace.kind == .build ? "Live Build" : "Live Terminal"
        case .success:
            return trace.kind == .build ? "Build Complete" : "Terminal Complete"
        case .error:
            return trace.kind == .build ? "Build Error" : "Terminal Error"
        }
    }

    private var summaryText: String {
        switch trace.status {
        case .running:
            return trace.title
        case .success:
            return "\(trace.title) completed"
        case .error:
            return "\(trace.title) failed"
        }
    }

    private var emptyStateText: String {
        switch trace.status {
        case .running:
            return "Waiting for terminal output..."
        case .success:
            return "Command completed."
        case .error:
            return "Command failed."
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        let anchor = trace.liveOutput.isEmpty ? -1 : trace.liveOutput.count - 1
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(anchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }
}

private struct TerminalConsoleLine: View {

    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(prefix)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .center)

            Text(text.isEmpty ? " " : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(StudioTheme.primaryText.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var prefix: String {
        let lowercased = text.lowercased()
        if lowercased.contains("[error]") || lowercased.contains("error") || lowercased.contains("fatal") || lowercased.contains("failed") {
            return "!"
        }
        return ">"
    }
}

private struct TurnArtifactSummary: View {

    let turn: ConversationTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let metrics = turn.metrics {
                CompletionMetricsRow(metrics: metrics)
            }

            if let screenshotPath = turn.screenshotPath {
                InlineScreenshotView(path: screenshotPath)
                    .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
            }
        }
        .padding(.top, 2)
    }
}

private struct ResponseActionRow: View {

    let turn: ConversationTurn
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onReuseGoal: (String) -> Void
    let onCancelTurn: () -> Void
    let isLatestInteractiveTurn: Bool
    let isHighlighted: Bool
    let isRowHovering: Bool

    @AppStorage("packageRoot") private var storedPackageRoot = ""
    @State private var isShowingDiffPreview = false
    @State private var diffPreviewState: CodeDiffPreviewState = .idle
    @State private var isPreparingDiff = false
    @State private var highlightedAction: ActionHighlight?

    private enum ActionHighlight: String {
        case cancel
        case diff
        case artifact
        case iterate
    }

    var body: some View {
        HStack(spacing: 14) {
            if isActiveTurn {
                InlineActionButton(
                    title: "Cancel",
                    systemImage: "stop.circle",
                    isHighlighted: highlightedAction == .cancel,
                    isDisabled: !isLatestInteractiveTurn
                ) {
                    trigger(.cancel) {
                        onCancelTurn()
                    }
                }
            } else if turn.isHistorical {
                if hasDiffSource {
                    InlineActionButton(
                        title: "View Diff",
                        systemImage: "arrow.left.and.right.square",
                        isHighlighted: highlightedAction == .diff || isShowingDiffPreview,
                        isDisabled: false
                    ) {
                        trigger(.diff) {
                            openDiff()
                        }
                    }
                }

                if hasArtifact {
                    InlineActionButton(
                        title: "View Artifact",
                        systemImage: "sidebar.right",
                        isHighlighted: highlightedAction == .artifact,
                        isDisabled: false
                    ) {
                        trigger(.artifact) {
                            openArtifact()
                        }
                    }
                }
            } else {
                if hasDiffSource {
                    InlineActionButton(
                        title: isPreparingDiff ? "Preparing Diff" : "Open Diff",
                        systemImage: "arrow.left.and.right.square",
                        isHighlighted: highlightedAction == .diff || isPreparingDiff || isShowingDiffPreview,
                        isDisabled: isPreparingDiff
                    ) {
                        trigger(.diff) {
                            openDiff()
                        }
                    }
                }

                if hasArtifact {
                    InlineActionButton(
                        title: "Open Artifact",
                        systemImage: "sidebar.right",
                        isHighlighted: highlightedAction == .artifact,
                        isDisabled: false
                    ) {
                        trigger(.artifact) {
                            openArtifact()
                        }
                    }
                }

                InlineActionButton(
                    title: "Iterate",
                    systemImage: "arrow.clockwise",
                    isHighlighted: highlightedAction == .iterate,
                    isDisabled: false
                ) {
                    trigger(.iterate) {
                        onReuseGoal(turn.userGoal)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .padding(.top, 2)
        .opacity(actionRowOpacity)
        .contentTransition(.opacity)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: actionStateKey)
        .animation(.easeOut(duration: 0.18), value: actionRowOpacity)
        .sheet(isPresented: $isShowingDiffPreview) {
            DiffPreviewSheet(
                state: $diffPreviewState,
                onCancel: {
                    isShowingDiffPreview = false
                },
                onAccept: applyDiff
            )
            .frame(minWidth: 900, minHeight: 620)
        }
    }

    private var actionStateKey: String {
        [
            turn.state.rawValue,
            turn.isHistorical ? "historical" : "live",
            isHighlighted ? "highlighted" : "idle",
            hasDiffSource ? "diff" : "nodiff",
            hasArtifact ? "artifact" : "noartifact"
        ].joined(separator: "-")
    }

    private var isActiveTurn: Bool {
        !turn.isHistorical
            && isLatestInteractiveTurn
            && (turn.state == .streaming || turn.state == .executing || turn.state == .finalizing)
    }

    private var actionRowOpacity: Double {
        guard turn.isHistorical else { return 1.0 }
        return (isHighlighted || isRowHovering) ? 1.0 : 0.45
    }

    private var hasArtifact: Bool {
        turn.epochID != nil && (turn.screenshotPath != nil || turn.metrics != nil)
    }

    private var hasDiffSource: Bool {
        firstCodeBlock != nil || turn.epochID != nil
    }

    private var firstCodeBlock: (language: String?, content: String, targetHint: String?)? {
        for block in MarkdownBlock.parse(turn.response.text) {
            if case .code(let language, let content, let targetHint) = block.kind {
                return (language, content, targetHint)
            }
        }
        return nil
    }

    private var resolvedPackageRoot: String {
        if !storedPackageRoot.isEmpty,
           FileManager.default.fileExists(atPath: "\(storedPackageRoot)/Package.swift") {
            return storedPackageRoot
        }

        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.path
            }
        }

        return FileManager.default.currentDirectoryPath
    }

    private func openDiff() {
        if let epochID = turn.epochID, turn.isHistorical {
            onOpenArtifact(epochID, .codeDiff)
            return
        }

        if let firstCodeBlock {
            isPreparingDiff = true
            diffPreviewState = .loading
            isShowingDiffPreview = true

            let packageRoot = resolvedPackageRoot
            let code = firstCodeBlock.content
            let targetHint = firstCodeBlock.targetHint

            Task {
                let state = await Task.detached(priority: .userInitiated) {
                    CodeDiffPreviewState.prepare(
                        code: code,
                        targetHint: targetHint,
                        packageRoot: packageRoot
                    )
                }.value

                await MainActor.run {
                    diffPreviewState = state
                    isPreparingDiff = false
                }
            }
            return
        }

        if let epochID = turn.epochID {
            onOpenArtifact(epochID, .codeDiff)
        }
    }

    private func openArtifact() {
        guard let epochID = turn.epochID else { return }
        onOpenArtifact(epochID, .preview)
    }

    private func applyDiff(_ session: CodeDiffSession) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CodeDiffWriter.write(session: session)
            }.value

            await MainActor.run {
                switch result {
                case .success:
                    isShowingDiffPreview = false
                    CodeApplyFeedback.performSuccess()
                case .failure(let error):
                    diffPreviewState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func trigger(_ action: ActionHighlight, perform work: () -> Void) {
        withAnimation(.easeOut(duration: 0.16)) {
            highlightedAction = action
        }
        work()

        Task {
            try? await Task.sleep(for: .seconds(1.1))
            await MainActor.run {
                guard highlightedAction == action else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    highlightedAction = nil
                }
            }
        }
    }
}

private struct InlineActionButton: View {

    let title: String
    let systemImage: String
    let isHighlighted: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(foregroundColor)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
            .scaleEffect(isHovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.56 : 1)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isHovering)
        .animation(.easeOut(duration: 0.18), value: isHighlighted)
    }

    private var backgroundColor: Color {
        if isHighlighted {
            return StudioTheme.accentFill
        }
        if isHovering {
            return StudioTheme.surfaceHighlight
        }
        return .clear
    }

    private var foregroundColor: Color {
        isHighlighted ? .primary : .secondary
    }
}

private struct ChatMessageRow: View {

    let message: ChatMessage
    let isHighlighted: Bool
    let isPipelineRunning: Bool
    let onOpenArtifact: (UUID?) -> Void

    var body: some View {
        switch message.kind {
        case .userGoal:
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownMessageContent(text: message.text)
                    if !message.attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(message.attachments) { attachment in
                                    ReferenceBadge(
                                        title: attachment.displayName,
                                        systemImage: "paperclip",
                                        style: .tinted,
                                        action: {
                                            NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(StudioTheme.surfaceHighlight)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isHighlighted ? StudioTheme.accentBorder : StudioTheme.divider, lineWidth: isHighlighted ? 1.2 : 1)
                )
            }

        case .acknowledgment:
            AssistantNarrativeSection(
                text: message.text,
                emphasis: .subtle,
                isPipelineRunning: isPipelineRunning
            )

        case .assistant:
            AssistantNarrativeSection(
                text: message.text,
                emphasis: .subtle,
                isPipelineRunning: isPipelineRunning,
                reasoningText: message.thinkingText
            )

        case .stageUpdate:
            AssistantNarrativeSection(
                text: message.text,
                emphasis: .subtle,
                isPipelineRunning: isPipelineRunning
            )

        case .criticFeedback:
            AssistantNarrativeSection(
                text: message.text,
                emphasis: .emphasized,
                isPipelineRunning: isPipelineRunning
            )

        case .completion:
            ArtifactCardView(
                message: message,
                isHighlighted: isHighlighted,
                onOpenArtifact: onOpenArtifact
            )

        case .error:
            AssistantNarrativeSection(
                text: message.text,
                emphasis: .error,
                isPipelineRunning: isPipelineRunning
            )

        case .executionTree:
            EmptyView()

        case .thinking:
            ThinkingMessageRow(label: "Thinking")

        case .streaming:
            StreamingAssistantMessageRow(message: message, isPipelineRunning: isPipelineRunning)
        }
    }
}

private struct AssistantNarrativeSection: View {

    enum Emphasis {
        case subtle
        case emphasized
        case error
    }

    let text: String
    let emphasis: Emphasis
    let isPipelineRunning: Bool
    var reasoningText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: CalmChatLayout.messageInternalSpacing) {
            MarkdownMessageContent(
                text: text,
                isStreaming: false,
                isPipelineRunning: isPipelineRunning
            )
                .foregroundStyle(.primary)

            if let reasoningText = trimmedReasoningText {
                ThinkingDisclosureView(text: reasoningText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(textColor)
        .padding(.vertical, 2)
    }

    private var textColor: Color {
        switch emphasis {
        case .subtle:
            return .primary
        case .emphasized:
            return StudioTheme.primaryText.opacity(0.96)
        case .error:
            return StudioTheme.primaryText.opacity(0.94)
        }
    }

    private var trimmedReasoningText: String? {
        let trimmed = reasoningText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

private struct StreamingAssistantMessageRow: View {

    let message: ChatMessage
    let isPipelineRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CalmChatLayout.messageInternalSpacing) {
            if shouldShowPendingPlaceholder {
                ThinkingMessageRow(label: "Thinking")
            }

            if !contextToolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(contextToolCalls) { toolCall in
                        PhantomToolLogView(toolCall: toolCall)
                    }
                }
            }

            if !actionToolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(actionToolCalls) { toolCall in
                        ToolCallCard(toolCall: toolCall)
                    }
                }
            }

            if !renderedText.isEmpty {
                StreamingPlainTextView(text: renderedText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var renderedText: String {
        let baseText = message.isStreaming
            ? message.streamingText
            : (message.text.isEmpty ? message.streamingText : message.text)

        guard !baseText.isEmpty else { return "" }
        return message.isStreaming ? "\(baseText)▍" : baseText
    }

    private var shouldShowPendingPlaceholder: Bool {
        renderedText.isEmpty
            && contextToolCalls.isEmpty
            && actionToolCalls.isEmpty
    }

    private var contextToolCalls: [ToolCall] {
        message.streamingToolCalls
            .map(displayedToolCall(for:))
            .filter(isContextTool(_:))
    }

    private var actionToolCalls: [ToolCall] {
        message.streamingToolCalls
            .map(displayedToolCall(for:))
            .filter { !isContextTool($0) }
    }

    private func displayedToolCall(for call: StreamingToolCall) -> ToolCall {
        ToolCall(
            toolType: toolType(for: call.name),
            command: commandText(for: call),
            status: call.status,
            liveOutput: liveOutput(for: call)
        )
    }

    private func toolType(for name: String) -> ToolType {
        switch name {
        case "file_read":
            return .fileRead
        case "file_write":
            return .fileWrite
        case "file_patch":
            return .filePatch
        case "list_files":
            return .listFiles
        case "web_search":
            return .webSearch
        case "web_fetch":
            return .webFetch
        default:
            return .terminal
        }
    }

    private func isContextTool(_ toolCall: ToolCall) -> Bool {
        switch toolCall.toolType {
        case .fileRead, .listFiles, .webSearch, .webFetch:
            return true
        case .terminal, .fileWrite, .filePatch:
            return false
        }
    }

    private func commandText(for call: StreamingToolCall) -> String {
        let input = parsedJSON(from: call.inputJSON)

        switch toolType(for: call.name) {
        case .terminal:
            return call.displayCommand
                ?? (input?["objective"] as? String)
                ?? (input?["starting_command"] as? String)
                ?? (input?["command"] as? String)
                ?? "Terminal session"
        case .fileRead:
            return "Read \((input?["path"] as? String) ?? "file")"
        case .fileWrite:
            return "Write \((input?["path"] as? String) ?? "file")"
        case .filePatch:
            return "Patch \((input?["path"] as? String) ?? "file")"
        case .listFiles:
            return "List \((input?["path"] as? String) ?? ".")"
        case .webSearch:
            return (input?["query"] as? String) ?? "Web search"
        case .webFetch:
            return (input?["url"] as? String) ?? "Web fetch"
        }
    }

    private func liveOutput(for call: StreamingToolCall) -> [String] {
        if !call.liveOutput.isEmpty {
            return call.liveOutput
        }

        let source = call.result ?? ""
        let lines = source
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        if !lines.isEmpty {
            return lines
        }

        switch call.status {
        case .active:
            return ["Waiting for tool output..."]
        case .failed:
            return ["Tool failed without additional output."]
        case .completed:
            return ["Tool completed."]
        case .pending, .warning:
            return ["Waiting for tool input..."]
        }
    }

    private func parsedJSON(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

private struct StreamingPlainTextView: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .regular))
            .tracking(CalmChatLayout.bodyLetterSpacing)
            .foregroundStyle(StudioTheme.primaryText)
            .lineSpacing(6)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 720, alignment: .leading)
    }
}

private struct ThinkingDisclosureView: View {

    let text: String
    let isLive: Bool

    @State private var isExpanded = false

    init(text: String, isLive: Bool = false) {
        self.text = text
        self.isLive = isLive
        _isExpanded = State(initialValue: false)
    }

    var body: some View {
        CalmChatMetaCard(opacity: 0.6) {
            DisclosureGroup(isExpanded: $isExpanded) {
                MarkdownMessageContent(text: text, tone: .meta)
                    .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: CalmChatLayout.metaFontSize, weight: .semibold))
                        .foregroundStyle(StudioTheme.secondaryText)

                    Text(isLive ? "Thinking" : "Reasoning")
                        .font(.system(size: CalmChatLayout.metaFontSize, weight: .semibold, design: .monospaced))
                        .foregroundStyle(StudioTheme.secondaryText)

                    Spacer(minLength: 0)
                }
            }
            .tint(StudioTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ArtifactCardView: View {

    let message: ChatMessage
    let isHighlighted: Bool
    let onOpenArtifact: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MarkdownMessageContent(text: message.text)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Label("Artifact", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        onOpenArtifact(message.epochID)
                    } label: {
                        Label("Open Canvas", systemImage: "sidebar.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudioTheme.accent)
                    }
                    .buttonStyle(.plain)
                }

                if let metrics = message.metrics {
                    CompletionMetricsRow(metrics: metrics)
                }

                CompletionSourcesRow(message: message)

                if let screenshotPath = message.screenshotPath {
                    InlineScreenshotView(path: screenshotPath)
                        .frame(maxHeight: 220)
                }

                if let detailText = message.detailText,
                   !detailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MessageDetailPanel(text: detailText)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(StudioTheme.surfaceEmphasis)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isHighlighted ? StudioTheme.accentBorderStrong : StudioTheme.divider,
                        lineWidth: isHighlighted ? 1.3 : 1
                    )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            onOpenArtifact(message.epochID)
        }
    }
}

private struct CompletionMetricsRow: View {

    let metrics: MessageMetrics

    var body: some View {
        HStack(spacing: 8) {
            CompletionMetricChip(label: "File", value: (metrics.targetFile as NSString).lastPathComponent)
            CompletionMetricChip(label: "Direction", value: metrics.archetype.isEmpty ? "Native" : metrics.archetype)
            if let elapsedString {
                CompletionMetricChip(label: "Time", value: elapsedString)
            }
        }
    }

    private var elapsedString: String? {
        guard let elapsedSeconds = metrics.elapsedSeconds else { return nil }
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        if minutes == 0 {
            return "\(seconds)s"
        }
        return "\(minutes)m \(seconds)s"
    }
}

private struct CompletionMetricChip: View {

    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(StudioTheme.surfaceFill)
        )
    }
}

private struct MessageDetailPanel: View {

    let text: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MarkdownMessageContent(text: text)
                .padding(.top, 8)
        } label: {
            Label("Design Rationale", systemImage: "text.document")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StudioTheme.liftedSurface.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(StudioTheme.stroke, lineWidth: 1)
        )
    }
}

private struct CompletionSourcesRow: View {

    @AppStorage("packageRoot") private var storedPackageRoot = ""

    let message: ChatMessage

    private var resolvedTargetFilePath: String? {
        guard let targetFile = message.metrics?.targetFile, !targetFile.isEmpty else { return nil }
        if targetFile.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: targetFile) ? targetFile : nil
        }

        let candidates = [
            resolvedPackageRoot,
            FileManager.default.currentDirectoryPath
        ].filter { !$0.isEmpty }

        for root in candidates {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(targetFile).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let targetFile = message.metrics?.targetFile, !targetFile.isEmpty {
                    ReferenceBadge(
                        title: (targetFile as NSString).lastPathComponent,
                        systemImage: "doc.text"
                    ) {
                        if let resolvedTargetFilePath {
                            openFile(at: resolvedTargetFilePath)
                        } else {
                            copyToPasteboard(targetFile)
                        }
                    }
                }

                if let packetID = message.packetID {
                    ReferenceBadge(
                        title: "Packet \(packetID.uuidString.prefix(8))",
                        systemImage: "shippingbox"
                    ) {
                        copyToPasteboard(packetID.uuidString)
                    }
                }

                if let epochID = message.epochID {
                    ReferenceBadge(
                        title: "Epoch \(epochID.uuidString.prefix(6))",
                        systemImage: "clock.arrow.circlepath"
                    ) {
                        copyToPasteboard(epochID.uuidString)
                    }
                }

                if let screenshotPath = message.screenshotPath {
                    ReferenceBadge(
                        title: "Screenshot",
                        systemImage: "photo"
                    ) {
                        revealInFinder(path: screenshotPath)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var resolvedPackageRoot: String {
        if !storedPackageRoot.isEmpty,
           FileManager.default.fileExists(atPath: "\(storedPackageRoot)/Package.swift") {
            return storedPackageRoot
        }

        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url.path
            }
        }

        return ""
    }

    private func openFile(at path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct MessageTimestampLabel: View {

    let timestamp: Date

    var body: some View {
        Text(timestamp.formatted(date: .omitted, time: .shortened))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
    }
}

private struct ReferenceBadge: View {

    enum Style {
        case standard
        case tinted

        var fillColor: Color {
            switch self {
            case .standard:
                return StudioTheme.surfaceFill
            case .tinted:
                return StudioTheme.accentSurface
            }
        }

        var strokeColor: Color {
            switch self {
            case .standard:
                return StudioTheme.stroke
            case .tinted:
                return StudioTheme.accentBorder
            }
        }
    }

    let title: String
    let systemImage: String
    var style: Style = .standard
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(style.fillColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(style.strokeColor, lineWidth: 1)
        )
    }
}

private struct MarkdownListItem: Identifiable {

    enum Marker {
        case unordered
        case ordered(Int)

        var labelText: String {
            switch self {
            case .unordered:
                return "\u{2022}"
            case .ordered(let number):
                return "\(number)."
            }
        }
    }

    let id: String
    let text: String
    let marker: Marker
    var children: [MarkdownListItem]
}

private struct MarkdownListView: View {

    let items: [MarkdownListItem]
    var tone: MarkdownMessageContent.Tone = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(item.marker.labelText)
                            .font(markerFont(for: item.marker))
                            .foregroundStyle(tone == .meta ? StudioTheme.secondaryText : StudioTheme.secondaryText)
                            .frame(minWidth: 28, alignment: .trailing)

                        MarkdownInlineText(text: item.text, tone: tone)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !item.children.isEmpty {
                        MarkdownListView(items: item.children, tone: tone)
                            .padding(.leading, 28)
                    }
                }
            }
        }
    }

    private func markerFont(for marker: MarkdownListItem.Marker) -> Font {
        switch marker {
        case .unordered:
            return .system(size: tone == .meta ? CalmChatLayout.metaFontSize : CalmChatLayout.bodyFontSize, weight: .semibold)
        case .ordered:
            return .system(size: tone == .meta ? CalmChatLayout.metaFontSize : CalmChatLayout.bodyFontSize, weight: .semibold, design: .monospaced)
        }
    }
}

private struct MarkdownMessageContent: View {

    enum Tone {
        case body
        case meta
    }

    let text: String
    var isStreaming = false
    var isPipelineRunning = false
    var tone: Tone = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .heading(let level, let value):
                    MarkdownInlineText(text: value, tone: tone)
                        .font(headingFont(for: level))
                        .padding(.top, CalmChatLayout.headingTopSpacing)
                        .padding(.bottom, CalmChatLayout.headingBottomSpacing)
                case .paragraph(let value):
                    MarkdownInlineText(text: value, tone: tone)
                        .padding(.bottom, CalmChatLayout.messageInternalSpacing)
                case .list(let items):
                    MarkdownListView(items: items, tone: tone)
                        .padding(.bottom, CalmChatLayout.messageInternalSpacing)
                case .checklist(let tasks):
                    if isStreaming || isPipelineRunning {
                        BlueprintCompactView(tasks: tasks, isPipelineRunning: isPipelineRunning)
                            .padding(.bottom, CalmChatLayout.messageInternalSpacing)
                    } else {
                        BlueprintCardView(tasks: tasks, isPipelineRunning: isPipelineRunning)
                            .padding(.bottom, CalmChatLayout.messageInternalSpacing)
                    }
                case .quote(let value):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(StudioTheme.accentSurfaceStrong)
                            .frame(width: 3)
                        MarkdownInlineText(text: value, tone: tone)
                    }
                    .padding(.bottom, CalmChatLayout.messageInternalSpacing)
                case .code(let language, let code, let targetHint):
                    CodeBlockCard(
                        language: language,
                        code: code,
                        targetHint: targetHint,
                        isStreaming: isStreaming
                    )
                    .padding(.bottom, CalmChatLayout.messageInternalSpacing)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func headingFont(for level: Int) -> Font {
        switch tone {
        case .body:
            return .system(size: CalmChatLayout.headingFontSize, weight: .semibold, design: .default)
        case .meta:
            return .system(size: CalmChatLayout.metaFontSize, weight: .semibold, design: .monospaced)
        }
    }
}

private struct MarkdownInlineText: View {

    let text: String
    var tone: MarkdownMessageContent.Tone = .body

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(font)
                .tracking(CalmChatLayout.bodyLetterSpacing)
                .foregroundStyle(foregroundStyle)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(font)
                .tracking(CalmChatLayout.bodyLetterSpacing)
                .foregroundStyle(foregroundStyle)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var font: Font {
        switch tone {
        case .body:
            return .system(size: CalmChatLayout.bodyFontSize, weight: .regular)
        case .meta:
            return .system(size: CalmChatLayout.metaFontSize, weight: .regular, design: .monospaced)
        }
    }

    private var foregroundStyle: Color {
        switch tone {
        case .body:
            return StudioTheme.primaryText
        case .meta:
            return StudioTheme.secondaryText
        }
    }

    private var lineSpacing: CGFloat {
        switch tone {
        case .body:
            return CalmChatLayout.bodyLineSpacing
        case .meta:
            return 4
        }
    }
}

private struct CodeBlockCard: View {

    let language: String?
    let code: String
    let targetHint: String?
    let isStreaming: Bool

    @AppStorage("packageRoot") private var storedPackageRoot = ""
    @AppStorage("autonomyMode") private var storedAutonomyMode = AutonomyMode.review.rawValue
    @State private var isShowingDiffPreview = false
    @State private var diffPreviewState: CodeDiffPreviewState = .idle
    @State private var isPreparingDiff = false
    @State private var isApplyingToFile = false
    @State private var hasApplied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ReferenceBadge(
                    title: language?.isEmpty == false ? language!.uppercased() : "Code",
                    systemImage: "chevron.left.forwardslash.chevron.right"
                )
                Spacer()
                if let resolvedTarget = resolvedTargetHint {
                    Text(resolvedTarget)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlightedCode)
                    .font(.system(.body, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 18)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(StudioTheme.terminalBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(StudioTheme.stroke, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Button {
                        viewDiff()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: viewDiffButtonIcon)
                            Text(viewDiffButtonTitle)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(.secondary)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.clear)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(StudioTheme.stroke, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isPreparingDiff || isApplyingToFile || isStreaming)

                    Button {
                        applyToFile()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: applyButtonIcon)
                            Text(applyButtonTitle)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(applyButtonForeground)
                        .background(
                            Capsule(style: .continuous)
                                .fill(applyButtonFill)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(applyButtonStroke, lineWidth: 1)
                        )
                        .contentTransition(.opacity)
                    }
                    .buttonStyle(.plain)
                    .disabled(isPreparingDiff || isApplyingToFile || isStreaming || autonomyMode == .plan)
                    .animation(.snappy(duration: 0.24), value: applyButtonStateKey)
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(StudioTheme.panelBackground.opacity(0.96))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(StudioTheme.stroke, lineWidth: 1)
                )
                .padding(10)
            }
        }
        .sheet(isPresented: $isShowingDiffPreview) {
            DiffPreviewSheet(
                state: $diffPreviewState,
                onCancel: {
                    isShowingDiffPreview = false
                },
                onAccept: acceptDiffWrite
            )
            .frame(minWidth: 900, minHeight: 620)
        }
        .onChange(of: applyStateSignature) { _, _ in
            withAnimation(.snappy(duration: 0.2)) {
                hasApplied = false
            }
        }
    }

    private var highlightedCode: AttributedString {
        CodeSyntaxHighlighter.highlight(code: code, language: language)
    }

    private var resolvedPackageRoot: String {
        if !storedPackageRoot.isEmpty,
           FileManager.default.fileExists(atPath: "\(storedPackageRoot)/Package.swift") {
            return storedPackageRoot
        }

        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url.path
            }
        }

        return FileManager.default.currentDirectoryPath
    }

    private var resolvedTargetHint: String? {
        CodeTargetResolver.extractTargetHint(explicitHint: targetHint, code: code)
    }

    private var autonomyMode: AutonomyMode {
        AutonomyMode(rawValue: storedAutonomyMode) ?? .review
    }

    private var viewDiffButtonTitle: String {
        isPreparingDiff ? "Loading Diff..." : "View Diff"
    }

    private var viewDiffButtonIcon: String {
        isPreparingDiff ? "clock.arrow.circlepath" : "arrow.left.and.right.square"
    }

    private var applyButtonTitle: String {
        if hasApplied {
            return "Applied"
        }
        if isApplyingToFile {
            return "Applying to File..."
        }
        if isStreaming {
            return "Streaming"
        }
        if autonomyMode == .plan {
            return "Plan Only"
        }
        return "Apply to File"
    }

    private var applyButtonIcon: String {
        if hasApplied {
            return "checkmark.circle.fill"
        }
        if isApplyingToFile {
            return "square.and.arrow.down.fill"
        }
        if isStreaming {
            return "waveform"
        }
        if autonomyMode == .plan {
            return "lock.fill"
        }
        return "square.and.arrow.down"
    }

    private var applyButtonForeground: Color {
        hasApplied ? StudioTheme.success : StudioTheme.accent
    }

    private var applyButtonFill: Color {
        if hasApplied {
            return StudioTheme.successSurface
        }
        if isApplyingToFile {
            return StudioTheme.surfaceHighlight
        }
        return Color.clear
    }

    private var applyButtonStroke: Color {
        if hasApplied {
            return StudioTheme.successStroke
        }
        return StudioTheme.divider
    }

    private var applyButtonStateKey: String {
        "\(applyButtonTitle)-\(applyButtonIcon)-\(hasApplied)-\(isApplyingToFile)-\(isStreaming)-\(autonomyMode.rawValue)"
    }

    private var applyStateSignature: String {
        [language ?? "", targetHint ?? "", code].joined(separator: "|")
    }

    private func viewDiff() {
        guard !isPreparingDiff, !isApplyingToFile, !isStreaming else { return }
        isPreparingDiff = true
        diffPreviewState = .loading
        isShowingDiffPreview = true

        prepareDiffState { state in
            diffPreviewState = state
            isPreparingDiff = false
        }
    }

    private func applyToFile() {
        guard !isPreparingDiff, !isApplyingToFile, !isStreaming, autonomyMode != .plan else { return }
        isApplyingToFile = true

        prepareDiffState { state in
            switch state {
            case .ready(let session):
                writeDiff(session)
            case .failed(let message):
                diffPreviewState = .failed(message)
                isShowingDiffPreview = true
                isApplyingToFile = false
            case .idle, .loading:
                isApplyingToFile = false
            }
        }
    }

    private func prepareDiffState(_ completion: @escaping (CodeDiffPreviewState) -> Void) {
        let packageRoot = resolvedPackageRoot
        let code = self.code
        let targetHint = resolvedTargetHint

        Task {
            let state = await Task.detached(priority: .userInitiated) {
                CodeDiffPreviewState.prepare(
                    code: code,
                    targetHint: targetHint,
                    packageRoot: packageRoot
                )
            }.value

            await MainActor.run {
                completion(state)
            }
        }
    }

    private func acceptDiffWrite(_ session: CodeDiffSession) {
        guard !isApplyingToFile else { return }
        isApplyingToFile = true
        writeDiff(session)
    }

    private func writeDiff(_ session: CodeDiffSession) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CodeDiffWriter.write(session: session)
            }.value

            await MainActor.run {
                isApplyingToFile = false
                switch result {
                case .success:
                    withAnimation(.snappy(duration: 0.24)) {
                        hasApplied = true
                        isShowingDiffPreview = false
                    }
                    CodeApplyFeedback.performSuccess()
                case .failure(let error):
                    diffPreviewState = .failed(error.localizedDescription)
                    isShowingDiffPreview = true
                }
            }
        }
    }
}

private struct MarkdownBlock: Identifiable {

    private struct ListEntry {
        let indent: Int
        let marker: MarkdownListItem.Marker
        let text: String
    }

    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([MarkdownListItem])
        case checklist([BlueprintTask])
        case quote(String)
        case code(language: String?, content: String, targetHint: String?)
    }

    let id: String
    let kind: Kind

    static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0
        var codeBlockOrdinal = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                let inferredTargetHint = inferredCodeTargetHint(
                    previousBlock: blocks.last,
                    previousLine: index > 1 ? lines[index - codeLines.count - 2] : nil,
                    codeLines: codeLines
                )
                let codeBlockID = "code-\(codeBlockOrdinal)"
                codeBlockOrdinal += 1
                blocks.append(
                    MarkdownBlock(
                        id: codeBlockID,
                        kind: .code(
                            language: language.isEmpty ? nil : language,
                            content: codeLines.joined(separator: "\n"),
                            targetHint: inferredTargetHint
                        )
                    )
                )
                continue
            }

            if let heading = headingBlock(from: trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if checklistItem(in: trimmed) != nil {
                var tasks: [BlueprintTask] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = checklistItem(in: current) else { break }
                    tasks.append(
                        BlueprintTask(
                            id: stableID(prefix: "task", content: "\(tasks.count)-\(item.title)"),
                            title: item.title,
                            isCompleted: item.isCompleted
                        )
                    )
                    index += 1
                }
                blocks.append(
                    MarkdownBlock(
                        id: stableID(
                            prefix: "checklist",
                            content: tasks.map { "\($0.title)|\($0.isCompleted)" }.joined(separator: "|")
                        ),
                        kind: .checklist(tasks)
                    )
                )
                continue
            }

            if listEntry(in: line) != nil {
                var entries: [ListEntry] = []
                while index < lines.count {
                    guard let entry = listEntry(in: lines[index]) else { break }
                    entries.append(entry)
                    index += 1
                }
                blocks.append(
                    MarkdownBlock(
                        id: stableID(
                            prefix: "list",
                            content: entries.map { "\($0.indent)|\($0.marker.labelText)|\($0.text)" }.joined(separator: "|")
                        ),
                        kind: .list(buildListItems(from: entries))
                    )
                )
                continue
            }

            if trimmed.hasPrefix(">") {
                var quotes: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quotes.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let quoteText = quotes.joined(separator: " ")
                blocks.append(
                    MarkdownBlock(
                        id: stableID(prefix: "quote", content: quoteText),
                        kind: .quote(quoteText)
                    )
                )
                continue
            }

            var paragraphLines: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let current = lines[index].trimmingCharacters(in: .whitespaces)
                if current.isEmpty ||
                    current.hasPrefix("```") ||
                    headingBlock(from: current) != nil ||
                    checklistItem(in: current) != nil ||
                    listEntry(in: lines[index]) != nil ||
                    current.hasPrefix(">") {
                    break
                }
                paragraphLines.append(current)
                index += 1
            }
            let paragraphText = paragraphLines.joined(separator: " ")
            blocks.append(
                MarkdownBlock(
                    id: stableID(prefix: "paragraph", content: paragraphText),
                    kind: .paragraph(paragraphText)
                )
            )
        }

        return blocks
    }

    private static func headingBlock(from line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        guard level > 0, level <= 6 else { return nil }
        let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownBlock(
            id: stableID(prefix: "heading\(level)", content: text),
            kind: .heading(level: level, text: text)
        )
    }

    private static func checklistItem(in line: String) -> (title: String, isCompleted: Bool)? {
        guard let match = line.range(
            of: #"^[-*]\s+\[( |x|X)\]\s+"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let prefix = String(line[match])
        let title = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (title, prefix.localizedCaseInsensitiveContains("[x]"))
    }

    private static func listEntry(in line: String) -> ListEntry? {
        let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leadingWhitespace.reduce(into: 0) { result, character in
            result += character == "\t" ? 4 : 1
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return ListEntry(
                indent: indent,
                marker: .unordered,
                text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            )
        }

        guard let match = trimmed.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) else {
            return nil
        }

        let prefix = String(trimmed[..<match.upperBound])
        let numberText = prefix.components(separatedBy: ".").first ?? "1"
        let number = Int(numberText) ?? 1
        let text = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return ListEntry(indent: indent, marker: .ordered(number), text: text)
    }

    private static func buildListItems(from entries: [ListEntry]) -> [MarkdownListItem] {
        guard let firstIndent = entries.first?.indent else { return [] }
        var index = 0
        return parseListItems(entries, index: &index, indent: firstIndent)
    }

    private static func parseListItems(
        _ entries: [ListEntry],
        index: inout Int,
        indent: Int
    ) -> [MarkdownListItem] {
        var items: [MarkdownListItem] = []

        while index < entries.count {
            let entry = entries[index]

            if entry.indent < indent {
                break
            }

            if entry.indent > indent {
                if !items.isEmpty {
                    var lastItem = items.removeLast()
                    lastItem.children = parseListItems(entries, index: &index, indent: entry.indent)
                    items.append(lastItem)
                    continue
                }

                return parseListItems(entries, index: &index, indent: entry.indent)
            }

            var item = MarkdownListItem(
                id: stableID(
                    prefix: "list-item",
                    content: "\(entry.indent)|\(entry.marker.labelText)|\(entry.text)|\(index)"
                ),
                text: entry.text,
                marker: entry.marker,
                children: []
            )
            index += 1

            if index < entries.count, entries[index].indent > indent {
                item.children = parseListItems(entries, index: &index, indent: entries[index].indent)
            }

            items.append(item)
        }

        return items
    }

    private static func inferredCodeTargetHint(
        previousBlock: MarkdownBlock?,
        previousLine: String?,
        codeLines: [String]
    ) -> String? {
        if let previousBlock,
           case .paragraph(let text) = previousBlock.kind,
           let extracted = CodeTargetResolver.normalizedPathHint(from: text) {
            return extracted
        }

        if let previousLine,
           let extracted = CodeTargetResolver.normalizedPathHint(from: previousLine) {
            return extracted
        }

        for line in codeLines.prefix(4) {
            if let extracted = CodeTargetResolver.normalizedPathHint(from: line) {
                return extracted
            }
        }

        return nil
    }

    private static func stableID(prefix: String, content: String) -> String {
        let digest = String(content.hashValue, radix: 16, uppercase: false)
        return "\(prefix)-\(digest)"
    }
}

private enum CodeDiffPreviewState {
    case idle
    case loading
    case ready(CodeDiffSession)
    case failed(String)

    static func prepare(code: String, targetHint: String?, packageRoot: String) -> CodeDiffPreviewState {
        guard let targetURL = CodeTargetResolver.resolveTargetURL(
            targetHint: targetHint,
            packageRoot: packageRoot
        ) else {
            return .failed("I couldn’t locate a target file for this code block.")
        }

        let currentSource: String
        if FileManager.default.fileExists(atPath: targetURL.path) {
            currentSource = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? ""
        } else {
            currentSource = ""
        }

        return .ready(
            CodeDiffSession(
                targetURL: targetURL,
                targetDisplayName: CodeTargetResolver.displayName(for: targetURL, packageRoot: packageRoot),
                originalSource: currentSource,
                proposedSource: code,
                diffLines: DiffEngine.makeLines(
                    currentSource: currentSource,
                    proposedSource: code,
                    targetDisplayName: CodeTargetResolver.displayName(for: targetURL, packageRoot: packageRoot)
                ),
                isNewFile: !FileManager.default.fileExists(atPath: targetURL.path)
            )
        )
    }
}

private struct CodeDiffSession {
    let targetURL: URL
    let targetDisplayName: String
    let originalSource: String
    let proposedSource: String
    let diffLines: [DiffLine]
    let isNewFile: Bool
}

private struct DiffLine: Identifiable {

    enum Kind {
        case header
        case context
        case addition
        case removal
    }

    let id: Int
    let kind: Kind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String
}

private struct DiffPreviewSheet: View {

    @Binding var state: CodeDiffPreviewState
    let onCancel: () -> Void
    let onAccept: (CodeDiffSession) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diff Preview")
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(StudioTheme.panelBackground)

            Divider()

            Group {
                switch state {
                case .idle, .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("Preparing diff preview…")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    ContentUnavailableView(
                        "Apply Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .ready(let session):
                    DiffPreviewView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioTheme.panelBackground)

            Divider()

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if case .ready(let session) = state {
                    Button("Apply to File") {
                        onAccept(session)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(StudioTheme.panelBackground)
        }
    }

    private var subtitle: String {
        switch state {
        case .ready(let session):
            return session.targetDisplayName
        case .failed:
            return "No target file"
        case .idle, .loading:
            return "Resolving target"
        }
    }
}

private struct DiffPreviewView: View {

    let session: CodeDiffSession

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(session.diffLines) { line in
                    HStack(alignment: .top, spacing: 12) {
                        lineNumberColumn(line.oldLineNumber)
                        lineNumberColumn(line.newLineNumber)

                        Text(prefix(for: line.kind) + (line.text.isEmpty ? " " : line.text))
                            .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(foregroundColor(for: line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 3)
                    .background(backgroundColor(for: line.kind))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(18)
        }
    }

    private func lineNumberColumn(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 40, alignment: .trailing)
    }

    private func prefix(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .header:
            return "@ "
        case .context:
            return "  "
        case .addition:
            return "+ "
        case .removal:
            return "- "
        }
    }

    private func foregroundColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .header:
            return .orange
        case .context:
            return .primary
        case .addition:
            return .green
        case .removal:
            return .red
        }
    }

    private func backgroundColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .header:
            return StudioTheme.accentSurface
        case .context:
            return Color.clear
        case .addition:
            return StudioTheme.surfaceBare
        case .removal:
            return StudioTheme.surfaceSoft
        }
    }
}

private enum DiffEngine {

    static func makeLines(
        currentSource: String,
        proposedSource: String,
        targetDisplayName: String
    ) -> [DiffLine] {
        let oldLines = splitLines(currentSource)
        let newLines = splitLines(proposedSource)
        let diff = newLines.difference(from: oldLines)

        let removals = Dictionary(grouping: diff.removals, by: changeOffset)
        let insertions = Dictionary(grouping: diff.insertions, by: changeOffset)

        var rows: [DiffLine] = [
            DiffLine(id: 0, kind: .header, oldLineNumber: nil, newLineNumber: nil, text: "--- \(targetDisplayName)"),
            DiffLine(id: 1, kind: .header, oldLineNumber: nil, newLineNumber: nil, text: "+++ Proposed")
        ]

        var oldIndex = 0
        var newIndex = 0
        var oldLineNumber = 1
        var newLineNumber = 1
        var rowID = 2

        while oldIndex < oldLines.count || newIndex < newLines.count {
            if let removalGroup = removals[oldIndex], !removalGroup.isEmpty {
                for _ in removalGroup {
                    guard oldIndex < oldLines.count else { break }
                    rows.append(
                        DiffLine(
                            id: rowID,
                            kind: .removal,
                            oldLineNumber: oldLineNumber,
                            newLineNumber: nil,
                            text: oldLines[oldIndex]
                        )
                    )
                    rowID += 1
                    oldIndex += 1
                    oldLineNumber += 1
                }
                continue
            }

            if let insertionGroup = insertions[newIndex], !insertionGroup.isEmpty {
                for _ in insertionGroup {
                    guard newIndex < newLines.count else { break }
                    rows.append(
                        DiffLine(
                            id: rowID,
                            kind: .addition,
                            oldLineNumber: nil,
                            newLineNumber: newLineNumber,
                            text: newLines[newIndex]
                        )
                    )
                    rowID += 1
                    newIndex += 1
                    newLineNumber += 1
                }
                continue
            }

            if oldIndex < oldLines.count, newIndex < newLines.count {
                rows.append(
                    DiffLine(
                        id: rowID,
                        kind: .context,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: newLineNumber,
                        text: oldLines[oldIndex]
                    )
                )
                rowID += 1
                oldIndex += 1
                newIndex += 1
                oldLineNumber += 1
                newLineNumber += 1
            } else if oldIndex < oldLines.count {
                rows.append(
                    DiffLine(
                        id: rowID,
                        kind: .removal,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: nil,
                        text: oldLines[oldIndex]
                    )
                )
                rowID += 1
                oldIndex += 1
                oldLineNumber += 1
            } else if newIndex < newLines.count {
                rows.append(
                    DiffLine(
                        id: rowID,
                        kind: .addition,
                        oldLineNumber: nil,
                        newLineNumber: newLineNumber,
                        text: newLines[newIndex]
                    )
                )
                rowID += 1
                newIndex += 1
                newLineNumber += 1
            }
        }

        return rows
    }

    private static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func changeOffset(_ change: CollectionDifference<String>.Change) -> Int {
        switch change {
        case .remove(let offset, _, _), .insert(let offset, _, _):
            return offset
        }
    }
}

private enum CodeDiffWriter {

    static func write(session: CodeDiffSession) -> Result<Void, Error> {
        let parentDirectory = session.targetURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            try session.proposedSource.write(to: session.targetURL, atomically: true, encoding: .utf8)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

private enum CodeTargetResolver {

    private static let allowedExtensions = Set([
        "swift", "m", "mm", "h", "json", "plist", "md", "txt", "py", "sh", "yaml", "yml"
    ])

    static func extractTargetHint(explicitHint: String?, code: String) -> String? {
        if let explicitHint,
           let normalized = normalizedPathHint(from: explicitHint) {
            return normalized
        }

        for line in code.components(separatedBy: .newlines).prefix(4) {
            if let normalized = normalizedPathHint(from: line) {
                return normalized
            }
        }

        return nil
    }

    static func normalizedPathHint(from text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if candidate.hasPrefix("//") {
            candidate = String(candidate.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if candidate.hasPrefix("#") {
            candidate = String(candidate.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if candidate.lowercased().hasPrefix("file:") {
            candidate = String(candidate.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if candidate.lowercased().hasPrefix("path:") {
            candidate = String(candidate.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'*/ "))
        guard !candidate.isEmpty else { return nil }

        let url = URL(fileURLWithPath: candidate)
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return nil }

        if candidate.contains("/") || candidate.contains("\\") || candidate.contains(".") {
            return candidate.replacingOccurrences(of: "\\", with: "/")
        }

        return nil
    }

    static func resolveTargetURL(targetHint: String?, packageRoot: String) -> URL? {
        guard let targetHint else { return nil }

        if targetHint.hasPrefix("/") {
            return URL(fileURLWithPath: targetHint)
        }

        let rootURL = URL(fileURLWithPath: packageRoot, isDirectory: true)
        let relativeCandidate = rootURL.appendingPathComponent(targetHint)
        if FileManager.default.fileExists(atPath: relativeCandidate.path) || targetHint.contains("/") {
            return relativeCandidate
        }

        let basename = (targetHint as NSString).lastPathComponent
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var matches: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == basename else { continue }
            matches.append(url)
            if matches.count > 1 {
                break
            }
        }

        if matches.count == 1 {
            return matches[0]
        }

        if matches.count > 1 {
            return nil
        }

        return targetHint.contains("/") ? relativeCandidate : nil
    }

    static func displayName(for url: URL, packageRoot: String) -> String {
        let rootPath = URL(fileURLWithPath: packageRoot, isDirectory: true).path
        let path = url.path
        if path.hasPrefix(rootPath) {
            let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? url.lastPathComponent : relative
        }
        return path
    }
}

private enum CodeSyntaxHighlighter {

    static func highlight(code: String, language: String?) -> AttributedString {
        let attributed = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95)
            ]
        )

        let nsRange = NSRange(location: 0, length: (code as NSString).length)
        let commentRegex = try? NSRegularExpression(pattern: #"//.*$"#, options: [.anchorsMatchLines])
        commentRegex?.enumerateMatches(in: code, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
        }

        let stringRegex = try? NSRegularExpression(pattern: #""([^"\\]|\\.)*""#, options: [])
        stringRegex?.enumerateMatches(in: code, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: match.range)
        }

        let keywordPattern = #"\b(struct|class|enum|protocol|extension|var|let|func|import|return|if|else|guard|switch|case|for|while|await|async|throws|try|some|View)\b"#
        let keywordRegex = try? NSRegularExpression(pattern: keywordPattern, options: [])
        keywordRegex?.enumerateMatches(in: code, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range)
        }

        let typeRegex = try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, options: [])
        typeRegex?.enumerateMatches(in: code, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: NSColor.systemPink, range: match.range)
        }

        return AttributedString(attributed)
    }
}

private enum CodeApplyFeedback {

    static func performSuccess() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        NSSound(named: NSSound.Name("Glass"))?.play()
    }
}

private struct InlineScreenshotView: View {

    let path: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(StudioTheme.divider, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(StudioTheme.surfaceSoft)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .overlay {
                        Text("Screenshot unavailable")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .onAppear(perform: loadImage)
        .onChange(of: path) { _, _ in
            loadImage()
        }
    }

    private func loadImage() {
        guard FileManager.default.fileExists(atPath: path) else {
            image = nil
            return
        }

        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOfFile: path)
            }.value
            image = loaded
        }
    }
}

private struct ArtifactCanvasView: View {

    private enum CanvasTab: String, CaseIterable, Identifiable {
        case inspector = "Inspector"
        case deployment = "Deploy"

        var id: String { rawValue }
    }

    private enum InspectorMode: String, CaseIterable, Identifiable {
        case files = "Files"
        case preview = "Preview"
        case codeDiff = "Code Diff"

        var id: String { rawValue }
    }

    fileprivate struct InspectorFileRecord: Identifiable, Equatable {
        let path: String
        let displayName: String
        let kind: ToolTrace.Kind
        let linesAdded: Int?
        let linesRemoved: Int?
        let timestamp: Date

        var id: String { path }
    }

    let epoch: Epoch?
    let turns: [ConversationTurn]
    let deploymentState: DeploymentState
    let packageRoot: String
    let initialMode: ArtifactCanvasLaunchMode
    let onClose: () -> Void

    @State private var canvasTab: CanvasTab
    @State private var inspectorMode: InspectorMode
    @State private var image: NSImage?
    @State private var isImageLoaded = false
    @State private var isLoadingImage = false
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var selectedInspectorFilePath: String?
    @State private var selectedInspectorContent: AttributedString?
    @State private var isLoadingInspectorContent = false
    @State private var inspectorLoadTask: Task<Void, Never>?

    init(
        epoch: Epoch?,
        turns: [ConversationTurn],
        deploymentState: DeploymentState,
        packageRoot: String,
        initialMode: ArtifactCanvasLaunchMode = .preview,
        onClose: @escaping () -> Void
    ) {
        self.epoch = epoch
        self.turns = turns
        self.deploymentState = deploymentState
        self.packageRoot = packageRoot
        self.initialMode = initialMode
        self.onClose = onClose
        _canvasTab = State(initialValue: Self.canvasTab(for: initialMode))
        _inspectorMode = State(initialValue: Self.inspectorMode(for: initialMode))
    }

    private var selectedTurn: ConversationTurn? {
        if let epoch,
           let matchedTurn = turns.last(where: { $0.epochID == epoch.id }) {
            return matchedTurn
        }

        return turns.last(where: { $0.toolTraces.contains(where: { $0.filePath != nil }) })
            ?? turns.last(where: { !$0.isHistorical })
            ?? turns.last
    }

    private var title: String {
        if let epoch {
            return "Epoch \(epoch.index)"
        }
        if deploymentState.isVisible {
            return "Deployment"
        }
        return "Inspector"
    }

    private var subtitle: String {
        if canvasTab == .deployment {
            return deploymentState.targetDirectory ?? packageRoot
        }
        if let selectedInspectorFile {
            return selectedInspectorFile.displayName
        }
        if let epoch {
            return (epoch.targetFile as NSString).lastPathComponent
        }
        return selectedTurn?.userGoal ?? "Current turn"
    }

    private var screenshotPath: String? {
        epoch?.screenshotPath
    }

    private var inspectorFiles: [InspectorFileRecord] {
        var records: [InspectorFileRecord] = []
        var seenPaths = Set<String>()

        if let selectedTurn {
            for trace in selectedTurn.toolTraces.sorted(by: isHigherPriorityTrace) {
                let rawPaths = !trace.relatedFilePaths.isEmpty
                    ? trace.relatedFilePaths
                    : [trace.filePath].compactMap { $0 }

                for rawPath in rawPaths {
                    guard let absolutePath = normalizedInspectorPath(rawPath) else { continue }
                    guard !seenPaths.contains(absolutePath) else { continue }
                    seenPaths.insert(absolutePath)
                    records.append(
                        InspectorFileRecord(
                            path: absolutePath,
                            displayName: CodeTargetResolver.displayName(
                                for: URL(fileURLWithPath: absolutePath),
                                packageRoot: packageRoot
                            ),
                            kind: trace.kind,
                            linesAdded: trace.linesAdded,
                            linesRemoved: trace.linesRemoved,
                            timestamp: trace.timestamp
                        )
                    )
                }
            }
        }

        if records.isEmpty,
           let epoch,
           let fallbackPath = normalizedInspectorPath(epoch.targetFile),
           FileManager.default.fileExists(atPath: fallbackPath) {
            records.append(
                InspectorFileRecord(
                    path: fallbackPath,
                    displayName: CodeTargetResolver.displayName(
                        for: URL(fileURLWithPath: fallbackPath),
                        packageRoot: packageRoot
                    ),
                    kind: .write,
                    linesAdded: nil,
                    linesRemoved: nil,
                    timestamp: epoch.mergedAt
                )
            )
        }

        return records
    }

    private var availableInspectorModes: [InspectorMode] {
        var modes: [InspectorMode] = []
        if !inspectorFiles.isEmpty {
            modes.append(.files)
        }
        if epoch != nil {
            modes.append(.preview)
            if let diffText = epoch?.diffText,
               !diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                modes.append(.codeDiff)
            }
        }
        return modes.isEmpty ? [.files] : modes
    }

    private var selectedInspectorFile: InspectorFileRecord? {
        if let selectedInspectorFilePath,
           let matched = inspectorFiles.first(where: { $0.path == selectedInspectorFilePath }) {
            return matched
        }
        return inspectorFiles.first
    }

    private var deploymentConsoleToolCall: ToolCall {
        ToolCall(
            toolType: .terminal,
            command: deploymentState.command ?? "fastlane \(deploymentState.lane)",
            status: deploymentStepStatus,
            liveOutput: deploymentState.lines
        )
    }

    private var deploymentStepStatus: StepStatus {
        switch deploymentState.phase {
        case .idle:
            return .pending
        case .running:
            return .active
        case .completed:
            return .completed
        case .failed:
            return .failed
        }
    }

    private var deploymentDurationText: String? {
        guard let startedAt = deploymentState.startedAt else { return nil }
        let finishedAt = deploymentState.finishedAt ?? Date()
        let seconds = max(0, Int(finishedAt.timeIntervalSince(startedAt).rounded()))
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch canvasTab {
                case .inspector:
                    inspectorContent
                case .deployment:
                    deploymentContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            ZStack {
                Color.black

                LinearGradient(
                    colors: [
                        Color.clear,
                        StudioTheme.panelBackground.opacity(0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .onAppear {
            normalizeInspectorMode()
            synchronizeSelectedFile(resetSelection: false)
            loadImage()
            loadSelectedInspectorFile()
        }
        .onChange(of: initialMode) { _, newMode in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                canvasTab = Self.canvasTab(for: newMode)
                inspectorMode = Self.inspectorMode(for: newMode)
            }
            normalizeInspectorMode()
        }
        .onChange(of: epoch?.id) { _, _ in
            normalizeInspectorMode()
            loadImage()
        }
        .onChange(of: inspectorFiles.map(\.id)) { _, _ in
            synchronizeSelectedFile(resetSelection: false)
            normalizeInspectorMode()
        }
        .onChange(of: selectedInspectorFilePath) { _, _ in
            loadSelectedInspectorFile()
        }
        .onChange(of: canvasTab) { _, _ in
            normalizeInspectorMode()
        }
        .onDisappear {
            imageLoadTask?.cancel()
            inspectorLoadTask?.cancel()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StudioTheme.primaryText)

                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(StudioTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 10) {
                Picker("Canvas", selection: $canvasTab) {
                    ForEach(CanvasTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                if canvasTab == .inspector, availableInspectorModes.count > 1 {
                    Picker("Inspector Mode", selection: $inspectorMode) {
                        ForEach(availableInspectorModes) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                }
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StudioTheme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Close Artifact Canvas")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [
                    StudioTheme.surfaceWarm,
                    StudioTheme.panelBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch inspectorMode {
        case .files:
            ArtifactInspectorFilesView(
                files: inspectorFiles,
                selectedFilePath: $selectedInspectorFilePath,
                selectedFileContent: selectedInspectorContent,
                isLoadingContent: isLoadingInspectorContent,
                packageRoot: packageRoot
            )
        case .preview:
            artifactPreview
        case .codeDiff:
            ArtifactCodeDiffView(diffText: epoch?.diffText)
        }
    }

    private var deploymentContent: some View {
        DeploymentDashboardView(
            deploymentState: deploymentState,
            toolCall: deploymentConsoleToolCall,
            durationText: deploymentDurationText
        )
    }

    private static func canvasTab(for launchMode: ArtifactCanvasLaunchMode) -> CanvasTab {
        switch launchMode {
        case .deployment:
            return .deployment
        case .inspector, .preview, .codeDiff:
            return .inspector
        }
    }

    private static func inspectorMode(for launchMode: ArtifactCanvasLaunchMode) -> InspectorMode {
        switch launchMode {
        case .inspector:
            return .files
        case .preview:
            return .preview
        case .codeDiff:
            return .codeDiff
        case .deployment:
            return .files
        }
    }

    private func normalizeInspectorMode() {
        let modes = availableInspectorModes
        guard canvasTab == .inspector else { return }
        if !modes.contains(inspectorMode) {
            inspectorMode = modes.first ?? .files
        }
    }

    private func synchronizeSelectedFile(resetSelection: Bool) {
        let preferredPath = inspectorFiles.first?.path

        if resetSelection {
            selectedInspectorFilePath = preferredPath
            return
        }

        if let preferredPath {
            selectedInspectorFilePath = preferredPath
            return
        }

        selectedInspectorFilePath = nil
    }

    private var artifactPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(StudioTheme.panelBackground)

                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .padding(14)
                            .opacity(isImageLoaded ? 1 : 0)
                            .animation(.easeIn(duration: 0.3), value: isImageLoaded)
                    } else if isLoadingImage {
                        VStack(spacing: 10) {
                            ProcessingGearsView()
                            Text("Mounting Viewport...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("Simulator screenshot unavailable")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(StudioTheme.stroke, lineWidth: 1)
                )

                if let epoch {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 120), spacing: 10),
                            GridItem(.flexible(minimum: 120), spacing: 10)
                        ],
                        spacing: 10
                    ) {
                        ArtifactMetricPill(label: "HIG Score", value: "\(Int((epoch.higScore * 100).rounded()))%")
                        ArtifactMetricPill(label: "Components Built", value: componentsBuiltValue(for: epoch))
                        ArtifactMetricPill(label: "Deviation Cost", value: "\(Int((epoch.deviationCost * 100).rounded()))")
                        ArtifactMetricPill(label: "Drift", value: "\(Int((epoch.driftScore * 100).rounded()))")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                            Text("Summary")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(StudioTheme.secondaryText)

                        Text(epoch.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(StudioTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(StudioTheme.panelBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(StudioTheme.stroke, lineWidth: 1)
                    )
                }
            }
            .padding(18)
        }
        .background(StudioTheme.panelBackground)
    }

    private func componentsBuiltValue(for epoch: Epoch) -> String {
        if let componentsBuilt = epoch.componentsBuilt {
            return "\(componentsBuilt)"
        }
        if let diffText = epoch.diffText, !diffText.isEmpty {
            return "1"
        }
        return "0"
    }

    private func loadImage() {
        imageLoadTask?.cancel()
        image = nil
        isImageLoaded = false

        guard let screenshotPath,
              FileManager.default.fileExists(atPath: screenshotPath) else {
            isLoadingImage = false
            return
        }

        isLoadingImage = true
        imageLoadTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOfFile: screenshotPath)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                image = loaded
                isLoadingImage = false
                isImageLoaded = loaded != nil
            }
        }
    }

    private func loadSelectedInspectorFile() {
        inspectorLoadTask?.cancel()
        selectedInspectorContent = nil

        guard let selectedInspectorFile else {
            isLoadingInspectorContent = false
            return
        }

        isLoadingInspectorContent = true
        inspectorLoadTask = Task {
            let content = await Task.detached(priority: .userInitiated) { () -> AttributedString? in
                guard let source = try? String(contentsOfFile: selectedInspectorFile.path, encoding: .utf8) else {
                    return nil
                }
                return CodeSyntaxHighlighter.highlight(
                    code: source,
                    language: selectedInspectorFile.path.components(separatedBy: ".").last
                )
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                selectedInspectorContent = content
                isLoadingInspectorContent = false
            }
        }
    }

    private func normalizedInspectorPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else {
            url = URL(fileURLWithPath: packageRoot, isDirectory: true).appendingPathComponent(trimmed)
        }

        let standardizedPath = url.standardizedFileURL.path
        return FileManager.default.fileExists(atPath: standardizedPath) ? standardizedPath : nil
    }

    private func isHigherPriorityTrace(_ lhs: ToolTrace, _ rhs: ToolTrace) -> Bool {
        let lhsPriority = inspectorPriority(for: lhs)
        let rhsPriority = inspectorPriority(for: rhs)

        if lhsPriority != rhsPriority {
            return lhsPriority > rhsPriority
        }

        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }

        return lhs.id < rhs.id
    }

    private func inspectorPriority(for trace: ToolTrace) -> Int {
        if trace.sourceName == "delegate_to_reviewer" && trace.isLive {
            return 4
        }

        if (trace.sourceName == "file_write" || trace.sourceName == "file_patch") && trace.isLive {
            return 3
        }

        if trace.sourceName == "file_write" || trace.sourceName == "file_patch" {
            return 2
        }

        if trace.sourceName == "delegate_to_reviewer" {
            return 1
        }

        return 0
    }
}

private struct ArtifactInspectorFilesView: View {

    let files: [ArtifactCanvasView.InspectorFileRecord]
    @Binding var selectedFilePath: String?
    let selectedFileContent: AttributedString?
    let isLoadingContent: Bool
    let packageRoot: String

    var body: some View {
        VStack(spacing: 0) {
            if files.isEmpty {
                ContentUnavailableView(
                    "No Modified Files",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("When the current turn reads or writes files, they’ll appear here for inspection.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioTheme.panelBackground)
            } else {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(files) { file in
                                ArtifactInspectorFileChip(
                                    file: file,
                                    isSelected: selectedFilePath == file.path
                                ) {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        selectedFilePath = file.path
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                    }

                    Divider()

                    Group {
                        if isLoadingContent {
                            VStack(spacing: 10) {
                                ProcessingGearsView()
                                Text("Loading file...")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(StudioTheme.tertiaryText)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let selectedFileContent {
                            ScrollView([.vertical, .horizontal]) {
                                Text(selectedFileContent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(18)
                                    .textSelection(.enabled)
                            }
                        } else {
                            ContentUnavailableView(
                                "File Unavailable",
                                systemImage: "doc.badge.xmark",
                                description: Text("The selected file could not be loaded from the current project root.")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .background(StudioTheme.terminalBackground)
                }
                .background(StudioTheme.panelBackground)
            }
        }
    }
}

private struct ArtifactInspectorFileChip: View {

    let file: ArtifactCanvasView.InspectorFileRecord
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? StudioTheme.primaryText : StudioTheme.secondaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.primaryText)
                        .lineLimit(1)

                    if let diffSummary {
                        Text(diffSummary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(StudioTheme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }

    private var symbolName: String {
        switch file.kind {
        case .read:
            return "doc.text"
        case .edit:
            return "square.and.pencil"
        case .write:
            return "doc.badge.plus"
        case .search:
            return "magnifyingglass"
        case .build:
            return "hammer.fill"
        case .terminal:
            return "terminal.fill"
        case .screenshot:
            return "camera.viewfinder"
        case .artifact:
            return "rectangle.split.3x1"
        }
    }

    private var diffSummary: String? {
        guard file.linesAdded != nil || file.linesRemoved != nil else { return nil }
        let added = file.linesAdded ?? 0
        let removed = file.linesRemoved ?? 0
        return "+\(added) -\(removed)"
    }

    private var backgroundColor: Color {
        if isSelected {
            return StudioTheme.accentSurfaceStrong
        }
        if isHovering {
            return StudioTheme.surfaceFill
        }
        return StudioTheme.liftedSurface.opacity(0.84)
    }

    private var borderColor: Color {
        isSelected ? StudioTheme.accentStroke : StudioTheme.stroke
    }
}

private struct DeploymentDashboardView: View {

    let deploymentState: DeploymentState
    let toolCall: ToolCall
    let durationText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(StudioTheme.accentSurfaceStrong.opacity(0.85))
                                .frame(width: 44, height: 44)

                            if deploymentState.isActive {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(StudioTheme.accent)
                            } else {
                                Image(systemName: statusSymbolName)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(StudioTheme.secondaryText)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(headerTitle)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(StudioTheme.primaryText)

                            Text(headerSubtitle)
                                .font(.caption)
                                .foregroundStyle(StudioTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        if let durationText {
                            Text(durationText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(StudioTheme.secondaryText)
                        }
                    }

                    if let targetDirectory = deploymentState.targetDirectory,
                       !targetDirectory.isEmpty {
                        Text(targetDirectory)
                            .font(.caption.monospaced())
                            .foregroundStyle(StudioTheme.tertiaryText)
                            .textSelection(.enabled)
                    }
                }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(StudioTheme.panelBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(StudioTheme.stroke, lineWidth: 1)
                        )

                ArtifactConsoleBlock(toolCall: toolCall)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toolCall.status)
            }
            .padding(18)
        }
        .background(StudioTheme.panelBackground)
    }

    private var headerTitle: String {
        switch deploymentState.phase {
        case .idle:
            return "Deployment idle"
        case .running:
            return "Shipping to TestFlight"
        case .completed:
            return "Deployment complete"
        case .failed:
            return "Deployment failed"
        }
    }

    private var headerSubtitle: String {
        deploymentState.summary ?? "Fastlane \(deploymentState.lane)"
    }

    private var statusSymbolName: String {
        switch deploymentState.phase {
        case .idle:
            return "paperplane"
        case .running:
            return "paperplane.fill"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "xmark.circle"
        }
    }
}

private struct ArtifactMetricPill: View {

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioTheme.secondaryText)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(StudioTheme.primaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StudioTheme.liftedSurface.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(StudioTheme.stroke, lineWidth: 1)
        )
    }
}

private struct ArtifactCodeDiffView: View {

    let diffText: String?

    private var lines: [String] {
        guard let diffText else { return [] }
        return diffText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    var body: some View {
        Group {
            if lines.isEmpty {
                ContentUnavailableView(
                    "No Grounded Diff",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("This epoch was archived without a source delta, so there’s no exact code diff to render.")
                )
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .trailing)

                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                                    .foregroundStyle(color(for: line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 3)
                            .background(backgroundColor(for: line))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(18)
                }
                .background(StudioTheme.terminalBackground)
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return StudioTheme.success
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return StudioTheme.danger
        }
        if line.hasPrefix("@@") {
            return StudioTheme.warning
        }
        return StudioTheme.primaryText
    }

    private func backgroundColor(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return StudioTheme.success.opacity(0.10)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return StudioTheme.danger.opacity(0.10)
        }
        if line.hasPrefix("@@") {
            return StudioTheme.warning.opacity(0.10)
        }
        return Color.clear
    }
}

private struct ThinkingMessageRow: View {

    let label: String

    var body: some View {
        CalmChatMetaCard(opacity: 0.6) {
            HStack(spacing: 10) {
                ProcessingGearsView()

                Text(label)
                    .font(.system(size: CalmChatLayout.metaFontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .shimmer(isActive: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExecutionTreeView: View {

    let steps: [ExecutionStep]
    let timestamp: Date
    let isHighlighted: Bool

    private var summary: ExecutionTreeSummary {
        ExecutionTreeSummary(steps: steps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Factory Run", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                ExecutionStatusBadge(status: summary.status)
            }

            Text(summaryText)
                .font(.system(size: 13))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if councilStep != nil {
                OrchestrationPipelineView(
                    specialistStatus: statusForCouncilChild("specialist"),
                    criticStatus: statusForCouncilChild("critic"),
                    architectStatus: statusForCouncilChild("architect"),
                    summary: councilSummary
                )
            }

            if let researcherTool = step(id: "researcher")?.toolCall {
                ToolCallCard(toolCall: researcherTool)
            }

            if let webFetchTool = step(id: "web-fetch")?.toolCall {
                ToolCallCard(toolCall: webFetchTool)
            }

            if let weaverTool = step(id: "weaver")?.toolCall {
                ToolCallCard(toolCall: weaverTool)
            }

            if let verifyStep {
                InlineStageNote(
                    title: "Verification",
                    systemImage: "checkmark.shield",
                    status: verifyStep.status
                )
            }

            if let executorTool = step(id: "executor")?.toolCall {
                ToolCallCard(toolCall: executorTool)
            }

            HStack {
                Spacer()
                MessageTimestampLabel(timestamp: timestamp)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, isHighlighted ? 12 : 0)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isHighlighted ? StudioTheme.accentSurface.opacity(0.42) : Color.clear)
        )
    }

    private var pipelineStep: ExecutionStep? {
        steps.first(where: { $0.id == "pipeline" }) ?? steps.first
    }

    private var pipelineChildren: [ExecutionStep] {
        pipelineStep?.children ?? []
    }

    private var councilStep: ExecutionStep? {
        step(id: "council")
    }

    private var verifyStep: ExecutionStep? {
        step(id: "verify")
    }

    private func step(id: String) -> ExecutionStep? {
        pipelineChildren.first(where: { $0.id == id })
    }

    private func statusForCouncilChild(_ id: String) -> StepStatus {
        councilStep?.children.first(where: { $0.id == id })?.status ?? .pending
    }

    private var summaryText: String {
        if let executorStep = step(id: "executor"), executorStep.status == .active {
            return "Automatic repair is resolving the latest build issues in a grounded console."
        }
        if let weaverStep = step(id: "weaver"), weaverStep.status == .active {
            return "Approved changes are being woven into the codebase."
        }
        if let verifyStep, verifyStep.status == .active {
            return "Verification is checking the current build."
        }
        if let councilStep, councilStep.status == .active {
            return councilSummary
        }
        if let researcherStep = step(id: "researcher"), researcherStep.status == .active {
            return "The factory is grounding itself in current Apple platform context before writing code."
        }

        switch summary.status {
        case .completed:
            return "The run completed with grounded artifacts and a captured result."
        case .warning:
            return "The run completed, but one stage needed attention."
        case .failed:
            return "The run stopped after capturing the latest grounded artifacts."
        case .pending:
            return "Waiting for pipeline activity."
        case .active:
            return "The factory is actively working through the run."
        }
    }

    private var councilSummary: String {
        switch (statusForCouncilChild("specialist"), statusForCouncilChild("critic"), statusForCouncilChild("architect")) {
        case (.active, _, _):
            return "Council review is shaping the initial proposal."
        case (.completed, .active, _):
            return "Council review is testing the proposal against product and design constraints."
        case (.completed, .completed, .active):
            return "Council aligned on the direction and is locking the merge."
        case (.completed, .completed, .completed):
            return "Council aligned on model structure. Proceeding to weave changes."
        case (_, .warning, _), (_, _, .warning):
            return "Council requested another pass before implementation."
        case (_, _, .failed), (_, .failed, _), (.failed, _, _):
            return "Council review stopped before alignment."
        default:
            return "Council review is preparing the implementation direction."
        }
    }
}

private struct OrchestrationPipelineView: View {

    let specialistStatus: StepStatus
    let criticStatus: StepStatus
    let architectStatus: StepStatus
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Council Review")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.secondaryText)

                Spacer(minLength: 8)

                PipelinePhaseNode(title: "Specialist", status: specialistStatus)
                PipelineConnector(isLit: specialistStatus != .pending)
                PipelinePhaseNode(title: "Critic", status: criticStatus)
                PipelineConnector(isLit: criticStatus != .pending)
                PipelinePhaseNode(title: "Architect", status: architectStatus)
            }

            Text(summary)
                .font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StudioTheme.liftedSurface.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(StudioTheme.stroke, lineWidth: 1)
        )
    }
}

private struct PipelinePhaseNode: View {

    let title: String
    let status: StepStatus

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .active)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudioTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var iconName: String {
        switch status {
        case .pending:
            return "circle.dashed"
        case .active:
            return "ellipsis.circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch status {
        case .pending:
            return StudioTheme.tertiaryText
        case .active:
            return StudioTheme.accent
        case .completed:
            return StudioTheme.success
        case .warning:
            return StudioTheme.warning
        case .failed:
            return StudioTheme.danger
        }
    }
}

private struct PipelineConnector: View {

    let isLit: Bool

    var body: some View {
        Capsule(style: .continuous)
            .fill(isLit ? StudioTheme.accentSurfaceStrong : StudioTheme.stroke)
            .frame(width: 18, height: 2)
    }
}

private struct InlineStageNote: View {

    let title: String
    let systemImage: String
    let status: StepStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioTheme.secondaryText)
            Spacer()
            ExecutionStatusBadge(status: status)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StudioTheme.liftedSurface.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(StudioTheme.stroke, lineWidth: 1)
        )
    }

    private var iconColor: Color {
        switch status {
        case .pending:
            return StudioTheme.tertiaryText
        case .active:
            return StudioTheme.accent
        case .completed:
            return StudioTheme.success
        case .warning:
            return StudioTheme.warning
        case .failed:
            return StudioTheme.danger
        }
    }
}

private struct ExecutionStatusBadge: View {

    let status: StepStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .active)
            Text(label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        )
    }

    private var label: String {
        switch status {
        case .pending:
            return "Pending"
        case .active:
            return "Running"
        case .completed:
            return "Complete"
        case .warning:
            return "Attention"
        case .failed:
            return "Failed"
        }
    }

    private var iconName: String {
        switch status {
        case .pending:
            return "circle.dashed"
        case .active:
            return "hourglass.circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .pending:
            return StudioTheme.secondaryText
        case .active:
            return StudioTheme.accent
        case .completed:
            return StudioTheme.success
        case .warning:
            return StudioTheme.warning
        case .failed:
            return StudioTheme.danger
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .pending:
            return StudioTheme.liftedSurface.opacity(0.92)
        case .active:
            return StudioTheme.accentSurface
        case .completed:
            return StudioTheme.success.opacity(0.12)
        case .warning:
            return StudioTheme.warning.opacity(0.12)
        case .failed:
            return StudioTheme.danger.opacity(0.12)
        }
    }

    private var strokeColor: Color {
        switch status {
        case .pending:
            return StudioTheme.stroke
        case .active:
            return StudioTheme.accentStroke
        case .completed:
            return StudioTheme.success.opacity(0.34)
        case .warning:
            return StudioTheme.warning.opacity(0.34)
        case .failed:
            return StudioTheme.danger.opacity(0.34)
        }
    }
}

private struct ExecutionTreeSummary {

    let status: StepStatus
    let subtitle: String

    init(steps: [ExecutionStep]) {
        let flattened = ExecutionTreeSummary.flatten(steps)
        let detailSteps = flattened.filter { $0.id != "pipeline" }
        status = flattened.first?.status ?? .pending

        let completedCount = detailSteps.filter { $0.status == .completed }.count
        let totalCount = max(detailSteps.count, 1)
        let activeTitle = detailSteps.last(where: { $0.status == .active })?.title

        switch status {
        case .active:
            if let activeTitle {
                subtitle = "\(completedCount) of \(totalCount) steps complete. Working on \(activeTitle)."
            } else {
                subtitle = "\(completedCount) of \(totalCount) steps complete."
            }
        case .completed:
            subtitle = "Run trace finalized from live pipeline output."
        case .warning:
            subtitle = "The run completed with a step that needed attention."
        case .failed:
            subtitle = "The run trace captured a failure before completion."
        case .pending:
            subtitle = "Waiting for pipeline activity."
        }
    }

    private static func flatten(_ steps: [ExecutionStep]) -> [ExecutionStep] {
        steps.flatMap { step in
            [step] + flatten(step.children)
        }
    }
}

// MARK: - Diff Inspector Pane (Pane 2)

/// Center detail: chat thread, scrubber, and goal input.
private struct DiffInspectorPane: View {

    let project: AppProject?
    @Binding var selectedEpochID: UUID?
    let runner: PipelineRunner
    let repositoryState: GitRepositoryState
    let isRefreshingRepository: Bool
    let conversationStore: ConversationStore
    @Binding var goalText: String
    @Binding var attachments: [ChatAttachment]
    let onSubmit: () -> Void
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onRefreshRepository: () -> Void
    let onInitializeRepository: () -> Void
    let onOpenWorkspace: () -> Void

    @State private var reusedPromptToken: UUID?
    @State private var reusedPromptText: String?
    @State private var floatingComposerHeight: CGFloat = 120

    private var sortedEpochs: [Epoch] {
        project?.epochs.sorted { $0.index < $1.index } ?? []
    }

    private var shouldShowEpochScrubber: Bool {
        !sortedEpochs.isEmpty && !runner.isRunning
    }

    private var historicalMessages: [ChatMessage] {
        guard let project else { return [] }
        return sortedEpochs.map { epoch in
            ChatMessage(
                id: epoch.id,
                kind: .completion,
                goal: project.goal,
                text: completionText(for: epoch),
                detailText: epoch.summary,
                timestamp: epoch.mergedAt,
                screenshotPath: epoch.screenshotPath,
                metrics: MessageMetrics(
                    higScore: Int((epoch.higScore * 100).rounded()),
                    archetype: epoch.archetype ?? "",
                    targetFile: epoch.targetFile,
                    deviationCost: epoch.deviationCost,
                    elapsedSeconds: nil
                ),
                executionTree: nil,
                epochID: epoch.id,
                packetID: epoch.packetID
            )
        }
    }

    private var activeGoal: String? {
        project?.goal ?? runner.activeGoal
    }

    private var liveMessageLedger: [ChatMessage] {
        guard let activeGoal else { return [] }
        return runner.chatThread.messages.filter { message in
            message.goal == activeGoal
        }
    }

    private var conversationSourceMessages: [ChatMessage] {
        let liveEpochs = Set(liveMessageLedger.compactMap(\.epochID))
        let baseHistory = historicalMessages.filter { message in
            guard let epochID = message.epochID else { return true }
            return !liveEpochs.contains(epochID)
        }
        return (baseHistory + liveMessageLedger).sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.timestamp < rhs.timestamp
        }
    }

    private var conversationSourceSignature: Int {
        var hasher = Hasher()
        hasher.combine(runner.isRunning)
        for message in conversationSourceMessages {
            hasher.combine(message.id)
            hasher.combine(message.kind.rawValue)
            hasher.combine(message.timestamp)
            hasher.combine(message.text)
            hasher.combine(message.detailText)
            hasher.combine(message.streamingText)
            hasher.combine(message.isStreaming)
            hasher.combine(message.epochID)
            hasher.combine(message.packetID)
            hasher.combine(message.streamingToolCalls.count)
            hasher.combine(message.executionTree?.count ?? 0)
        }
        return hasher.finalize()
    }

    private var reservedThreadInset: CGFloat {
        floatingComposerHeight + CalmChatLayout.floatingComposerBottomInset + CalmChatLayout.floatingComposerReserveGap
    }

    private func floatingComposerOverlay(columnWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(StudioTheme.dockDivider)
                .frame(height: 1)

            VStack(spacing: 14) {
                CalmChatColumn(width: columnWidth) {
                    WorkspaceRepositoryCard(
                        repositoryState: repositoryState,
                        isRefreshing: isRefreshingRepository,
                        onRefresh: onRefreshRepository,
                        onInitializeGit: onInitializeRepository,
                        onOpenWorkspace: onOpenWorkspace
                    )
                }

                CalmChatColumn(width: columnWidth) {
                    WorkspaceOperatorRoutingCard()
                }

                if project?.requiresHumanOverride == true {
                    ManualOverrideBanner()
                        .frame(width: columnWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if shouldShowEpochScrubber {
                    CalmChatColumn(width: columnWidth) {
                        EpochScrubber(
                            epochs: sortedEpochs,
                            selectedEpochID: $selectedEpochID
                        )
                        .frame(height: 96)
                    }
                }

                CalmChatColumn(width: columnWidth) {
                    GoalInputBar(
                        goalText: $goalText,
                        attachments: $attachments,
                        runner: runner,
                        reusedPromptToken: reusedPromptToken,
                        reusedPromptText: reusedPromptText,
                        onSubmit: onSubmit
                    )
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, CalmChatLayout.columnHorizontalPadding)
            .padding(.bottom, CalmChatLayout.floatingComposerBottomInset)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color.clear,
                    StudioTheme.dockFill.opacity(0.78),
                    StudioTheme.dockFill
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FloatingComposerHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = CalmChatLayout.columnWidth(for: proxy.size.width)

            ChatThreadView(
                turns: conversationStore.turns,
                isPipelineRunning: runner.isRunning,
                selectedEpochID: selectedEpochID,
                columnWidth: columnWidth,
                bottomContentInset: reservedThreadInset,
                suggestions: goalSuggestions,
                onSelectSuggestion: { suggestion in
                    goalText = suggestion.prompt
                },
                onOpenArtifact: onOpenArtifact,
                onReuseGoal: { goal in
                    goalText = goal
                    reusedPromptText = "Prompt reused from this turn"
                    reusedPromptToken = UUID()
                },
                onCancelTurn: {
                    runner.cancel()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioCanvasView())
            .overlay(alignment: .bottom) {
                floatingComposerOverlay(columnWidth: columnWidth)
            }
            .onPreferenceChange(FloatingComposerHeightPreferenceKey.self) { newHeight in
                guard newHeight > 0 else { return }
                floatingComposerHeight = newHeight
            }
        }
        .task(id: conversationSourceSignature) {
            conversationStore.rebuild(
                from: conversationSourceMessages,
                isPipelineRunning: runner.isRunning
            )
        }
        .navigationTitle(project?.name ?? "")
        .navigationSubtitle("")
    }

    private func completionText(for epoch: Epoch) -> String {
        let fileName = (epoch.targetFile as NSString).lastPathComponent
        let direction = designDirectionText(for: epoch.archetype)
        return "Done — I built \(fileName) with \(direction). HIG alignment is \(Int((epoch.higScore * 100).rounded()))%."
    }

    private func designDirectionText(for archetype: String?) -> String {
        switch archetype?.lowercased() {
        case "athletic":
            return "an energetic, performance-led direction"
        case "financial":
            return "a sober, trust-first direction"
        case "socialreactive":
            return "a lively, reactive direction"
        case "tactical":
            return "a precise, information-forward direction"
        case "utilityminimal":
            return "a minimal, distraction-free direction"
        default:
            return "a focused, native direction"
        }
    }

    private var goalSuggestions: [AgenticSuggestion] {
        if let latestEpoch = sortedEpochs.last {
            return [
                AgenticSuggestion(
                    id: "audit-latest-workspace",
                    title: "Audit Codebase",
                    prompt: "Audit this workspace around \(latestEpoch.targetFile) and map the architecture before making changes.",
                    symbolName: "magnifyingglass"
                ),
                AgenticSuggestion(
                    id: "scaffold-follow-up",
                    title: "Scaffold New UI",
                    prompt: "Scaffold the next layer of this iOS app with native SwiftUI structure and production-ready screens.",
                    symbolName: "hammer.fill"
                ),
                AgenticSuggestion(
                    id: "review-latest-architecture",
                    title: "Review Architecture",
                    prompt: "Review the current architecture around \(latestEpoch.targetFile) for bugs, HIG drift, and structural risks.",
                    symbolName: "checklist"
                )
            ]
        }

        return [
            AgenticSuggestion(
                id: "audit-workspace",
                title: "Audit Codebase",
                prompt: "Audit this workspace and map the key architecture before making changes.",
                symbolName: "magnifyingglass"
            ),
            AgenticSuggestion(
                id: "scaffold-ios-app",
                title: "Scaffold New UI",
                prompt: "Scaffold a native iOS app with SwiftUI, clean structure, and production-ready screens.",
                symbolName: "hammer.fill"
            ),
            AgenticSuggestion(
                id: "review-architecture",
                title: "Review Architecture",
                prompt: "Review the current architecture for bottlenecks, HIG drift, and structural risks.",
                symbolName: "checklist"
            )
        ]
    }
}

private struct WorktreeJobDetailPane: View {

    let session: AgentSession

    @State private var selectedDiffID: String?

    private var reviewThread: ReviewThread? {
        session.reviewThread
    }

    private var diffContexts: [ReviewDiffContext] {
        reviewThread?.diffContexts ?? []
    }

    private var selectedDiffContext: ReviewDiffContext? {
        if let selectedDiffID,
           let match = diffContexts.first(where: { $0.id == selectedDiffID }) {
            return match
        }
        return diffContexts.first
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorktreeContextBanner(session: session)
                    WorktreeJobSummaryCard(session: session)
                    WorktreeCommentaryCard(session: session)
                    WorktreeEventLogCard(events: session.eventLog)
                }
                .padding(24)
            }
            .frame(minWidth: 340, idealWidth: 420)
            .background(StudioCanvasView())

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorktreeDiffNavigator(
                        contexts: diffContexts,
                        selectedDiffID: $selectedDiffID
                    )

                    if let selectedDiffContext {
                        WorktreeDiffCard(context: selectedDiffContext)
                    } else {
                        WorktreeDiffEmptyState(status: session.status)
                    }
                }
                .padding(24)
            }
            .frame(minWidth: 460, idealWidth: 760)
            .background(StudioCanvasView())
        }
        .background(StudioCanvasView())
        .navigationTitle(session.displayTitle)
        .navigationSubtitle(session.branchName)
        .task(id: reviewThread?.updatedAt) {
            if let firstContext = diffContexts.first,
               diffContexts.contains(where: { $0.id == selectedDiffID }) == false {
                selectedDiffID = firstContext.id
            }
        }
    }
}

private struct WorktreeContextBanner: View {

    let session: AgentSession

    private var statusColor: Color {
        switch session.status {
        case .queued:
            return StudioTheme.secondaryText
        case .preparing, .running:
            return StudioTheme.accent
        case .reviewing:
            return StudioTheme.warning
        case .completed:
            return StudioTheme.success
        case .failed, .cancelled:
            return StudioTheme.danger
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text("Background Worktree")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)

                Text("\(session.status.title) on \(session.branchName)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StudioTheme.primaryText)
            }

            Spacer(minLength: 12)

            ReferenceBadge(
                title: session.modelDisplayName,
                systemImage: "brain",
                style: .tinted
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.accentSurface.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioTheme.accentBorder, lineWidth: 1)
        )
    }
}

private struct WorktreeJobSummaryCard: View {

    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Task")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StudioTheme.secondaryText)

                    Text(session.taskPrompt)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(StudioTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.worktreePath)])
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("Reveal Worktree")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(StudioTheme.surfaceFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(StudioTheme.stroke, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            StudioPillFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ReferenceBadge(
                    title: session.branchName,
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                )
                ReferenceBadge(
                    title: session.worktreeDisplayName,
                    systemImage: "square.split.2x1"
                )
                ReferenceBadge(
                    title: session.status.title,
                    systemImage: session.status.symbolName
                )
                ReferenceBadge(
                    title: session.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Execution Directory")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(StudioTheme.tertiaryText)

                Text(session.executionDirectoryPath)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

private struct WorktreeCommentaryCard: View {

    let session: AgentSession

    private var commentary: String {
        let reviewMarkdown = (session.reviewThread?.commentaryMarkdown ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !reviewMarkdown.isEmpty {
            return reviewMarkdown
        }

        let latest = session.latestMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !latest.isEmpty {
            return latest
        }

        switch session.status {
        case .queued, .preparing:
            return "This background job is preparing its isolated worktree and will stream a review summary here once it has enough context."
        case .running:
            return "The background worker is still making changes inside the isolated worktree."
        case .reviewing:
            return "The background worker finished editing and is assembling a review summary."
        case .completed:
            return "This background job finished without additional commentary."
        case .failed:
            return session.errorMessage ?? "The background job failed before it could produce a review summary."
        case .cancelled:
            return "This background job was cancelled."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review Thread")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                if let reviewThread = session.reviewThread {
                    Text(reviewThread.updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StudioTheme.tertiaryText)
                }
            }

            MarkdownMessageContent(
                text: commentary,
                isStreaming: session.status == .running || session.status == .reviewing,
                isPipelineRunning: false
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

private struct WorktreeEventLogCard: View {

    let events: [String]

    private var visibleEvents: [String] {
        Array(events.suffix(16))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Log")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StudioTheme.secondaryText)

            if visibleEvents.isEmpty {
                Text("No session events yet.")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(visibleEvents.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(StudioTheme.primaryText.opacity(0.78))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(StudioTheme.terminalBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(StudioTheme.stroke, lineWidth: 1)
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

private struct WorktreeDiffNavigator: View {

    let contexts: [ReviewDiffContext]
    @Binding var selectedDiffID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Changed Files")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                if !contexts.isEmpty {
                    Text("\(contexts.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StudioTheme.tertiaryText)
                }
            }

            if contexts.isEmpty {
                Text("No captured diff context yet.")
                    .font(.callout)
                    .foregroundStyle(StudioTheme.secondaryText)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(contexts) { context in
                            Button {
                                selectedDiffID = context.id
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text")
                                        .font(.caption.weight(.semibold))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((context.path as NSString).lastPathComponent)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        Text(context.changeSummary)
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(StudioTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(selectedDiffID == context.id ? StudioTheme.accentSurfaceStrong : StudioTheme.surfaceSoft)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(selectedDiffID == context.id ? StudioTheme.accentBorderStrong : StudioTheme.dockDivider, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

private struct WorktreeDiffCard: View {

    let context: ReviewDiffContext

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text((context.path as NSString).lastPathComponent)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StudioTheme.primaryText)
                    Text(context.path)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioTheme.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                ReferenceBadge(
                    title: context.changeSummary,
                    systemImage: "arrow.left.arrow.right"
                )
            }

            if let originalPath = context.originalPath, originalPath != context.path {
                Text("Previous path: \(originalPath)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.tertiaryText)
                    .textSelection(.enabled)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(context.diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No diff text captured." : context.diffText)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .lineSpacing(2)
                    .foregroundStyle(StudioTheme.primaryText.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(StudioTheme.terminalBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(StudioTheme.stroke, lineWidth: 1)
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

private struct WorktreeDiffEmptyState: View {

    let status: AgentSessionStatus

    private var message: String {
        switch status {
        case .queued, .preparing:
            return "This job is still preparing its isolated workspace."
        case .running:
            return "Diff context will appear here as soon as the background worker finishes editing."
        case .reviewing:
            return "The worker finished editing. Diff context is still being assembled."
        case .completed:
            return "This job completed without captured file changes."
        case .failed:
            return "The job failed before a diff could be captured."
        case .cancelled:
            return "The job was cancelled before it produced a diff."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No Diff Yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StudioTheme.primaryText)

            Text(message)
                .font(.callout)
                .foregroundStyle(StudioTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioTheme.surfaceBare)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioTheme.dockDivider, lineWidth: 1)
        )
    }
}

/// Horizontal scrubber of epoch cards.
private struct EpochScrubber: View {

    let epochs: [Epoch]
    @Binding var selectedEpochID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(epochs, id: \.id) { epoch in
                    EpochCard(
                        epoch: epoch,
                        isSelected: selectedEpochID == epoch.id
                    )
                    .onTapGesture {
                        selectedEpochID = epoch.id
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(StudioTheme.charcoal)
    }
}

/// A single epoch card in the scrubber.
private struct EpochCard: View {

    let epoch: Epoch
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("E\(epoch.index)")
                    .font(.caption.monospacedDigit().bold())
                Spacer()
                if let archetype = epoch.archetype {
                    Text(archetype)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(epoch.summary)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer()

            HStack(spacing: 8) {
                MetricPill(label: "HIG", value: String(format: "%.0f", epoch.higScore * 100))
                MetricPill(label: "Cost", value: String(format: "%.0f", epoch.deviationCost * 100))
                if epoch.driftScore > 0.20 {
                    MetricPill(label: "Drift", value: String(format: "%.0f", epoch.driftScore * 100))
                }
            }
        }
        .padding(8)
        .frame(width: 180, height: 100)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? StudioTheme.accentSurfaceStrong : StudioTheme.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? StudioTheme.accent : StudioTheme.stroke, lineWidth: isSelected ? 2 : 1)
        )
    }
}

/// Tiny metric pill (e.g., "HIG 91").
private struct MetricPill: View {

    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium).monospaced())
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Warning banner shown when a project requires human intervention.
private struct ManualOverrideBanner: View {

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(StudioTheme.warning)
            Text("Manual override required — review before next pipeline run")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            // TODO: Add "Acknowledge" button that clears requiresHumanOverride
        }
        .padding(10)
        .background(StudioTheme.warningSurface)
    }
}

// MARK: - Auditor Pane (Pane 3)

/// Right inspector: Critic voice + trust metrics.
private struct AuditorPane: View {

    let project: AppProject
    let selectedEpochID: UUID?
    let runner: PipelineRunner

    /// Live critic verdict takes priority during a pipeline run.
    private var activeVerdict: String? {
        runner.criticVerdict ?? project.latestCriticVerdict
    }

    var body: some View {
        ZStack {
            AuditorPaneBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AuditorSectionCard {
                        CriticVoiceLayer(verdict: activeVerdict)
                    }

                    AuditorSectionCard {
                        TrustMetrics(project: project)
                    }

                    AuditorSectionCard {
                        BudgetForecast(project: project)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AuditorPaneBackdrop: View {

    var body: some View {
        ZStack {
            Color.black

            LinearGradient(
                colors: [
                    Color.clear,
                    StudioTheme.panelBackground.opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    StudioTheme.primaryText.opacity(0.03),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 220
            )
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(StudioTheme.surfaceSoft)
                .frame(width: 1)
        }
    }
}

private struct AuditorSectionCard<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(StudioTheme.panelBackground.opacity(0.86))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(StudioTheme.stroke, lineWidth: 1)
            )
    }
}

private struct AuditorEmptyState: View {

    var body: some View {
        ZStack {
            AuditorPaneBackdrop()

            VStack(spacing: 22) {
                Circle()
                    .fill(StudioTheme.surfaceBare)
                    .frame(width: 88, height: 88)
                    .overlay(
                        Circle()
                            .stroke(StudioTheme.accent.opacity(0.24), lineWidth: 1)
                    )
                    .overlay {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(StudioTheme.accent)
                    }

                VStack(spacing: 8) {
                    Text("No Project")
                        .font(.system(size: 30, weight: .bold, design: .serif))
                        .foregroundStyle(StudioTheme.primaryText)

                    Text("Select a project to view its audit trail.")
                        .font(.callout)
                        .foregroundStyle(StudioTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Terminal-style Critic verdict display.
private struct CriticVoiceLayer: View {

    let verdict: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Critic", systemImage: "eye.trianglebadge.exclamationmark")
                .font(.caption.bold())
                .foregroundStyle(StudioTheme.secondaryText)

            if let verdict = verdict {
                Text(verdict)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(StudioTheme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(StudioTheme.terminalBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(StudioTheme.subtleStroke, lineWidth: 1)
                    )
            } else {
                Text("No verdict available.")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.tertiaryText)
            }
        }
    }
}

/// Flow integrity + deviation/drift budget gauges.
private struct TrustMetrics: View {

    let project: AppProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Trust Metrics", systemImage: "checkmark.shield")
                .font(.caption.bold())
                .foregroundStyle(StudioTheme.secondaryText)

            MetricRow(
                label: "Flow Integrity",
                value: project.flowIntegrityScore,
                format: "%.0f%%",
                multiplier: 100
            )

            MetricRow(
                label: "Confidence",
                value: Double(project.confidenceScore),
                format: "%.0f",
                multiplier: 1
            )
        }
    }
}

/// Deviation + drift budget forecasts.
private struct BudgetForecast: View {

    let project: AppProject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Budget Forecast", systemImage: "gauge.with.dots.needle.33percent")
                .font(.caption.bold())
                .foregroundStyle(StudioTheme.secondaryText)

            BudgetBar(
                label: "Deviation Budget",
                remaining: project.deviationBudgetRemaining
            )

            BudgetBar(
                label: "Drift Budget",
                remaining: project.driftBudgetRemaining
            )
        }
    }
}

/// A single labeled budget bar.
private struct BudgetBar: View {

    let label: String
    let remaining: Double

    private var barColor: Color {
        if remaining >= 0.50 { return StudioTheme.accent }
        if remaining >= 0.25 { return StudioTheme.warning }
        return StudioTheme.danger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(StudioTheme.secondaryText)
                Spacer()
                Text(String(format: "%.0f%% remaining", remaining * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StudioTheme.secondaryText)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(StudioTheme.surfaceFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: geo.size.width * remaining)
                }
            }
            .frame(height: 6)
        }
    }
}

/// A single metric row with label and formatted value.
private struct MetricRow: View {

    let label: String
    let value: Double
    let format: String
    let multiplier: Double

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(StudioTheme.secondaryText)
            Spacer()
            Text(String(format: format, value * multiplier))
                .font(.callout.monospacedDigit().bold())
                .foregroundStyle(StudioTheme.primaryText)
        }
    }
}

// MARK: - Preview

private enum CalmChatPreviewData {
    static let turns: [ConversationTurn] = [
        ConversationTurn(
            id: UUID(),
            userGoal: "Redesign the onboarding thread to feel calmer and easier to scan.",
            response: AssistantResponse(
                text: """
                ## Direction
                Use a centered reading column with softer spacing and less chrome.

                ## What To Change
                - Reduce the visual weight of reasoning and process state.
                - Keep the assistant response as plain text instead of boxing it.
                - Dock the input bar at the bottom so the transcript feels stable.

                ## Why It Works
                A narrower column lowers scan fatigue and makes long responses feel more trustworthy.
                """,
                thinkingText: "Prioritizing readability, hierarchy, and a stable composer placement."
            ),
            toolTraces: [],
            state: .completed,
            timestamp: .now,
            isHistorical: false
        ),
        ConversationTurn(
            id: UUID(),
            userGoal: "",
            response: AssistantResponse(
                text: "I’m applying the new layout constants now.",
                streamingText: "Next I’ll soften the reasoning card and tighten the bottom composer.",
                isStreaming: true,
                thinkingText: "Keeping the answer layer clean while the process layer stays collapsible."
            ),
            toolTraces: [],
            state: .streaming,
            timestamp: .now,
            isHistorical: false
        )
    ]
}

private struct CalmChatInterfacePreview: View {
    @State private var draft = "Polish the response spacing and keep the UI very calm."
    @State private var attachments: [ChatAttachment] = []
    @State private var runner = PipelineRunner(packageRoot: "/Users/tj/Desktop/Studio.92")

    var body: some View {
        ZStack {
            StudioCanvasView()

            VStack(spacing: 0) {
                ChatThreadView(
                    turns: CalmChatPreviewData.turns,
                    isPipelineRunning: true,
                    selectedEpochID: nil,
                    columnWidth: CalmChatLayout.columnIdealWidth,
                    bottomContentInset: 156,
                    suggestions: [],
                    onSelectSuggestion: { _ in },
                    onOpenArtifact: { _, _ in },
                    onReuseGoal: { _ in },
                    onCancelTurn: { }
                )

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(StudioTheme.dockDivider)
                        .frame(height: 1)

                    CalmChatColumn(width: CalmChatLayout.columnIdealWidth) {
                        GoalInputBar(
                            goalText: $draft,
                            attachments: $attachments,
                            runner: runner,
                            reusedPromptToken: nil,
                            reusedPromptText: nil,
                            onSubmit: { }
                        )
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.92))
            }
        }
        .frame(width: 1280, height: 840)
    }
}

#Preview("Calm Chat Interface") {
    CalmChatInterfacePreview()
}

#Preview {
    CommandCenterView(packageRoot: "/Users/tj/Desktop/Studio.92")
        .modelContainer(for: [AppProject.self, Epoch.self], inMemory: true)
        .frame(width: 1200, height: 800)
}
