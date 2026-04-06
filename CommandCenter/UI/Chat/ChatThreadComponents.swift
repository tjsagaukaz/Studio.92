// ChatThreadComponents.swift
// Studio.92 — Command Center

import SwiftUI
import AppKit

// MARK: - Empty State Watermark

struct StudioEmptyStateWatermark: View {
    var body: some View {
        VStack(spacing: StudioSpacing.sectionGap) {
            if let heroURL = Bundle.main.url(forResource: "studio92-hero", withExtension: "jpg"),
               let nsImage = NSImage(contentsOf: heroURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 180, height: 180)
                    .saturation(0)
                    .opacity(0.08)
                    .clipShape(Circle())
            }

            Text("Ready when you are")
                .font(StudioTypography.headlineMedium)
                .foregroundStyle(StudioTextColor.tertiary)
                .tracking(0.3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: 40)
    }
}

// MARK: - Chat Thread

struct ChatThreadView: View {

    let project: AppProject?
    let allProjects: [AppProject]
    let jobs: [AgentSession]
    let turns: [ConversationTurn]
    let turnStructureVersion: Int
    let turnContentVersion: Int
    let isPipelineRunning: Bool
    let selectedEpochID: UUID?
    let columnWidth: CGFloat
    let repositoryState: GitRepositoryState?
    let isRefreshingRepository: Bool
    let suggestions: [AgenticSuggestion]
    let onSelectSuggestion: (AgenticSuggestion) -> Void
    let onLaunchPrompt: (String) -> Void
    let onSelectJob: (UUID) -> Void
    let onSelectProject: (UUID) -> Void
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onReuseGoal: (String) -> Void
    let onRefreshRepository: () -> Void
    let onInitializeRepository: () -> Void
    let onOpenWorkspace: () -> Void
    let onCancelTurn: () -> Void
    let latencyRunID: String?
    let auditEntries: [ApprovalAuditEntry]
    let onShowRevert: ((ApprovalAuditEntry) -> Void)?

    @State private var highlightedEpochID: UUID?
    @State private var scrollDebounceTask: Task<Void, Never>?
    /// Distance in points from the bottom of the scrollable content to the visible bottom.
    @State private var scrollDistanceFromBottom: CGFloat = 0
    /// Briefly true when new content arrives while the user is scrolled up — triggers a pulse.
    @State private var hasUnseenContent: Bool = false

    private let bottomSentinelID = "chat-thread-bottom"
    /// User is considered "at bottom" when within this threshold.
    private static let nearBottomThreshold: CGFloat = 80

    init(
        project: AppProject? = nil,
        allProjects: [AppProject] = [],
        jobs: [AgentSession] = [],
        turns: [ConversationTurn],
        turnStructureVersion: Int = 0,
        turnContentVersion: Int = 0,
        isPipelineRunning: Bool,
        selectedEpochID: UUID?,
        columnWidth: CGFloat,
        repositoryState: GitRepositoryState? = nil,
        isRefreshingRepository: Bool = false,
        suggestions: [AgenticSuggestion],
        onSelectSuggestion: @escaping (AgenticSuggestion) -> Void,
        onLaunchPrompt: @escaping (String) -> Void = { _ in },
        onSelectJob: @escaping (UUID) -> Void = { _ in },
        onSelectProject: @escaping (UUID) -> Void = { _ in },
        onOpenArtifact: @escaping (UUID?, ArtifactCanvasLaunchMode) -> Void,
        onReuseGoal: @escaping (String) -> Void,
        onRefreshRepository: @escaping () -> Void = {},
        onInitializeRepository: @escaping () -> Void = {},
        onOpenWorkspace: @escaping () -> Void = {},
        onCancelTurn: @escaping () -> Void,
        latencyRunID: String? = nil,
        auditEntries: [ApprovalAuditEntry] = [],
        onShowRevert: ((ApprovalAuditEntry) -> Void)? = nil
    ) {
        self.project = project
        self.allProjects = allProjects
        self.jobs = jobs
        self.turns = turns
        self.turnStructureVersion = turnStructureVersion
        self.turnContentVersion = turnContentVersion
        self.isPipelineRunning = isPipelineRunning
        self.selectedEpochID = selectedEpochID
        self.columnWidth = columnWidth
        self.repositoryState = repositoryState
        self.isRefreshingRepository = isRefreshingRepository
        self.suggestions = suggestions
        self.onSelectSuggestion = onSelectSuggestion
        self.onLaunchPrompt = onLaunchPrompt
        self.onSelectJob = onSelectJob
        self.onSelectProject = onSelectProject
        self.onOpenArtifact = onOpenArtifact
        self.onReuseGoal = onReuseGoal
        self.onRefreshRepository = onRefreshRepository
        self.onInitializeRepository = onInitializeRepository
        self.onOpenWorkspace = onOpenWorkspace
        self.onCancelTurn = onCancelTurn
        self.latencyRunID = latencyRunID
        self.auditEntries = auditEntries
        self.onShowRevert = onShowRevert
    }

    private var latestInteractiveTurnID: UUID? {
        turns.last(where: { !$0.isHistorical })?.id
    }

    private var isNearBottom: Bool {
        scrollDistanceFromBottom < Self.nearBottomThreshold
    }

    private var showScrollButton: Bool {
        !turns.isEmpty && !isNearBottom
    }

    @State private var containerHeight: CGFloat = 0

    @Environment(\.streamPhaseController) private var streamPhaseController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Top anchor — tracks how far the content has been scrolled.
                    GeometryReader { geo in
                        Color.clear
                            .preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geo.frame(in: .named("chatScroll")).minY
                            )
                    }
                    .frame(height: 0)

                    CalmChatColumn(width: columnWidth) {
                        if turns.isEmpty {
                            ThreadEmptyState(
                                project: project,
                                allProjects: allProjects,
                                jobs: jobs,
                                isPipelineRunning: isPipelineRunning,
                                repositoryState: repositoryState,
                                isRefreshingRepository: isRefreshingRepository,
                                suggestions: suggestions,
                                onSelectSuggestion: onSelectSuggestion,
                                onLaunchPrompt: onLaunchPrompt,
                                onSelectProject: onSelectProject,
                                onSelectJob: onSelectJob,
                                onOpenArtifact: onOpenArtifact,
                                onRefreshRepository: onRefreshRepository,
                                onInitializeRepository: onInitializeRepository,
                                onOpenWorkspace: onOpenWorkspace
                            )
                            .frame(maxWidth: .infinity, minHeight: 0)
                        } else {
                            VStack(alignment: .leading, spacing: StudioChatLayout.messageSpacing) {
                                ForEach(turns, id: \.id) { turn in
                                    ConversationTurnListItem(
                                        turn: turn,
                                        isHighlighted: highlightedEpochID.map { turn.epochID == $0 } ?? false,
                                        isPipelineRunning: isPipelineRunning,
                                        onOpenArtifact: onOpenArtifact,
                                        onReuseGoal: onReuseGoal,
                                        isLatestInteractiveTurn: turn.id == latestInteractiveTurnID,
                                        onCancelTurn: onCancelTurn
                                    )
                                }
                                if !auditEntries.isEmpty {
                                    VStack(spacing: 2) {
                                        ForEach(auditEntries) { entry in
                                            ApprovalAuditRow(
                                                entry: entry,
                                                onShowRevert: onShowRevert
                                            )
                                        }
                                    }
                                    .padding(.top, StudioSpacing.sm)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    Color.clear
                        .frame(height: StudioChatLayout.composerScrollClearance)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ScrollBottomOffsetKey.self,
                                    value: geo.frame(in: .named("chatScroll")).maxY
                                )
                            }
                        )
                        .id(bottomSentinelID)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, StudioChatLayout.columnHorizontalPadding)
                .padding(.top, StudioChatLayout.columnVerticalPadding)
                .textSelection(.enabled)
            }
            .coordinateSpace(name: "chatScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { topY in
                // topY is the minY of the top-of-content anchor in the scroll coordinate space.
                // At the very top: topY ~0. Scrolled down: topY is negative.
                // Distance from bottom = total scrollable content + topY (topY is negative when scrolled).
                // We use the container height captured via GeometryReader background to compute this.
                let scrolled = max(0, -topY)
                // containerHeight is the visible height of the scroll view.
                // When scrolled == 0 we're at top; distance from bottom = (contentHeight - containerHeight).
                // We don't have contentHeight cheaply, so we use the bottom sentinel's offset instead.
                // This preference just keeps topY fresh for the sentinel calculation below.
                _ = scrolled
            }
            .onPreferenceChange(ScrollBottomOffsetKey.self) { sentinelMaxY in
                // sentinelMaxY is the maxY of the bottom sentinel in the scroll coordinate space.
                // containerHeight is the visible height. The sentinel is "at bottom" when
                // sentinelMaxY <= containerHeight (it's within view). Distance = max(0, sentinelMaxY - containerHeight).
                let dist = sentinelMaxY - containerHeight
                scrollDistanceFromBottom = max(0, dist)
            }
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { containerHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in containerHeight = h }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .mask(
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(
                        gradient: Gradient(colors: [.black, .clear]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 56)
                }
            )
            // Scroll-to-bottom button — sits above the safe area (command bar)
            .overlay(alignment: .bottomTrailing) {
                if showScrollButton {
                    ScrollToBottomButton(hasUnseenContent: hasUnseenContent) {
                        hasUnseenContent = false
                        withAnimation(.easeOut(duration: 0.28)) {
                            proxy.scrollTo(bottomSentinelID, anchor: .bottom)
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6))
                                .animation(.easeOut(duration: 0.14)),
                            removal: .opacity.animation(.easeOut(duration: 0.10))
                        )
                    )
                }
            }
            .animation(.easeOut(duration: 0.14), value: showScrollButton)
            .onAppear {
                scrollToBottom(using: proxy, animated: false)
            }
            .onChange(of: turnStructureVersion) { _, _ in
                guard selectedEpochID == nil else { return }
                if isNearBottom {
                    // Scroll to the top of the newest turn so the user sees
                    // the start of their message and the collapse boundary.
                    scrollToLatestTurn(using: proxy, animated: !isPipelineRunning)
                } else {
                    hasUnseenContent = true
                }
            }
            .onChange(of: turnContentVersion) { _, _ in
                guard selectedEpochID == nil else { return }
                if isNearBottom {
                    // Content delta during streaming — debounce and snap (no animation)
                    scrollDebounceTask?.cancel()
                    scrollDebounceTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        guard !Task.isCancelled else { return }
                        scrollToBottom(using: proxy, animated: false)
                    }
                } else {
                    hasUnseenContent = true
                }
            }
            .onChange(of: selectedEpochID) { _, newValue in
                highlightedEpochID = newValue
                guard let newValue else { return }
                withAnimation(StudioMotion.standardSpring) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(StudioMotion.softFade) {
                proxy.scrollTo(bottomSentinelID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomSentinelID, anchor: .bottom)
        }
    }

    /// Scrolls to the top of the most recent turn so the user immediately
    /// sees the start of their input and the collapse boundary (if any).
    private func scrollToLatestTurn(using proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = turns.last?.id else {
            scrollToBottom(using: proxy, animated: animated)
            return
        }
        if animated {
            withAnimation(StudioMotion.softFade) {
                proxy.scrollTo(lastID, anchor: .top)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .top)
        }
    }
}

// MARK: - Scroll Offset Preference Key

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Scroll to Bottom Button

private struct ScrollToBottomButton: View {
    let hasUnseenContent: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPulsing = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1.0 : (isPulsing ? 0.95 : 0.72))
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .onChange(of: hasUnseenContent) { _, newValue in
            guard newValue else { return }
            // Brief opacity pulse — no scale, communicates "something arrived"
            withAnimation(.easeOut(duration: 0.15)) { isPulsing = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                withAnimation(.easeOut(duration: 0.25)) { isPulsing = false }
            }
        }
    }
}

struct ConversationTurnListItem: View, Equatable {

    let turn: ConversationTurn
    let isHighlighted: Bool
    let isPipelineRunning: Bool
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onReuseGoal: (String) -> Void
    let isLatestInteractiveTurn: Bool
    let onCancelTurn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let epochID = turn.epochID {
                Color.clear
                    .frame(height: 0)
                    .id(epochID)
            }

            ConversationTurnRow(
                turn: turn,
                isHighlighted: isHighlighted,
                isPipelineRunning: isPipelineRunning,
                onOpenArtifact: onOpenArtifact,
                onReuseGoal: onReuseGoal,
                isLatestInteractiveTurn: isLatestInteractiveTurn,
                onCancelTurn: onCancelTurn
            )
        }
    }

    static func == (lhs: ConversationTurnListItem, rhs: ConversationTurnListItem) -> Bool {
        lhs.turn.id == rhs.turn.id
            && lhs.turn.userGoal == rhs.turn.userGoal
            && lhs.turn.userAttachments == rhs.turn.userAttachments
            && lhs.turn.response == rhs.turn.response
            && lhs.turn.toolTraces == rhs.turn.toolTraces
            && lhs.turn.state == rhs.turn.state
            && lhs.turn.epochID == rhs.turn.epochID
            && lhs.turn.screenshotPath == rhs.turn.screenshotPath
            && lhs.turn.metrics == rhs.turn.metrics
            && lhs.turn.isHistorical == rhs.turn.isHistorical
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.isPipelineRunning == rhs.isPipelineRunning
            && lhs.isLatestInteractiveTurn == rhs.isLatestInteractiveTurn
    }
}

struct ConversationTurnRow: View {

    let turn: ConversationTurn
    let isHighlighted: Bool
    let isPipelineRunning: Bool
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onReuseGoal: (String) -> Void
    let isLatestInteractiveTurn: Bool
    let onCancelTurn: () -> Void

    @Environment(\.streamPhaseController) private var streamPhaseController
    @State private var isHovering = false

    private var trimmedGoal: String {
        turn.userGoal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var responseText: String {
        turn.response.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Show the pulsing dot at the tail of the turn whenever this turn is
    /// actively running — regardless of whether text or tools are visible.
    private var isActivelyWorking: Bool {
        isLatestInteractiveTurn
            && isPipelineRunning
            && (turn.state == .streaming || turn.state == .executing || turn.state == .finalizing)
    }

    private var hasFinishedAssistantResponse: Bool {
        !responseText.isEmpty && (turn.isHistorical || turn.state == .completed || turn.state == .failed)
    }

    private var shouldShowActionRow: Bool {
        if turn.isHistorical || hasFinishedAssistantResponse {
            return true
        }

        // Don't show an empty action row during early streaming.
        if responseText.isEmpty {
            return false
        }

        return isLatestInteractiveTurn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioChatLayout.userToAssistantSpacing) {
            if !trimmedGoal.isEmpty {
                UserGoalBubbleView(
                    goal: trimmedGoal,
                    attachments: turn.userAttachments,
                    isHighlighted: isHighlighted
                )
                .equatable()
            }

            VStack(alignment: .leading, spacing: StudioChatLayout.messageInternalSpacing) {
                // Interleaved text + tool blocks for both live and settled turns.
                // During active execution the StreamStepTracker replaces InlineToolTraceGroup.
                if !turn.toolTraces.isEmpty || !responseText.isEmpty {
                    InterleavedTurnContentView(
                        turn: turn,
                        isPipelineRunning: isPipelineRunning,
                        liveController: isActivelyWorking ? streamPhaseController : nil
                    )
                }

                // Anchor dot — only visible before any content lands (no text, no tools).
                // Once text flows, the inline stream cursor takes over inside the text view.
                if isActivelyWorking && responseText.isEmpty && turn.toolTraces.isEmpty {
                    ThinkingPulse()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if turn.state == .completed, (turn.metrics != nil || turn.screenshotPath != nil) {
                    TurnArtifactSummary(turn: turn)
                        .equatable()
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

                // Confidence + elapsed time — only on completed turns
                if turn.state == .completed {
                    TurnCompletionFooter(turn: turn)
                }

                // Triage card — collapsed failure summary with one-click recovery
                if turn.state == .failed {
                    TriageRecoveryCard(
                        turn: turn,
                        onDiagnose: { onReuseGoal("Diagnose and fix the error above.") }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, StudioSpacing.xxs)
        .textSelection(.enabled)
        .overlay(alignment: .topLeading) {
            // Margin tag for persisted reasoning — floats just outside the response
            // at -20pt leading. Tap to reveal the full thought process.
            let thinkingContent = turn.response.thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !thinkingContent.isEmpty && (turn.state == .completed || turn.isHistorical) {
                ReasoningMarginTag(thinkingText: thinkingContent)
                    .offset(x: -22, y: 2)
            }
        }
        .overlay(alignment: .leading) {
            if isHighlighted {
                RoundedRectangle(cornerRadius: StudioRadius.pill, style: .continuous)
                    .fill(StudioTextColor.primary.opacity(0.18))
                    .frame(width: 2)
                    .offset(x: -14)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(StudioMotion.standardSpring, value: isHighlighted)
        .animation(StudioMotion.hoverEase, value: isHovering)
    }
}

// MARK: - Interleaved Turn Content

/// Renders a turn as interleaved text segments and tool trace groups,
/// matching the VS Code Copilot pattern where tool calls appear inline between text.
struct InterleavedTurnContentView: View {

    let turn: ConversationTurn
    let isPipelineRunning: Bool
    /// Non-nil only during active live execution — switches tool blocks to StreamStepTracker.
    var liveController: StreamPhaseController? = nil

    private var isLive: Bool {
        turn.response.isStreaming
            || turn.state == .streaming
            || turn.state == .executing
    }

    private var useLiveStepTracker: Bool {
        guard let controller = liveController else { return false }
        return !controller.steps.isEmpty
    }

    private var activeStepID: String? {
        guard let controller = liveController else { return nil }
        if case .executing(let id) = controller.phase { return id }
        return nil
    }

    var body: some View {
        let blocks = turn.interleavedBlocks
        VStack(alignment: .leading, spacing: StudioChatLayout.messageInternalSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                switch block {
                case .text(_, let text):
                    let isLastBlock = index == blocks.count - 1
                    if isLive && isLastBlock {
                        // Streaming — show raw text.
                        StreamingMarkdownRevealView(
                            text: text,
                            isPipelineRunning: isPipelineRunning,
                            showsCursor: turn.response.isStreaming,
                            tone: .assistant
                        )
                    } else {
                        // Settled — render directly.
                        MarkdownMessageContent(
                            text: text,
                            isStreaming: false,
                            isPipelineRunning: isPipelineRunning,
                            tone: .assistant
                        )
                    }

                case .toolActivity(_, let traces):
                    if useLiveStepTracker {
                        // Suppressed — StreamStepTracker renders once below.
                        EmptyView()
                    } else {
                        InlineToolTraceGroup(traces: traces)
                    }
                }
            }

            // Live step tracker — single consolidated view for all active steps.
            // Replaces inline InlineToolTraceGroup during active execution only.
            if useLiveStepTracker, let controller = liveController {
                StreamStepTracker(
                    steps: controller.steps,
                    activeStepID: activeStepID
                )
                .environment(\.streamDeepLinkRouter, controller.deepLinkRouter)
                .transition(.studioFadeLift)
            }
        }
    }
}

/// Compact inline tool activity — single summary line, expandable.
/// Follows the 2026 pattern: collapsed natural-language summary,
/// click to see details. No timeline rail, no vertical connectors.
private struct InlineToolTraceGroup: View {

    let traces: [ToolTrace]

    @State private var isExpanded = false

    private var sortedTraces: [ToolTrace] {
        traces.filter { !$0.isConsoleTrace }
            .sorted(by: { $0.timestamp < $1.timestamp })
    }

    private var hasLive: Bool {
        sortedTraces.contains(where: \.isLive)
    }

    /// Natural language summary: "Searched 3 files, edited 2 files"
    private var summaryText: String {
        if hasLive, let current = sortedTraces.last(where: \.isLive) {
            return liveDescription(current)
        }

        var counts: [ToolTrace.Kind: Int] = [:]
        var webCount = 0
        for trace in sortedTraces {
            if trace.sourceName == "web_search" || trace.sourceName == "web_fetch" {
                webCount += 1
            } else {
                counts[trace.kind, default: 0] += 1
            }
        }

        var parts: [String] = []
        if webCount > 0 {
            parts.append("Searched web")
        }

        parts += counts.sorted(by: { $0.value > $1.value }).prefix(3).map { kind, count in
            "\(verbPastTense(kind)) \(count) \(count == 1 ? "file" : "files")"
        }

        if parts.isEmpty { return "Ran tools" }
        return parts.joined(separator: ", ")
    }

    private var hasWeb: Bool {
        sortedTraces.contains { $0.sourceName == "web_search" || $0.sourceName == "web_fetch" }
    }

    var body: some View {
        if !sortedTraces.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(StudioMotion.standardSpring) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: StudioSpacing.sm) {
                        Image(systemName: hasLive ? (hasWeb ? "globe" : "circle.fill") : (hasWeb ? "globe" : "checkmark"))
                            .font(.system(size: hasLive && !hasWeb ? 5 : (hasWeb ? 10 : 8), weight: .semibold))
                            .foregroundStyle(hasLive ? StudioAccentColor.primary : StudioTextColor.tertiary)
                            .frame(width: 12)

                        Text(summaryText)
                            .font(StudioTypography.footnoteMedium)
                            .foregroundStyle(hasLive ? StudioTextColor.secondary : StudioTextColor.tertiary)
                            .lineLimit(1)

                        if sortedTraces.count > 1 {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(StudioTypography.badge)
                                .foregroundStyle(StudioTextColor.tertiary.opacity(0.6))
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, StudioSpacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded && sortedTraces.count > 1 {
                    VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus) {
                        ForEach(sortedTraces, id: \.id) { trace in
                            HStack(spacing: StudioSpacing.sm) {
                                Image(systemName: traceIcon(trace))
                                    .font(StudioTypography.badgeMedium)
                                    .foregroundStyle(trace.isLive ? StudioTextColor.secondary : StudioTextColor.tertiary.opacity(0.6))
                                    .frame(width: 12)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(traceLabel(trace))
                                        .font(StudioTypography.caption)
                                        .foregroundStyle(trace.isLive ? StudioTextColor.secondary : StudioTextColor.tertiary)
                                        .lineLimit(1)

                                    if let desc = traceDescription(trace), !desc.isEmpty {
                                        Text(desc)
                                            .font(StudioTypography.badgeSmall)
                                            .foregroundStyle(StudioTextColor.tertiary.opacity(0.6))
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.leading, 0)
                    .padding(.top, StudioSpacing.xxs)
                    .padding(.bottom, StudioSpacing.xs)
                    .transition(.studioCollapse)
                }
            }
            .opacity(StudioChatLayout.toolTraceOpacity)
        }
    }

    private func liveDescription(_ trace: ToolTrace) -> String {
        if trace.sourceName == "web_search" {
            let query = webQuery(trace)
            return "Searching web — \(query)"
        }
        if trace.sourceName == "web_fetch" {
            let url = webQuery(trace)
            return "Fetching — \(url)"
        }
        let target = traceTarget(trace)
        switch trace.kind {
        case .search: return "Searching\(target)"
        case .read:   return "Reading\(target)"
        case .edit:   return "Editing\(target)"
        case .write:  return "Writing\(target)"
        case .build:  return "Building…"
        case .terminal: return "Running command…"
        case .screenshot: return "Taking screenshot…"
        case .artifact: return "Creating artifact…"
        }
    }

    private func traceTarget(_ trace: ToolTrace) -> String {
        if let file = trace.filePath {
            return " \(URL(fileURLWithPath: file).lastPathComponent)"
        }
        if let intent = trace.intent, !intent.isEmpty {
            return " \(intent)"
        }
        return "…"
    }

    /// Secondary description shown beneath the trace label in the expanded list.
    /// Shows the intent when it differs from the target already shown in the label.
    private func traceDescription(_ trace: ToolTrace) -> String? {
        // Web searches already show query in the label — use detail if available.
        if trace.sourceName == "web_search" || trace.sourceName == "web_fetch" {
            return trace.detail
        }

        // If we have both a file path and an intent, show the intent as description.
        if trace.filePath != nil, let intent = trace.intent, !intent.isEmpty {
            return intent
        }

        // If we have detail, show it.
        if let detail = trace.detail, !detail.isEmpty {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 80 ? String(trimmed.prefix(77)) + "…" : trimmed
        }

        return nil
    }

    private func traceLabel(_ trace: ToolTrace) -> String {
        if trace.sourceName == "web_search" {
            let query = webQuery(trace)
            return trace.isLive ? "Searching web — \(query)" : "Searched web — \(query)"
        }
        if trace.sourceName == "web_fetch" {
            let url = webQuery(trace)
            return trace.isLive ? "Fetching — \(url)" : "Fetched — \(url)"
        }
        let verb: String
        switch trace.kind {
        case .search: verb = trace.isLive ? "Searching" : "Searched"
        case .read:   verb = trace.isLive ? "Reading" : "Read"
        case .edit:   verb = trace.isLive ? "Editing" : "Edited"
        case .write:  verb = trace.isLive ? "Writing" : "Wrote"
        case .build:  verb = trace.isLive ? "Building" : "Built"
        case .terminal: verb = trace.isLive ? "Running" : "Ran"
        case .screenshot: verb = trace.isLive ? "Capturing" : "Captured"
        case .artifact: verb = trace.isLive ? "Creating" : "Created"
        }
        return "\(verb)\(traceTarget(trace))"
    }

    private func traceIcon(_ trace: ToolTrace) -> String {
        if trace.sourceName == "web_search" || trace.sourceName == "web_fetch" {
            return "globe"
        }
        switch trace.kind {
        case .search: return "magnifyingglass"
        case .read:   return "doc.text"
        case .edit:   return "pencil"
        case .write:  return "doc.badge.plus"
        case .build:  return "hammer"
        case .terminal: return "terminal"
        case .screenshot: return "camera"
        case .artifact: return "cube"
        }
    }

    private func webQuery(_ trace: ToolTrace) -> String {
        // title is pre-formatted as "Searching <query>" or "Fetching <url>"
        let title = trace.title
        if let range = title.range(of: " ", options: .literal) {
            let remainder = String(title[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty { return remainder }
        }
        return trace.intent ?? "the web"
    }

    private func verbPastTense(_ kind: ToolTrace.Kind) -> String {
        switch kind {
        case .search: return "Searched"
        case .read:   return "Read"
        case .edit:   return "Edited"
        case .write:  return "Wrote"
        case .build:  return "Built"
        case .terminal: return "Ran"
        case .screenshot: return "Captured"
        case .artifact: return "Created"
        }
    }
}

struct UserGoalBubbleView: View, Equatable {

    let goal: String
    let attachments: [ChatAttachment]
    let isHighlighted: Bool

    static func == (lhs: UserGoalBubbleView, rhs: UserGoalBubbleView) -> Bool {
        lhs.goal == rhs.goal &&
        lhs.attachments == rhs.attachments &&
        lhs.isHighlighted == rhs.isHighlighted
    }

    // MARK: - Collapse State

    @State private var isExpanded: Bool = false
    @State private var isCollapsible: Bool = false
    @State private var isShowMoreHovered: Bool = false
    /// Natural (unconstrained) height of the content VStack. Monotonically increases;
    /// never overwritten once the constraint is applied, to avoid feedback loops.
    @State private var naturalHeight: CGFloat = 0

    /// Height of 5 rendered lines at 15pt + 10pt spacing + vertical bubble padding.
    /// Clamped to 340pt so dense markdown (headings, lists) can't blow past a visual ceiling.
    private static let collapsedHeight: CGFloat = min(140, 340)
    /// Buffer above collapsedHeight before isCollapsible flips — mirrors viewport hysteresis.
    private static let collapseBuffer: CGFloat = 12
    private static let bubbleBackground = Color(hex: "#14181D")

    /// True when the goal is predominantly fenced code — don't collapse those.
    private var isPurelyCode: Bool {
        let lines = goal.components(separatedBy: .newlines)
        var inFence = false
        var fenceLines = 0
        var totalLines = 0
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            totalLines += 1
            if t.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { fenceLines += 1 }
        }
        return totalLines > 3 && Double(fenceLines) / Double(totalLines) > 0.6
    }

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .leading, spacing: 0) {

                // MARK: Content + Fade Overlay

                // Content — renders at natural size; height constraint applied via frame
                VStack(alignment: .leading, spacing: StudioChatLayout.messageInternalSpacing) {
                    MarkdownMessageContent(text: goal, tone: .user)
                        .equatable()

                    if !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: StudioSpacing.md) {
                                ForEach(attachments) { attachment in
                                    ReferenceBadge(
                                        title: attachment.displayName,
                                        systemImage: attachment.isImage ? "photo" : StudioSymbol.resolve("plus.rectangle.on.folder", "paperclip"),
                                        style: .tinted
                                    ) {
                                        NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
                                    }
                                }
                            }
                            .padding(.vertical, StudioSpacing.xxs)
                        }
                    }
                }
                // Measure the content's natural height once, before any constraint.
                // Guard (geo.size.height > naturalHeight) prevents updating after
                // the constraint is applied, avoiding a feedback loop.
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear {
                            if geo.size.height > naturalHeight {
                                naturalHeight = geo.size.height
                                if !isPurelyCode {
                                    let effective = min(naturalHeight, 340)
                                    isCollapsible = effective > Self.collapsedHeight + Self.collapseBuffer
                                }
                            }
                        }
                    }
                )
                .frame(maxHeight: (isCollapsible && !isExpanded) ? Self.collapsedHeight : .infinity)
                .clipped()
                // Gradient fade + structural divider — overlay so it doesn't drive width
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: Self.bubbleBackground.opacity(0.04), location: 0.00),
                            .init(color: Self.bubbleBackground.opacity(0.40), location: 0.55),
                            .init(color: Self.bubbleBackground.opacity(0.90), location: 0.85),
                            .init(color: Self.bubbleBackground,              location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 64)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 1)
                    }
                    .allowsHitTesting(false)
                    .opacity((isCollapsible && !isExpanded) ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: isExpanded)
                }

                // MARK: Show more / Show less
                if isCollapsible {
                    HStack {
                        Spacer()
                        // Refinement 3: hover opacity response
                        Button {
                            withAnimation(.easeOut(duration: isExpanded ? 0.18 : 0.20)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Group {
                                if isExpanded {
                                    Text("Show less")
                                        .font(.system(size: 12, weight: .regular))
                                } else {
                                    HStack(spacing: 4) {
                                        Text("Show more")
                                            .font(.system(size: 12, weight: .medium))
                                        Image(systemName: "arrow.down")
                                            .font(.system(size: 11, weight: .medium))
                                            .opacity(0.85)
                                    }
                                }
                            }
                            .foregroundStyle(
                                Color.white.opacity(
                                    isShowMoreHovered
                                        ? (isExpanded ? 0.60 : 0.80)
                                        : (isExpanded ? 0.35 : 0.50)
                                )
                            )
                            .animation(.easeOut(duration: 0.12), value: isShowMoreHovered)
                        }
                        .buttonStyle(.plain)
                        .onHover { isShowMoreHovered = $0 }
                    }
                .padding(.top, 3)
                }
            }
            .padding(.horizontal, StudioChatLayout.userBubbleHPad)
            .padding(.vertical, StudioChatLayout.userBubbleVPad)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: StudioChatLayout.userBubbleCornerRadius, style: .continuous)
                    .fill(Self.bubbleBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioChatLayout.userBubbleCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .textSelection(.enabled)
        }
    }
}

struct AssistantTextView: View, Equatable {

    let turn: ConversationTurn
    let isPipelineRunning: Bool

    private var stableText: String {
        turn.response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var liveText: String {
        turn.response.streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioChatLayout.messageInternalSpacing) {
            if !stableText.isEmpty {
                MarkdownMessageContent(
                    text: stableText,
                    isStreaming: false,
                    isPipelineRunning: isPipelineRunning,
                    tone: .assistant
                )
                .equatable()
            }

            if !liveText.isEmpty {
                StreamingMarkdownRevealView(
                    text: liveText,
                    isPipelineRunning: isPipelineRunning,
                    showsCursor: turn.response.isStreaming,
                    tone: .assistant
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StreamingMarkdownRevealView: View {

    let text: String
    let isPipelineRunning: Bool
    let showsCursor: Bool
    var tone: MarkdownMessageContent.Tone = .body

    @State private var revealedCount = 0
    @State private var revealDriverID = UUID()

    var body: some View {
        MarkdownMessageContent(
            text: revealedText,
            isStreaming: true,
            isPipelineRunning: isPipelineRunning,
            tone: tone
        )
        .equatable()
        .overlay(alignment: .bottomTrailing) {
            if showsCursor {
                StreamingCursorView()
                    .padding(.trailing, -8)
                    .padding(.bottom, StudioSpacing.xs)
            }
        }
        .task(id: revealDriverID) {
            await revealTowardLatestText()
        }
        .onAppear {
            revealedCount = min(revealedCount, text.count)
        }
        .onChange(of: text) { _, _ in
            revealDriverID = UUID()
        }
    }

    private var revealedText: String {
        String(text.prefix(revealedCount))
    }

    private func revealTowardLatestText() async {
        let targetCount = text.count

        if targetCount < revealedCount {
            revealedCount = targetCount
            return
        }

        let completedCodeBlocks = Self.completedCodeBlockRanges(in: text)

        while revealedCount < targetCount {
            if let nextBlock = completedCodeBlocks.first(where: {
                $0.upperBound > revealedCount && $0.lowerBound <= revealedCount
            }) {
                revealedCount = nextBlock.upperBound
                try? await Task.sleep(nanoseconds: 6_000_000)
                continue
            }

            let remaining = targetCount - revealedCount
            let nextCodeBlockStart = completedCodeBlocks
                .lazy
                .map(\.lowerBound)
                .first(where: { $0 > revealedCount })
            let step: Int

            switch remaining {
            case 0...24:
                step = 1
            case 25...80:
                step = 2
            case 81...180:
                step = 4
            default:
                step = 7
            }

            let unclampedNext = min(revealedCount + step, targetCount)
            if let nextCodeBlockStart, unclampedNext > nextCodeBlockStart {
                revealedCount = nextCodeBlockStart
            } else {
                revealedCount = unclampedNext
            }

            let sleepMs: UInt64
            switch remaining {
            case 0...24:
                sleepMs = 18
            case 25...80:
                sleepMs = 14
            case 81...180:
                sleepMs = 10
            default:
                sleepMs = 8
            }

            try? await Task.sleep(nanoseconds: sleepMs * 1_000_000)
        }
    }

    private static func completedCodeBlockRanges(in text: String) -> [Range<Int>] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let pattern = "```[\\s\\S]*?```"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return regex.matches(in: text, options: [], range: fullRange).compactMap { match in
            guard let lower = utf16OffsetToCharacterOffset(match.range.location, in: text),
                  let upper = utf16OffsetToCharacterOffset(match.range.location + match.range.length, in: text) else {
                return nil
            }
            return lower..<upper
        }
    }

    private static func utf16OffsetToCharacterOffset(_ utf16Offset: Int, in text: String) -> Int? {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count else {
            return nil
        }

        let scalarIndex = String.Index(utf16Offset: utf16Offset, in: text)
        return text.distance(from: text.startIndex, to: scalarIndex)
    }
}

struct StreamingCursorView: View {

    @State private var isVisible = true

    var body: some View {
        Capsule(style: .continuous)
            .fill(StudioTextColor.primary.opacity(0.78))
            .frame(width: 12, height: 3)
            .opacity(isVisible ? 1 : 0.2)
            .onAppear {
                withAnimation(StudioMotion.breathe) {
                    isVisible = false
                }
            }
    }
}

struct TurnArtifactSummary: View, Equatable {

    let turn: ConversationTurn

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xl) {
            if let metrics = turn.metrics {
                CompletionMetricsRow(metrics: metrics)
            }

            if let screenshotPath = turn.screenshotPath {
                InlineScreenshotView(path: screenshotPath)
                    .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
            }
        }
        .padding(.top, StudioSpacing.xxs)
    }
}

// MARK: - Turn Completion Footer (Confidence + Elapsed)

struct TurnCompletionFooter: View {

    let turn: ConversationTurn

    private var elapsedLabel: String? {
        guard let seconds = turn.metrics?.elapsedSeconds, seconds > 0 else { return nil }
        if seconds < 60 {
            return "Completed in \(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder > 0
            ? "Completed in \(minutes)m \(remainder)s"
            : "Completed in \(minutes)m"
    }

    private enum Confidence {
        case high, medium, low
    }

    private var confidence: Confidence {
        guard let metrics = turn.metrics else { return .high }
        // High > 80 HIG score with low deviation
        if metrics.higScore >= 80 && metrics.deviationCost < 0.3 { return .high }
        // Low < 50 HIG score or high deviation
        if metrics.higScore < 50 || metrics.deviationCost > 0.7 { return .low }
        return .medium
    }

    private var confidenceLabel: String? {
        switch confidence {
        case .high: return nil  // No label for high confidence
        case .medium: return "Review suggested"
        case .low: return "Needs attention"
        }
    }

    private var confidenceColor: Color {
        switch confidence {
        case .high: return StudioTextColor.tertiary
        case .medium: return Color.orange.opacity(0.7)
        case .low: return StudioStatusColor.danger.opacity(0.8)
        }
    }

    var body: some View {
        let hasContent = elapsedLabel != nil || confidenceLabel != nil
        if hasContent {
            HStack(spacing: StudioSpacing.lg) {
                if let elapsed = elapsedLabel {
                    Text(elapsed)
                        .font(StudioTypography.microMedium)
                        .foregroundStyle(StudioTextColor.tertiary)
                }
                if let conf = confidenceLabel {
                    Text("·")
                        .font(StudioTypography.microSemibold)
                        .foregroundStyle(StudioTextColor.tertiary.opacity(0.4))
                    Text(conf)
                        .font(StudioTypography.microMedium)
                        .foregroundStyle(confidenceColor)
                }
                Spacer()
            }
            .padding(.top, StudioSpacing.xxs)
        }
    }
}

struct ResponseActionRow: View {

    let turn: ConversationTurn
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onReuseGoal: (String) -> Void
    let onCancelTurn: () -> Void
    let isLatestInteractiveTurn: Bool
    let isHighlighted: Bool
    let isRowHovering: Bool

    @AppStorage("packageRoot") private var storedPackageRoot = ""
    @Environment(\.viewportActionContext) private var viewportActions
    @State private var isPreparingDiff = false
    @State private var isDiffApplied = false
    @State private var appliedAnchor: ActionAnchor?
    @State private var highlightedAction: ActionHighlight?

    private enum ActionHighlight: String {
        case diff
        case artifact
        case copy
    }

    var body: some View {
        HStack(spacing: StudioSpacing.xxl) {
            if turn.isHistorical {
                if hasDiffSource {
                    InlineActionButton(
                        title: "View Diff",
                        systemImage: "arrow.left.and.right.square",
                        isHighlighted: highlightedAction == .diff || isPreparingDiff,
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
                    HStack(spacing: StudioSpacing.xs) {
                        InlineActionButton(
                            title: isDiffApplied ? "Applied" : (isPreparingDiff ? "Preparing Diff" : "Open Diff"),
                            systemImage: isDiffApplied ? "checkmark.circle.fill" : "arrow.left.and.right.square",
                            isHighlighted: isDiffApplied || highlightedAction == .diff || isPreparingDiff,
                            isDisabled: isPreparingDiff || isDiffApplied,
                            accentColor: isDiffApplied ? Color(hex: "#86EFAC") : nil
                        ) {
                            trigger(.diff) {
                                openDiff()
                            }
                        }

                        if isDiffApplied, let anchor = appliedAnchor {
                            Button {
                                viewportActions.showTemporalRevert(TemporalRevertModel(
                                    anchorID: anchor.id,
                                    title: anchor.title,
                                    actionPreview: anchor.actionPreview,
                                    anchorSHA: anchor.gitSHA,
                                    anchorTimestamp: anchor.timestamp
                                ))
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(StudioTypography.footnoteSemibold)
                                    .foregroundStyle(StudioTextColorDark.tertiary)
                                    .padding(.horizontal, StudioSpacing.sm)
                                    .padding(.vertical, StudioSpacing.xxs)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .opacity(isRowHovering ? 1 : 0)
                            .scaleEffect(isRowHovering ? 1 : 0.85, anchor: .leading)
                            .animation(StudioMotion.hoverEase, value: isRowHovering)
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
            }

            Spacer(minLength: 0)

            // Copy lives at the trailing edge — anchored to the right margin,
            // never floating above content cards.
            if let copyableResponseText {
                InlineActionButton(
                    title: "Copy",
                    systemImage: "doc.on.doc",
                    isHighlighted: highlightedAction == .copy,
                    isDisabled: false
                ) {
                    trigger(.copy) {
                        writeTextToPasteboard(copyableResponseText)
                    }
                }
            }
        }
        .font(StudioTypography.footnoteSemibold)
        .padding(.top, StudioSpacing.xxs)
        .opacity(actionRowOpacity)
        .contentTransition(.opacity)
        .animation(StudioMotion.hoverEase, value: actionStateKey)
        .animation(StudioMotion.settledFade, value: actionRowOpacity)
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

    private var actionRowOpacity: Double {
        if isHighlighted || isRowHovering { return 1.0 }
        return turn.isHistorical ? 0.45 : 0.6
    }

    private var hasArtifact: Bool {
        turn.epochID != nil && (turn.screenshotPath != nil || turn.metrics != nil)
    }

    private var hasDiffSource: Bool {
        firstCodeBlock != nil || turn.epochID != nil
    }

    private var copyableResponseText: String? {
        let trimmed = turn.response.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard turn.isHistorical || turn.state == .completed || turn.state == .failed else { return nil }
        return trimmed
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
            viewportActions.showDiffPreview(
                ViewportDiffModel(title: "Diff Preview", state: .loading, canApply: false),
                nil
            )

            let packageRoot = resolvedPackageRoot
            let code = firstCodeBlock.content
            let targetHint = firstCodeBlock.targetHint

            DispatchQueue.global(qos: .userInitiated).async {
                let state = CodeDiffPreviewState.prepare(
                    code: code,
                    targetHint: targetHint,
                    packageRoot: packageRoot
                )
                DispatchQueue.main.async {
                    viewportActions.showDiffPreview(
                        ViewportDiffModel(title: "Diff Preview", state: state),
                        state.supportsApply ? applyDiff : nil
                    )
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
            // Create the anchor BEFORE writing so the snapshot is pristine.
            let filePath = session.targetURL.path
            let anchorTitle = filePath.isEmpty
                ? "Diff Applied"
                : (filePath as NSString).lastPathComponent
            let anchor = await viewportActions.createAnchor(anchorTitle, filePath)

            let result = await Task.detached(priority: .userInitiated) {
                CodeDiffWriter.write(session: session)
            }.value

            await MainActor.run {
                switch result {
                case .success:
                    viewportActions.showDiffPreview(
                        ViewportDiffModel(title: "Diff Preview", state: .ready(session), canApply: false),
                        nil
                    )
                    withAnimation(StudioMotion.fastSpring) {
                        isDiffApplied = true
                    }
                    appliedAnchor = anchor
                    CodeApplyFeedback.performSuccess()

                    // Surface revert entry in viewport if anchor was created.
                    if let anchor {
                        viewportActions.showTemporalRevert(TemporalRevertModel(
                            anchorID: anchor.id,
                            title: anchor.title,
                            actionPreview: anchor.actionPreview,
                            anchorSHA: anchor.gitSHA,
                            anchorTimestamp: anchor.timestamp
                        ))
                    }

                case .failure(let error):
                    viewportActions.showDiffPreview(
                        ViewportDiffModel(title: "Diff Preview", state: .failed(error.localizedDescription), canApply: false),
                        nil
                    )
                }
            }
        }
    }

    private func trigger(_ action: ActionHighlight, perform work: () -> Void) {
        withAnimation(StudioMotion.softFade) {
            highlightedAction = action
        }
        work()

        Task {
            try? await Task.sleep(for: .seconds(1.1))
            await MainActor.run {
                guard highlightedAction == action else { return }
                withAnimation(StudioMotion.softFade) {
                    highlightedAction = nil
                }
            }
        }
    }
}

func writeTextToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct InlineActionButton: View {

    let title: String
    let systemImage: String
    let isHighlighted: Bool
    let isDisabled: Bool
    var accentColor: Color? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioSpacing.sm) {
                Image(systemName: systemImage)
                    .font(StudioTypography.captionSemibold)
                Text(title)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, StudioSpacing.xs)
            .foregroundStyle(foregroundColor)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
            .scaleEffect(isHovering ? StudioMotion.hoverScale : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.56 : 1)
        .onHover { isHovering = $0 }
        .animation(StudioMotion.hoverEase, value: isHovering)
        .animation(StudioMotion.hoverEase, value: isHighlighted)
    }

    private var backgroundColor: Color {
        if isHighlighted {
            return StudioSurfaceElevated.level2
        }
        if isHovering {
            return StudioSurfaceGrouped.secondary
        }
        return Color.clear
    }

    private var foregroundColor: Color {
        if isHighlighted, let accentColor { return accentColor }
        return isHighlighted ? StudioTextColor.primary : StudioTextColor.secondary
    }
}

struct ChatMessageRow: View {

    let message: ChatMessage
    let isHighlighted: Bool
    let isPipelineRunning: Bool
    let onOpenArtifact: (UUID?) -> Void

    var body: some View {
        switch message.kind {
        case .userGoal:
            VStack(alignment: .leading, spacing: StudioSpacing.lg) {
                VStack(alignment: .leading, spacing: 0) {
                    // Reference pills bundled at the top, hairline then text
                    if !message.attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: StudioSpacing.sm) {
                                ForEach(message.attachments) { attachment in
                                    SentReferencePill(attachment: attachment)
                                }
                            }
                            .padding(.horizontal, StudioSpacing.panel)
                            .padding(.top, StudioSpacing.section)
                            .padding(.bottom, StudioSpacing.md)
                        }

                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                    }

                    MarkdownMessageContent(text: message.text)
                        .padding(.horizontal, StudioSpacing.panel)
                        .padding(.vertical, StudioSpacing.section)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                        .fill(StudioSurfaceGrouped.primary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                        .stroke(isHighlighted ? StudioSeparator.strong : StudioSeparator.subtle, lineWidth: isHighlighted ? 1.2 : 1)
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
                reasoningText: message.thinkingText,
                isPartial: message.isPartial
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
            ThinkingMessageRow(statusLabel: "Thinking")

        case .streaming:
            StreamingAssistantMessageRow(message: message, isPipelineRunning: isPipelineRunning)

        case .planViewportCard:
            PlanViewportIndicatorRow()

        case .compactionDivider:
            CompactionDividerRow(label: message.text)

        case .timelineFracture:
            TimelineFractureRow(label: message.text)
        }
    }
}

// MARK: - Plan Viewport Indicator Row

struct PlanViewportIndicatorRow: View {

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: StudioSpacing.xl) {
            // Cyan left accent
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(StudioAccentColor.primary.opacity(0.7))
                .frame(width: 2.5, height: 32)

            VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus) {
                HStack(spacing: StudioSpacing.sm) {
                    Circle()
                        .fill(StudioAccentColor.primary)
                        .frame(width: 5, height: 5)
                    Text("Plan generated")
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(StudioAccentColor.primary)
                        .tracking(0.1)
                }
                Text("Open the Viewport to review, approve, or suggest changes")
                    .font(StudioTypography.caption)
                    .foregroundStyle(StudioTextColor.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "sidebar.right")
                .font(StudioTypography.captionSemibold)
                .foregroundStyle(
                    isHovered
                        ? StudioAccentColor.primary
                        : StudioTextColor.tertiary.opacity(0.5)
                )
        }
        .padding(.horizontal, StudioSpacing.xl)
        .padding(.vertical, StudioSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .fill(
                    isHovered
                        ? StudioAccentColor.primary.opacity(0.07)
                        : StudioAccentColor.primary.opacity(0.04)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                        .strokeBorder(StudioAccentColor.primary.opacity(isHovered ? 0.22 : 0.12), lineWidth: 1)
                )
        )
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fastSpring, value: isHovered)
    }
}

// MARK: - Triage Recovery Card

struct TriageRecoveryCard: View {

    let turn: ConversationTurn
    let onDiagnose: () -> Void

    @State private var cardVisible = false

    private let coolRed = Color(hex: "#FF7373")
    private let cardSpring = Animation.spring(response: 0.28, dampingFraction: 0.88)

    private var crashSummary: String {
        let text = turn.response.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "The pipeline failed without a response."
        }
        // Surface the last meaningful sentence as the summary (up to ~120 chars)
        let sentences = text.components(separatedBy: ". ")
        for sentence in sentences.reversed() {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 20 {
                return String(trimmed.prefix(120))
            }
        }
        return String(text.prefix(120))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            HStack(alignment: .center, spacing: StudioSpacing.lg) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(coolRed)
                    .symbolRenderingMode(.monochrome)

                VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                    Text("Pipeline failed")
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(StudioTextColor.primary)

                    Text(crashSummary)
                        .font(StudioTypography.footnote)
                        .foregroundStyle(StudioTextColor.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Button(action: onDiagnose) {
                    Text("Diagnose & Fix")
                        .font(StudioTypography.footnoteMedium)
                        .foregroundStyle(.black)
                        .padding(.horizontal, StudioSpacing.xl)
                        .padding(.vertical, StudioSpacing.lg)
                        .background(
                            Capsule(style: .continuous)
                                .fill(StudioAccentColor.primary)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, StudioSpacing.xl)
        .padding(.vertical, StudioSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .fill(Color(hex: "#14181D"))
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                        .strokeBorder(coolRed.opacity(0.18), lineWidth: 0.5)
                )
        )
        .opacity(cardVisible ? 1 : 0)
        .offset(y: cardVisible ? 0 : 6)
        .onAppear {
            withAnimation(cardSpring) {
                cardVisible = true
            }
        }
    }
}

struct CompactionDividerRow: View {
    let label: String

    var body: some View {
        HStack(spacing: StudioSpacing.xl) {
            Rectangle()
                .fill(StudioAccentColor.muted.opacity(0.4))
                .frame(height: 1)
            Text(label)
                .font(StudioTypography.footnote)
                .fontWeight(.medium)
                .foregroundStyle(StudioTextColor.secondary)
                .layoutPriority(1)
            Rectangle()
                .fill(StudioAccentColor.muted.opacity(0.4))
                .frame(height: 1)
        }
        .padding(.horizontal, StudioSpacing.panel)
        .padding(.vertical, StudioSpacing.lg)
    }
}

// MARK: - Timeline Fracture Row

struct TimelineFractureRow: View {
    let label: String

    var body: some View {
        HStack(spacing: StudioSpacing.lg) {
            dashedLine
            HStack(spacing: StudioSpacing.sm) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.28))
                Text(label)
                    .font(StudioTypography.microMedium)
                    .foregroundStyle(Color.white.opacity(0.28))
                    .layoutPriority(1)
            }
            dashedLine
        }
        .padding(.horizontal, StudioSpacing.panel)
        .padding(.vertical, StudioSpacing.xl)
    }

    private var dashedLine: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: .init(x: 0, y: 0.5))
                path.addLine(to: .init(x: geo.size.width, y: 0.5))
            }
            .stroke(
                Color.white.opacity(0.14),
                style: StrokeStyle(lineWidth: 1, dash: [3, 4])
            )
        }
        .frame(height: 1)
    }
}

struct AssistantNarrativeSection: View {

    enum Emphasis {
        case subtle
        case emphasized
        case error
    }

    let text: String
    let emphasis: Emphasis
    let isPipelineRunning: Bool
    var reasoningText: String? = nil
    var isPartial: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: StudioSpacing.lg) {
            // Left-border anchor — 2pt rail that groups all text belonging to this AI turn.
            // Cyan when the turn is active/streaming; muted graphite when settled.
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(isPipelineRunning
                      ? StudioAccentColor.primary.opacity(0.55)
                      : StudioTextColor.tertiary.opacity(0.18))
                .frame(width: 2)
                .animation(StudioMotion.softFade, value: isPipelineRunning)

            VStack(alignment: .leading, spacing: StudioChatLayout.messageInternalSpacing) {
                MarkdownMessageContent(
                    text: text,
                    isStreaming: false,
                    isPipelineRunning: isPipelineRunning
                )
                    .foregroundStyle(StudioTextColor.primary)

                if isPartial {
                    Text("Partial")
                        .font(StudioTypography.microMedium)
                        .foregroundStyle(StudioTextColor.tertiary)
                        .padding(.top, StudioSpacing.xxs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(textColor)
        .padding(.vertical, StudioSpacing.xxs)
    }

    private var textColor: Color {
        switch emphasis {
        case .subtle:
            return StudioTextColor.primary
        case .emphasized:
            return StudioTextColor.primary.opacity(0.96)
        case .error:
            return StudioTextColor.primary.opacity(0.94)
        }
    }

    private var trimmedReasoningText: String? {
        let trimmed = reasoningText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

struct StreamingAssistantMessageRow: View {

    let message: ChatMessage
    let isPipelineRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StudioChatLayout.messageInternalSpacing) {
            if shouldShowPendingPlaceholder {
                ThinkingMessageRow(statusLabel: "Thinking")
            }

            if !renderedText.isEmpty {
                StreamingPlainTextView(text: renderedText, isStreaming: message.isStreaming)
            }

            if !contextToolCalls.isEmpty {
                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    ForEach(contextToolCalls) { toolCall in
                        PhantomToolLogView(toolCall: toolCall)
                    }
                }
            }

            if !actionToolCalls.isEmpty {
                VStack(alignment: .leading, spacing: StudioSpacing.lg) {
                    ForEach(actionToolCalls) { toolCall in
                        ToolCallCard(toolCall: toolCall)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, StudioSpacing.xxs)
    }

    private var renderedText: String {
        let baseText = message.isStreaming
            ? message.streamingText
            : (message.text.isEmpty ? message.streamingText : message.text)

        guard !baseText.isEmpty else { return "" }
        return baseText
    }

    private var shouldShowPendingPlaceholder: Bool {
        isPipelineRunning
            && renderedText.isEmpty
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
        case "file_read", "read_file":
            return .fileRead
        case "file_write", "create_file", "write_file":
            return .fileWrite
        case "file_patch", "apply_patch":
            return .filePatch
        case "list_files", "list_dir", "file_search", "grep_search", "semantic_search":
            return .listFiles
        case "web_search":
            return .webSearch
        case "web_fetch", "fetch_webpage":
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
            return "Read \(displayedPath(from: input) ?? "file")"
        case .fileWrite:
            return "Write \(displayedPath(from: input) ?? "file")"
        case .filePatch:
            return "Patch \(displayedPath(from: input) ?? "file")"
        case .listFiles:
            return "List \((input?["path"] as? String) ?? (input?["filePath"] as? String) ?? ".")"
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

    private func displayedPath(from input: [String: Any]?) -> String? {
        let rawPath = (input?["path"] as? String) ?? (input?["filePath"] as? String) ?? (input?["file_path"] as? String)
        guard let rawPath, !rawPath.isEmpty else { return nil }
        let lastComponent = URL(fileURLWithPath: rawPath).lastPathComponent
        return lastComponent.isEmpty ? rawPath : lastComponent
    }
}

struct StreamingPlainTextView: View {

    let text: String
    var isStreaming: Bool = false

    var body: some View {
        liveText
            .font(.system(size: StudioChatLayout.bodyFontSize, weight: .regular))
            .tracking(StudioChatLayout.bodyLetterSpacing)
            .foregroundStyle(StudioTextColor.primary)
            .lineSpacing(StudioChatLayout.bodyLineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Returns plain Text when settled, or Text + inline cyan circle when streaming.
    /// The dot wraps with the text naturally — no geometry tracking needed.
    private var liveText: Text {
        guard isStreaming else { return Text(text) }
        return Text(text)
            + Text(" ")
            + Text(Image(systemName: "circle.fill"))
                .foregroundStyle(StudioAccentColor.primary)
    }
}

// MARK: - Reasoning Margin Tag

/// Tiny `cpu` icon floating in the left margin of settled turns that have reasoning data.
/// Tapping pops open a popover with the full thought process.
struct ReasoningMarginTag: View {

    let thinkingText: String

    @State private var isPopoverOpen = false
    @State private var isHovered = false

    var body: some View {
        Button { isPopoverOpen.toggle() } label: {
            Image(systemName: "cpu")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(
                    isHovered
                        ? StudioAccentColor.primary.opacity(0.85)
                        : StudioAccentColor.primary.opacity(0.28)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fastSpring, value: isHovered)
        .popover(isPresented: $isPopoverOpen, arrowEdge: .leading) {
            ReasoningPopoverContent(text: thinkingText)
        }
    }
}

private struct ReasoningPopoverContent: View {

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            HStack(spacing: StudioSpacing.md) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioAccentColor.primary.opacity(0.7))
                Text("Thought Process")
                    .font(StudioTypography.captionSemibold)
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer(minLength: 0)
            }
            Divider().background(Color.white.opacity(0.07))
            ScrollView(.vertical, showsIndicators: false) {
                MarkdownMessageContent(text: text, tone: .meta)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
        .padding(StudioSpacing.section)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Thinking Disclosure View (retained for legacy/popover use)

struct ThinkingDisclosureView: View {

    let text: String
    let isLive: Bool

    @State private var isExpanded = false

    init(text: String, isLive: Bool = false) {
        self.text = text
        self.isLive = isLive
        _isExpanded = State(initialValue: isLive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.sm) {
            Button {
                withAnimation(StudioMotion.standardSpring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: StudioSpacing.md) {
                    Image(systemName: StudioSymbol.resolve("brain.head.profile", "brain"))
                        .font(.system(size: StudioChatLayout.metaFontSize - 1, weight: .semibold))
                        .foregroundStyle(StudioTextColor.tertiary)

                    Text(summaryText)
                        .font(.system(size: StudioChatLayout.metaFontSize, weight: .medium))
                        .foregroundStyle(StudioTextColor.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(StudioTypography.badge)
                        .foregroundStyle(StudioTextColor.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView(.vertical, showsIndicators: false) {
                    MarkdownMessageContent(text: text, tone: .meta)
                        .padding(.leading, 22)
                        .padding(.bottom, StudioSpacing.xs)
                }
                .frame(maxHeight: 100)
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, Color.primary],
                            startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.35)
                        )
                        .frame(height: 16)
                        Color.primary
                    }
                )
                .transition(.studioCollapse)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Thought process" }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let cleaned = firstLine
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
        guard !cleaned.isEmpty else { return "Thought process" }
        return cleaned.count <= 80 ? cleaned : String(cleaned.prefix(77)) + "..."
    }
}

