// DashboardViews.swift
// Studio.92 — Command Center

import SwiftUI

struct AgenticSuggestion: Identifiable, Hashable {
    let id: String
    let title: String
    let prompt: String
    let symbolName: String
    var templateDescription: String?

    var isTemplate: Bool { templateDescription != nil }
}

struct ThreadEmptyState: View {

    let project: AppProject?
    let allProjects: [AppProject]
    let jobs: [AgentSession]
    let isPipelineRunning: Bool
    let repositoryState: GitRepositoryState?
    let isRefreshingRepository: Bool
    let suggestions: [AgenticSuggestion]
    let onSelectSuggestion: (AgenticSuggestion) -> Void
    let onLaunchPrompt: (String) -> Void
    let onSelectProject: (UUID) -> Void
    let onSelectJob: (UUID) -> Void
    let onOpenArtifact: (UUID?, ArtifactCanvasLaunchMode) -> Void
    let onRefreshRepository: () -> Void
    let onInitializeRepository: () -> Void
    let onOpenWorkspace: () -> Void

    private var latestEpoch: Epoch? {
        project?.sortedEpochs.last
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

    private var repositoryReviewPrompt: String {
        "Review the current workspace diff, inspect the changed files, and call out bugs, regressions, and missing tests before we merge."
    }

    private var activeJobNames: Set<String> {
        Set(jobs.compactMap { session in
            switch session.status {
            case .queued, .preparing, .running, .reviewing:
                return session.branchName
            case .completed, .failed, .cancelled:
                return nil
            }
        })
    }

    private var insights: [Insight] {
        StudioInsightEngine.evaluate(
            projects: allProjects,
            activeJobProjectNames: activeJobNames
        )
    }

    private var automationProposals: [AutomationProposal] {
        StudioAutomationEngine.evaluate(
            projects: allProjects,
            insights: insights,
            activeJobProjectNames: activeJobNames,
            isPipelineRunning: isPipelineRunning,
            preferences: AutomationPreferenceStore.shared
        )
    }

    var body: some View {
        // Empty state — the centered command bar in ExecutionPaneView serves
        // as the sole call-to-action. No redundant placeholder text needed.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    private var dashboardRepositorySection: some View {
        DashboardSection(
            title: "Git Status",
            subtitle: repositorySubtitle,
            systemImage: "point.topleft.down.curvedto.point.bottomright.up"
        ) {
            VStack(alignment: .leading, spacing: StudioSpacing.xl) {
                if let repositoryState, repositoryState.phase == .ready {
                    Text(repositoryState.branchDisplayName)
                        .font(StudioTypography.dataCaption)
                        .foregroundStyle(StudioTextColor.primary)

                    HStack(spacing: StudioSpacing.md) {
                        Text("\(repositoryState.changeSummary.totalCount) pending change\(repositoryState.changeSummary.totalCount == 1 ? "" : "s")")
                        Text("•")
                        Text("\(repositoryState.worktreeCount) worktree\(repositoryState.worktreeCount == 1 ? "" : "s")")
                        if repositoryState.aheadCount > 0 || repositoryState.behindCount > 0 {
                            Text("•")
                            Text("↑\(repositoryState.aheadCount) ↓\(repositoryState.behindCount)")
                        }
                    }
                    .font(StudioTypography.dataMicro)
                    .foregroundStyle(StudioTextColor.secondary.opacity(0.82))

                    Text(repositoryState.detailMessage)
                        .font(StudioTypography.caption)
                        .foregroundStyle(StudioTextColor.secondary.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)

                    DashboardActionButton(
                        title: "Launch Review",
                        systemImage: "doc.text.magnifyingglass",
                        isProminent: true,
                        isDisabled: isPipelineRunning
                    ) {
                        onLaunchPrompt(repositoryReviewPrompt)
                    }
                } else {
                    Text(repositoryState?.detailMessage ?? "Select a workspace so Studio.92 can inspect branch health and launch a review thread.")
                        .font(StudioTypography.caption)
                        .foregroundStyle(StudioTextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: StudioSpacing.md) {
                        DashboardActionButton(
                            title: "Open Workspace",
                            systemImage: "folder.badge.plus",
                            isDisabled: false,
                            action: onOpenWorkspace
                        )

                        if repositoryState?.phase == .notRepository {
                            DashboardActionButton(
                                title: "Init Git",
                                systemImage: "shippingbox",
                                isDisabled: false,
                                action: onInitializeRepository
                            )
                        }
                    }
                }
            }
        }
    }

    private var dashboardJobsSection: some View {
        DashboardSection(
            title: "Active Worktrees",
            subtitle: activeJobs.isEmpty ? "Background rail is clear" : "\(activeJobs.count) sessions in flight",
            systemImage: "gearshape.2"
        ) {
            VStack(alignment: .leading, spacing: StudioSpacing.xl) {
                if activeJobs.isEmpty {
                    Text("Queued and running worktrees will surface here with quick entry back into their review threads.")
                        .font(StudioTypography.caption)
                        .foregroundStyle(StudioTextColor.secondary.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: StudioSpacing.md) {
                        ForEach(Array(activeJobs.prefix(2))) { job in
                            Button {
                                onSelectJob(job.id)
                            } label: {
                                FleetJobRow(session: job, isSelected: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let firstJob = activeJobs.first {
                        DashboardActionButton(
                            title: "Open Latest Job",
                            systemImage: "arrow.right.circle",
                            isDisabled: false
                        ) {
                            onSelectJob(firstJob.id)
                        }
                    }
                }
            }
        }
    }

    private var dashboardUtilitiesSection: some View {
        let hasTemplates = suggestions.contains(where: { $0.isTemplate })
        return DashboardSection(
            title: hasTemplates ? "Launchpad" : "Utilities",
            subtitle: hasTemplates ? "One-click session templates" : "Launch focused workflows",
            systemImage: hasTemplates ? "square.grid.2x2" : "sparkles"
        ) {
            VStack(spacing: StudioSpacing.lg) {
                ForEach(Array(suggestions.prefix(5))) { suggestion in
                    DashboardUtilityButton(
                        suggestion: suggestion,
                        isDisabled: isPipelineRunning
                    ) {
                        onSelectSuggestion(suggestion)
                        onLaunchPrompt(suggestion.prompt)
                    }
                }
            }
        }
    }

    private var dashboardViewportSection: some View {
        DashboardSection(
            title: "Recent Output",
            subtitle: latestEpoch == nil ? "Viewport is standing by" : "Open the latest artifact instantly",
            systemImage: "iphone.gen3"
        ) {
            VStack(alignment: .leading, spacing: StudioSpacing.xl) {
                if let latestEpoch {
                    Text(latestEpoch.summary)
                        .font(StudioTypography.caption)
                        .foregroundStyle(StudioTextColor.secondary.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: StudioSpacing.md) {
                        DashboardActionButton(
                            title: "Preview",
                            systemImage: "play.rectangle.on.rectangle",
                            isDisabled: false
                        ) {
                            onOpenArtifact(latestEpoch.id, .preview)
                        }

                        DashboardActionButton(
                            title: "Diff",
                            systemImage: "sidebar.right",
                            isDisabled: false
                        ) {
                            onOpenArtifact(latestEpoch.id, .codeDiff)
                        }
                    }
                } else {
                    Text("The viewport will lock onto your latest simulator frame or archived artifact as soon as the first run lands.")
                        .font(StudioTypography.caption)
                        .foregroundStyle(StudioTextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    DashboardActionButton(
                        title: "Open Workspace",
                        systemImage: "folder",
                        isDisabled: false,
                        action: onOpenWorkspace
                    )
                }
            }
        }
    }

    private var repositorySubtitle: String {
        guard let repositoryState else { return "Workspace needed" }
        if isRefreshingRepository {
            return "Refreshing repository state"
        }

        switch repositoryState.phase {
        case .ready:
            return repositoryState.repositoryDisplayName
        case .loading:
            return "Reading workspace state"
        case .notRepository:
            return "Git not initialized"
        case .missingWorkspace:
            return "Workspace missing"
        case .failed:
            return "Repository check failed"
        }
    }
}

struct DashboardSection<Content: View>: View {

    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.xxl) {
            HStack(alignment: .top, spacing: StudioSpacing.lg) {
                Image(systemName: systemImage)
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(StudioTextColor.tertiary)

                VStack(alignment: .leading, spacing: StudioSpacing.xs) {
                    Text(title)
                        .font(StudioTypography.bodySemibold)
                        .foregroundStyle(StudioTextColor.primary)

                    Text(subtitle)
                        .font(StudioTypography.dataMicro)
                        .tracking(1.4)
                        .foregroundStyle(StudioTextColor.tertiary)
                        .lineLimit(1)
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ExecutionSmokedGlassCard: View {

    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(StudioSurfaceGrouped.primary)
    }
}

struct ExecutionSpecularStroke: View {

    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(StudioSeparator.subtle, lineWidth: 1)
    }
}

struct DashboardActionButton: View {

    let title: String
    let systemImage: String
    var isProminent = false
    var isDisabled = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioSpacing.md) {
                Image(systemName: systemImage)
                    .font(StudioTypography.captionSemibold)
                Text(title)
                    .font(StudioTypography.captionMedium)
            }
            .font(StudioTypography.captionMedium)
            .foregroundStyle(StudioTextColor.primary.opacity(isHovered ? 1.0 : (isProminent ? 0.96 : 0.84)))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1.0)
        .onHover { isHovered = $0 }
    }
}

struct DashboardUtilityButton: View {

    let suggestion: AgenticSuggestion
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioSpacing.xl) {
                Image(systemName: suggestion.symbolName)
                    .font(StudioTypography.subheadlineMedium)
                    .foregroundStyle(StudioTextColor.secondary)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: StudioSpacing.xxsPlus) {
                    Text(suggestion.title)
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(StudioTextColor.primary)

                    Text(suggestion.templateDescription ?? suggestion.prompt)
                        .font(StudioTypography.micro)
                        .foregroundStyle(StudioTextColor.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(StudioTypography.microSemibold)
                    .foregroundStyle(StudioTextColor.tertiary)
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                    .fill(isHovered ? StudioSurfaceGrouped.primary : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1.0)
        .onHover { isHovered = $0 }
    }

}

struct FactoryHeroGraphic: View {

    private static let bundledHeroImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "studio92-hero", withExtension: "jpg") {
            return NSImage(contentsOf: url)
        }
        return nil
    }()

    var body: some View {
        Group {
            if let heroImage = Self.bundledHeroImage {
                Image(nsImage: heroImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
            } else {
                ZStack {
                    Circle()
                        .fill(StudioSurfaceElevated.level1)

                    ZStack {
                        Image(systemName: "cpu")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(StudioTextColor.secondary)

                        Image(systemName: "hammer")
                            .font(StudioTypography.headline)
                            .foregroundStyle(StudioTextColor.secondary)
                            .offset(x: 23, y: 23)
                    }
                }
            }
        }
        .frame(width: 132, height: 132)
    }
}

struct AgenticSuggestionPill: View {

    let suggestion: AgenticSuggestion
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudioSpacing.lg) {
                Image(systemName: suggestion.symbolName)
                    .font(StudioTypography.headline)
                    .foregroundStyle(StudioTextColor.secondary)

                Text(suggestion.title)
                    .font(StudioTypography.subheadlineMedium)
                    .foregroundStyle(StudioTextColor.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, StudioSpacing.section)
            .padding(.vertical, StudioSpacing.lg)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.xl, style: .continuous)
                    .fill(isHovered ? StudioSurfaceGrouped.secondary : StudioSurfaceElevated.level1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(StudioMotion.fastSpring, value: isHovered)
    }
}

