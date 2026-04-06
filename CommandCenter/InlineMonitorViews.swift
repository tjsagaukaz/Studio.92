// InlineMonitorViews.swift
// Studio.92 — CommandCenter
//
// Reasoning HUD, inline terminal strip, and inline task plan strip.

import SwiftUI

// MARK: - Reasoning HUD

/// Top-left telemetry HUD that surfaces live AI reasoning outside the chat column.
/// Resolves upward into place on `.thinking`, fades + scales out when execution begins.
struct ReasoningHUD: View {

    let controller: StreamPhaseController

    /// Visible while reasoning text is available and the stream is still active.
    private var isVisible: Bool {
        let hasText = !controller.thinkingText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch controller.phase {
        case .thinking, .intent, .planning, .executing:
            return hasText
        default:
            return false
        }
    }

    /// All non-empty reasoning lines, keyed for identity.
    private var allLines: [ReasoningLine] {
        let raw = controller.thinkingText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let parts = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.enumerated().map { ReasoningLine(index: $0.offset, text: $0.element) }
    }

    var body: some View {
        if isVisible {
            HUDScrollCard(lines: allLines)
                .transition(
                    .asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(y: 10))
                            .animation(.easeOut(duration: 0.28)),
                        removal: .opacity
                            .combined(with: .scale(scale: 0.97))
                            .animation(.easeIn(duration: 0.22))
                    )
                )
        }
    }
}

/// Stable identity for a reasoning line so ScrollViewReader can target it.
private struct ReasoningLine: Identifiable, Equatable {
    let index: Int
    let text: String
    var id: Int { index }
}

private struct HUDScrollCard: View {

    let lines: [ReasoningLine]

    /// Maximum visible lines before the card reaches its height cap.
    private static let visibleLineCount = 7

    @State private var iconPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            // Header row
            HStack(spacing: StudioSpacing.md) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        StudioAccentColor.primary.opacity(iconPulse ? 0.95 : 0.45)
                    )
                    .shadow(color: StudioAccentColor.primary.opacity(iconPulse ? 0.5 : 0.0), radius: 4)
                    .onAppear {
                        withAnimation(StudioMotion.breathe) { iconPulse = true }
                    }

                Text("Reasoning")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .tracking(0.5)

                Spacer(minLength: 0)

                // Live pulse badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(StudioAccentColor.primary.opacity(iconPulse ? 0.85 : 0.3))
                        .frame(width: 4, height: 4)
                    Text("live")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(StudioAccentColor.primary.opacity(0.55))
                }
            }

            // Scrolling reasoning ticker — shows up to 7 lines, auto-scrolls to newest.
            if !lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                            ForEach(lines) { line in
                                Text(line.text)
                                    .reasoningLineStyle(
                                        opacity: lineOpacity(for: line)
                                    )
                                    .id(line.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: CGFloat(Self.visibleLineCount) * 16)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.18),
                                .init(color: .black, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .onChange(of: lines.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(lines.last?.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, StudioSpacing.xxl)
        .padding(.vertical, StudioSpacing.lg)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
    }

    /// Lines closer to the bottom are brighter; top lines fade out.
    private func lineOpacity(for line: ReasoningLine) -> Double {
        guard lines.count > 1 else { return 0.72 }
        let lastIndex = lines.last?.index ?? 0
        let distance = lastIndex - line.index
        // Newest line: 0.72, each step back fades by ~0.08, floor at 0.18
        return max(0.18, 0.72 - Double(distance) * 0.08)
    }
}

private extension Text {
    func reasoningLineStyle(opacity: Double) -> some View {
        self
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(Color(hex: "#7E8794").opacity(opacity))
            .lineLimit(2)
            .truncationMode(.tail)
    }
}

// MARK: - Inline Task Plan Monitor

/// Display-level status for a single step in the inline task plan strip.
enum InlineTaskStepStatus: Equatable {
    case pending
    case active
    case completed
    case failed
    case skipped

    init(streamStatus: StreamPlanStepStatus) {
        switch streamStatus {
        case .pending:    self = .pending
        case .inProgress: self = .active
        case .completed:  self = .completed
        case .skipped:    self = .skipped
        }
    }
}

/// A single step row in the task plan strip.
struct InlineTaskStep: Identifiable, Equatable {
    let id: String
    var title: String
    var status: InlineTaskStepStatus
}

/// Observable state for the inline task plan strip that slides up below the chat column.
/// Fed by StreamPipelineCoordinator whenever a plan is detected or updated.
@MainActor
@Observable
final class InlineTaskPlanMonitor {

    var steps: [InlineTaskStep] = []
    var title: String = "Plan"
    var isRevealed: Bool = false

    func setPlan(_ plan: StreamPlan) {
        title = plan.title.isEmpty ? "Plan" : plan.title
        steps = plan.steps.map {
            InlineTaskStep(id: $0.id, title: $0.title, status: InlineTaskStepStatus(streamStatus: $0.status))
        }
        if !steps.isEmpty {
            isRevealed = true
        }
    }

    func refresh(_ plan: StreamPlan) {
        for i in steps.indices {
            if let src = plan.steps.first(where: { $0.id == steps[i].id }) {
                steps[i].status = InlineTaskStepStatus(streamStatus: src.status)
            }
        }
    }

    private var dismissTask: Task<Void, Never>?

    /// Called when the run completes. Lingers so the user sees all checkmarks, then slides away.
    func finish() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            self.isRevealed = false
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.steps = []
            self.title = "Plan"
        }
    }

    func reset() {
        dismissTask?.cancel()
        dismissTask = nil
        isRevealed = false
        steps = []
        title = "Plan"
    }
}

// MARK: - Inline Terminal Monitor

/// Lightweight terminal state for the slide-up strip below the chat column.
/// Fed by StreamPipelineCoordinator alongside the viewport terminal model.
@MainActor
@Observable
final class InlineTerminalMonitor {

    var command: String = ""
    var lines: [String] = []
    var isRunning: Bool = false
    var isRevealed: Bool = false

    private var dismissTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?

    /// Maximum lines retained. UI shows only the last few.
    private static let maxLines = 60

    func start(command: String) {
        dismissTask?.cancel()
        dismissTask = nil

        self.command = command
        self.lines = []
        self.isRunning = true

        // Debounce reveal — skip flash for instant commands.
        revealTask?.cancel()
        revealTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self.isRevealed = true
        }
    }

    func appendLine(_ line: String) {
        lines.append(line)
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }

    func updateCommand(_ command: String) {
        self.command = command
    }

    func finish() {
        revealTask?.cancel()
        revealTask = nil
        isRunning = false

        // Linger briefly so the user sees the final output, then slide away.
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            self.isRevealed = false
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.lines = []
            self.command = ""
        }
    }

    func reset() {
        revealTask?.cancel()
        dismissTask?.cancel()
        isRevealed = false
        isRunning = false
        lines = []
        command = ""
    }
}

// MARK: - Inline Terminal Strip View

/// A compact terminal-styled readout that slides up from the bottom
/// of the chat pane when terminal activity is detected.
/// Styled as a dark terminal surface with monospaced output.
struct InlineTerminalStrip: View {

    let monitor: InlineTerminalMonitor

    /// Number of visible output lines.
    private static let visibleLineCount = 6

    var body: some View {
        if monitor.isRevealed {
            VStack(alignment: .leading, spacing: 0) {
                // Title bar
                HStack(spacing: StudioSpacing.md) {
                    // Traffic-light dots (decorative)
                    HStack(spacing: StudioSpacing.xs) {
                        Circle().fill(Color(hex: "#FF5F57")).frame(width: 8, height: 8)
                        Circle().fill(Color(hex: "#FEBC2E")).frame(width: 8, height: 8)
                        Circle().fill(Color(hex: "#28C840")).frame(width: 8, height: 8)
                    }
                    .opacity(0.7)

                    Spacer(minLength: 0)

                    Text("Terminal")
                        .font(StudioTypography.captionMedium)
                        .foregroundStyle(Color.white.opacity(0.4))

                    Spacer(minLength: 0)

                    // Live indicator
                    if monitor.isRunning {
                        HStack(spacing: StudioSpacing.xs) {
                            Circle()
                                .fill(Color(hex: "#28C840"))
                                .frame(width: 5, height: 5)
                            Text("running")
                                .font(StudioTypography.badgeSmallMono)
                                .foregroundStyle(Color(hex: "#28C840").opacity(0.8))
                        }
                    }
                }
                .padding(.horizontal, StudioSpacing.lg)
                .padding(.top, StudioSpacing.md)
                .padding(.bottom, StudioSpacing.sm)

                Divider()
                    .background(Color.white.opacity(0.08))

                // Command prompt line
                HStack(spacing: StudioSpacing.xs) {
                    Text("$")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: "#28C840").opacity(0.9))
                    Text(monitor.command)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, StudioSpacing.lg)
                .padding(.top, StudioSpacing.md)
                .padding(.bottom, StudioSpacing.xs)

                // Output lines — last N
                let tail = monitor.lines.suffix(Self.visibleLineCount)
                if !tail.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(.horizontal, StudioSpacing.lg)
                    .padding(.bottom, StudioSpacing.md)
                    .contentTransition(.numericText())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                    .fill(Color(hex: "#1A1A1E"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
            .transition(.studioBottomLift)
        }
    }
}

// MARK: - Inline Task Plan Strip

/// A frosted task-list strip that slides up below the chat column when a plan is detected.
/// Shows numbered steps with a strikethrough on completed items and a cyan pulse on the active one.
struct InlineTaskPlanStrip: View {

    let monitor: InlineTaskPlanMonitor

    /// How many steps to show before scrolling.
    private static let maxVisibleRows = 6

    var body: some View {
        if monitor.isRevealed {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ──────────────────────────────────────────────────
                HStack(spacing: StudioSpacing.md) {
                    // Cyan task-list icon
                    Image(systemName: "checklist")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioAccentColor.primary.opacity(0.9))

                    Text(monitor.title)
                        .font(StudioTypography.captionMedium)
                        .foregroundStyle(Color.white.opacity(0.55))

                    Spacer(minLength: 0)

                    // Steps progress badge
                    let doneCount = monitor.steps.filter { $0.status == .completed || $0.status == .skipped }.count
                    let totalCount = monitor.steps.count
                    if totalCount > 0 {
                        Text("\(doneCount)/\(totalCount)")
                            .font(StudioTypography.badgeSmallMono)
                            .foregroundStyle(doneCount == totalCount
                                ? StudioAccentColor.primary.opacity(0.8)
                                : Color.white.opacity(0.3))
                            .contentTransition(.numericText())
                            .animation(StudioMotion.fastSpring, value: doneCount)
                    }
                }
                .padding(.horizontal, StudioSpacing.lg)
                .padding(.top, StudioSpacing.md)
                .padding(.bottom, StudioSpacing.xs)

                Divider()
                    .background(Color.white.opacity(0.07))

                // ── Step rows ────────────────────────────────────────────────
                let visible = Array(monitor.steps.prefix(Self.maxVisibleRows))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, step in
                        InlineTaskStepRow(ordinal: index + 1, step: step)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Overflow hint
                    if monitor.steps.count > Self.maxVisibleRows {
                        let extra = monitor.steps.count - Self.maxVisibleRows
                        Text("+ \(extra) more")
                            .font(StudioTypography.micro)
                            .foregroundStyle(Color.white.opacity(0.25))
                            .padding(.horizontal, StudioSpacing.lg)
                            .padding(.vertical, StudioSpacing.xs)
                    }
                }
                .animation(StudioMotion.standardSpring, value: visible.map(\.status))
                .padding(.top, StudioSpacing.xs)
                .padding(.bottom, StudioSpacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                    .fill(Color(hex: "#0F1117"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                    .stroke(StudioAccentColor.primary.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 14, x: 0, y: 5)
            .transition(.studioBottomLift)
        }
    }
}

// MARK: - Inline Task Step Row

private struct InlineTaskStepRow: View {
    let ordinal: Int
    let step: InlineTaskStep

    @State private var activePulse = false

    private var isFinished: Bool { step.status == .completed || step.status == .skipped }
    private var isActive: Bool   { step.status == .active }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: StudioSpacing.md) {

            // Ordinal badge or status icon
            ZStack {
                if isFinished {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StudioAccentColor.primary.opacity(0.7))
                } else if isActive {
                    Circle()
                        .fill(StudioAccentColor.primary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(activePulse ? 1.35 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                            value: activePulse
                        )
                        .onAppear { activePulse = true }
                        .onDisappear { activePulse = false }
                } else {
                    Text("\(ordinal)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.2))
                }
            }
            .frame(width: 14, alignment: .center)

            // Step title
            Text(step.title)
                .font(StudioTypography.footnote)
                .foregroundStyle(
                    isFinished ? Color.white.opacity(0.3) :
                    isActive   ? Color.white.opacity(0.9) :
                                 Color.white.opacity(0.55)
                )
                .strikethrough(isFinished, color: Color.white.opacity(0.2))
                .lineLimit(2)
                .animation(StudioMotion.fastSpring, value: isFinished)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, StudioSpacing.sm)
        .background(
            isActive
                ? StudioAccentColor.primary.opacity(0.04)
                : Color.clear
        )
        .animation(StudioMotion.fastSpring, value: isActive)
    }
}
