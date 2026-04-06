// ExecutionTreeViews.swift
// Studio.92 — Command Center

import SwiftUI

struct ThinkingMessageRow: View {

    let statusLabel: String

    var body: some View {
        ThinkingPulse()
            .accessibilityLabel(Text(statusLabel))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A single breathing dot — Electric Cyan. Anchors the response area while
/// the engine spins up, then hands off to the inline stream cursor.
struct ThinkingPulse: View {

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(StudioAccentColor.primary)
            .frame(width: 6, height: 6)
            .opacity(isPulsing ? 0.95 : 0.35)
            .shadow(color: StudioAccentColor.primary.opacity(isPulsing ? 0.55 : 0.15), radius: 5, x: 0, y: 0)
            .padding(.vertical, StudioSpacing.xl)
            .onAppear {
                withAnimation(StudioMotion.breathe) {
                    isPulsing = true
                }
            }
    }
}

struct ExecutionTreeView: View {

    let steps: [ExecutionStep]
    let timestamp: Date
    let isHighlighted: Bool

    private var summary: ExecutionTreeSummary {
        ExecutionTreeSummary(steps: steps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxl) {
            HStack {
                Label("Factory Run", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColorDark.secondary)
                Spacer()
                ExecutionStatusBadge(status: summary.status)
            }

            Text(summaryText)
                .font(StudioTypography.subheadline)
                .foregroundStyle(StudioTextColorDark.secondary)
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
        .padding(.vertical, StudioSpacing.xs)
        .padding(.horizontal, isHighlighted ? 12 : 0)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xxl, style: .continuous)
                .fill(isHighlighted ? StudioSurfaceElevated.level2.opacity(0.42) : Color.clear)
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

struct OrchestrationPipelineView: View {

    let specialistStatus: StepStatus
    let criticStatus: StepStatus
    let architectStatus: StepStatus
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.lg) {
            HStack(spacing: StudioSpacing.md) {
                Text("Council Review")
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColorDark.secondary)

                Spacer(minLength: 8)

                PipelinePhaseNode(title: "Specialist", status: specialistStatus)
                PipelineConnector(isLit: specialistStatus != .pending)
                PipelinePhaseNode(title: "Critic", status: criticStatus)
                PipelineConnector(isLit: criticStatus != .pending)
                PipelinePhaseNode(title: "Architect", status: architectStatus)
            }

            Text(summary)
                .font(StudioTypography.subheadline)
                .foregroundStyle(StudioTextColorDark.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(StudioSpacing.xl)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }
}

struct PipelinePhaseNode: View {

    let title: String
    let status: StepStatus

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: iconName)
                .font(StudioTypography.captionSemibold)
                .foregroundStyle(iconColor)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .active)

            Text(title)
                .font(StudioTypography.captionSemibold)
                .tracking(0.3)
                .foregroundStyle(StudioTextColorDark.secondary)
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
            return StudioTextColorDark.tertiary
        case .active:
            return StudioAccentColor.primary
        case .completed:
            return StudioStatusColor.success
        case .warning:
            return StudioStatusColor.warning
        case .failed:
            return StudioStatusColor.danger
        }
    }
}

struct PipelineConnector: View {

    let isLit: Bool

    var body: some View {
        Capsule(style: .continuous)
            .fill(isLit ? StudioAccentColor.primary.opacity(0.20) : StudioSurfaceElevated.level2)
            .frame(width: 18, height: 2)
    }
}

struct InlineStageNote: View {

    let title: String
    let systemImage: String
    let status: StepStatus

    var body: some View {
        HStack(spacing: StudioSpacing.md) {
            Image(systemName: systemImage)
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(iconColor)
            Text(title)
                .font(StudioTypography.footnoteSemibold)
                .foregroundStyle(StudioTextColorDark.secondary)
            Spacer()
            ExecutionStatusBadge(status: status)
        }
        .padding(.horizontal, StudioSpacing.xl)
        .padding(.vertical, StudioSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                .stroke(StudioSeparator.subtle, lineWidth: 1)
        )
    }

    private var iconColor: Color {
        switch status {
        case .pending:
            return StudioTextColorDark.tertiary
        case .active:
            return StudioAccentColor.primary
        case .completed:
            return StudioStatusColor.success
        case .warning:
            return StudioStatusColor.warning
        case .failed:
            return StudioStatusColor.danger
        }
    }
}

struct ExecutionStatusBadge: View {

    let status: StepStatus

    var body: some View {
        HStack(spacing: StudioSpacing.sm) {
            Image(systemName: iconName)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .active)
            Text(label)
        }
        .font(StudioTypography.footnoteSemibold)
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, StudioSpacing.lg)
        .padding(.vertical, StudioSpacing.sm)
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
            return StudioTextColorDark.secondary
        case .active:
            return StudioAccentColor.primary
        case .completed:
            return StudioStatusColor.success
        case .warning:
            return StudioStatusColor.warning
        case .failed:
            return StudioStatusColor.danger
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .pending:
            return StudioSurfaceElevated.level2.opacity(0.92)
        case .active:
            return StudioStatusColor.successSurface
        case .completed:
            return StudioStatusColor.success.opacity(0.12)
        case .warning:
            return StudioStatusColor.warning.opacity(0.12)
        case .failed:
            return StudioStatusColor.danger.opacity(0.12)
        }
    }

    private var strokeColor: Color {
        switch status {
        case .pending:
            return Color.clear
        case .active:
            return StudioAccentColor.primary.opacity(0.14)
        case .completed:
            return StudioStatusColor.success.opacity(0.14)
        case .warning:
            return StudioStatusColor.warning.opacity(0.14)
        case .failed:
            return StudioStatusColor.danger.opacity(0.14)
        }
    }
}

struct ExecutionTreeSummary {

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

