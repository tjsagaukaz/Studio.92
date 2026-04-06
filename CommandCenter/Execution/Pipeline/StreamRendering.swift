import SwiftUI
import AppKit

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Environment Key
// ═══════════════════════════════════════════════════════════════════════════════

private struct StreamPhaseControllerKey: EnvironmentKey {
    static let defaultValue: StreamPhaseController? = nil
}

private struct StreamDeepLinkRouterKey: EnvironmentKey {
    static let defaultValue: StreamDeepLinkRouter? = nil
}

extension EnvironmentValues {
    var streamPhaseController: StreamPhaseController? {
        get { self[StreamPhaseControllerKey.self] }
        set { self[StreamPhaseControllerKey.self] = newValue }
    }

    var streamDeepLinkRouter: StreamDeepLinkRouter? {
        get { self[StreamDeepLinkRouterKey.self] }
        set { self[StreamDeepLinkRouterKey.self] = newValue }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Phase-Aware Turn Content
// ═══════════════════════════════════════════════════════════════════════════════
//
// Replaces the static ThinkingMessageRow → AssistantTextView → ToolTraceListView
// sequence with a phase-driven renderer. Each phase has a dedicated view that
// occupies a stable container. No layout shifts between phases.

struct StreamPhaseRenderer: View {

    let controller: StreamPhaseController
    let turn: ConversationTurn
    let isPipelineRunning: Bool

    /// The previous phase key, used to compute transition-specific animation.
    @State private var previousPhaseKey: String = "idle"

    var body: some View {
        // The outer container is always present. It never appears or disappears.
        // Only its *contents* resolve. This makes the renderer a continuous
        // surface rather than a sequence of swapped views.
        VStack(alignment: .leading, spacing: StudioChatLayout.messageInternalSpacing) {
            phaseContent
        }
        // Transition-specific animation: duration and curve derived from
        // the (from, to) pair, not a single global value.
        .animation(resolvedAnimation, value: phaseKey)
        .onChange(of: phaseKey) { old, _ in
            previousPhaseKey = old
        }
    }

    // MARK: - Resolved Animation
    //
    // Each transition pair gets its own duration. The curve is always
    // .easeOut — no springs, no bounces. Springs feel reactive;
    // easeOut feels resolved.

    private var resolvedAnimation: Animation {
        let duration = StreamPhaseController.transitionDuration(
            from: phaseFromKey(previousPhaseKey),
            to: controller.phase
        )
        return .easeOut(duration: duration)
    }

    // MARK: - Phase Content
    //
    // Content uses .opacity transition exclusively. No .blurReplace,
    // no .move. Opacity dissolves feel like content resolving into
    // place. Blur and movement feel like UI switching.

    @ViewBuilder
    private var phaseContent: some View {
        switch controller.phase {
        case .idle:
            EmptyView()

        case .acknowledging:
            StreamGhostSkeleton()
                .transition(.studioFadeLift)

        case .thinking:
            // Reasoning is handled entirely by the ReasoningHUD overlay outside the chat column.
            // Keep the skeleton visible so the user knows the system is working.
            StreamGhostSkeleton()
                .transition(.studioCollapse)

        case .intent:
            // Keep skeleton visible while waiting for tool calls or narrative.
            StreamGhostSkeleton()
                .transition(.studioCollapse)

        case .planning:
            // Plan card now renders as a floating overlay via StreamPlanOverlay.
            EmptyView()
                .transition(.studioCollapse)

        case .executing(let activeStepID):
            // Reasoning lives in the HUD — center column stays pure.
            StreamStepTracker(
                steps: controller.steps,
                activeStepID: activeStepID
            )
            .transition(.studioFadeLift)

        case .completed:
            EmptyView()

        case .failed(let error):
            StreamErrorCard(error: error)
                .transition(.studioFadeLift)
        }
    }

    // MARK: - Phase Key

    private var phaseKey: String {
        switch controller.phase {
        case .idle:                     return "idle"
        case .acknowledging:            return "ack"
        case .thinking:                 return "think"
        case .intent:                   return "intent"
        case .planning:                 return "plan"
        case .executing(let id):        return "exec-\(id ?? "none")"
        case .completed:                return "done"
        case .failed:                   return "fail"
        }
    }

    /// Reconstruct a StreamPhase from a key string for duration lookup.
    private func phaseFromKey(_ key: String) -> StreamPhase {
        switch key {
        case "idle":    return .idle
        case "ack":     return .acknowledging
        case "think":   return .thinking
        case "intent":  return .intent("")
        case "plan":    return .planning(StreamPlan(title: "", steps: []))
        case "done":    return .completed
        case "fail":    return .failed(StreamError(message: "", isRecoverable: false, stepID: nil))
        default:
            if key.hasPrefix("exec") { return .executing(activeStepID: nil) }
            return .idle
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Ghost Skeleton
// ═══════════════════════════════════════════════════════════════════════════════
//
// Phase 0: Immediate acknowledgment (<150ms). Shows a skeleton that matches
// the final layout of an assistant response. The shimmer is extremely subtle
// and slow — it reads as a dormant surface waiting to resolve, not a
// loading indicator.

struct StreamGhostSkeleton: View {

    var body: some View {
        ThinkingPulse()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Thinking View
// ═══════════════════════════════════════════════════════════════════════════════
//
// Minimal pulsing dot — the only signal that the system is working.
// No text, no cards. Just a single silver dot that breathes.

struct StreamReasoningDisclosure: View {

    let summary: String?
    let text: String
    let isLive: Bool
    let forceExpanded: Bool

    @State private var isExpanded = false

    var body: some View {
        if let displayText = displaySummary, !displayText.isEmpty {
            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                Button {
                    withAnimation(StudioMotion.standardSpring) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .center, spacing: StudioSpacing.md) {
                        Image(systemName: StudioSymbol.resolve("brain.head.profile", "brain"))
                            .font(StudioTypography.microMedium)
                            .foregroundStyle(StudioTextColor.tertiary)
                            .frame(width: 12)

                        Text(displayText)
                            .font(StudioTypography.captionMedium)
                            .foregroundStyle(StudioTextColor.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(StudioTypography.badge)
                            .foregroundStyle(StudioTextColor.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            MarkdownMessageContent(text: text, tone: .meta)
                                .padding(.leading, StudioSpacing.sectionGap)
                                .padding(.bottom, StudioSpacing.xs)
                                .id("thinking-anchor")
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
                        .onChange(of: text) { _, _ in
                            if isLive {
                                withAnimation(StudioMotion.softFade) {
                                    proxy.scrollTo("thinking-anchor", anchor: .bottom)
                                }
                            }
                        }
                        .onAppear {
                            if isLive {
                                proxy.scrollTo("thinking-anchor", anchor: .bottom)
                            }
                        }
                    }
                    .transition(.studioCollapse)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                isExpanded = forceExpanded
            }
            .onChange(of: forceExpanded) { _, expanded in
                withAnimation(StudioMotion.standardSpring) {
                    isExpanded = expanded
                }
            }
        }
    }

    private var displaySummary: String? {
        let preferred = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preferred, !preferred.isEmpty {
            return preferred
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        return String(trimmedText.prefix(90))
    }
}

/// The thermal glow bar is the system's heartbeat indicator.
/// Its animation is deliberately slow (6s) — more like breathing
/// than pulsing. It should feel biological, not mechanical.
struct ThermalGlowBar: View {

    @State private var phase: CGFloat = 0

    var body: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: StudioColorTokens.ThermalGlow.cool, location: 0),
                        .init(color: StudioColorTokens.ThermalGlow.neutral, location: 0.5),
                        .init(color: StudioColorTokens.ThermalGlow.warm, location: 1)
                    ],
                    startPoint: UnitPoint(x: phase - 0.3, y: 0.5),
                    endPoint: UnitPoint(x: phase + 0.7, y: 0.5)
                )
            )
            .frame(width: 32, height: 4)
            .opacity(0.64)
            .onAppear {
                // 6s full cycle — reads as ambient warmth, not activity.
                withAnimation(StudioMotion.thermalDrift) {
                    phase = 1.0
                }
            }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Step Tracker
// ═══════════════════════════════════════════════════════════════════════════════
//
// Phase 3: Step-by-step execution. Shows each tool call as a step with
// status, command, and collapsible output. Steps only appear when started
// and never disappear. Monotonic rendering.

struct StreamStepTracker: View {

    let steps: [StreamStep]
    let activeStepID: String?

    @State private var isExpanded = false

    /// Maximum visible height for the scrolling feed during live execution.
    private static let maxLiveHeight: CGFloat = 400

    private var completedSteps: [StreamStep] {
        steps.filter { $0.status != .active }
    }

    private var activeSteps: [StreamStep] {
        steps.filter { $0.status == .active || $0.id == activeStepID }
    }

    /// True while any step is still running.
    private var isLive: Bool {
        steps.contains { $0.status == .active }
    }

    private var summaryLabel: String {
        let count = completedSteps.count
        guard count > 0 else { return "" }
        let kinds = Set(completedSteps.compactMap { $0.title.components(separatedBy: " ").first?.lowercased() })
        let verbs = kinds.prefix(3).joined(separator: ", ")
        if verbs.isEmpty {
            return "Completed \(count) step\(count == 1 ? "" : "s")"
        }
        return "\(verbs.capitalized) — \(count) step\(count == 1 ? "" : "s")"
    }

    var body: some View {
        if !steps.isEmpty {
            if isLive {
                liveFeedView
            } else {
                settledView
            }
        }
    }

    // MARK: - Live Feed (persistent scrolling timeline during execution)

    private var liveFeedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary header — always visible, shows running count
            HStack(spacing: StudioSpacing.md) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(StudioAccentColor.primary)
                    .symbolEffect(.pulse, options: .repeating, isActive: true)

                Text(liveSummaryLabel)
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(StudioTextColor.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, StudioSpacing.xs)

            // Scrolling step feed — all steps visible, auto-scrolls to newest
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            StreamStepRow(
                                step: step,
                                isActive: step.id == activeStepID || step.status == .active,
                                showsConnector: index < steps.count - 1
                            )
                            .id(step.id)
                            .transition(.studioFadeLift)
                        }
                    }
                    .padding(.leading, StudioSpacing.xs)
                }
                .frame(maxHeight: Self.maxLiveHeight)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.06),
                            .init(color: .black, location: 0.94),
                            .init(color: .black, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onChange(of: steps.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(steps.last?.id, anchor: .bottom)
                    }
                }
                .onChange(of: activeStepID) { _, newID in
                    if let newID {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(newID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .animation(StudioMotion.standardSpring, value: steps.map(\.id))
    }

    private var liveSummaryLabel: String {
        let done = completedSteps.count
        let total = steps.count
        if done == 0 { return "Working…" }
        return "\(done) of \(total) step\(total == 1 ? "" : "s") completed"
    }

    // MARK: - Settled View (collapsed summary after stream ends)

    private var settledView: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.sm) {
            if !completedSteps.isEmpty {
                Button {
                    withAnimation(StudioMotion.standardSpring) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: StudioSpacing.md) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(StudioTypography.badge)
                            .foregroundStyle(StudioTextColor.tertiary)

                        Text(summaryLabel)
                            .font(StudioTypography.captionMedium)
                            .foregroundStyle(StudioTextColor.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, StudioSpacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                        ForEach(Array(completedSteps.enumerated()), id: \.element.id) { index, step in
                            StreamStepRow(
                                step: step,
                                isActive: false,
                                showsConnector: index < completedSteps.count - 1
                            )
                            .transition(.studioCollapse)
                        }
                    }
                    .padding(.leading, StudioSpacing.section)
                }
            }
        }
    }
}

struct StreamStepRow: View {

    let step: StreamStep
    let isActive: Bool
    let showsConnector: Bool

    @Environment(\.streamDeepLinkRouter) private var streamDeepLinkRouter
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: StudioSpacing.lg) {
            timelineRail

            VStack(alignment: .leading, spacing: 0) {
                stepHeader

                if let actionLabel = deepLinkActionLabel, let deepLink = step.deepLink {
                    Button(actionLabel) {
                        streamDeepLinkRouter?.navigate(deepLink)
                    }
                    .buttonStyle(.plain)
                    .font(StudioTypography.microMedium)
                    .foregroundStyle(StudioTextColor.secondary)
                    .padding(.top, StudioSpacing.xs)
                    .padding(.bottom, isExpanded && canExpandInline ? 4 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isExpanded && canExpandInline {
                    stepOutput
                        .transition(.studioCollapse)
                }
            }
        }
        .animation(StudioMotion.standardSpring, value: isExpanded)
        .onChange(of: step.status) { _, newValue in
            guard newValue != .active, isExpanded else { return }
            withAnimation(StudioMotion.softFade) {
                isExpanded = false
                showAllOutput = false
            }
        }
    }

    private var timelineRail: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(StudioTextColor.tertiary.opacity(isActive ? 0.18 : 0.12))
                    .frame(width: 20, height: 20)

                stepStatusIcon
            }

            if showsConnector {
                Rectangle()
                    .fill(StudioTextColor.tertiary.opacity(0.18))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.top, StudioSpacing.xxs)
                    .padding(.bottom, -6)
            }
        }
        .frame(width: 20)
    }

    private var stepHeader: some View {
        Button {
            if canExpandInline {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .top, spacing: StudioSpacing.md) {
                VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus) {
                    Text(step.title)
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(isActive ? StudioTextColor.primary : StudioTextColor.secondary)
                        .lineLimit(1)

                    if let target = step.target, !target.isEmpty, target != "." {
                        Text(target)
                            .font(StudioTypography.codeSmallMedium)
                            .foregroundStyle(StudioTextColor.tertiary)
                            .lineLimit(1)
                    }

                    if let preview = collapsedPreviewText {
                        Text(preview)
                            .font(StudioTypography.caption)
                            .foregroundStyle(StudioTextColor.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                stepDurationView

                if canExpandInline {
                    Image(systemName: "chevron.right")
                        .font(StudioTypography.badge)
                        .foregroundStyle(StudioTextColor.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.vertical, StudioSpacing.xs)
        }
        .buttonStyle(.plain)
        .shimmer(isActive: isActive)
    }

    private var collapsedPreviewText: String? {
        guard !isExpanded else { return nil }
        if let preview = step.previewText, !preview.isEmpty {
            return preview
        }
        return step.outputLines.last?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nonEmptyOutputLines: [String] {
        step.outputLines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canExpandInline: Bool {
        if step.outputLines.isEmpty { return false }
        if step.totalOutputLineCount > StreamStep.collapsedInlineOutputLines { return true }
        if nonEmptyOutputLines.count >= 2 { return true }
        guard let firstLine = nonEmptyOutputLines.first else { return false }
        return firstLine.count > 100
    }

    private var shouldHintExternalDetail: Bool {
        step.totalOutputLineCount > step.outputLines.count
    }

    private var deepLinkActionLabel: String? {
        guard let deepLink = step.deepLink, streamDeepLinkRouter != nil else { return nil }

        switch deepLink {
        case .inspector:
            if step.status == .failed {
                return "View Details"
            }
            return shouldHintExternalDetail ? "Open Inspector" : nil

        case .file, .screenshot:
            return "Open Artifact"
        }
    }

    @ViewBuilder
    private var stepStatusIcon: some View {
        switch step.status {
        case .active:
            Image(systemName: activeSymbolName)
                .font(StudioTypography.microSemibold)
                .foregroundStyle(StudioTextColor.secondary)

        case .completed:
            Image(systemName: activeSymbolName)
                .font(StudioTypography.microSemibold)
                .foregroundStyle(StudioTextColor.tertiary)

        case .failed:
            Image(systemName: StudioSymbol.resolve("exclamationmark.circle", "xmark.circle"))
                .font(StudioTypography.microSemibold)
                .foregroundStyle(StudioTextColor.secondary)

        case .skipped:
            Image(systemName: "circle")
                .font(StudioTypography.microSemibold)
                .foregroundStyle(StudioTextColor.tertiary)
        }
    }

    private var activeSymbolName: String {
        switch step.kind {
        case .search:
            return StudioSymbol.resolve("magnifyingglass", "doc.text")
        case .read:
            return StudioSymbol.resolve("doc.viewfinder", "doc.text")
        case .write:
            return StudioSymbol.resolve("doc.badge.plus", "square.and.arrow.down")
        case .edit:
            return StudioSymbol.resolve("pencil.line", "square.and.pencil")
        case .build:
            return StudioSymbol.resolve("hammer", "wrench.and.screwdriver")
        case .terminal:
            return StudioSymbol.resolve("apple.terminal", "terminal")
        case .delegation:
            return StudioSymbol.resolve("scope", "person.2")
        case .deploy:
            return StudioSymbol.resolve("paperplane", "arrow.up.right")
        case .screenshot:
            return StudioSymbol.resolve("camera.viewfinder", "camera")
        case .other:
            return "circle.dashed"
        }
    }

    @State private var showAllOutput = false
    @State private var hasCopiedOutput = false

    @ViewBuilder
    private var stepDurationView: some View {
        if let completed = step.completedAt {
            Text(formatDuration(completed.timeIntervalSince(step.startedAt)))
                .font(StudioTypography.monoDigitsSmall)
                .foregroundStyle(StudioTextColor.tertiary.opacity(0.72))
        } else if step.status == .active {
            TimelineView(.periodic(from: step.startedAt, by: 1.0)) { context in
                Text(formatDuration(context.date.timeIntervalSince(step.startedAt)))
                    .font(StudioTypography.monoDigitsSmall)
                    .foregroundStyle(StudioTextColor.tertiary.opacity(0.72))
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 10 { return String(format: "%.1fs", s) }
        if s < 60 { return "\(Int(s))s" }
        let m = Int(s / 60)
        let rem = Int(s) % 60
        return "\(m)m \(rem)s"
    }

    private func copyOutputToClipboard() {
        let text = step.outputLines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hasCopiedOutput = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            hasCopiedOutput = false
        }
    }

    private var stepOutput: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cmd = step.displayCommand, !cmd.isEmpty, cmd != (step.target ?? "") {
                HStack(spacing: StudioSpacing.xs) {
                    Text("$")
                        .font(StudioTypography.dataMicro)
                        .foregroundStyle(StudioTextColor.tertiary.opacity(0.6))
                    Text(cmd)
                        .font(StudioTypography.dataMicro)
                        .foregroundStyle(StudioTextColor.secondary.opacity(0.9))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, StudioSpacing.lg)
                .padding(.top, StudioSpacing.sm)
                .padding(.bottom, StudioSpacing.xxs)
            }
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !showAllOutput && step.totalOutputLineCount > StreamStep.collapsedInlineOutputLines {
                        Text("\(step.totalOutputLineCount - StreamStep.collapsedInlineOutputLines) earlier lines hidden")
                            .font(StudioTypography.badgeSmallMono)
                            .foregroundStyle(StudioTextColor.tertiary.opacity(0.6))
                            .padding(.bottom, StudioSpacing.xxs)
                    }
                    if shouldHintExternalDetail {
                        Text("Showing recent output only. Full detail lives in the Session Log.")
                            .font(StudioTypography.badgeSmall)
                            .foregroundStyle(StudioTextColor.tertiary.opacity(0.72))
                            .padding(.bottom, StudioSpacing.xs)
                    }
                    ForEach(Array(displayedLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(StudioTypography.dataMicro)
                            .foregroundStyle(StudioTextColor.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, StudioSpacing.lg)
                .padding(.vertical, StudioSpacing.sm)
            }
            .frame(maxHeight: showAllOutput ? 220 : 96)

            if step.outputLines.count > StreamStep.collapsedInlineOutputLines {
                Button {
                    withAnimation(StudioMotion.standardSpring) {
                        showAllOutput.toggle()
                    }
                } label: {
                    Text(showAllOutput ? "Show less" : "Show more recent output")
                        .font(StudioTypography.badgeSmallMono)
                        .foregroundStyle(StudioTextColor.secondary)
                        .padding(.horizontal, StudioSpacing.lg)
                        .padding(.vertical, StudioSpacing.xs)
                }
                .buttonStyle(.plain)
            }
            if !step.outputLines.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Button {
                        copyOutputToClipboard()
                    } label: {
                        Image(systemName: hasCopiedOutput ? "checkmark" : "doc.on.doc")
                            .font(StudioTypography.badge)
                            .foregroundStyle(hasCopiedOutput ? StudioStatusColor.success : StudioTextColor.tertiary)
                            .padding(.trailing, StudioSpacing.lg)
                            .padding(.vertical, StudioSpacing.xs)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(step.kind == .terminal || step.kind == .build ? StudioSurface.viewport : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous))
        .padding(.leading, StudioSpacing.xxs)
        .padding(.bottom, StudioSpacing.sm)
    }

    private var displayedLines: [String] {
        showAllOutput
            ? step.outputLines
            : Array(step.outputLines.suffix(StreamStep.collapsedInlineOutputLines))
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Error Card
// ═══════════════════════════════════════════════════════════════════════════════

struct StreamErrorCard: View {

    let error: StreamError

    var body: some View {
        HStack(alignment: .top, spacing: StudioSpacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(StudioStatusColor.danger)

            VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                Text("Error")
                    .font(StudioTypography.captionSemibold)
                    .foregroundStyle(StudioTextColor.primary)

                Text(error.message)
                    .font(StudioTypography.footnote)
                    .foregroundStyle(StudioTextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if error.isRecoverable {
                    Text("This error may be recoverable. Try again.")
                        .font(StudioTypography.captionMedium)
                        .foregroundStyle(StudioTextColor.tertiary)
                        .padding(.top, StudioSpacing.xxs)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(StudioSpacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
    }
}
