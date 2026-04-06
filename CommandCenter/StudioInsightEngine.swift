// StudioInsightEngine.swift
// Studio.92 — Command Center
//
// Behavioral intelligence layer. Evaluates project state and surfaces
// the 2–4 most urgent items that need human attention — calmly, without
// nagging. Insights are ordered by a simple risk score:
//
//   Risk = (Urgency × 0.7) + (MissingInfo × 0.3)
//
// Timing: re-evaluated on app open, data ingest, pipeline completion,
// and whenever the project list changes. Never during active typing.

import SwiftUI

// MARK: - Insight Model

struct Insight: Identifiable, Equatable {

    enum Priority: Int, Comparable {
        case high   = 3
        case medium = 2
        case low    = 1

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum Action: Equatable {
        case selectProject(UUID)
        case reviewProject(UUID)
    }

    let id: UUID
    let projectID: UUID
    let title: String        // Calm microcopy — never shouty
    let subtitle: String     // One-line context
    let symbolName: String
    let priority: Priority
    let action: Action
    let riskScore: Double    // 0.0–1.0 composite, used for sorting
}

// MARK: - Insight Engine

enum StudioInsightEngine {

    /// Maximum insights surfaced at once.
    static let maxSurfaced = 4

    /// Evaluate all projects and return the top insights, sorted by risk.
    static func evaluate(
        projects: [AppProject],
        activeJobProjectNames: Set<String> = [],
        now: Date = Date()
    ) -> [Insight] {
        var insights: [Insight] = []

        for project in projects {
            // Skip projects that are actively running — don't nag mid-pipeline.
            if activeJobProjectNames.contains(project.name) { continue }

            insights.append(contentsOf: evaluate(project: project, now: now))
        }

        // Sort by risk score descending, then by priority as tiebreaker.
        let sorted = insights.sorted { lhs, rhs in
            if lhs.riskScore != rhs.riskScore { return lhs.riskScore > rhs.riskScore }
            return lhs.priority > rhs.priority
        }

        return Array(sorted.prefix(maxSurfaced))
    }

    // MARK: - Per-Project Evaluation

    private static func evaluate(project: AppProject, now: Date) -> [Insight] {
        var results: [Insight] = []

        // Signal 1: Human override required — hard blocker.
        if project.requiresHumanOverride {
            let urgency = 1.0
            let missing = project.primaryRiskLabel == nil ? 0.3 : 0.0
            results.append(Insight(
                id: deterministicID(project.id, suffix: "override"),
                projectID: project.id,
                title: "Needs your input before continuing",
                subtitle: project.secondaryRiskDetail ?? project.primaryRiskLabel ?? "Pipeline paused",
                symbolName: "hand.raised.fill",
                priority: .high,
                action: .reviewProject(project.id),
                riskScore: risk(urgency: urgency, missing: missing)
            ))
        }

        // Signal 2: Critically low confidence.
        if project.confidenceScore < 40 {
            let urgency = Double(40 - project.confidenceScore) / 40.0
            let missing = project.latestCriticVerdict == nil ? 0.3 : 0.0
            results.append(Insight(
                id: deterministicID(project.id, suffix: "confidence"),
                projectID: project.id,
                title: "Confidence is low — may need a review",
                subtitle: project.latestCriticVerdict ?? "Score: \(project.confidenceScore)/100",
                symbolName: "gauge.with.dots.needle.0percent",
                priority: project.confidenceScore < 20 ? .high : .medium,
                action: .reviewProject(project.id),
                riskScore: risk(urgency: urgency, missing: missing)
            ))
        }

        // Signal 3: Deviation budget nearly exhausted.
        if project.deviationBudgetRemaining < 0.15 {
            let urgency = 1.0 - (project.deviationBudgetRemaining / 0.15)
            results.append(Insight(
                id: deterministicID(project.id, suffix: "deviation"),
                projectID: project.id,
                title: "Design latitude is running thin",
                subtitle: "Deviation budget at \(Int(project.deviationBudgetRemaining * 100))%",
                symbolName: "ruler",
                priority: project.deviationBudgetRemaining < 0.05 ? .high : .medium,
                action: .selectProject(project.id),
                riskScore: risk(urgency: urgency, missing: 0.0)
            ))
        }

        // Signal 4: Drift budget nearly exhausted.
        if project.driftBudgetRemaining < 0.15 {
            let urgency = 1.0 - (project.driftBudgetRemaining / 0.15)
            results.append(Insight(
                id: deterministicID(project.id, suffix: "drift"),
                projectID: project.id,
                title: "Paradigm headroom is low",
                subtitle: "Drift budget at \(Int(project.driftBudgetRemaining * 100))%",
                symbolName: "arrow.triangle.branch",
                priority: project.driftBudgetRemaining < 0.05 ? .high : .medium,
                action: .selectProject(project.id),
                riskScore: risk(urgency: urgency, missing: 0.0)
            ))
        }

        // Signal 5: Flow integrity degraded.
        if project.flowIntegrityScore < 0.5 {
            let urgency = 1.0 - (project.flowIntegrityScore / 0.5)
            results.append(Insight(
                id: deterministicID(project.id, suffix: "flow"),
                projectID: project.id,
                title: "Pipeline flow needs attention",
                subtitle: "Integrity at \(Int(project.flowIntegrityScore * 100))%",
                symbolName: "waveform.path.ecg",
                priority: project.flowIntegrityScore < 0.25 ? .high : .medium,
                action: .reviewProject(project.id),
                riskScore: risk(urgency: urgency, missing: 0.0)
            ))
        }

        // Signal 6: Stale project with unresolved risk.
        let hoursSinceActivity = now.timeIntervalSince(project.lastActivityAt) / 3600
        if hoursSinceActivity > 24 && project.primaryRiskLabel != nil {
            let staleness = min(hoursSinceActivity / 72.0, 1.0)
            results.append(Insight(
                id: deterministicID(project.id, suffix: "stale"),
                projectID: project.id,
                title: "Hasn't been touched in a while",
                subtitle: project.primaryRiskLabel ?? "Last active \(Int(hoursSinceActivity))h ago",
                symbolName: "clock.arrow.circlepath",
                priority: .low,
                action: .selectProject(project.id),
                riskScore: risk(urgency: staleness * 0.5, missing: 0.2)
            ))
        }

        return results
    }

    // MARK: - Risk Formula

    private static func risk(urgency: Double, missing: Double) -> Double {
        min((urgency * 0.7) + (missing * 0.3), 1.0)
    }

    // MARK: - Deterministic IDs

    /// Stable ID per project+signal so SwiftUI diffing works across evaluations.
    private static func deterministicID(_ projectID: UUID, suffix: String) -> UUID {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: projectID.uuid) { Data($0) })
        data.append(contentsOf: suffix.utf8)

        // Simple hash → UUID (not cryptographic, just stable).
        var hash: UInt64 = 5381
        for byte in data { hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) }
        var hash2: UInt64 = 0
        for byte in data.reversed() { hash2 = ((hash2 &<< 5) &+ hash2) &+ UInt64(byte) }

        var bytes = withUnsafeBytes(of: hash) { Array($0) }
        bytes.append(contentsOf: withUnsafeBytes(of: hash2) { Array($0) })
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - Insight Row View

/// A single insight row used in the dashboard and sidebar.
/// Calm, non-intrusive: icon + two lines of text, tappable.
struct InsightRow: View {

    let insight: Insight
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: StudioSpacing.xl) {
                Image(systemName: insight.symbolName)
                    .font(StudioTypography.subheadlineMedium)
                    .foregroundStyle(priorityColor)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                    Text(insight.title)
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(StudioTextColor.primary)
                        .lineLimit(1)

                    Text(insight.subtitle)
                        .font(StudioTypography.micro)
                        .foregroundStyle(StudioTextColor.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(StudioTypography.microSemibold)
                    .foregroundStyle(StudioTextColor.tertiary)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, StudioSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                    .fill(isHovered ? StudioSurfaceGrouped.secondary.opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var priorityColor: Color {
        switch insight.priority {
        case .high:   return StudioStatusColor.danger
        case .medium: return StudioStatusColor.warning
        case .low:    return StudioTextColor.secondary
        }
    }
}

// MARK: - Needs Attention Section (Dashboard)

/// Compact "Needs Attention" section for the workspace dashboard.
/// Shows top 2–4 insights when projects need human awareness.
/// Invisible when everything is healthy — no empty state.
struct NeedsAttentionSection: View {

    let insights: [Insight]
    let onSelectProject: (UUID) -> Void
    let onLaunchReview: (String) -> Void

    var body: some View {
        if !insights.isEmpty {
            DashboardSection(
                title: "Needs Attention",
                subtitle: summaryLine,
                systemImage: "eye.trianglebadge.exclamationmark"
            ) {
                VStack(spacing: StudioSpacing.xs) {
                    ForEach(insights) { insight in
                        InsightRow(insight: insight) {
                            StudioFeedback.select()
                            handleAction(insight.action)
                        }
                    }
                }
            }
        }
    }

    private var summaryLine: String {
        let count = insights.count
        let highCount = insights.filter { $0.priority == .high }.count
        if highCount > 0 {
            return "\(count) item\(count == 1 ? "" : "s") · \(highCount) urgent"
        }
        return "\(count) item\(count == 1 ? "" : "s") to review"
    }

    private func handleAction(_ action: Insight.Action) {
        switch action {
        case .selectProject(let id):
            onSelectProject(id)
        case .reviewProject(let id):
            onSelectProject(id)
        }
    }
}

// MARK: - Sidebar Attention Indicator

/// Minimal indicator inserted between the sidebar header and the Projects section.
/// Shows when any insights exist, disappears when everything is healthy.
struct SidebarAttentionBadge: View {

    let count: Int
    let highPriorityCount: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: StudioSpacing.sm) {
                Circle()
                    .fill(highPriorityCount > 0 ? StudioStatusColor.danger : StudioStatusColor.warning)
                    .frame(width: 6, height: 6)

                Text(label)
                    .font(StudioTypography.micro)
                    .foregroundStyle(StudioTextColor.secondary)
            }
            .padding(.top, StudioSpacing.sm)
            .padding(.bottom, StudioSpacing.xxs)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    private var label: String {
        if count == 1 {
            return "1 item needs attention"
        }
        return "\(count) items need attention"
    }
}
