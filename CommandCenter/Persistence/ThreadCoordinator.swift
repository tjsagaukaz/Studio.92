// ThreadCoordinator.swift
// Studio.92 — Command Center
// Owns thread persistence, sidebar threads, session selection, composer state, and submitGoal.

import SwiftUI
import SwiftData

@Observable @MainActor
final class ThreadCoordinator {

    // MARK: - Owned State

    var activeThreadID: UUID?
    var threadPersistence: ThreadPersistenceCoordinator?
    var workingMemoryPersistence: WorkingMemoryPersistence?
    var runCheckpointManager: RunCheckpointManager?
    var memoryPackAssembler: MemoryPackAssembler?
    var sidebarThreads: [PersistedThread] = []
    var resumeThread: PersistedThread?
    var selectedSessionID: UUID?
    var restoredContentOpacity: Double = 1.0
    var didAutorunPrompt = false
    var goalText = ""
    var composerAttachments: [ChatAttachment] = []
    let titleGenerator = ThreadTitleGenerator()

    // MARK: - Shared References

    let runner: PipelineRunner
    let conversationStore: ConversationStore
    let jobMonitor: JobMonitor
    let repositoryMonitor: RepositoryMonitor

    // MARK: - Cross-coordinator & View References (set via configure)

    weak var workspace: WorkspaceCoordinator?
    private(set) var viewportModel: ViewportStreamModel!
    private(set) var simulatorPreviewService: SimulatorPreviewService!

    init(
        runner: PipelineRunner,
        conversationStore: ConversationStore,
        jobMonitor: JobMonitor,
        repositoryMonitor: RepositoryMonitor
    ) {
        self.runner = runner
        self.conversationStore = conversationStore
        self.jobMonitor = jobMonitor
        self.repositoryMonitor = repositoryMonitor
    }

    func configure(viewportModel: ViewportStreamModel, previewService: SimulatorPreviewService) {
        self.viewportModel = viewportModel
        self.simulatorPreviewService = previewService

        titleGenerator.onTitleGenerated = { [weak self] threadID, title in
            guard let self else { return }
            if let thread = self.threadPersistence?.thread(byID: threadID) {
                thread.title = title
                thread.updatedAt = Date()
            }
            self.refreshSidebarThreads()
        }
    }

    // MARK: - Computed Properties

    var selectedSession: AgentSession? {
        jobMonitor.session(id: selectedSessionID)
    }

    var activeJobProjectIDs: Set<UUID> {
        guard let workspace else { return [] }
        var ids = Set<UUID>()
        for job in jobMonitor.sessions where job.status == .running {
            if let project = workspace.engine.projects.first(where: { $0.name == job.branchName }) {
                ids.insert(project.id)
            }
        }
        return ids
    }

    var threadProjectIDs: Set<UUID> {
        let cutoff = Date().addingTimeInterval(-600)
        var ids = Set<UUID>()
        for thread in sidebarThreads {
            if let pid = thread.projectID, thread.updatedAt > cutoff {
                ids.insert(pid)
            }
        }
        return ids
    }

    // MARK: - Persistence Initialization

    func initializePersistence(modelContext: ModelContext) {
        guard threadPersistence == nil else { return }
        threadPersistence = ThreadPersistenceCoordinator(modelContext: modelContext)
        workingMemoryPersistence = WorkingMemoryPersistence(modelContext: modelContext)
        runCheckpointManager = RunCheckpointManager(modelContext: modelContext)
        memoryPackAssembler = MemoryPackAssembler(modelContext: modelContext)
        _ = memoryPackAssembler?.loadOrCreateProfile()
        runCheckpointManager?.garbageCollect()
        workingMemoryPersistence?.garbageCollect()
    }

    // MARK: - Thread Rehydration

    func rehydrateThread(forProject projectID: UUID) {
        guard !runner.isRunning else { return }
        guard let coordinator = threadPersistence else { return }
        let threads = coordinator.threads(forProject: projectID, limit: 1)
        guard let latest = threads.first else { return }
        restoredContentOpacity = 0
        coordinator.rehydrate(thread: latest, into: conversationStore)
        activeThreadID = latest.id
        restoreRunnerWorkingMemory(threadID: latest.id)
        withAnimation(StudioMotion.softFade) {
            restoredContentOpacity = 1.0
        }
    }

    func rehydrateThread(_ thread: PersistedThread) {
        guard !runner.isRunning else { return }
        guard let coordinator = threadPersistence else { return }
        restoredContentOpacity = 0
        coordinator.rehydrate(thread: thread, into: conversationStore)
        activeThreadID = thread.id
        titleGenerator.reset()
        if let projectID = thread.projectID {
            workspace?.selectedProjectID = projectID
        }
        restoreRunnerWorkingMemory(threadID: thread.id)
        withAnimation(StudioMotion.softFade) {
            restoredContentOpacity = 1.0
        }
    }

    func restoreRunnerWorkingMemory(threadID: UUID) {
        guard let persistence = workingMemoryPersistence else { return }
        let restoredTurns = persistence.restore(threadID: threadID)
        if !restoredTurns.isEmpty {
            runner.chatThread.completedTurns = restoredTurns
        }
    }

    // MARK: - Thread Lifecycle

    func persistCurrentThread() {
        guard !conversationStore.turns.isEmpty else { return }
        threadPersistence?.persist(
            threadID: activeThreadID,
            turns: conversationStore.turns,
            goal: runner.activeGoal ?? conversationStore.turns.first?.userGoal ?? "",
            workspacePath: repositoryMonitor.workspaceURL.path,
            projectID: workspace?.selectedProjectID
        )
        if let threadID = activeThreadID {
            let summaryJSON: Data? = {
                guard let summary = runner.lastCompactionSummary else { return nil }
                return try? JSONEncoder().encode(summary)
            }()
            workingMemoryPersistence?.save(
                threadID: threadID,
                completedTurns: runner.chatThread.completedTurns,
                compactionSummaryJSON: summaryJSON,
                unresolvedTasks: runner.lastCompactionSummary?.openTasks ?? [],
                recentDecisions: runner.lastCompactionSummary?.decisions ?? [],
                activeGoal: runner.activeGoal
            )
        }
    }

    func startNewThread() {
        guard !runner.isRunning else { return }
        if !conversationStore.turns.isEmpty {
            threadPersistence?.persist(
                threadID: activeThreadID,
                turns: conversationStore.turns,
                goal: runner.activeGoal ?? "",
                workspacePath: repositoryMonitor.workspaceURL.path,
                projectID: workspace?.selectedProjectID
            )
            refreshSidebarThreads()
        }
        goalText = ""
        composerAttachments = []
        workspace?.selectedProjectID = nil
        selectedSessionID = nil
        activeThreadID = nil
        conversationStore.reset()
        runner.reset()
        titleGenerator.reset()
        viewportModel.resetToAutomatic(selectedEpoch: nil, previewService: simulatorPreviewService)
    }

    func deleteThread(_ thread: PersistedThread, modelContext: ModelContext) {
        if activeThreadID == thread.id {
            activeThreadID = nil
            conversationStore.reset()
            runner.reset()
            titleGenerator.reset()
        }
        modelContext.delete(thread)
        modelContext.saveWithLogging()
        refreshSidebarThreads()
    }

    // MARK: - Thread Queries

    func refreshSidebarThreads() {
        guard let coordinator = threadPersistence else { return }
        let activeProjectIDs = activeJobProjectIDs
        sidebarThreads = coordinator.scoredThreads(
            forWorkspace: repositoryMonitor.workspaceURL.path,
            activeJobProjectIDs: activeProjectIDs
        )
        resumeThread = coordinator.mostRecentThread(
            forWorkspace: repositoryMonitor.workspaceURL.path
        )
    }

    // MARK: - Session Selection

    func selectSession(_ sessionID: UUID) {
        guard let workspace else { return }
        selectedSessionID = sessionID
        viewportModel.resetToAutomatic(selectedEpoch: workspace.selectedEpoch, previewService: simulatorPreviewService)
    }

    // MARK: - Goal Submission

    func submitGoal(modelContext: ModelContext) {
        let submitTriggeredAt = CFAbsoluteTimeGetCurrent()
        let rawGoal = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = composerAttachments
        let hasVisualReference = attachments.contains(where: { $0.isImage })
        let displayGoal = rawGoal.isEmpty && hasVisualReference
            ? "Recreate the attached visual reference in native SwiftUI."
            : rawGoal
        guard !displayGoal.isEmpty else { return }
        let goal = Self.composePipelineGoal(displayGoal: displayGoal, attachments: attachments)
        goalText = ""
        composerAttachments = []
        guard let workspace else { return }
        let ambientContextSnapshot = workspace.ambientContext.executionSnapshot()
        viewportModel.resetToAutomatic(selectedEpoch: workspace.selectedEpoch, previewService: simulatorPreviewService)

        let apiKey = StudioCredentialStore.load(key: "anthropicAPIKey")
        let openAIKey = StudioCredentialStore.load(key: "openAIAPIKey")
        let submitPreparedAt = CFAbsoluteTimeGetCurrent()
        let latencyRunID = LatencyDiagnostics.makeRunID()

        Task {
            await LatencyDiagnostics.shared.beginRun(
                id: latencyRunID,
                goalPreview: displayGoal,
                triggeredAt: submitTriggeredAt,
                metadata: [
                    "attachment_count": String(attachments.count),
                    "has_visual_reference": hasVisualReference ? "true" : "false"
                ]
            )
            await LatencyDiagnostics.shared.recordStage(
                runID: latencyRunID,
                name: "UI Submit Pipeline",
                startedAt: submitTriggeredAt,
                endedAt: submitPreparedAt,
                notes: "display_goal_chars=\(displayGoal.count) composed_goal_chars=\(goal.count) attachments=\(attachments.count)"
            )
            await LatencyDiagnostics.shared.markPoint(
                runID: latencyRunID,
                name: "Runner Task Invoked",
                notes: "submitGoal dispatched PipelineRunner.run"
            )

            if let assembler = memoryPackAssembler {
                let pack = assembler.assemble(
                    threadID: activeThreadID,
                    activeGoal: displayGoal,
                    completedTurns: runner.chatThread.completedTurns
                )
                runner.activeMemoryPack = pack
            }

            let runThreadID: UUID
            if let existing = activeThreadID {
                runThreadID = existing
            } else if let coordinator = threadPersistence,
                      let recent = coordinator.mostRecentThread(forWorkspace: repositoryMonitor.workspaceURL.path) {
                runThreadID = recent.id
                activeThreadID = runThreadID
            } else {
                runThreadID = UUID()
                activeThreadID = runThreadID
            }

            runCheckpointManager?.beginRun(threadID: runThreadID, goal: displayGoal)

            await runner.run(
                goal: goal,
                displayGoal: displayGoal,
                attachments: attachments,
                ambientContextSnapshot: ambientContextSnapshot,
                apiKey: apiKey,
                openAIKey: openAIKey,
                latencyRunID: latencyRunID
            )

            if runner.stage == .failed {
                runCheckpointManager?.markFailed(threadID: runThreadID)
            } else {
                runCheckpointManager?.markCompleted(threadID: runThreadID)
            }

            let summaryJSON: Data? = {
                guard let summary = runner.lastCompactionSummary else { return nil }
                return try? JSONEncoder().encode(summary)
            }()
            workingMemoryPersistence?.save(
                threadID: runThreadID,
                completedTurns: runner.chatThread.completedTurns,
                compactionSummaryJSON: summaryJSON,
                unresolvedTasks: runner.lastCompactionSummary?.openTasks ?? [],
                recentDecisions: runner.lastCompactionSummary?.decisions ?? [],
                activeGoal: displayGoal
            )

            let ingestStartedAt = CFAbsoluteTimeGetCurrent()
            var ingestNotes = "no packet ingest"
            if runner.stage == .succeeded,
               let json = runner.approvedPacketJSON,
               let data = json.data(using: .utf8),
               let packet = try? JSONDecoder().decode(PacketSummary.self, from: data) {
                let result = workspace.engine.ingestPipelineResult(
                    goal: goal,
                    displayGoal: displayGoal,
                    packet: packet,
                    context: modelContext
                )
                if case .success(let projectID) = result {
                    workspace.selectedProjectID = projectID
                    ingestNotes = "ingested project_id=\(projectID.uuidString)"
                    if let latestEpoch = workspace.engine.project(for: projectID)?.sortedEpochs.last {
                        workspace.selectedEpochID = latestEpoch.id
                        runner.attachCompletionIfMatching(epoch: latestEpoch, goal: goal)
                        ingestNotes += " epoch_id=\(latestEpoch.id.uuidString)"
                    }
                } else {
                    ingestNotes = "ingest failed"
                }
            }
            let ingestEndedAt = CFAbsoluteTimeGetCurrent()
            await LatencyDiagnostics.shared.recordStage(
                runID: latencyRunID,
                name: "Pipeline Result Ingest",
                startedAt: ingestStartedAt,
                endedAt: ingestEndedAt,
                notes: ingestNotes
            )
            await LatencyDiagnostics.shared.finishRun(
                runID: latencyRunID,
                outcome: runner.stage.rawValue,
                notes: runner.statusMessage
            )

            threadPersistence?.persist(
                threadID: activeThreadID,
                turns: conversationStore.turns,
                goal: displayGoal,
                workspacePath: repositoryMonitor.workspaceURL.path,
                projectID: workspace.selectedProjectID
            )
            refreshSidebarThreads()

            // Auto-generate thread title after first successful response
            if let threadID = activeThreadID,
               runner.stage != .failed {
                let firstResponse = conversationStore.turns.first?.response.renderedText ?? ""
                if !firstResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    titleGenerator.generateIfNeeded(
                        threadID: threadID,
                        userGoal: displayGoal,
                        assistantResponse: firstResponse
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    static func composePipelineGoal(displayGoal: String, attachments: [ChatAttachment]) -> String {
        let fileReferences = attachments.filter { !$0.isImage }
        guard !fileReferences.isEmpty else { return displayGoal }

        let references = fileReferences
            .map { "- \($0.url.path)" }
            .joined(separator: "\n")

        return """
        \(displayGoal)

        Reference files:
        \(references)
        """
    }
}
