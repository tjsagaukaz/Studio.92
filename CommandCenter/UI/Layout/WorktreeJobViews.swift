// WorktreeJobViews.swift
// Studio.92 — Command Center

import SwiftUI

struct WorktreeJobDetailPane: View {

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
                VStack(alignment: .leading, spacing: StudioSpacing.section) {
                    WorktreeContextBanner(session: session)
                    WorktreeJobSummaryCard(session: session)
                    WorktreeCommentaryCard(session: session)
                    WorktreeEventLogCard(events: session.eventLog)
                }
                .padding(StudioSpacing.columnPad)
            }
            .frame(minWidth: 340, idealWidth: 420)
            .background(StudioCanvasView())

            ScrollView {
                VStack(alignment: .leading, spacing: StudioSpacing.section) {
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
                .padding(StudioSpacing.columnPad)
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

struct WorktreeContextBanner: View {

    let session: AgentSession

    private var statusColor: Color {
        switch session.status {
        case .queued:
            return StudioTextColor.secondary
        case .preparing, .running:
            return StudioAccentColor.primary
        case .reviewing:
            return StudioStatusColor.warning
        case .completed:
            return StudioStatusColor.success
        case .failed, .cancelled:
            return StudioStatusColor.danger
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: StudioSpacing.xl) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                Text("Background Worktree")
                    .font(StudioTypography.dataCaption)
                    .foregroundStyle(StudioTextColor.secondary)

                Text("\(session.status.title) on \(session.branchName)")
                    .font(StudioTypography.title)
                    .foregroundStyle(StudioTextColor.primary)
            }

            Spacer(minLength: 12)

            ReferenceBadge(
                title: session.modelDisplayName,
                systemImage: "brain",
                style: .tinted
            )
        }
        .padding(StudioSpacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }
}

struct WorktreeJobSummaryCard: View {

    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxl) {
            HStack(alignment: .top, spacing: StudioSpacing.xl) {
                VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                    Text("Task")
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(StudioTextColor.secondary)

                    Text(session.taskPrompt)
                        .font(StudioTypography.headlineMedium)
                        .foregroundStyle(StudioTextColor.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.worktreePath)])
                } label: {
                    HStack(spacing: StudioSpacing.sm) {
                        Image(systemName: "folder")
                        Text("Reveal Worktree")
                    }
                    .font(StudioTypography.footnoteMedium)
                    .padding(.horizontal, StudioSpacing.lg)
                    .padding(.vertical, StudioSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                            .fill(StudioSurfaceElevated.level1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                            .stroke(StudioSeparator.subtle, lineWidth: 1)
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

            VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                Text("Execution Directory")
                    .font(StudioTypography.codeSmallMedium)
                    .foregroundStyle(StudioTextColor.tertiary)

                Text(session.executionDirectoryPath)
                    .font(StudioTypography.codeSmallMedium)
                    .foregroundStyle(StudioTextColor.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(StudioSpacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }
}

struct WorktreeCommentaryCard: View {

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
        VStack(alignment: .leading, spacing: StudioSpacing.xl) {
            HStack {
                Text("Review Thread")
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColor.secondary)
                Spacer()
                if let reviewThread = session.reviewThread {
                    Text(reviewThread.updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(StudioTypography.monoDigits)
                        .foregroundStyle(StudioTextColor.tertiary)
                }
            }

            MarkdownMessageContent(
                text: commentary,
                isStreaming: session.status == .running || session.status == .reviewing,
                isPipelineRunning: false
            )
        }
        .padding(StudioSpacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }
}

struct WorktreeEventLogCard: View {

    let events: [String]

    private var visibleEvents: [String] {
        Array(events.suffix(16))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xl) {
            Text("Session Log")
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(StudioTextColor.secondary)

            if visibleEvents.isEmpty {
                Text("No session events yet.")
                    .font(StudioTypography.dataCaption)
                    .foregroundStyle(StudioTextColor.tertiary)
            } else {
                VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                    ForEach(Array(visibleEvents.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(StudioTypography.dataCaption)
                            .foregroundStyle(StudioTextColor.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(StudioSpacing.xxl)
                .background(
                    RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                        .fill(StudioSurface.viewport)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                        .stroke(StudioSeparator.subtle, lineWidth: 1)
                )
            }
        }
        .padding(StudioSpacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }
}

struct WorktreeDiffNavigator: View {

    let contexts: [ReviewDiffContext]
    @Binding var selectedDiffID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.lg) {
            HStack {
                Text("Changed Files")
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColor.secondary)
                Spacer()
                if !contexts.isEmpty {
                    Text("\(contexts.count)")
                        .font(StudioTypography.monoDigits)
                        .foregroundStyle(StudioTextColor.tertiary)
                }
            }

            if contexts.isEmpty {
                Text("No captured diff context yet.")
                    .font(StudioTypography.subheadline)
                    .foregroundStyle(StudioTextColor.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: StudioSpacing.md) {
                        ForEach(contexts) { context in
                            Button {
                                selectedDiffID = context.id
                            } label: {
                                HStack(spacing: StudioSpacing.md) {
                                    Image(systemName: "doc.text")
                                        .font(StudioTypography.footnoteSemibold)
                                    VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                                        Text((context.path as NSString).lastPathComponent)
                                            .font(StudioTypography.footnoteSemibold)
                                            .lineLimit(1)
                                        Text(context.changeSummary)
                                            .font(StudioTypography.dataMicro)
                                            .foregroundStyle(StudioTextColor.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, StudioSpacing.lg)
                                .padding(.vertical, StudioSpacing.md)
                                .background(
                                    RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                                        .fill(selectedDiffID == context.id ? StudioSurfaceElevated.level2 : StudioSurfaceGrouped.primary)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: StudioRadius.lg, style: .continuous)
                                        .stroke(selectedDiffID == context.id ? StudioTextColor.primary.opacity(0.10) : StudioSeparator.subtle, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(StudioSpacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }
}

struct WorktreeDiffCard: View {

    let context: ReviewDiffContext

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxl) {
            HStack(alignment: .top, spacing: StudioSpacing.xl) {
                VStack(alignment: .leading, spacing: StudioSpacing.sm) {
                    Text((context.path as NSString).lastPathComponent)
                        .font(StudioTypography.titleLarge)
                        .foregroundStyle(StudioTextColor.primary)
                    Text(context.path)
                        .font(StudioTypography.codeSmallMedium)
                        .foregroundStyle(StudioTextColor.secondary)
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
                    .font(StudioTypography.codeSmallMedium)
                    .foregroundStyle(StudioTextColor.tertiary)
                    .textSelection(.enabled)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(context.diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No diff text captured." : context.diffText)
                    .font(StudioTypography.codeSemibold)
                    .lineSpacing(2)
                    .foregroundStyle(StudioTextColor.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(StudioSpacing.section)
            }
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .fill(StudioSurface.viewport)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .stroke(StudioSeparator.subtle, lineWidth: 1)
            )
        }
        .padding(StudioSpacing.section)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }
}

struct WorktreeDiffEmptyState: View {

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
        VStack(alignment: .leading, spacing: StudioSpacing.xl) {
            Text("No Diff Yet")
                .font(StudioTypography.titleLarge)
                .foregroundStyle(StudioTextColor.primary)

            Text(message)
                .font(StudioTypography.subheadline)
                .foregroundStyle(StudioTextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudioSpacing.sectionGap)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }
}

/// Horizontal scrubber of epoch cards.
struct EpochScrubber: View {

    let epochs: [Epoch]
    @Binding var selectedEpochID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: StudioSpacing.md) {
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
            .padding(.horizontal, StudioSpacing.xl)
            .padding(.vertical, StudioSpacing.md)
        }
        .background(StudioSurface.viewport)
        .environment(\.colorScheme, .dark)
    }
}

/// A single epoch card in the scrubber.
struct EpochCard: View {

    let epoch: Epoch
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xs) {
            HStack {
                Text("E\(epoch.index)")
                    .font(StudioTypography.monoDigits)
                Spacer()
                if let archetype = epoch.archetype {
                    Text(archetype)
                        .font(StudioTypography.caption)
                        .tracking(0.3)
                        .foregroundStyle(StudioTextColor.secondary)
                }
            }

            Text(epoch.summary)
                .font(StudioTypography.footnote)
                .foregroundStyle(StudioTextColor.primary)
                .lineLimit(2)

            Spacer()

            HStack(spacing: StudioSpacing.md) {
                MetricPill(label: "HIG", value: String(format: "%.0f", epoch.higScore * 100))
                MetricPill(label: "Cost", value: String(format: "%.0f", epoch.deviationCost * 100))
                if epoch.driftScore > 0.20 {
                    MetricPill(label: "Drift", value: String(format: "%.0f", epoch.driftScore * 100))
                }
            }
        }
        .padding(StudioSpacing.md)
        .frame(width: 180, height: 100)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.sm)
                .fill(isSelected ? StudioSurfaceElevated.level2 : StudioSurfaceElevated.level1)
        )
    }
}

/// Tiny metric pill (e.g., "HIG 91").
struct MetricPill: View {

    let label: String
    let value: String

    var body: some View {
        HStack(spacing: StudioSpacing.xxs) {
            Text(label)
                .font(StudioTypography.badgeSmallMono)
                .foregroundStyle(StudioTextColor.tertiary)
            Text(value)
                .font(StudioTypography.badgeSmallMono)
                .foregroundStyle(StudioTextColor.secondary)
        }
    }
}

/// Warning banner shown when a project requires human intervention.
struct ManualOverrideBanner: View {

    var body: some View {
        HStack(spacing: StudioSpacing.md) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(StudioStatusColor.warning)
            Text("Manual override required — review before next pipeline run")
                .font(StudioTypography.subheadline)
                .foregroundStyle(StudioTextColor.secondary)
            Spacer()
            // TODO: Add "Acknowledge" button that clears requiresHumanOverride
        }
        .padding(StudioSpacing.lg)
        .background(StudioStatusColor.warningSurface)
    }
}

struct BackgroundJobPersistenceBanner: View {

    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: StudioSpacing.xl) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(StudioTypography.bodySemibold)
                .foregroundStyle(StudioStatusColor.warning)

            VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                Text("Background Job Save Failed")
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColor.primary)

                Text(message)
                    .font(StudioTypography.footnoteMedium)
                    .foregroundStyle(StudioTextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(StudioSpacing.xxl)
        .frame(maxWidth: 760, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .fill(StudioStatusColor.warningSurface.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .stroke(Color.clear, lineWidth: 1)
        )
    }
}

