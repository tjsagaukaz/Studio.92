// CommandCenterView.swift
// Studio.92 — Command Center
// Split workspace shell: sidebar, execution pane, viewport pane.

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

enum ArtifactCanvasLaunchMode {
    case inspector
    case preview
    case codeDiff
    case deployment
}

enum StudioWordmarkFont {
    static func display(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func body(size: CGFloat) -> Font {
        .system(size: size, weight: .medium)
    }
}

enum StudioSymbol {
    private static let lock = NSLock()
    private static var resolvedNames: [String: String] = [:]

    static func resolve(_ candidates: String...) -> String {
        resolve(candidates)
    }

    static func resolve(_ candidates: [String]) -> String {
        let filtered = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !filtered.isEmpty else { return "questionmark" }

        let cacheKey = filtered.joined(separator: "|")
        lock.lock()
        if let cached = resolvedNames[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = filtered.first(where: isAvailable(systemName:))
            ?? filtered.last
            ?? "questionmark"

        lock.lock()
        resolvedNames[cacheKey] = resolved
        lock.unlock()
        return resolved
    }

    private static func isAvailable(systemName: String) -> Bool {
        NSImage(systemSymbolName: systemName, accessibilityDescription: nil) != nil
    }
}

struct CalmChatColumn<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct CalmChatMetaCard<Content: View>: View {
    let opacity: Double
    @ViewBuilder let content: () -> Content

    init(opacity: Double = 0.6, @ViewBuilder content: @escaping () -> Content) {
        self.opacity = opacity
        self.content = content
    }

    var body: some View {
        content()
            .padding(StudioSpacing.xxl)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .fill(StudioSurfaceElevated.level1)
            )
            .opacity(opacity)
    }
}

extension Notification.Name {
    static let focusStudioComposer = Notification.Name("focusStudioComposer")
    /// Post this to pre-fill the composer with a string and focus it.
    /// userInfo key: "text" → String
    static let prefillStudioComposer = Notification.Name("prefillStudioComposer")
    /// Post this to immediately submit a message to the AI without touching the composer.
    /// userInfo key: "text" → String
    static let submitStudioMessage = Notification.Name("submitStudioMessage")
}

struct StudioBackgroundView: View {

    var body: some View {
        StudioSurface.base
            .ignoresSafeArea()
    }
}

struct StudioCanvasView: View {

    var body: some View {
        StudioSurface.base
    }
}

struct StudioWordmarkView: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text("Studio")
                .font(.system(size: size, weight: .heavy))
                .foregroundStyle(.white)
                .tracking(1.5)

            Text(".92")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(StudioAccentColor.primary)
                .tracking(1.5)
        }
    }
}

// MARK: - Pane Divider

struct PaneDivider: View {
    let axis: Axis

    @State private var isHovered = false

    var body: some View {
        Group {
            if axis == .vertical {
                Rectangle()
                    .fill(isHovered ? StudioTextColor.primary.opacity(0.12) : StudioTextColor.primary.opacity(0.07))
                    .frame(width: isHovered ? 3 : 1)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle().inset(by: -3))
                    .onHover { hovering in
                        withAnimation(StudioMotion.softFade) { isHovered = hovering }
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            } else {
                Rectangle()
                    .fill(isHovered ? StudioTextColor.primary.opacity(0.12) : StudioTextColor.primary.opacity(0.07))
                    .frame(height: isHovered ? 3 : 1)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle().inset(by: -3))
                    .onHover { hovering in
                        withAnimation(StudioMotion.softFade) { isHovered = hovering }
                        if hovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }
        }
        .animation(StudioMotion.softFade, value: isHovered)
    }
}

// MARK: - CommandCenterView

/// Root view. Thin shell that composes WorkspaceCoordinator and ThreadCoordinator.
struct CommandCenterView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var workspace: WorkspaceCoordinator
    @State private var threads: ThreadCoordinator
    @StateObject private var conversationStore: ConversationStore
    @State private var viewportModel = ViewportStreamModel()
    private let simulatorPreviewService = SimulatorPreviewService.shared
    @State private var templateEngine: SessionTemplateEngine
    /// Git anchor registry: id → ActionAnchor. Lives only in memory; Git refs survive crashes.
    @State private var anchorRegistry: [UUID: ActionAnchor] = [:]
    private let gitService = GitService()
    @AppStorage("isSidebarVisible") private var isSidebarVisible = true
    @AppStorage("isViewportVisible") private var isViewportVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 246
    @AppStorage("viewportWidth") private var viewportWidth: Double = 400
    @State private var isDropTargetActive = false

    init(packageRoot: String) {
        let runner = PipelineRunner(packageRoot: packageRoot)
        let repoMonitor = RepositoryMonitor(
            workspaceURL: URL(fileURLWithPath: packageRoot, isDirectory: true)
        )
        let jobMonitor = JobMonitor(
            workspaceURL: URL(fileURLWithPath: packageRoot, isDirectory: true)
        )
        let store = ConversationStore()

        let ws = WorkspaceCoordinator(runner: runner, repositoryMonitor: repoMonitor)
        let tc = ThreadCoordinator(
            runner: runner,
            conversationStore: store,
            jobMonitor: jobMonitor,
            repositoryMonitor: repoMonitor
        )
        ws.threads = tc
        tc.workspace = ws

        _workspace = State(initialValue: ws)
        _threads = State(initialValue: tc)
        _conversationStore = StateObject(wrappedValue: store)
        _templateEngine = State(initialValue: SessionTemplateEngine(workspacePath: packageRoot))
    }

    private var sidebarContent: some View {
        FleetSidebar(
            projects: workspace.sortedProjects,
            jobs: threads.jobMonitor.sessions,
            repositoryState: workspace.repositoryMonitor.repositoryState,
            isRefreshingRepository: workspace.repositoryMonitor.isRefreshing,
            activeProject: workspace.selectedProject,
            activeGoal: workspace.runner.activeGoal,
            isPipelineRunning: workspace.runner.isRunning,
            currentWorkspacePath: workspace.repositoryMonitor.workspaceURL.path,
            recentWorkspacePaths: workspace.recentWorkspacePaths,
            selectedProjectID: workspace.selectedProjectID,
            selectedSessionID: threads.selectedSessionID,
            persistedThreads: threads.sidebarThreads,
            resumeThread: threads.resumeThread,
            threadProjectIDs: threads.threadProjectIDs,
            onSelectProject: workspace.selectProject,
            onSelectSession: threads.selectSession,
            onSelectThread: threads.rehydrateThread,
            onSelectWorkspacePath: workspace.reopenWorkspace,
            onOpenWorkspace: workspace.openWorkspacePanel,
            onDeleteProject: { workspace.deleteProject($0, modelContext: modelContext) },
            onDeleteThread: { threads.deleteThread($0, modelContext: modelContext) },
            onNewThread: threads.startNewThread,
            onCollapseSidebar: {
                withAnimation(StudioMotion.panelSpring) { isSidebarVisible = false }
            }
        )
    }

    private var detailContent: some View {
        WorkspaceShellView(
            project: workspace.selectedProject,
            allProjects: workspace.sortedProjects,
            jobs: threads.jobMonitor.sessions,
            selectedSession: threads.selectedSession,
            selectedEpochID: Binding(
                get: { workspace.selectedEpochID },
                set: { workspace.selectedEpochID = $0 }
            ),
            runner: workspace.runner,
            repositoryState: workspace.repositoryMonitor.repositoryState,
            isRefreshingRepository: workspace.repositoryMonitor.isRefreshing,
            goalText: Binding(
                get: { threads.goalText },
                set: { threads.goalText = $0 }
            ),
            attachments: Binding(
                get: { threads.composerAttachments },
                set: { threads.composerAttachments = $0 }
            ),
            viewportModel: viewportModel,
            onSubmit: { threads.submitGoal(modelContext: modelContext) },
            onSelectSession: threads.selectSession,
            onSelectProject: workspace.selectProject,
            onOpenArtifact: openViewportArtifact,
            onRefreshRepository: workspace.refreshRepositoryStatus,
            onInitializeRepository: workspace.initializeGitRepository,
            onOpenWorkspace: workspace.openWorkspacePanel,
            simulatorPreviewService: simulatorPreviewService,
            templateEngine: templateEngine,
            onExecuteRevert: { model in
                Task {
                    let workspaceURL = URL(fileURLWithPath: workspace.runner.packageRoot, isDirectory: true)
                    viewportModel.updateTemporalRevertState(isReverting: true)
                    do {
                        let result = try await gitService.revertToAnchor(
                            sha: model.anchorSHA,
                            workspaceURL: workspaceURL
                        )
                        await MainActor.run {
                            viewportModel.dismissTemporalRevert()
                            let ts = DateFormatter.localizedString(
                                from: model.anchorTimestamp,
                                dateStyle: .none,
                                timeStyle: .medium
                            )
                            workspace.runner.chatThread.postTimelineFracture(
                                label: "Workspace reverted to \(ts)"
                            )
                            if case .stashedDirtyState(let label) = result {
                                workspace.runner.chatThread.postTimelineFracture(
                                    label: "Uncommitted changes stashed for safety (\(label))"
                                )
                            }
                            workspace.refreshRepositoryStatus()
                        }
                    } catch {
                        await MainActor.run {
                            viewportModel.updateTemporalRevertState(isReverting: false)
                        }
                    }
                }
            },
            onCancelRevert: {
                viewportModel.dismissTemporalRevert()
            },
            onShowRevert: { entry in
                // Find the most recent anchor matching this entry's title and timestamp proximity.
                // Anchors for destructive commands are created in AgenticToolDispatch; for diffs,
                // they are created in applyDiff. Match by title prefix.
                let candidate = anchorRegistry.values
                    .filter { $0.title.hasPrefix(entry.title) || entry.title.hasPrefix($0.title) }
                    .sorted { abs($0.timestamp.timeIntervalSince(entry.timestamp)) < abs($1.timestamp.timeIntervalSince(entry.timestamp)) }
                    .first
                guard let anchor = candidate else { return }
                viewportModel.showTemporalRevert(TemporalRevertModel(
                    anchorID: anchor.id,
                    title: anchor.title,
                    actionPreview: anchor.actionPreview,
                    anchorSHA: anchor.gitSHA,
                    anchorTimestamp: anchor.timestamp
                ))
            },
            onAuthorizeApproval: {
                Task {
                    let controller = CommandApprovalController.shared
                    if let request = controller.pendingRequest {
                        let anchorID = UUID()
                        let workspaceURL = URL(fileURLWithPath: workspace.runner.packageRoot, isDirectory: true)
                        let anchorTitle: String
                        if let preview = request.actionPreview, !preview.isEmpty {
                            let firstLine = preview
                                .components(separatedBy: .newlines)
                                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? preview
                            anchorTitle = "Authorized: \(firstLine.prefix(60))"
                        } else {
                            anchorTitle = request.title
                        }
                        do {
                            let sha = try await gitService.createAnchor(id: anchorID, workspaceURL: workspaceURL)
                            let anchor = ActionAnchor(
                                id: anchorID,
                                kind: .destructiveCommand,
                                title: anchorTitle,
                                actionPreview: request.actionPreview,
                                gitSHA: sha
                            )
                            await MainActor.run { anchorRegistry[anchorID] = anchor }
                        } catch {
                            // Anchor creation failed — approve anyway; never block the user.
                        }
                    }
                    await MainActor.run { controller.approve() }
                }
            },
            showSidebarToggle: !isSidebarVisible,
            onToggleSidebar: { withAnimation(StudioMotion.panelSpring) { isSidebarVisible = true } },
            titleGenerator: threads.titleGenerator,
            isViewportVisible: $isViewportVisible,
            viewportWidth: $viewportWidth
        )
        .environmentObject(conversationStore)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.viewportActionContext, viewportActionContext)
    }

    private var shellContent: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                sidebarContent
                    .frame(width: max(180, min(sidebarWidth, 360)))
                    .transition(.studioPanelLeading)

                PaneDivider(axis: .vertical)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                sidebarWidth = max(180, min(value.location.x - 12, 360))
                            }
                    )
            }

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(threads.restoredContentOpacity)
        }
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .fill(StudioSurface.base)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous))
        .overlay {
            // Cyan glow border — appears only while a folder is dragged over the window.
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .strokeBorder(
                    StudioAccentColor.primary.opacity(isDropTargetActive ? 0.85 : 0),
                    lineWidth: 1.5
                )
                .shadow(color: StudioAccentColor.primary.opacity(isDropTargetActive ? 0.25 : 0), radius: 12)
                .animation(StudioMotion.hoverEase, value: isDropTargetActive)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargetActive) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue else { return }
                Task { @MainActor in
                    await workspace.selectWorkspace(url)
                }
            }
            return true
        }
        .padding(StudioSpacing.xl)
    }

    @MainActor
    private func configureStreamDeepLinks() {
        workspace.runner.streamCoordinator.deepLinkRouter.openInspector = { [workspace] spanID in
            workspace.runner.sessionInspector.source = .live
            workspace.runner.sessionInspector.focus(spanID: spanID)
            withAnimation(StudioMotion.panelSpring) {
                workspace.runner.sessionInspector.isVisible = true
            }
        }

        workspace.runner.streamCoordinator.deepLinkRouter.openFilePreview = { [viewportModel] path, sourceLabel in
            withAnimation(StudioMotion.panelSpring) {
                isViewportVisible = true
            }
            viewportModel.showFilePreview(path: path, sourceLabel: sourceLabel)
        }

        workspace.runner.streamCoordinator.deepLinkRouter.openScreenshot = { [viewportModel] path in
            withAnimation(StudioMotion.panelSpring) {
                isViewportVisible = true
            }
            viewportModel.imagePath = path
            viewportModel.requestTransition(to: .preview, content: .artifactImage(path: path))
        }

        viewportModel.onRequestReveal = {
            withAnimation(StudioMotion.panelSpring) {
                isViewportVisible = true
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            StudioBackgroundView()

            shellContent

            // Hidden keyboard shortcut buttons
            Button(action: threads.startNewThread) {}
                .keyboardShortcut("n", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)

            Button(action: { withAnimation(StudioMotion.panelSpring) { isSidebarVisible.toggle() } }) {}
                .keyboardShortcut("s", modifiers: [.command, .control])
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)

            Button(action: { withAnimation(StudioMotion.panelSpring) { isViewportVisible.toggle() } }) {}
                .keyboardShortcut("p", modifiers: [.command, .control])
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)

            if let persistenceFailureMessage = threads.jobMonitor.persistenceFailureMessage {
                BackgroundJobPersistenceBanner(message: persistenceFailureMessage)
                    .padding(.horizontal, StudioSpacing.pagePad)
                    .padding(.top, StudioSpacing.sectionGap)
                    .transition(.studioTopDrop)
            }
        }
        .tint(StudioAccentColor.primary)
        .accentColor(StudioAccentColor.primary)
        .foregroundStyle(StudioTextColor.primary)
        .preferredColorScheme(.dark)
        .toolbar(.hidden)
        .animation(StudioMotion.standardSpring, value: threads.jobMonitor.persistenceFailureMessage)
        .onAppear {
            workspace.configure(viewportModel: viewportModel, previewService: simulatorPreviewService, templateEngine: templateEngine)
            threads.configure(viewportModel: viewportModel, previewService: simulatorPreviewService)
            workspace.engine.load(from: modelContext)
            threads.initializePersistence(modelContext: modelContext)
            workspace.repositoryMonitor.start()
            threads.jobMonitor.start()
            templateEngine.start()
            simulatorPreviewService.start()
            workspace.loadRecentWorkspaces()
            workspace.rememberWorkspace(path: workspace.repositoryMonitor.workspaceURL.path)
            workspace.runner.streamCoordinator.viewportModel = viewportModel
            configureStreamDeepLinks()
            refreshViewportModel()
            threads.refreshSidebarThreads()
            if !threads.didAutorunPrompt,
               let autorunPrompt = ProcessInfo.processInfo.environment["STUDIO92_AUTORUN_PROMPT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !autorunPrompt.isEmpty {
                threads.didAutorunPrompt = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    guard !workspace.runner.isRunning else { return }
                    threads.goalText = autorunPrompt
                    threads.submitGoal(modelContext: modelContext)
                }
            }
        }
        .onDisappear {
            threads.persistCurrentThread()
            workspace.repositoryMonitor.stop()
            threads.jobMonitor.stop()
            templateEngine.stop()
            simulatorPreviewService.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            threads.persistCurrentThread()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            threads.persistCurrentThread()
        }
        .onReceive(NotificationCenter.default.publisher(for: .submitStudioMessage)) { notification in
            guard let text = notification.userInfo?["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard !workspace.runner.isRunning else { return }
            threads.goalText = text
            threads.submitGoal(modelContext: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .telemetryIngested)) { notification in
            workspace.engine.load(from: modelContext)
            if let projectID = notification.userInfo?["projectID"] as? UUID {
                if workspace.selectedProjectID == nil {
                    workspace.selectedProjectID = projectID
                }

                if let project = workspace.engine.project(for: projectID),
                   let latestEpoch = project.sortedEpochs.last {
                    if workspace.selectedProjectID == projectID {
                        workspace.selectedEpochID = latestEpoch.id
                    }
                    workspace.runner.attachCompletionIfMatching(epoch: latestEpoch, goal: project.goal)
                }
            }
        }
        .onChange(of: workspace.selectedProjectID) { _, newValue in
            guard newValue != nil else { return }
            threads.selectedSessionID = nil
            viewportModel.resetToAutomatic(selectedEpoch: workspace.selectedEpoch, previewService: simulatorPreviewService)
        }
        .onChange(of: threads.selectedSessionID) { _, newValue in
            guard newValue != nil else { return }
            workspace.selectedProjectID = nil
            workspace.selectedEpochID = nil
            viewportModel.resetToAutomatic(selectedEpoch: workspace.selectedEpoch, previewService: simulatorPreviewService)
        }
        .onChange(of: workspace.selectedEpochID) { _, _ in
            refreshViewportModel()
        }
        .onChange(of: simulatorPreviewService.latestScreenshotPath) { _, _ in
            refreshViewportModel()
        }
        .onChange(of: simulatorPreviewService.status) { _, _ in
            refreshViewportModel()
        }
        .onChange(of: threads.jobMonitor.sessions) { _, sessions in
            guard let selectedSessionID = threads.selectedSessionID else { return }
            if sessions.contains(where: { $0.id == selectedSessionID }) == false {
                threads.selectedSessionID = nil
            }
        }
        .onChange(of: workspace.runner.isRunning) { _, running in
            viewportModel.isPipelineActive = running
            if !running { viewportModel.pipelineStageLabel = "" }
        }
        .onChange(of: workspace.runner.stage) { _, stage in
            viewportModel.pipelineStageLabel = stage.displayLabel
        }
        .onChange(of: workspace.runner.pendingBBoxOverlays) { _, overlays in
            if overlays.isEmpty {
                viewportModel.clearBBoxOverlays()
            } else {
                viewportModel.showBBoxOverlays(overlays, sourceImageURL: workspace.runner.pendingBBoxSourceImageURL)
            }
        }
    }

    // MARK: - View-Local Helpers

    private func refreshViewportModel() {
        viewportModel.sync(selectedEpoch: workspace.selectedEpoch, previewService: simulatorPreviewService)
    }

    private var viewportActionContext: ViewportActionContext {
        let packageRoot = workspace.runner.packageRoot
        return ViewportActionContext(
            showDiffPreview: { model, onAccept in
                viewportModel.showDiffPreview(model, onAccept: onAccept)
            },
            showFilePreview: { path in
                viewportModel.showFilePreview(path: path)
            },
            showPlanDocument: { plan in
                viewportModel.showPlanDocument(plan)
            },
            showTerminalActivity: { terminal in
                viewportModel.showTerminalActivity(terminal)
            },
            updateTerminalActivity: { terminal in
                viewportModel.updateTerminalActivity(terminal)
            },
            dismissTerminalActivity: {
                viewportModel.dismissTerminalActivity()
            },
            showTemporalRevert: { model in
                viewportModel.showTemporalRevert(model)
            },
            dismissTemporalRevert: {
                viewportModel.dismissTemporalRevert()
            },
            createAnchor: { title, preview in
                let workspaceURL = URL(fileURLWithPath: packageRoot, isDirectory: true)
                let anchorID = UUID()
                do {
                    let sha = try await gitService.createAnchor(
                        id: anchorID,
                        workspaceURL: workspaceURL
                    )
                    let anchor = ActionAnchor(
                        id: anchorID,
                        kind: .diffApplied,
                        title: title,
                        actionPreview: preview,
                        gitSHA: sha
                    )
                    await MainActor.run { anchorRegistry[anchorID] = anchor }
                    return anchor
                } catch {
                    return nil
                }
            }
        )
    }

    private func openViewportArtifact(
        for epochID: UUID?,
        preferredMode: ArtifactCanvasLaunchMode = .preview
    ) {
        if let epochID {
            workspace.selectedEpochID = epochID
        }

        let epoch: Epoch?
        if let epochID, let selectedProjectID = workspace.selectedProjectID {
            epoch = workspace.engine.epoch(for: epochID, in: selectedProjectID)
        } else {
            epoch = nil
        }

        if let epoch {
            viewportModel.showEpochArtifact(epoch, mode: preferredMode)
        } else {
            viewportModel.resetToAutomatic(selectedEpoch: workspace.selectedEpoch, previewService: simulatorPreviewService)
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
                    columnWidth: StudioChatLayout.columnIdealWidth,
                    suggestions: [],
                    onSelectSuggestion: { _ in },
                    onLaunchPrompt: { _ in },
                    onSelectJob: { _ in },
                    onOpenArtifact: { _, _ in },
                    onReuseGoal: { _ in },
                    onCancelTurn: { }
                )

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(StudioSeparator.subtle)
                        .frame(height: 1)

                    CalmChatColumn(width: StudioChatLayout.columnIdealWidth) {
                        MinimalComposerDock(
                            goalText: $draft,
                            attachments: $attachments,
                            runner: runner,
                            onSubmit: { }
                        )
                    }
                    .padding(.top, StudioSpacing.panel)
                    .padding(.bottom, StudioSpacing.sectionGap)
                }
                .frame(maxWidth: .infinity)
                .background(StudioSurface.sidebar)
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
        .modelContainer(for: [AppProject.self, Epoch.self, PersistedSpan.self], inMemory: true)
        .frame(width: 1200, height: 800)
}
