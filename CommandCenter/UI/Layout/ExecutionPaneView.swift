import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExecutionPaneView: View {

    let project: AppProject?
    let allProjects: [AppProject]
    let jobs: [AgentSession]
    let selectedSession: AgentSession?
    @Binding var selectedEpochID: UUID?
    let runner: PipelineRunner
    let repositoryState: GitRepositoryState
    let isRefreshingRepository: Bool
    @EnvironmentObject private var conversationStore: ConversationStore
    @ObservedObject private var commandAccess = CommandAccessPreferenceStore.shared
    @ObservedObject private var commandApproval = CommandApprovalController.shared
    private var todoGate: TodoGateController { TodoGateController.shared }
    @Binding var goalText: String
    @Binding var attachments: [ChatAttachment]
    let templateEngine: SessionTemplateEngine
    let onSubmit: () -> Void
    let onSelectSession: (UUID) -> Void
    let onSelectProject: (UUID) -> Void
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onRefreshRepository: () -> Void
    let onInitializeRepository: () -> Void
    let onOpenWorkspace: () -> Void
    var onShowRevert: ((ApprovalAuditEntry) -> Void)? = nil
    var onAuthorizeApproval: (() -> Void)? = nil
    var showSidebarToggle: Bool = false
    var showViewportToggle: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onToggleViewport: (() -> Void)? = nil
    @ObservedObject var titleGenerator: ThreadTitleGenerator

    @State private var conversationSourceCache = ConversationSourceCache()
    @State private var pendingStructuralSyncTask: Task<Void, Never>?
    @State private var pendingContentUpdateTask: Task<Void, Never>?
    /// Live anchor registry — keyed by `ActionAnchor.id`. Never persisted to disk;
    /// the actual safety net lives in `refs/studio92/anchors/<uuid>` in Git.
    @State private var anchorRegistry: [UUID: ActionAnchor] = [:]
    @AppStorage("packageRoot") private var storedPackageRoot = ""

    private let executionColumnWidth: CGFloat = 560
    private static let structuralSyncDebounce: Duration = .milliseconds(50)
    private static let contentUpdateDebounce: Duration = .milliseconds(16) // ~60 fps ceiling

    private struct ConversationSourceSignature: Equatable {
        var projectID: UUID?
        var projectLastActivityAt: Date?
        var activeGoal: String?
        var liveStructureVersion = 0
    }

    private struct ConversationSourceCache {
        var signature = ConversationSourceSignature()
        var activeGoal: String?
        var messages: [ChatMessage] = []
        var suggestions = ExecutionPaneView.defaultGoalSuggestions
    }

    private static var defaultGoalSuggestions: [AgenticSuggestion] {
        [
            AgenticSuggestion(
                id: "audit-workspace",
                title: "Audit Codebase",
                prompt: "Audit this workspace and map the key architecture before making changes.",
                symbolName: StudioSymbol.resolve("scope", "magnifyingglass")
            ),
            AgenticSuggestion(
                id: "scaffold-ios-app",
                title: "Scaffold New UI",
                prompt: "Scaffold a native iOS app with SwiftUI, clean structure, and production-ready screens.",
                symbolName: StudioSymbol.resolve("sparkles.rectangle.stack", "hammer.fill")
            ),
            AgenticSuggestion(
                id: "review-architecture",
                title: "Review Architecture",
                prompt: "Review the current architecture for bottlenecks, HIG drift, and structural risks.",
                symbolName: StudioSymbol.resolve("checklist.checked", "checklist")
            )
        ]
    }

    var body: some View {
        Group {
            if let selectedSession {
                WorktreeJobDetailPane(session: selectedSession)
            } else if isComposerLifted {
                // Centered command surface — the idle "ready" state.
                // Standalone layout with no ScrollView underneath to steal focus.
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        ContextHeaderView(
                            turns: conversationStore.turns,
                            project: project,
                            repositoryState: repositoryState,
                            showSidebarToggle: showSidebarToggle,
                            showViewportToggle: showViewportToggle,
                            onToggleSidebar: onToggleSidebar,
                            onToggleViewport: onToggleViewport,
                            titleGenerator: titleGenerator
                        )
                        // Position at ~42% from top — slightly above center for intentional placement.
                        Spacer()
                            .frame(height: max(0, geometry.size.height * 0.40 - 60))
                        commandSurface(columnWidth: executionColumnWidth)
                            .padding(.horizontal, StudioSpacing.sectionGap)
                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                ChatThreadView(
                    project: project,
                    allProjects: allProjects,
                    jobs: jobs,
                    turns: conversationStore.turns,
                    turnStructureVersion: conversationStore.structureVersion,
                    turnContentVersion: conversationStore.contentVersion,
                    isPipelineRunning: runner.isRunning,
                    selectedEpochID: selectedEpochID,
                    columnWidth: executionColumnWidth,
                    repositoryState: repositoryState,
                    isRefreshingRepository: isRefreshingRepository,
                    suggestions: conversationSourceCache.suggestions,
                    onSelectSuggestion: { suggestion in
                        goalText = suggestion.prompt
                    },
                    onLaunchPrompt: { prompt in
                        launchQuickPrompt(prompt)
                    },
                    onSelectJob: onSelectSession,
                    onSelectProject: onSelectProject,
                    onOpenArtifact: onOpenArtifact,
                    onReuseGoal: { goal in
                        goalText = goal
                    },
                    onRefreshRepository: onRefreshRepository,
                    onInitializeRepository: onInitializeRepository,
                    onOpenWorkspace: onOpenWorkspace,
                    onCancelTurn: {
                        Task {
                            await runner.cancel()
                        }
                    },
                    latencyRunID: runner.activeLatencyRunID,
                    auditEntries: commandApproval.auditLog,
                    onShowRevert: onShowRevert
                )
                .environment(\.streamPhaseController, runner.streamCoordinator.phaseController)
                .environment(\.streamDeepLinkRouter, runner.streamCoordinator.deepLinkRouter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    GeometryReader { geo in
                        // Available leading space = gap between pane edge and chat column.
                        // Subtract two sectionGap widths (leading inset + buffer from column).
                        let leadingMargin = (geo.size.width - executionColumnWidth) / 2
                        let availableWidth = max(60, leadingMargin - StudioSpacing.sectionGap * 2)
                        ReasoningHUD(
                            controller: runner.streamCoordinator.phaseController,
                            maxWidth: availableWidth
                        )
                        .padding(.top, StudioSpacing.section)
                        .padding(.leading, StudioSpacing.sectionGap)
                    }
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    if let pending = todoGate.pendingPlan {
                        TodoGateCard(
                            request: pending,
                            onApprove: { todoGate.approve() },
                            onRefine: {
                                goalText = ""
                                todoGate.refine(feedback: "")
                            }
                        )
                        .padding(.top, StudioSpacing.section)
                        .padding(.trailing, StudioSpacing.sectionGap)
                        .transition(.studioFadeLift)
                    }
                }
                .animation(StudioMotion.panelSpring, value: todoGate.isGateActive)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        // Security gate — intercepts risky tool calls, slides up for authorization.
                        if let pending = commandApproval.pendingRequest {
                            SecurityGateCard(
                                request: pending,
                                onAuthorize: onAuthorizeApproval ?? { commandApproval.approve() },
                                onReject: { commandApproval.deny() }
                            )
                            .padding(.horizontal, StudioSpacing.sectionGap)
                            .padding(.bottom, StudioSpacing.xs)
                            .transition(.studioBottomLift)
                        }

                        // Task plan strip — slides up when a plan is detected, stays live through execution.
                        if runner.streamCoordinator.taskPlanMonitor.isRevealed {
                            InlineTaskPlanStrip(monitor: runner.streamCoordinator.taskPlanMonitor)
                                .padding(.horizontal, StudioSpacing.sectionGap)
                                .padding(.bottom, StudioSpacing.xs)
                                .transition(.studioBottomLift)
                        }

                        // Inline terminal — sits above inspector/composer, pushes chat up
                        if runner.streamCoordinator.terminalMonitor.isRevealed {
                            InlineTerminalStrip(monitor: runner.streamCoordinator.terminalMonitor)
                                .padding(.horizontal, StudioSpacing.sectionGap)
                                .padding(.bottom, StudioSpacing.xs)
                                .transition(.studioBottomLift)
                        }

                        // Session Inspector (slides up when visible)
                        if runner.sessionInspector.isVisible {
                            SessionInspectorView(
                                model: runner.sessionInspector,
                                traceHistory: runner.traceHistory,
                                onRerun: nil,
                                onDismiss: {
                                    withAnimation(StudioMotion.panelSpring) {
                                        runner.sessionInspector.isVisible = false
                                    }
                                },
                                latencyRunID: runner.activeLatencyRunID
                            )
                            .padding(.horizontal, StudioSpacing.sectionGap)
                            .padding(.bottom, StudioSpacing.xxs)
                            .transition(.studioBottomLift)
                        }

                        commandSurface(columnWidth: executionColumnWidth)
                            .padding(.horizontal, StudioSpacing.sectionGap)
                            .padding(.bottom, StudioSpacing.section)
                    }
                    .animation(StudioMotion.panelSpring, value: commandApproval.pendingRequest != nil)
                    .animation(StudioMotion.panelSpring, value: runner.streamCoordinator.terminalMonitor.isRevealed)
                    .animation(StudioMotion.panelSpring, value: runner.streamCoordinator.taskPlanMonitor.isRevealed)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    ContextHeaderView(
                        turns: conversationStore.turns,
                        project: project,
                        repositoryState: repositoryState,
                        showSidebarToggle: showSidebarToggle,
                        showViewportToggle: showViewportToggle,
                        onToggleSidebar: onToggleSidebar,
                        onToggleViewport: onToggleViewport,
                        titleGenerator: titleGenerator
                    )
                }
            }
        }
        .background(WorkspaceBackground())
        .onAppear {
            refreshConversationSourceCache(force: true)
        }
        .onDisappear {
            pendingStructuralSyncTask?.cancel()
            pendingStructuralSyncTask = nil
            pendingStageTask?.cancel()
            pendingStageTask = nil
            pendingContentUpdateTask?.cancel()
            pendingContentUpdateTask = nil
        }
        .onChange(of: project?.id) { _, _ in
            scheduleStructuralSync()
        }
        .onChange(of: project?.goal) { _, _ in
            scheduleStructuralSync()
        }
        .onChange(of: project?.lastActivityAt) { _, _ in
            scheduleStructuralSync()
        }
        .onChange(of: runner.chatThread.structureVersion) { _, _ in
            scheduleStructuralSync()
        }
        .onChange(of: runner.chatThread.contentVersion) { _, _ in
            if runner.chatThread.consumePendingRebuildBoundary() == .messageCompleted {
                scheduleStructuralSync()
            }
            scheduleContentUpdate()
        }
        .onChange(of: runner.isRunning) { wasRunning, isRunning in
            conversationStore.refreshPipelineState(isPipelineRunning: isRunning)
            if wasRunning && !isRunning {
                withAnimation(StudioMotion.standardSpring) {
                    showResultLock = true
                }
            } else if isRunning {
                withAnimation(StudioMotion.softFade) {
                    showResultLock = false
                }
            }
        }
        .onChange(of: templateEngine.templates) { _, _ in
            refreshConversationSourceCache(force: true)
        }
    }

    // MARK: - Two-Layer Command Surface

    @State private var hasShownFirstInput = false
    /// Whether the command bar is lifted to vertical center (empty state).
    /// Disabled — command bar always stays docked at the bottom.
    private var isComposerLifted: Bool { false }
    /// Whether the last run has completed (shows result lock divider)
    @State private var showResultLock = false

    private func commandSurface(columnWidth: CGFloat) -> some View {
        CalmChatColumn(width: columnWidth) {
            VStack(spacing: 0) {
                // Result lock divider — subtle line after completion
                if showResultLock && !runner.isRunning {
                    Rectangle()
                        .fill(StudioSeparator.subtle)
                        .frame(height: 1)
                        .frame(maxWidth: columnWidth - 60)
                        .padding(.bottom, StudioSpacing.md)
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    // Slim Context Bar (top layer — context, narrower + centered)
                    // padding(.bottom, -1) overlaps the composer by exactly 1pt so the
                    // context bar's opaque fill erases the composer's top border at the
                    // join point, creating one continuous stepped hardware outline.
                    slimContextBar
                        .frame(maxWidth: columnWidth - 40)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, -1)
                        .zIndex(1)

                    // Primary Command Bar (bottom layer — execution)
                    primaryCommandBar
                }

                CommandPolicyStrip(runner: runner)
                    .frame(maxWidth: columnWidth - 6, alignment: .leading)
                    .padding(.top, StudioSpacing.sm)
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: runner.isRunning) { wasRunning, isRunning in
            // Drop the centered command bar on first submit.
            if isRunning && !hasShownFirstInput {
                withAnimation(StudioMotion.panelSpring) {
                    hasShownFirstInput = true
                }
            }
        }
        .onChange(of: conversationStore.turns.count) { oldCount, newCount in
            // Also drop if turns appear (e.g. rehydrated thread).
            if newCount > 0 && !hasShownFirstInput {
                withAnimation(StudioMotion.panelSpring) {
                    hasShownFirstInput = true
                }
            }
        }
    }

    private var activeModelShortName: String {
        let packageRoot = runner.packageRoot
        let descriptor = StudioModelStrategy.primaryModel(packageRoot: packageRoot)
        return descriptor.shortName
    }

    /// Label for the model pill: "Auto · Model" or "Pinned · Model"
    private var modelPillLabel: String {
        if let pinned = runner.pinnedModelIdentifier {
            return "Pinned · \(StudioModelStrategy.shortName(for: pinned))"
        }
        if runner.isRunning, let active = runner.activeModelName {
            return active
        }
        return "Auto · \(activeModelShortName)"
    }

    /// Whether the model is manually pinned (changes pill accent).
    private var isModelPinned: Bool {
        runner.pinnedModelIdentifier != nil
    }

    @State private var isSlimBarHovered = false
    @State private var shimmerPhase: CGFloat = 0.0

    // MARK: - Stage Stability (minimum display duration)

    @State private var displayedStage: PipelineStage = .idle
    @State private var stageLockedUntil: Date = .distantPast
    @State private var pendingStageTask: Task<Void, Never>?

    private static let minimumStageDuration: TimeInterval = 0.7

    /// Shimmer gradient mask for live pipeline status text.
    private func shimmerMask(width: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.4), location: shimmerPhase - 0.3),
                .init(color: .white, location: shimmerPhase),
                .init(color: .white.opacity(0.4), location: shimmerPhase + 0.3),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: width)
    }

    private var slimContextBar: some View {
        Button {
            withAnimation(StudioMotion.standardSpring) {
                runner.sessionInspector.isVisible.toggle()
            }
            // When opening during a run, auto-focus the latest active span
            if runner.sessionInspector.isVisible && runner.isRunning {
                if let activeSpan = runner.sessionInspector.spans.last(where: { $0.endedAt == nil && $0.kind != "session" }) {
                    runner.sessionInspector.focus(spanID: activeSpan.id)
                }
            }
        } label: {
            HStack(spacing: StudioSpacing.lg) {
                // Group 1: Session Log
                HStack(spacing: 5) {
                    Image(systemName: "timeline.selection")
                        .font(.system(size: 10, weight: .medium))
                    Text("Session Log")
                        .font(StudioTypography.captionMedium)
                }
                .foregroundStyle(
                    runner.sessionInspector.isVisible
                        ? StudioAccentColor.primary
                        : StudioTextColorDark.secondary
                )

                Text("·")
                    .font(StudioTypography.captionSemibold)
                    .foregroundStyle(StudioTextColorDark.tertiary)

                // Group 2: Live pipeline state or autonomy mode
                if runner.isCancelling {
                    HStack(spacing: StudioSpacing.xs) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 10, weight: .medium))
                        Text("Cancelling…")
                            .font(StudioTypography.microSemibold)
                    }
                    .foregroundStyle(StudioTextColorDark.tertiary)
                    .transition(.opacity)
                } else if runner.isRunning && displayedStage != .idle {
                    HStack(spacing: StudioSpacing.xs) {
                        Image(systemName: displayedStage.displaySymbol)
                            .font(.system(size: 10, weight: .medium))
                            .symbolEffect(.pulse, isActive: true)
                        Text(displayedStage.displayLabel)
                            .font(StudioTypography.microSemibold)
                            .contentTransition(.numericText())
                    }
                    .foregroundStyle(StudioAccentColor.primary)
                    .mask(shimmerMask(width: 120))
                    .animation(StudioMotion.emphasisFade, value: displayedStage)
                } else {
                    HStack(spacing: StudioSpacing.xs) {
                        Image(systemName: commandAccess.snapshot.accessScope.symbolName)
                            .font(.system(size: 10, weight: .medium))
                        Text(commandAccess.snapshot.accessScope.displayName)
                            .font(StudioTypography.microMedium)
                    }
                    .foregroundStyle(
                        commandAccess.snapshot.accessScope == .fullMacAccess
                            ? Color(hex: "#D4F000")
                            : StudioTextColorDark.primary
                    )
                }

                Text("·")
                    .font(StudioTypography.captionSemibold)
                    .foregroundStyle(StudioTextColorDark.tertiary)

                // Group 3: Active model & Active Project
                HStack(spacing: StudioSpacing.sm) {
                    if let proj = project {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(StudioAccentColor.primary)
                                .frame(width: 4, height: 4)
                                .shadow(color: StudioAccentColor.primary.opacity(0.6), radius: 3)
                            
                            Text(proj.name)
                                .font(StudioTypography.dataMicro)
                        }
                        .foregroundStyle(StudioTextColorDark.primary)

                        Text("·")
                            .font(StudioTypography.captionSemibold)
                            .foregroundStyle(StudioTextColorDark.tertiary)
                            .opacity(0.5)
                    }

                    Menu {
                        // Auto-route option
                        Button {
                            withAnimation(StudioMotion.fastSpring) {
                                runner.pinnedModelIdentifier = nil
                            }
                        } label: {
                            HStack {
                                Text("Auto-Route")
                                if runner.pinnedModelIdentifier == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Divider()

                        // Available models from configured roles
                        let models = StudioModelStrategy.availableModels(packageRoot: runner.packageRoot)
                        ForEach(models, id: \.identifier) { model in
                            Button {
                                withAnimation(StudioMotion.fastSpring) {
                                    runner.pinnedModelIdentifier = model.identifier
                                }
                            } label: {
                                HStack {
                                    Text("\(model.provider.title) · \(model.displayName)")
                                    if runner.pinnedModelIdentifier == model.identifier {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isModelPinned ? "pin.fill" : "cpu")
                                .font(.system(size: 10, weight: .medium))
                            Text(runner.isRunning ? (runner.activeModelName ?? activeModelShortName) : modelPillLabel)
                                .font(StudioTypography.dataMicro)
                                .contentTransition(.numericText())
                        }
                        .foregroundStyle(
                            isModelPinned
                                ? StudioAccentColor.primary.opacity(0.85)
                                : Color.white.opacity(0.62)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(runner.isRunning)
                }
                .padding(.horizontal, StudioSpacing.sm)
                .padding(.vertical, StudioSpacing.xxs)
                .background(
                    Capsule(style: .continuous)
                        .fill(StudioSurfaceGrouped.primary.opacity(0.5))
                )
                .animation(StudioMotion.softFade, value: runner.activeModelName)
                .animation(StudioMotion.softFade, value: runner.pinnedModelIdentifier)

                Spacer()

                if let summary = runner.sessionInspector.summary {
                    HStack(spacing: StudioSpacing.md) {
                        Text("\(summary.spanCount) spans")
                            .font(StudioTypography.dataMicro)
                        if summary.errorCount > 0 {
                            Text("\(summary.errorCount) err")
                                .font(StudioTypography.dataMicroSemibold)
                                .foregroundStyle(StudioStatusColor.danger)
                        }
                    }
                    .foregroundStyle(StudioTextColorDark.tertiary)
                }

                Image(systemName: runner.sessionInspector.isVisible ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(StudioTextColorDark.tertiary)
            }
            .padding(.horizontal, StudioSpacing.xl)
            .padding(.vertical, StudioSpacing.sm)
            .background(
                // Flat bottom corners so the bar physically fuses with the composer below
                UnevenRoundedRectangle(
                    topLeadingRadius: StudioRadius.lg,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: StudioRadius.lg,
                    style: .continuous
                )
                .fill(.thickMaterial)   // Exact same material as the composer
            )
            .overlay(
                // Border only on top, left, and right — none on the bottom
                // so there is no horizontal seam where they join.
                UnevenRoundedRectangle(
                    topLeadingRadius: StudioRadius.lg,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: StudioRadius.lg,
                    style: .continuous
                )
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .opacity(isSlimBarHovered ? 1.0 : 0.82)
            .animation(StudioMotion.softFade, value: isSlimBarHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isSlimBarHovered = hovering
        }
        .onAppear {
            withAnimation(StudioMotion.shimmer.repeatForever(autoreverses: false)) {
                shimmerPhase = 1.3
            }
        }
        .onChange(of: runner.stage) { _, newStage in
            let now = Date()
            let remaining = stageLockedUntil.timeIntervalSince(now)
            pendingStageTask?.cancel()

            if remaining > 0 {
                // Current stage hasn't hit minimum display time — queue the change
                pendingStageTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(remaining))
                    guard !Task.isCancelled else { return }
                    withAnimation(StudioMotion.softFade) {
                        displayedStage = newStage
                    }
                    stageLockedUntil = Date().addingTimeInterval(Self.minimumStageDuration)
                }
            } else {
                withAnimation(StudioMotion.softFade) {
                    displayedStage = newStage
                }
                stageLockedUntil = now.addingTimeInterval(Self.minimumStageDuration)
            }
        }
        .onChange(of: runner.isCancelling) { _, cancelling in
            if cancelling {
                pendingStageTask?.cancel()
                pendingStageTask = nil
            }
        }
    }

    private var primaryCommandBar: some View {
        MinimalComposerDock(
            goalText: $goalText,
            attachments: $attachments,
            runner: runner,
            onSubmit: onSubmit,
            isGated: commandApproval.pendingRequest != nil,
            isIndexing: isRefreshingRepository
        )
        .opacity(isRefreshingRepository ? 0.40 : 1.0)
        .animation(StudioMotion.softFade, value: isRefreshingRepository)
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

    private func launchQuickPrompt(_ prompt: String) {
        guard !runner.isRunning else { return }
        goalText = prompt
        onSubmit()
    }

    @MainActor
    private func scheduleStructuralSync() {
        pendingStructuralSyncTask?.cancel()
        pendingStructuralSyncTask = Task { @MainActor in
            try? await Task.sleep(for: Self.structuralSyncDebounce)
            guard !Task.isCancelled else { return }
            refreshConversationSourceCache(force: true)
            pendingStructuralSyncTask = nil
        }
    }

    @MainActor
    private func scheduleContentUpdate() {
        guard pendingContentUpdateTask == nil else { return }
        pendingContentUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: Self.contentUpdateDebounce)
            guard !Task.isCancelled else { return }
            applyBufferedConversationUpdate()
            pendingContentUpdateTask = nil
        }
    }

    private func makeConversationSourceSignature() -> ConversationSourceSignature {
        ConversationSourceSignature(
            projectID: project?.id,
            projectLastActivityAt: project?.lastActivityAt,
            activeGoal: project?.goal ?? runner.activeGoal,
            liveStructureVersion: runner.chatThread.structureVersion
        )
    }

    private func buildHistoricalMessages(from epochs: [Epoch]) -> [ChatMessage] {
        guard let project else { return [] }

        return epochs.map { epoch in
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

    private func buildGoalSuggestions(latestEpoch: Epoch?) -> [AgenticSuggestion] {
        // Template-engine suggestions take the first slots when loaded.
        // Fall back to static defaults only when the engine has no templates at all.
        let templateSuggestions = templateEngine.suggestions
        if !templateSuggestions.isEmpty {
            return templateSuggestions
        }
        guard let latestEpoch else { return Self.defaultGoalSuggestions }

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

    @MainActor
    private func refreshConversationSourceCache(force: Bool = false) {
        let signature = makeConversationSourceSignature()
        guard force || signature != conversationSourceCache.signature else { return }

        let sortedEpochs = project?.sortedEpochs ?? []
        let historicalMessages = buildHistoricalMessages(from: sortedEpochs)
        let messages = buildConversationMessageSnapshot(
            historicalMessages: historicalMessages,
            activeGoal: signature.activeGoal
        )

        conversationSourceCache = ConversationSourceCache(
            signature: signature,
            activeGoal: signature.activeGoal,
            messages: messages,
            suggestions: buildGoalSuggestions(latestEpoch: sortedEpochs.last)
        )

        syncConversationStoreStructurally(from: messages)
    }

    @MainActor
    private func syncConversationStoreStructurally(from messages: [ChatMessage]? = nil) {
        let messages = messages ?? conversationSourceCache.messages
        let rebuildStartedAt = CFAbsoluteTimeGetCurrent()
        conversationStore.rebuild(
            from: messages,
            isPipelineRunning: runner.isRunning
        )
        let rebuildEndedAt = CFAbsoluteTimeGetCurrent()
        Task {
            await LatencyDiagnostics.shared.recordStage(
                runID: runner.activeLatencyRunID,
                name: "Conversation Store Rebuild",
                startedAt: rebuildStartedAt,
                endedAt: rebuildEndedAt,
                notes: "messages=\(messages.count) turns=\(conversationStore.turns.count)"
            )
        }
    }

    @MainActor
    private func applyBufferedConversationUpdate() {
        guard let activeGoal = conversationSourceCache.activeGoal,
              let message = runner.chatThread.message(withID: runner.chatThread.lastUpdatedMessageID),
              message.goal == activeGoal else { return }

        let updateStartedAt = CFAbsoluteTimeGetCurrent()
        conversationStore.applyLiveMessage(
            message,
            isPipelineRunning: runner.isRunning
        )
        let updateEndedAt = CFAbsoluteTimeGetCurrent()
        Task {
            await LatencyDiagnostics.shared.recordStage(
                runID: runner.activeLatencyRunID,
                name: "Conversation Store Live Update",
                startedAt: updateStartedAt,
                endedAt: updateEndedAt,
                notes: "message_id=\(message.id.uuidString) streaming=\(message.isStreaming)"
            )
        }
    }

    private func buildConversationMessageSnapshot(
        historicalMessages: [ChatMessage],
        activeGoal: String?
    ) -> [ChatMessage] {
        // Include ALL thread messages so prior turns stay visible.
        let liveMessages = runner.chatThread.messages
        let liveEpochs = Set(liveMessages.compactMap(\.epochID))
        let baseHistory = historicalMessages.filter { message in
            guard let epochID = message.epochID else { return true }
            return !liveEpochs.contains(epochID)
        }

        return (baseHistory + liveMessages).sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.timestamp < rhs.timestamp
        }
    }
}
