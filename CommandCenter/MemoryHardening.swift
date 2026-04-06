// MemoryHardening.swift
// Studio.92 — Command Center
// Durable memory system for cross-session assistant continuity.
// Tasks 2–10 of the Memory Hardening Sprint.

import Foundation
import SwiftData

// MARK: - Schema Version

private let currentMemorySchemaVersion = 1

// MARK: - Durable Memory Profile (Task 2)

/// Single-user durable identity and product memory.
/// Persists across all sessions, relaunches, and rebuilds.
@Model
final class DurableMemoryProfile {

    @Attribute(.unique)
    var id: UUID

    /// Schema version for migration safety.
    var schemaVersion: Int

    // MARK: User Identity
    var userName: String
    var userRole: String

    // MARK: Product Identity
    var appIdentity: String
    var productVision: String

    // MARK: Standing Instructions
    var standingInstructions: [String]

    // MARK: Durable Facts
    var durableFacts: [String]

    // MARK: Timestamps
    var createdAt: Date
    var updatedAt: Date

    init(
        userName: String = "TJ",
        userRole: String = "Solo operator and builder",
        appIdentity: String = "Studio.92 — a single-user autonomous software delivery console built by and for TJ",
        productVision: String = """
            The long-term goal is autonomous software delivery: discuss → plan → build → test → \
            audit → archive → App Store Connect preparation → human approval. Chat is the primary \
            control surface. The app must remain clean, trustworthy, and non-spaghetti.
            """,
        standingInstructions: [String] = [
            "Prefer continuity with prior decisions stored in durable memory.",
            "Never pretend to remember facts that are not present in injected memory or current session context.",
            "Keep architecture clean. Avoid God Objects and spaghetti.",
            "Prefer SwiftUI and native Apple frameworks.",
            "Surface concrete ship blockers first.",
        ],
        durableFacts: [String] = []
    ) {
        self.id = UUID()
        self.schemaVersion = currentMemorySchemaVersion
        self.userName = userName
        self.userRole = userRole
        self.appIdentity = appIdentity
        self.productVision = productVision
        self.standingInstructions = standingInstructions
        self.durableFacts = durableFacts
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Working Memory Snapshot (Task 3)

/// Per-thread runner working memory persisted for rehydration.
/// Stores the actual conversation history the model needs, not just the UI transcript.
@Model
final class WorkingMemorySnapshot {

    @Attribute(.unique)
    var id: UUID

    /// The thread this snapshot belongs to.
    var threadID: UUID

    /// Schema version for migration safety.
    var schemaVersion: Int

    /// Serialized runner conversation history (completedTurns as JSON).
    @Attribute(.externalStorage)
    var completedTurnsJSON: Data?

    /// Compaction summary if the session was compacted.
    var compactionSummaryJSON: Data?

    /// Thread-level summary for quick context injection.
    var threadSummary: String?

    /// Unresolved tasks tracked during the session.
    var unresolvedTasks: [String]

    /// Recent important decisions made during the session.
    var recentDecisions: [String]

    /// The goal text of the active/last run.
    var activeGoal: String?

    var createdAt: Date
    var updatedAt: Date

    init(threadID: UUID) {
        self.id = UUID()
        self.threadID = threadID
        self.schemaVersion = currentMemorySchemaVersion
        self.completedTurnsJSON = nil
        self.compactionSummaryJSON = nil
        self.threadSummary = nil
        self.unresolvedTasks = []
        self.recentDecisions = []
        self.activeGoal = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Run Checkpoint (Task 7)

/// Tracks whether a run was interrupted or completed cleanly.
@Model
final class RunCheckpoint {

    @Attribute(.unique)
    var id: UUID

    var threadID: UUID
    var schemaVersion: Int

    /// "running", "completed", "failed", "interrupted"
    var lastKnownPhase: String

    /// The goal being executed.
    var goal: String

    /// Working memory snapshot ID for the run.
    var workingMemorySnapshotID: UUID?

    /// Whether the run completed cleanly.
    var completedCleanly: Bool

    var createdAt: Date
    var updatedAt: Date

    init(threadID: UUID, goal: String) {
        self.id = UUID()
        self.threadID = threadID
        self.schemaVersion = currentMemorySchemaVersion
        self.lastKnownPhase = "running"
        self.goal = goal
        self.workingMemorySnapshotID = nil
        self.completedCleanly = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Memory Pack (Task 4)

/// The canonical assembled memory payload injected into runs.
/// Composed from durable + working + thread context.
struct MemoryPack: Codable {

    struct DurableMemory: Codable {
        var userName: String
        var userRole: String
        var appIdentity: String
        var productVision: String
        var standingInstructions: [String]
        var durableFacts: [String]
    }

    struct WorkingMemory: Codable {
        var threadSummary: String?
        var activeGoal: String?
        var unresolvedTasks: [String]
        var recentDecisions: [String]
        var hasCompactedHistory: Bool
        var completedTurnCount: Int
    }

    struct InterruptedRunInfo: Codable {
        var goal: String
        var lastKnownPhase: String
        var interruptedAt: Date
    }

    var schemaVersion: Int
    var durable: DurableMemory
    var working: WorkingMemory?
    var interruptedRun: InterruptedRunInfo?
    var assembledAt: Date

    /// Render as a prompt-ready string for system prompt injection.
    func renderForPrompt() -> String {
        var sections: [String] = []

        // Durable Memory section
        var durableLines: [String] = []
        durableLines.append("- The user is \(durable.userName).")
        durableLines.append("- Role: \(durable.userRole).")
        durableLines.append("- \(durable.appIdentity).")
        durableLines.append("- Vision: \(durable.productVision)")
        for instruction in durable.standingInstructions {
            durableLines.append("- \(instruction)")
        }
        for fact in durable.durableFacts where !fact.isEmpty {
            durableLines.append("- \(fact)")
        }
        sections.append("""
        ### DURABLE MEMORY ###
        \(durableLines.joined(separator: "\n"))
        """)

        // Working Memory section
        if let working {
            var workingLines: [String] = []
            if let summary = working.threadSummary, !summary.isEmpty {
                workingLines.append("Thread summary: \(summary)")
            }
            if let goal = working.activeGoal, !goal.isEmpty {
                workingLines.append("Active goal: \(goal)")
            }
            if working.completedTurnCount > 0 {
                workingLines.append("Conversation turns in history: \(working.completedTurnCount)")
            }
            if working.hasCompactedHistory {
                workingLines.append("History has been compacted (summarized for context efficiency).")
            }
            for task in working.unresolvedTasks where !task.isEmpty {
                workingLines.append("Unresolved: \(task)")
            }
            for decision in working.recentDecisions where !decision.isEmpty {
                workingLines.append("Decision: \(decision)")
            }
            if !workingLines.isEmpty {
                sections.append("""
                ### CURRENT WORKING MEMORY ###
                \(workingLines.joined(separator: "\n"))
                """)
            }
        }

        // Interrupted Run section
        if let interrupted = interruptedRun {
            sections.append("""
            ### INTERRUPTED RUN ###
            A previous run was interrupted and may need continuation.
            - Goal: \(interrupted.goal)
            - Last phase: \(interrupted.lastKnownPhase)
            - Interrupted at: \(ISO8601DateFormatter().string(from: interrupted.interruptedAt))
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    /// Render a scoped version for subagents (includes standing instructions).
    func renderForSubagent() -> String {
        var lines: [String] = []
        lines.append("- The user is \(durable.userName).")
        lines.append("- \(durable.appIdentity).")
        lines.append("- Vision: \(durable.productVision)")
        for instruction in durable.standingInstructions {
            lines.append("- \(instruction)")
        }
        for fact in durable.durableFacts where !fact.isEmpty {
            lines.append("- \(fact)")
        }
        if let goal = working?.activeGoal, !goal.isEmpty {
            lines.append("- Current task context: \(goal)")
        }
        if let summary = working?.threadSummary, !summary.isEmpty {
            lines.append("- Thread context: \(summary)")
        }
        return """
        ### CONTEXT ###
        \(lines.joined(separator: "\n"))
        """
    }
}

// MARK: - Memory Pack Assembler (Task 4)

@MainActor
final class MemoryPackAssembler {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Assemble the full memory pack for a run.
    func assemble(
        threadID: UUID?,
        activeGoal: String?,
        completedTurns: [ConversationHistoryTurn],
        hasCompactedHistory: Bool = false
    ) -> MemoryPack {
        let profile = loadOrCreateProfile()
        let working = loadWorkingMemory(threadID: threadID, activeGoal: activeGoal, completedTurns: completedTurns, hasCompacted: hasCompactedHistory)
        let interrupted = loadInterruptedRun(excludingThreadID: threadID)

        return MemoryPack(
            schemaVersion: currentMemorySchemaVersion,
            durable: MemoryPack.DurableMemory(
                userName: profile.userName,
                userRole: profile.userRole,
                appIdentity: profile.appIdentity,
                productVision: profile.productVision,
                standingInstructions: profile.standingInstructions,
                durableFacts: profile.durableFacts
            ),
            working: working,
            interruptedRun: interrupted,
            assembledAt: Date()
        )
    }

    // MARK: - Profile Management

    func loadOrCreateProfile() -> DurableMemoryProfile {
        let descriptor = FetchDescriptor<DurableMemoryProfile>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let profile = DurableMemoryProfile()
        modelContext.insert(profile)
        modelContext.saveWithLogging()
        return profile
    }

    // MARK: - Working Memory

    private func loadWorkingMemory(
        threadID: UUID?,
        activeGoal: String?,
        completedTurns: [ConversationHistoryTurn],
        hasCompacted: Bool
    ) -> MemoryPack.WorkingMemory? {
        guard let threadID else { return nil }

        let snapshot = loadSnapshot(forThread: threadID)
        return MemoryPack.WorkingMemory(
            threadSummary: snapshot?.threadSummary,
            activeGoal: activeGoal ?? snapshot?.activeGoal,
            unresolvedTasks: snapshot?.unresolvedTasks ?? [],
            recentDecisions: snapshot?.recentDecisions ?? [],
            hasCompactedHistory: hasCompacted,
            completedTurnCount: completedTurns.count
        )
    }

    private func loadSnapshot(forThread threadID: UUID) -> WorkingMemorySnapshot? {
        let descriptor = FetchDescriptor<WorkingMemorySnapshot>(
            predicate: #Predicate { $0.threadID == threadID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Interrupted Run Detection

    /// Maximum age for an interrupted run to be injected into context.
    /// Runs older than this are stale and should not influence new sessions.
    private static let interruptedRunTTL: TimeInterval = 24 * 3600  // 24 hours

    private func loadInterruptedRun(excludingThreadID: UUID?) -> MemoryPack.InterruptedRunInfo? {
        let descriptor = FetchDescriptor<RunCheckpoint>(
            predicate: #Predicate { $0.completedCleanly == false },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        guard let checkpoint = try? modelContext.fetch(descriptor).first else { return nil }
        if let excludingThreadID, checkpoint.threadID == excludingThreadID { return nil }

        // Skip stale interrupted runs beyond the TTL.
        let age = Date().timeIntervalSince(checkpoint.updatedAt)
        guard age < Self.interruptedRunTTL else { return nil }

        return MemoryPack.InterruptedRunInfo(
            goal: checkpoint.goal,
            lastKnownPhase: checkpoint.lastKnownPhase,
            interruptedAt: checkpoint.updatedAt
        )
    }

    // MARK: - Observability (Task 10)

    /// Returns a diagnostic summary of current memory state.
    func diagnosticSummary() -> String {
        let profile = loadOrCreateProfile()
        let snapshotDescriptor = FetchDescriptor<WorkingMemorySnapshot>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let snapshots = (try? modelContext.fetch(snapshotDescriptor)) ?? []
        let checkpointDescriptor = FetchDescriptor<RunCheckpoint>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let checkpoints = (try? modelContext.fetch(checkpointDescriptor)) ?? []

        var lines: [String] = []
        lines.append("=== Memory Diagnostic ===")
        lines.append("Profile: \(profile.userName) | schema v\(profile.schemaVersion)")
        lines.append("  Identity: \(profile.appIdentity)")
        lines.append("  Vision: \(profile.productVision.prefix(80))...")
        lines.append("  Standing instructions: \(profile.standingInstructions.count)")
        lines.append("  Durable facts: \(profile.durableFacts.count)")
        lines.append("  Created: \(profile.createdAt)")
        lines.append("  Updated: \(profile.updatedAt)")
        lines.append("")
        lines.append("Working Memory Snapshots: \(snapshots.count)")
        for snapshot in snapshots.prefix(3) {
            let turnCount = (try? JSONDecoder().decode([CodableHistoryTurn].self, from: snapshot.completedTurnsJSON ?? Data()))?.count ?? 0
            lines.append("  Thread \(snapshot.threadID.uuidString.prefix(8)): \(turnCount) turns, goal=\(snapshot.activeGoal ?? "none"), updated=\(snapshot.updatedAt)")
        }
        lines.append("")
        lines.append("Run Checkpoints: \(checkpoints.count)")
        for cp in checkpoints.prefix(3) {
            lines.append("  Thread \(cp.threadID.uuidString.prefix(8)): phase=\(cp.lastKnownPhase) clean=\(cp.completedCleanly) goal=\(cp.goal.prefix(40))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Working Memory Persistence (Task 3 + Task 6)

@MainActor
final class WorkingMemoryPersistence {

    private let modelContext: ModelContext
    private var autosaveTask: Task<Void, Never>?
    private var pendingAutosave = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Save runner working memory for a thread.
    func save(
        threadID: UUID,
        completedTurns: [ConversationHistoryTurn],
        compactionSummaryJSON: Data? = nil,
        threadSummary: String? = nil,
        unresolvedTasks: [String] = [],
        recentDecisions: [String] = [],
        activeGoal: String? = nil
    ) {
        let snapshot = loadOrCreateSnapshot(forThread: threadID)
        snapshot.completedTurnsJSON = encodeTurns(completedTurns)
        snapshot.compactionSummaryJSON = compactionSummaryJSON
        snapshot.threadSummary = threadSummary
        snapshot.unresolvedTasks = unresolvedTasks
        snapshot.recentDecisions = recentDecisions
        snapshot.activeGoal = activeGoal
        snapshot.updatedAt = Date()
        modelContext.saveWithLogging()
    }

    /// Restore runner working memory for a thread.
    func restore(threadID: UUID) -> [ConversationHistoryTurn] {
        guard let snapshot = loadSnapshot(forThread: threadID),
              let data = snapshot.completedTurnsJSON else {
            return []
        }
        return decodeTurns(data)
    }

    /// Debounced autosave — triggers after 2 seconds of quiet.
    func scheduleAutosave(
        threadID: UUID,
        completedTurns: [ConversationHistoryTurn],
        activeGoal: String?
    ) {
        // Capture pending state so flushPendingAutosave can execute immediately.
        pendingThreadID = threadID
        pendingCompletedTurns = completedTurns
        pendingActiveGoal = activeGoal

        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.executePendingSave()
        }
    }

    /// Flush any pending autosave immediately (for lifecycle events).
    /// Unlike the old implementation, this actually executes the save instead of discarding it.
    func flushPendingAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        executePendingSave()
    }

    private var pendingThreadID: UUID?
    private var pendingCompletedTurns: [ConversationHistoryTurn]?
    private var pendingActiveGoal: String?

    private func executePendingSave() {
        guard let threadID = pendingThreadID,
              let turns = pendingCompletedTurns else { return }
        save(
            threadID: threadID,
            completedTurns: turns,
            activeGoal: pendingActiveGoal
        )
        pendingThreadID = nil
        pendingCompletedTurns = nil
        pendingActiveGoal = nil
    }

    // MARK: - Internal

    private func loadOrCreateSnapshot(forThread threadID: UUID) -> WorkingMemorySnapshot {
        if let existing = loadSnapshot(forThread: threadID) {
            return existing
        }
        let snapshot = WorkingMemorySnapshot(threadID: threadID)
        modelContext.insert(snapshot)
        return snapshot
    }

    private func loadSnapshot(forThread threadID: UUID) -> WorkingMemorySnapshot? {
        let descriptor = FetchDescriptor<WorkingMemorySnapshot>(
            predicate: #Predicate { $0.threadID == threadID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Turn Serialization

    private func encodeTurns(_ turns: [ConversationHistoryTurn]) -> Data? {
        let codable = turns.map { CodableHistoryTurn(from: $0) }
        return try? JSONEncoder().encode(codable)
    }

    private func decodeTurns(_ data: Data) -> [ConversationHistoryTurn] {
        guard let codable = try? JSONDecoder().decode([CodableHistoryTurn].self, from: data) else {
            return []
        }
        return codable.map { $0.toHistoryTurn() }
    }

    // MARK: - Garbage Collection

    /// Remove working memory snapshots older than `maxAge`.
    /// Call at launch to prevent unbounded growth.
    func garbageCollect(maxAge: TimeInterval = 30 * 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let descriptor = FetchDescriptor<WorkingMemorySnapshot>()
        guard let all = try? modelContext.fetch(descriptor) else { return }
        var deletedCount = 0
        for snapshot in all where snapshot.updatedAt < cutoff {
            modelContext.delete(snapshot)
            deletedCount += 1
        }
        if deletedCount > 0 {
            modelContext.saveWithLogging()
        }
    }
}

// MARK: - Run Checkpoint Manager (Task 7)

@MainActor
final class RunCheckpointManager {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Create or update a checkpoint when a run starts.
    func beginRun(threadID: UUID, goal: String) {
        let checkpoint = loadOrCreate(forThread: threadID)
        checkpoint.lastKnownPhase = "running"
        checkpoint.goal = goal
        checkpoint.completedCleanly = false
        checkpoint.updatedAt = Date()
        modelContext.saveWithLogging()
    }

    /// Update checkpoint phase during the run.
    func updatePhase(threadID: UUID, phase: String) {
        guard let checkpoint = load(forThread: threadID) else { return }
        checkpoint.lastKnownPhase = phase
        checkpoint.updatedAt = Date()
        modelContext.saveWithLogging()
    }

    /// Mark the run as completed cleanly.
    func markCompleted(threadID: UUID) {
        guard let checkpoint = load(forThread: threadID) else { return }
        checkpoint.lastKnownPhase = "completed"
        checkpoint.completedCleanly = true
        checkpoint.updatedAt = Date()
        modelContext.saveWithLogging()
    }

    /// Mark the run as failed.
    func markFailed(threadID: UUID) {
        guard let checkpoint = load(forThread: threadID) else { return }
        checkpoint.lastKnownPhase = "failed"
        checkpoint.completedCleanly = true  // intentional: a clean failure is not an interruption
        checkpoint.updatedAt = Date()
        modelContext.saveWithLogging()
    }

    /// Find the most recent interrupted (unclean) checkpoint.
    func latestInterruptedCheckpoint() -> RunCheckpoint? {
        let descriptor = FetchDescriptor<RunCheckpoint>(
            predicate: #Predicate { $0.completedCleanly == false },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Remove completed checkpoints older than `maxAge` and interrupted checkpoints
    /// older than `interruptedMaxAge`. Call at launch to prevent unbounded growth.
    func garbageCollect(
        maxAge: TimeInterval = 7 * 24 * 3600,       // 7 days for completed
        interruptedMaxAge: TimeInterval = 24 * 3600  // 24 hours for interrupted
    ) {
        let completedCutoff = Date().addingTimeInterval(-maxAge)
        let interruptedCutoff = Date().addingTimeInterval(-interruptedMaxAge)

        let descriptor = FetchDescriptor<RunCheckpoint>()
        guard let all = try? modelContext.fetch(descriptor) else { return }

        var deletedCount = 0
        for checkpoint in all {
            let shouldDelete: Bool
            if checkpoint.completedCleanly {
                shouldDelete = checkpoint.updatedAt < completedCutoff
            } else {
                shouldDelete = checkpoint.updatedAt < interruptedCutoff
            }
            if shouldDelete {
                modelContext.delete(checkpoint)
                deletedCount += 1
            }
        }
        if deletedCount > 0 {
            modelContext.saveWithLogging()
        }
    }

    private func loadOrCreate(forThread threadID: UUID) -> RunCheckpoint {
        if let existing = load(forThread: threadID) { return existing }
        let checkpoint = RunCheckpoint(threadID: threadID, goal: "")
        modelContext.insert(checkpoint)
        return checkpoint
    }

    private func load(forThread threadID: UUID) -> RunCheckpoint? {
        let descriptor = FetchDescriptor<RunCheckpoint>(
            predicate: #Predicate { $0.threadID == threadID }
        )
        return try? modelContext.fetch(descriptor).first
    }
}

// MARK: - Memory Export / Import (Task 8)

struct MemoryExportPayload: Codable {
    var schemaVersion: Int
    var exportedAt: Date
    var profile: ExportedProfile
    var workingSnapshots: [ExportedSnapshot]
    var checkpoints: [ExportedCheckpoint]

    struct ExportedProfile: Codable {
        var userName: String
        var userRole: String
        var appIdentity: String
        var productVision: String
        var standingInstructions: [String]
        var durableFacts: [String]
        var createdAt: Date
        var updatedAt: Date
    }

    struct ExportedSnapshot: Codable {
        var threadID: UUID
        var threadSummary: String?
        var activeGoal: String?
        var unresolvedTasks: [String]
        var recentDecisions: [String]
        var completedTurnCount: Int
        var createdAt: Date
        var updatedAt: Date
    }

    struct ExportedCheckpoint: Codable {
        var threadID: UUID
        var goal: String
        var lastKnownPhase: String
        var completedCleanly: Bool
        var createdAt: Date
        var updatedAt: Date
    }
}

@MainActor
final class MemoryExporter {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Export all memory to a JSON-serializable payload.
    func export() -> MemoryExportPayload {
        let assembler = MemoryPackAssembler(modelContext: modelContext)
        let profile = assembler.loadOrCreateProfile()

        let snapshotDescriptor = FetchDescriptor<WorkingMemorySnapshot>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let snapshots = (try? modelContext.fetch(snapshotDescriptor)) ?? []

        let checkpointDescriptor = FetchDescriptor<RunCheckpoint>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let checkpoints = (try? modelContext.fetch(checkpointDescriptor)) ?? []

        return MemoryExportPayload(
            schemaVersion: currentMemorySchemaVersion,
            exportedAt: Date(),
            profile: MemoryExportPayload.ExportedProfile(
                userName: profile.userName,
                userRole: profile.userRole,
                appIdentity: profile.appIdentity,
                productVision: profile.productVision,
                standingInstructions: profile.standingInstructions,
                durableFacts: profile.durableFacts,
                createdAt: profile.createdAt,
                updatedAt: profile.updatedAt
            ),
            workingSnapshots: snapshots.map { snap in
                let turnCount = (try? JSONDecoder().decode([CodableHistoryTurn].self, from: snap.completedTurnsJSON ?? Data()))?.count ?? 0
                return MemoryExportPayload.ExportedSnapshot(
                    threadID: snap.threadID,
                    threadSummary: snap.threadSummary,
                    activeGoal: snap.activeGoal,
                    unresolvedTasks: snap.unresolvedTasks,
                    recentDecisions: snap.recentDecisions,
                    completedTurnCount: turnCount,
                    createdAt: snap.createdAt,
                    updatedAt: snap.updatedAt
                )
            },
            checkpoints: checkpoints.map { cp in
                MemoryExportPayload.ExportedCheckpoint(
                    threadID: cp.threadID,
                    goal: cp.goal,
                    lastKnownPhase: cp.lastKnownPhase,
                    completedCleanly: cp.completedCleanly,
                    createdAt: cp.createdAt,
                    updatedAt: cp.updatedAt
                )
            }
        )
    }

    /// Export to a file path.
    func exportToFile(at url: URL) throws {
        let payload = export()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }

    /// Import from a file path.
    func importFromFile(at url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(MemoryExportPayload.self, from: data)

        // Restore profile
        let assembler = MemoryPackAssembler(modelContext: modelContext)
        let profile = assembler.loadOrCreateProfile()
        profile.userName = payload.profile.userName
        profile.userRole = payload.profile.userRole
        profile.appIdentity = payload.profile.appIdentity
        profile.productVision = payload.profile.productVision
        profile.standingInstructions = payload.profile.standingInstructions
        profile.durableFacts = payload.profile.durableFacts
        profile.updatedAt = Date()

        try modelContext.save()
    }

    /// Export to the workspace `.studio92/memory/` directory.
    func exportToWorkspace(projectRoot: String) throws -> URL {
        let memoryDir = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".studio92/memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "memory-snapshot-\(timestamp).json"
        let fileURL = memoryDir.appendingPathComponent(filename)
        try exportToFile(at: fileURL)
        return fileURL
    }
}

// MARK: - Codable History Turn (serialization bridge)

struct CodableHistoryTurn: Codable {
    var role: String
    var text: String
    var contentBlocks: [CodableContentBlock]?
    var timestamp: Date

    struct CodableContentBlock: Codable {
        var type: String  // "text" or "thinking"
        var text: String
        var signature: String?
    }

    init(from turn: ConversationHistoryTurn) {
        self.role = turn.role.rawValue
        self.text = turn.text
        self.timestamp = turn.timestamp
        self.contentBlocks = turn.contentBlocks?.map { block in
            switch block {
            case .text(let text):
                return CodableContentBlock(type: "text", text: text)
            case .thinking(let text, let signature):
                return CodableContentBlock(type: "thinking", text: text, signature: signature)
            }
        }
    }

    func toHistoryTurn() -> ConversationHistoryTurn {
        let turnRole = ConversationHistoryTurn.Role(rawValue: role) ?? .assistant
        let blocks: [ConversationHistoryTurn.HistoryContentBlock]? = contentBlocks?.map { block in
            if block.type == "thinking" {
                return .thinking(text: block.text, signature: block.signature)
            }
            return .text(block.text)
        }
        return ConversationHistoryTurn(
            role: turnRole,
            text: text,
            contentBlocks: blocks,
            timestamp: timestamp
        )
    }
}
