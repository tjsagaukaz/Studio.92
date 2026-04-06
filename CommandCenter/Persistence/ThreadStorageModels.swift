// PersistenceModels.swift
// Studio.92 — Command Center
// SwiftData @Model types for persistence: AppProject, Epoch, PersistedThread, PersistedMessage.

import Foundation
import SwiftData

// MARK: - ModelContext Safety

extension ModelContext {
    /// Saves and logs any failure instead of silently dropping it.
    func saveWithLogging(caller: String = #function) {
        do {
            try save()
        } catch {
            print("[Studio.92][SwiftData] Save failed in \(caller): \(error.localizedDescription)")
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when a telemetry file has been ingested into SwiftData.
    /// userInfo contains "projectID" (UUID).
    static let telemetryIngested = Notification.Name("telemetryIngested")
}

// MARK: - AppProject

/// A project managed by the Dark Factory.
/// Each project represents one iOS app being autonomously built.
@Model
final class AppProject {

    @Attribute(.unique)
    var id: UUID

    /// Human-readable project name (e.g., "NRL Scoreboard", "Solar Fitness").
    var name: String

    /// The original goal string passed to `swift run council`.
    var goal: String

    /// User-facing goal text without any system-added reference context.
    var displayGoal: String?

    /// Derived confidence score (0–100). Never user-editable.
    /// Computed from HIG compliance, deviation budget remaining, and drift state.
    var confidenceScore: Int

    /// The dominant archetype classification for this project.
    /// One of: Tactical, Athletic, Financial, UtilityMinimal, SocialReactive, or nil if unclassified.
    var dominantArchetype: String?

    /// Current deviation budget remaining (0.0–1.0).
    var deviationBudgetRemaining: Double

    /// Current drift budget remaining (0.0–1.0).
    var driftBudgetRemaining: Double

    /// The primary risk label shown in the sidebar (e.g., "HIG Violation", "Drift Alert").
    var primaryRiskLabel: String?

    /// Secondary detail shown below the risk label (e.g., "Blocker: User Override").
    var secondaryRiskDetail: String?

    /// Whether this project requires human intervention before the next pipeline run.
    var requiresHumanOverride: Bool

    /// The most recent Critic verdict text. Short, authoritative.
    var latestCriticVerdict: String?

    /// Flow integrity score (0.0–1.0). Measures how cleanly packets flow through the pipeline.
    var flowIntegrityScore: Double

    /// ISO 8601 timestamp of the last pipeline activity.
    var lastActivityAt: Date

    /// Persisted epochs for the project. Read through `sortedEpochs` for deterministic ordering.
    @Relationship(deleteRule: .cascade, inverse: \Epoch.project)
    var epochs: [Epoch]

    var sortedEpochs: [Epoch] {
        epochs.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    init(
        name:                     String,
        goal:                     String,
        confidenceScore:          Int     = 0,
        dominantArchetype:        String? = nil,
        deviationBudgetRemaining: Double  = 1.0,
        driftBudgetRemaining:     Double  = 1.0,
        primaryRiskLabel:         String? = nil,
        secondaryRiskDetail:      String? = nil,
        requiresHumanOverride:    Bool    = false,
        latestCriticVerdict:      String? = nil,
        flowIntegrityScore:       Double  = 1.0
    ) {
        self.id                       = UUID()
        self.name                     = name
        self.goal                     = goal
        self.displayGoal              = nil
        self.confidenceScore          = confidenceScore
        self.dominantArchetype        = dominantArchetype
        self.deviationBudgetRemaining = deviationBudgetRemaining
        self.driftBudgetRemaining     = driftBudgetRemaining
        self.primaryRiskLabel         = primaryRiskLabel
        self.secondaryRiskDetail      = secondaryRiskDetail
        self.requiresHumanOverride    = requiresHumanOverride
        self.latestCriticVerdict      = latestCriticVerdict
        self.flowIntegrityScore       = flowIntegrityScore
        self.lastActivityAt           = Date()
        self.epochs                   = []
    }
}

// MARK: - Epoch

/// A distinct state in a project's evolution.
/// Each epoch corresponds to one approved builder change that moved the app forward.
/// that moved the app from state N to state N+1.
@Model
final class Epoch {

    @Attribute(.unique)
    var id: UUID

    /// Sequential index within the project (0, 1, 2, ...).
    var index: Int

    /// One-line summary of what changed in this epoch.
    var summary: String

    /// The archetype classification at the time of this epoch.
    var archetype: String?

    /// The HIG compliance score of the packet that created this epoch.
    var higScore: Double

    /// The deviation budget cost of the packet that created this epoch.
    var deviationCost: Double

    /// The drift score at the time this epoch was created.
    var driftScore: Double

    /// The target file that was modified or created.
    var targetFile: String

    /// Whether this epoch created a new file or patched an existing one.
    var isNewFile: Bool

    /// The packet ID that produced this epoch.
    var packetID: UUID

    /// Timestamp of when this epoch was merged.
    var mergedAt: Date

    var createdAt: Date {
        mergedAt
    }

    /// File path to the Simulator screenshot captured after this epoch's build.
    var screenshotPath: String?

    /// Grounded source delta archived for this epoch when available.
    var diffText: String?

    /// Count of affected components/types archived for this epoch when available.
    var componentsBuilt: Int?

    /// Back-reference to the owning project.
    var project: AppProject?

    init(
        index:          Int,
        summary:        String,
        archetype:      String? = nil,
        higScore:       Double  = 0.0,
        deviationCost:  Double  = 0.0,
        driftScore:     Double  = 0.0,
        targetFile:     String  = "",
        isNewFile:      Bool    = false,
        packetID:       UUID    = UUID(),
        screenshotPath: String? = nil,
        diffText:       String? = nil,
        componentsBuilt: Int?   = nil
    ) {
        self.id             = UUID()
        self.index          = index
        self.summary        = summary
        self.archetype      = archetype
        self.higScore       = higScore
        self.deviationCost  = deviationCost
        self.driftScore     = driftScore
        self.targetFile     = targetFile
        self.isNewFile      = isNewFile
        self.packetID       = packetID
        self.screenshotPath = screenshotPath
        self.diffText       = diffText
        self.componentsBuilt = componentsBuilt
        self.mergedAt       = Date()
    }
}

// MARK: - PersistedThread

/// A persisted conversation thread. Stores the full conversation history that produced
/// project artifacts, so users can return to previous work with full context.
@Model
final class PersistedThread {

    @Attribute(.unique)
    var id: UUID

    /// Human-visible goal that started this thread.
    var title: String

    /// Workspace path this thread was opened against.
    var workspacePath: String

    var createdAt: Date
    var updatedAt: Date

    /// Optional back-link to the project this thread produced results for.
    var projectID: UUID?

    /// Persisted messages in this thread, ordered by timestamp.
    @Relationship(deleteRule: .cascade, inverse: \PersistedMessage.thread)
    var messages: [PersistedMessage]

    var sortedMessages: [PersistedMessage] {
        messages.sorted { $0.timestamp < $1.timestamp }
    }

    init(
        title: String,
        workspacePath: String,
        projectID: UUID? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.workspacePath = workspacePath
        self.projectID = projectID
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = []
    }
}

// MARK: - PersistedMessage

/// One message within a persisted conversation thread.
@Model
final class PersistedMessage {

    @Attribute(.unique)
    var id: UUID

    /// "userGoal", "assistant", "completion", "error", "tool"
    var kind: String

    /// The goal this message was posted under.
    var goal: String

    /// Main text content.
    var text: String

    /// Extended thinking text (for assistant messages).
    var thinkingText: String?

    /// Tool trace summary serialized as JSON (optional).
    var toolTracesJSON: Data?

    var timestamp: Date

    /// Link to the epoch this message produced, if any.
    var epochID: UUID?

    /// Back-reference to the owning thread.
    var thread: PersistedThread?

    init(
        kind: String,
        goal: String,
        text: String,
        thinkingText: String? = nil,
        toolTracesJSON: Data? = nil,
        timestamp: Date = Date(),
        epochID: UUID? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.goal = goal
        self.text = text
        self.thinkingText = thinkingText
        self.toolTracesJSON = toolTracesJSON
        self.timestamp = timestamp
        self.epochID = epochID
    }
}
