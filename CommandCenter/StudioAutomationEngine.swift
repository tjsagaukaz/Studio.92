// StudioAutomationEngine.swift
// Studio.92 — Command Center
//
// Trust-based automation layer. Evaluates project state and proposes
// actions the system can take on the user's behalf — always with
// visibility, reversibility, and explicit user consent.
//
// Trust model:
//   Phase 1 — Suggestions only (default)
//   Phase 2 — Confirmed automation (after user approves pattern)
//   Phase 3 — Auto-run option (after repeated confirmations)
//
// Every automated action is:  visible, explainable, undoable.

import SwiftUI

// MARK: - Automation Tier

/// Classifies how much user involvement an action requires.
enum AutomationTier: Int, Comparable, Codable {
    /// Low-risk, reversible. Can run silently after first consent.
    case safe = 0
    /// Requires confirmation each time until trust is earned.
    case assisted = 1
    /// Must ALWAYS require explicit confirmation. Never auto-run.
    case critical = 2

    static func < (lhs: AutomationTier, rhs: AutomationTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Rule Kind

/// The category of automation rule. Used as the key for preference tracking.
enum AutomationRuleKind: String, Codable, CaseIterable, Identifiable {
    /// Auto-refresh repository state on app launch / project switch.
    case autoRefreshRepository
    /// Suggest launching a review when confidence drops below threshold.
    case suggestReviewOnLowConfidence
    /// Suggest re-running the pipeline for stale projects with risk.
    case suggestRerunOnStale
    /// Auto-select the most recently ingested project.
    case autoSelectNewProject
    /// Suggest clearing resolved insights when risk clears.
    case suggestDismissResolvedInsights

    var id: String { rawValue }

    var tier: AutomationTier {
        switch self {
        case .autoRefreshRepository, .autoSelectNewProject:
            return .safe
        case .suggestReviewOnLowConfidence, .suggestRerunOnStale, .suggestDismissResolvedInsights:
            return .assisted
        }
    }

    var displayName: String {
        switch self {
        case .autoRefreshRepository:
            return "Auto-refresh repository"
        case .suggestReviewOnLowConfidence:
            return "Suggest review on low confidence"
        case .suggestRerunOnStale:
            return "Suggest re-run for stale projects"
        case .autoSelectNewProject:
            return "Auto-select new projects"
        case .suggestDismissResolvedInsights:
            return "Clear resolved insights"
        }
    }

    var description: String {
        switch self {
        case .autoRefreshRepository:
            return "Refresh git status when switching projects"
        case .suggestReviewOnLowConfidence:
            return "Offer to launch a review when confidence drops"
        case .suggestRerunOnStale:
            return "Suggest pipeline re-run for inactive projects"
        case .autoSelectNewProject:
            return "Focus newly ingested projects automatically"
        case .suggestDismissResolvedInsights:
            return "Remove insights when their triggers clear"
        }
    }

    var symbolName: String {
        switch self {
        case .autoRefreshRepository: return "arrow.triangle.2.circlepath"
        case .suggestReviewOnLowConfidence: return "eye.fill"
        case .suggestRerunOnStale: return "arrow.clockwise"
        case .autoSelectNewProject: return "scope"
        case .suggestDismissResolvedInsights: return "checkmark.circle"
        }
    }
}

// MARK: - Automation Proposal

/// A concrete action the engine proposes. Displayed to the user for approval
/// or (if confidence is high enough and tier allows) executed automatically.
struct AutomationProposal: Identifiable, Equatable {

    let id: UUID
    let ruleKind: AutomationRuleKind
    let projectID: UUID?
    let title: String       // Calm microcopy — "Based on what you usually do…"
    let subtitle: String    // One-line context
    let symbolName: String
    let confidence: Double  // 0.0–1.0, derived from preference history
    let canAutoRun: Bool    // True only if tier is safe AND confidence ≥ threshold

    /// The prompt to submit if the user accepts this proposal.
    let suggestedPrompt: String?

    static func == (lhs: AutomationProposal, rhs: AutomationProposal) -> Bool {
        lhs.id == rhs.id && lhs.ruleKind == rhs.ruleKind
            && lhs.projectID == rhs.projectID
            && lhs.confidence == rhs.confidence
    }
}

// MARK: - Automation Event (for Undo Banner)

/// Records an action that was taken so it can be displayed and undone.
struct AutomationEvent: Identifiable, Equatable {
    let id: UUID
    let ruleKind: AutomationRuleKind
    let description: String   // "Repository refreshed" / "Review launched"
    let timestamp: Date
    var isUndone: Bool = false
}

// MARK: - Preference Store

/// Tracks user accept/dismiss counts per rule kind to build trust over time.
/// Persisted via UserDefaults. Lightweight — no SwiftData dependency.
@MainActor
final class AutomationPreferenceStore: ObservableObject {

    static let shared = AutomationPreferenceStore()

    private static let defaultsKey = "studio92.automationPreferences"

    /// Confidence threshold for offering auto-run (Phase 3).
    static let autoRunThreshold: Double = 0.85

    /// Minimum confirmations before auto-run is offered.
    static let minimumConfirmations = 3

    struct RulePreference: Codable {
        var acceptCount: Int = 0
        var dismissCount: Int = 0
        var isEnabled: Bool = true
        var autoRunEnabled: Bool = false

        var totalInteractions: Int { acceptCount + dismissCount }

        /// Confidence based on accept ratio, weighted by volume.
        var confidence: Double {
            guard totalInteractions > 0 else { return 0.0 }
            let ratio = Double(acceptCount) / Double(totalInteractions)
            let volumeWeight = min(Double(totalInteractions) / 10.0, 1.0)
            return ratio * volumeWeight
        }
    }

    @Published private(set) var preferences: [String: RulePreference] = [:]

    init() {
        load()
    }

    func preference(for kind: AutomationRuleKind) -> RulePreference {
        preferences[kind.rawValue] ?? RulePreference()
    }

    func isEnabled(_ kind: AutomationRuleKind) -> Bool {
        preference(for: kind).isEnabled
    }

    func confidence(for kind: AutomationRuleKind) -> Double {
        preference(for: kind).confidence
    }

    func canAutoRun(_ kind: AutomationRuleKind) -> Bool {
        let pref = preference(for: kind)
        guard kind.tier == .safe else { return false }
        return pref.autoRunEnabled
            && pref.acceptCount >= Self.minimumConfirmations
            && pref.confidence >= Self.autoRunThreshold
    }

    // MARK: - Mutations

    func recordAccept(_ kind: AutomationRuleKind) {
        var pref = preference(for: kind)
        pref.acceptCount += 1
        preferences[kind.rawValue] = pref
        save()
    }

    func recordDismiss(_ kind: AutomationRuleKind) {
        var pref = preference(for: kind)
        pref.dismissCount += 1
        preferences[kind.rawValue] = pref
        save()
    }

    func setEnabled(_ kind: AutomationRuleKind, enabled: Bool) {
        var pref = preference(for: kind)
        pref.isEnabled = enabled
        preferences[kind.rawValue] = pref
        save()
    }

    func setAutoRun(_ kind: AutomationRuleKind, enabled: Bool) {
        var pref = preference(for: kind)
        pref.autoRunEnabled = enabled
        preferences[kind.rawValue] = pref
        save()
    }

    func resetAll() {
        preferences = [:]
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: RulePreference].self, from: data)
        else { return }
        preferences = decoded
    }
}

// MARK: - Automation Engine

enum StudioAutomationEngine {

    /// Maximum proposals surfaced at once.
    static let maxProposals = 3

    /// Evaluate current state and return actionable proposals.
    @MainActor
    static func evaluate(
        projects: [AppProject],
        insights: [Insight],
        activeJobProjectNames: Set<String>,
        isPipelineRunning: Bool,
        preferences: AutomationPreferenceStore,
        now: Date = Date()
    ) -> [AutomationProposal] {
        guard !isPipelineRunning else { return [] }

        var proposals: [AutomationProposal] = []

        // Rule 1: Suggest review for low-confidence projects (not already running).
        if preferences.isEnabled(.suggestReviewOnLowConfidence) {
            for project in projects where project.confidenceScore < 40
                && !activeJobProjectNames.contains(project.name)
                && !project.requiresHumanOverride {
                let conf = preferences.confidence(for: .suggestReviewOnLowConfidence)
                proposals.append(AutomationProposal(
                    id: deterministicID(project.id, suffix: "review-low"),
                    ruleKind: .suggestReviewOnLowConfidence,
                    projectID: project.id,
                    title: "Review \(project.name)?",
                    subtitle: "Confidence is at \(project.confidenceScore)% — a review could help",
                    symbolName: AutomationRuleKind.suggestReviewOnLowConfidence.symbolName,
                    confidence: conf,
                    canAutoRun: false,
                    suggestedPrompt: "Review the current state of \(project.name), identify risks, and suggest next steps."
                ))
            }
        }

        // Rule 2: Suggest re-run for stale projects with unresolved risk.
        if preferences.isEnabled(.suggestRerunOnStale) {
            for project in projects {
                let hoursSinceActivity = now.timeIntervalSince(project.lastActivityAt) / 3600
                guard hoursSinceActivity > 24,
                      project.primaryRiskLabel != nil,
                      !activeJobProjectNames.contains(project.name)
                else { continue }

                let conf = preferences.confidence(for: .suggestRerunOnStale)
                proposals.append(AutomationProposal(
                    id: deterministicID(project.id, suffix: "rerun-stale"),
                    ruleKind: .suggestRerunOnStale,
                    projectID: project.id,
                    title: "Resume \(project.name)?",
                    subtitle: "Inactive \(Int(hoursSinceActivity))h with unresolved: \(project.primaryRiskLabel ?? "risk")",
                    symbolName: AutomationRuleKind.suggestRerunOnStale.symbolName,
                    confidence: conf,
                    canAutoRun: false,
                    suggestedPrompt: "Continue working on \(project.name). Address the outstanding risk: \(project.primaryRiskLabel ?? "see project status")."
                ))
            }
        }

        // Sort by confidence descending, cap output.
        let sorted = proposals.sorted { $0.confidence > $1.confidence }
        return Array(sorted.prefix(maxProposals))
    }

    // MARK: - Deterministic IDs

    private static func deterministicID(_ projectID: UUID, suffix: String) -> UUID {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: projectID.uuid) { Data($0) })
        data.append(contentsOf: "auto-".utf8)
        data.append(contentsOf: suffix.utf8)

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

// MARK: - Automation Proposal Row

/// A single automation suggestion shown in the dashboard.
/// "Based on what you usually do…" — calm, non-intrusive.
struct AutomationProposalRow: View {

    let proposal: AutomationProposal
    let onAccept: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: StudioSpacing.xl) {
            Image(systemName: proposal.symbolName)
                .font(StudioTypography.subheadlineMedium)
                .foregroundStyle(StudioAccentColor.primary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                Text(proposal.title)
                    .font(StudioTypography.footnoteSemibold)
                    .foregroundStyle(StudioTextColor.primary)
                    .lineLimit(1)

                Text(proposal.subtitle)
                    .font(StudioTypography.micro)
                    .foregroundStyle(StudioTextColor.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isHovered {
                HStack(spacing: StudioSpacing.sm) {
                    Button(action: onAccept) {
                        Text("Go")
                            .font(StudioTypography.microMedium)
                            .foregroundStyle(StudioAccentColor.primary)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(StudioTypography.microSemibold)
                            .foregroundStyle(StudioTextColor.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, StudioSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                .fill(isHovered ? StudioAccentColor.primary.opacity(0.04) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Automation Banner (Post-Action Confirmation)

/// Slim, short-lived confirmation that surfaces after an automated action.
/// Shows what happened + Undo button. Auto-dismisses after 5 seconds.
struct AutomationBanner: View {

    let event: AutomationEvent
    let onUndo: () -> Void

    @State private var isVisible = true

    var body: some View {
        if isVisible && !event.isUndone {
            HStack(spacing: StudioSpacing.lg) {
                Image(systemName: "checkmark.circle.fill")
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(StudioStatusColor.success)

                Text(event.description)
                    .font(StudioTypography.micro)
                    .foregroundStyle(StudioTextColor.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button("Undo") {
                    StudioFeedback.cancel()
                    onUndo()
                    withAnimation(StudioMotion.softFade) { isVisible = false }
                }
                .font(StudioTypography.microMedium)
                .foregroundStyle(StudioAccentColor.primary)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, StudioSpacing.xxl)
            .padding(.vertical, StudioSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                    .fill(StudioSurfaceElevated.level1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                    .strokeBorder(StudioSeparator.subtle, lineWidth: 0.5)
            )
            .transition(.studioFadeLift)
            .task {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(StudioMotion.softFade) { isVisible = false }
            }
        }
    }
}

// MARK: - Suggested Actions Section (Dashboard)

/// "Suggested Actions" section for the workspace dashboard.
/// Shows automation proposals when available. Invisible when nothing to suggest.
struct SuggestedActionsSection: View {

    let proposals: [AutomationProposal]
    let onAccept: (AutomationProposal) -> Void
    let onDismiss: (AutomationProposal) -> Void

    var body: some View {
        if !proposals.isEmpty {
            DashboardSection(
                title: "Suggested",
                subtitle: "Based on your workflow",
                systemImage: "wand.and.rays"
            ) {
                VStack(spacing: StudioSpacing.xs) {
                    ForEach(proposals) { proposal in
                        AutomationProposalRow(
                            proposal: proposal,
                            onAccept: { onAccept(proposal) },
                            onDismiss: { onDismiss(proposal) }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Automation Settings Section

/// Settings section for managing automation rules.
/// Users can view all automations, disable any, and reset learned behavior.
struct AutomationSettingsSection: View {

    @ObservedObject var store: AutomationPreferenceStore

    var body: some View {
        Section("Automation") {
            VStack(alignment: .leading, spacing: StudioSpacing.xl) {
                Text("Studio.92 can suggest and perform actions based on your workflow patterns.")
                    .font(StudioTypography.subheadline)
                    .foregroundStyle(StudioTextColor.secondary)

                ForEach(AutomationRuleKind.allCases) { kind in
                    AutomationRuleRow(
                        kind: kind,
                        preference: store.preference(for: kind),
                        onToggle: { enabled in
                            store.setEnabled(kind, enabled: enabled)
                        },
                        onToggleAutoRun: { enabled in
                            store.setAutoRun(kind, enabled: enabled)
                        }
                    )
                }

                Button("Reset All Learned Preferences") {
                    store.resetAll()
                }
                .font(StudioTypography.footnote)
                .foregroundStyle(StudioStatusColor.danger)
                .buttonStyle(.plain)
                .padding(.top, StudioSpacing.md)
            }
            .padding(.vertical, StudioSpacing.xs)
        }
    }
}

private struct AutomationRuleRow: View {

    let kind: AutomationRuleKind
    let preference: AutomationPreferenceStore.RulePreference
    let onToggle: (Bool) -> Void
    let onToggleAutoRun: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudioSpacing.md) {
            HStack(spacing: StudioSpacing.lg) {
                Image(systemName: kind.symbolName)
                    .font(StudioTypography.captionMedium)
                    .foregroundStyle(StudioTextColor.secondary)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: StudioSpacing.xxs) {
                    Text(kind.displayName)
                        .font(StudioTypography.footnoteSemibold)
                        .foregroundStyle(StudioTextColor.primary)

                    Text(kind.description)
                        .font(StudioTypography.micro)
                        .foregroundStyle(StudioTextColor.secondary)
                }

                Spacer(minLength: 0)

                Toggle("", isOn: Binding(
                    get: { preference.isEnabled },
                    set: { onToggle($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if preference.isEnabled && preference.totalInteractions > 0 {
                HStack(spacing: StudioSpacing.lg) {
                    confidencePill

                    if kind.tier == .safe && preference.acceptCount >= AutomationPreferenceStore.minimumConfirmations {
                        Toggle("Auto-run", isOn: Binding(
                            get: { preference.autoRunEnabled },
                            set: { onToggleAutoRun($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(StudioTypography.micro)
                        .foregroundStyle(StudioTextColor.secondary)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(StudioSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.md, style: .continuous)
                .fill(StudioSurfaceElevated.level1)
        )
    }

    private var confidencePill: some View {
        HStack(spacing: StudioSpacing.sm) {
            Circle()
                .fill(confidenceColor)
                .frame(width: 5, height: 5)

            Text("\(preference.acceptCount) accepted · \(preference.dismissCount) dismissed")
                .font(StudioTypography.dataMicro)
                .foregroundStyle(StudioTextColor.tertiary)
        }
    }

    private var confidenceColor: Color {
        if preference.confidence >= AutomationPreferenceStore.autoRunThreshold {
            return StudioStatusColor.success
        } else if preference.confidence >= 0.5 {
            return StudioStatusColor.warning
        } else {
            return StudioTextColor.tertiary
        }
    }
}
