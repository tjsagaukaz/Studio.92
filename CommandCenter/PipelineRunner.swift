// PipelineRunner.swift
// CommandCenter
//
// Dark Factory pipeline orchestration, stage transitions, and run control.

import Foundation
import Combine
import Observation
import AgentCouncil

@MainActor
@Observable
final class PipelineRunner {

    private final class ExecutionState {
        var specialist = StepStatus.pending
        var critic = StepStatus.pending
        var architect = StepStatus.pending
        var weaver = StepStatus.pending
        var verify: StepStatus?
        var executor: StepStatus?

        var specialistTitle = "Specialist proposal"
        var criticTitle = "Critic review"
        var architectTitle = "Architect merge"
        var weaverTitle = "Apply approved changes"

        var councilTool: ToolCall?
        var weaverTool: ToolCall?
        var executorTool: ToolCall?
        var webSearchTool: ToolCall?
        var webFetchTool: ToolCall?
    }

    var stage: PipelineStage = .idle
    var statusMessage: String = "Ready"
    var activeModelName: String?
    /// The primary model name for the current run — restored after sub-agent execution.
    var primaryModelName: String?
    /// When non-nil, the user has manually pinned a model from the composer picker.
    /// This overrides keyword-based routing for the next send (or all sends until cleared).
    var pinnedModelIdentifier: String?
    var criticVerdict: String?
    var errorMessage: String?
    var approvedPacketJSON: String?
    var elapsedSeconds: Int = 0
    var chatThread = ChatThread()
    let deployment = DeploymentCoordinator()
    let streamCoordinator = StreamPipelineCoordinator()
    let compactionCoordinator = CompactionCoordinator()
    var activeGoal: String?
    var activeDisplayGoal: String?
    var activeLatencyRunID: String?
    /// Assembled memory pack for the current session, injected into system prompts.
    var activeMemoryPack: MemoryPack?
    /// Last Anthropic compaction summary, available for persistence after compaction.
    private(set) var lastCompactionSummary: CompactionSummary?
    var goalHistory: [String] = {
        UserDefaults.standard.stringArray(forKey: "goalHistory") ?? []
    }()

    var isRunning: Bool {
        stage == .running
    }

    var packageRoot: String

    private var activeProcess: Process?
    var researcherOutputDir: URL?
    private var elapsedTimer: Timer?
    private var currentExecutionState = ExecutionState()
    var currentRunMessageIDs: [UUID] = []
    private var currentExecutionTreeMessageID: UUID?
    private var currentCompletionMessageID: UUID?
    var currentStreamingMessageID: UUID?
    private var currentPacketID: UUID?
    private var emittedNarrativeKeys: Set<String> = []
    private var currentRunNarrativeCount = 0
    private let maxToolOutputLines = 160
    private var activeAgenticTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private let architectureValidator = ArchitectureValidator()
    /// Tracks consecutive failures on the same goal for DAG retry escalation.
    private var consecutiveFailureCount = 0
    private var lastFailedGoal: String?

    /// Active trace collector for the current run. Observable by UI for live span data.
    var activeTraceCollector: TraceCollector?
    var activeSessionSpanID: UUID?
    /// Completed trace summaries from previous runs in this session.
    var traceHistory: [TraceSummary] = []
    /// Session inspector model — shared with the UI for live span visualization.
    let sessionInspector = SessionInspectorModel()
    private(set) var isCancelling = false

    /// Bbox overlays from the most recent Locate Region response, if any.
    var pendingBBoxOverlays: [NormalizedBBox] = []
    /// Source image URL for the bbox overlays.
    var pendingBBoxSourceImageURL: URL?

    init(packageRoot: String) {
        self.packageRoot = packageRoot
    }

    @MainActor
    func updatePackageRoot(_ newValue: String) async {
        let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != packageRoot else { return }

        if isRunning || isCancelling || cancellationTask != nil {
            await cancel()
        }

        packageRoot = normalized
        stage = .idle
        statusMessage = "Workspace ready"
        criticVerdict = nil
        errorMessage = nil
        approvedPacketJSON = nil
        activeGoal = nil
        activeDisplayGoal = nil
        deployment.reset()
        activeProcess = nil
        activeAgenticTask = nil
        currentExecutionState = ExecutionState()
        currentRunMessageIDs = []
        currentExecutionTreeMessageID = nil
        currentCompletionMessageID = nil
        currentStreamingMessageID = nil
        currentPacketID = nil
        emittedNarrativeKeys = []
        currentRunNarrativeCount = 0
        chatThread = ChatThread()
        activeLatencyRunID = nil
        stopElapsedTimer()
        elapsedSeconds = 0
    }

    // MARK: - Run

    @MainActor
    func run(
        goal: String,
        displayGoal: String? = nil,
        attachments: [ChatAttachment] = [],
        apiKey: String? = nil,
        openAIKey: String? = nil,
        latencyRunID: String? = nil
    ) async {
        let runnerEntryStartedAt = CFAbsoluteTimeGetCurrent()
        if let cancellationTask {
            await cancellationTask.value
        }
        guard !isRunning else { return } // Hard run lock

        let resolvedLatencyRunID = latencyRunID ?? activeLatencyRunID ?? LatencyDiagnostics.makeRunID()
        activeLatencyRunID = resolvedLatencyRunID
        let historyValue = (displayGoal ?? goal).trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationHistory = chatThread.completedTurns
        let resolvedAnthropicKey = StudioModelStrategy.credential(provider: .anthropic, storedValue: apiKey)
        let resolvedOpenAIKey = StudioModelStrategy.credential(provider: .openAI, storedValue: openAIKey)

        // Track consecutive failures for DAG escalation and routing context.
        let failureCount: Int
        if lastFailedGoal == goal {
            failureCount = consecutiveFailureCount
        } else {
            failureCount = 0
        }

        // Model selection: manual pin > context-aware routing > keyword routing > default
        let routing: StudioModelStrategy.RoutingDecision
        if let pinned = pinnedModelIdentifier {
            let pinnedDescriptor = StudioModelStrategy.descriptorForIdentifier(pinned, packageRoot: packageRoot)
            routing = StudioModelStrategy.RoutingDecision(
                model: pinnedDescriptor,
                reason: "manual_pin",
                matchedSignals: []
            )
        } else {
            let routingContext = StudioModelStrategy.RoutingContext(
                goal: goal,
                packageRoot: packageRoot,
                consecutiveFailures: failureCount,
                lastFailedGoal: lastFailedGoal,
                conversationTurnCount: conversationHistory.count,
                attachmentCount: attachments.count,
                contextPressure: compactionCoordinator.contextPressure
            )
            routing = StudioModelStrategy.routingDecision(context: routingContext)
        }
        let selectedModel = routing.model
        activeModelName = selectedModel.shortName
        primaryModelName = selectedModel.shortName

        // Complexity assessment — decides if DAG orchestration is warranted.
        let complexity = TaskComplexityAnalyzer.analyze(
            goal: goal,
            attachmentCount: attachments.count,
            conversationHistoryCount: conversationHistory.count,
            previousFailureCount: failureCount
        )

        // Generate plan context supplement (nil for simple tasks).
        let planContext: String?
        let deterministicPlan: StreamPlan?
        if complexity.shouldUseDAG {
            let plan = TaskPlanGenerator.generate(goal: goal, assessment: complexity)
            if let firstStep = plan.steps.first {
                planContext = TaskPlanPromptInjection.promptSupplement(for: plan, currentStep: firstStep)
            } else {
                planContext = nil
            }
            deterministicPlan = TaskPlanBridge.streamPlan(from: plan)
        } else {
            planContext = nil
            deterministicPlan = nil
        }

        // Save to history
        goalHistory.removeAll { $0 == historyValue }
        goalHistory.insert(historyValue, at: 0)
        if goalHistory.count > 5 { goalHistory = Array(goalHistory.prefix(5)) }
        UserDefaults.standard.set(goalHistory, forKey: "goalHistory")
        let runnerEntryEndedAt = CFAbsoluteTimeGetCurrent()
        await LatencyDiagnostics.shared.recordStage(
            runID: resolvedLatencyRunID,
            name: "PipelineRunner Entry",
            startedAt: runnerEntryStartedAt,
            endedAt: runnerEntryEndedAt,
            notes: "model=\(selectedModel.identifier) provider=\(selectedModel.provider.rawValue) routing=\(routing.reason) signals=\(routing.matchedSignals.joined(separator: ",")) history_turns=\(conversationHistory.count) attachments=\(attachments.count)"
        )

        if let plannedReply = PipelineLightweightReplier.planReply(
            for: displayGoal ?? goal,
            attachments: attachments
        ) {
            let presentationStartedAt = CFAbsoluteTimeGetCurrent()
            beginAgenticPresentation(for: goal, displayGoal: displayGoal, attachments: attachments)
            chatThread.recordTurn(role: .user, text: displayGoal ?? goal)
            startElapsedTimer()
            let presentationEndedAt = CFAbsoluteTimeGetCurrent()
            await LatencyDiagnostics.shared.recordStage(
                runID: resolvedLatencyRunID,
                name: "Initial Presentation Bootstrap",
                startedAt: presentationStartedAt,
                endedAt: presentationEndedAt,
                notes: "lightweight_reply=true"
            )

            let task = Task { [weak self] in
                guard let self else { return }
                await self.runLightweightConversationReply(
                    goal: goal,
                    displayGoal: displayGoal,
                    attachments: attachments,
                    reply: plannedReply.text,
                    delay: plannedReply.delay,
                    latencyRunID: resolvedLatencyRunID
                )
            }
            activeAgenticTask = task
            await task.value
            if activeAgenticTask?.isCancelled == false {
                activeAgenticTask = nil
            }
            stopElapsedTimer()
            return
        }

        if selectedModel.isConfigured(
            anthropicKey: resolvedAnthropicKey,
            openAIKey: resolvedOpenAIKey
        ) {
            let presentationStartedAt = CFAbsoluteTimeGetCurrent()
            beginAgenticPresentation(for: goal, displayGoal: displayGoal, attachments: attachments)
            chatThread.recordTurn(role: .user, text: displayGoal ?? goal)
            startElapsedTimer()
            let presentationEndedAt = CFAbsoluteTimeGetCurrent()
            await LatencyDiagnostics.shared.recordStage(
                runID: resolvedLatencyRunID,
                name: "Initial Presentation Bootstrap",
                startedAt: presentationStartedAt,
                endedAt: presentationEndedAt,
                notes: "lightweight_reply=false"
            )

            let task = Task { [weak self] in
                guard let self else { return }
                await self.runAgentic(
                    goal: goal,
                    attachments: attachments,
                    anthropicAPIKey: resolvedAnthropicKey,
                    openAIKey: resolvedOpenAIKey,
                    selectedModel: selectedModel,
                    routingDecision: routing,
                    conversationHistory: conversationHistory,
                    latencyRunID: resolvedLatencyRunID,
                    planContext: planContext,
                    dagAssessment: complexity,
                    deterministicPlan: deterministicPlan
                )
            }
            activeAgenticTask = task
            await task.value
            if activeAgenticTask?.isCancelled == false {
                activeAgenticTask = nil
            }
            // Track failure state for DAG retry escalation.
            if stage == .failed {
                if lastFailedGoal == goal {
                    consecutiveFailureCount += 1
                } else {
                    consecutiveFailureCount = 1
                    lastFailedGoal = goal
                }
            } else {
                consecutiveFailureCount = 0
                lastFailedGoal = nil
            }
            stopElapsedTimer()
            return
        }

        let configurationMessage = PipelineMemoryPackStager.missingModelCredentialMessage(
            for: selectedModel
        )

        let configurationStartedAt = CFAbsoluteTimeGetCurrent()
        activeGoal = goal
        activeDisplayGoal = displayGoal ?? goal
        stage = .failed
        statusMessage = "Configure model access"
        criticVerdict = nil
        errorMessage = configurationMessage
        approvedPacketJSON = nil
        elapsedSeconds = 0
        currentPacketID = nil
        currentExecutionState = ExecutionState()
        currentRunMessageIDs = []
        currentExecutionTreeMessageID = nil
        currentCompletionMessageID = nil
        currentStreamingMessageID = nil
        emittedNarrativeKeys = []
        currentRunNarrativeCount = 0
        deployment.reset()

        _ = postRunMessage(
            kind: .userGoal,
            goal: goal,
            text: displayGoal ?? goal,
            attachments: attachments
        )
        _ = postRunMessage(
            kind: .error,
            goal: goal,
            text: configurationMessage
        )
        chatThread.recordTurn(role: .user, text: displayGoal ?? goal)
        chatThread.recordAssistantTurn(text: configurationMessage, thinking: nil, thinkingSignature: nil)
        chatThread.setThinking(false)
        stopElapsedTimer()
        let configurationEndedAt = CFAbsoluteTimeGetCurrent()
        await LatencyDiagnostics.shared.recordStage(
            runID: resolvedLatencyRunID,
            name: "Configuration Failure Presentation",
            startedAt: configurationStartedAt,
            endedAt: configurationEndedAt,
            notes: "provider=\(selectedModel.provider.rawValue)"
        )
        return
    }

    @MainActor
    func attachCompletionIfMatching(epoch: Epoch, goal: String) {
        guard let completionID = currentCompletionMessageID else { return }
        guard goal == activeGoal else { return }
        if let currentPacketID, currentPacketID != epoch.packetID {
            return
        }

        let existingMessage = chatThread.messages.first(where: { $0.id == completionID })
        let existingElapsed = existingMessage?.metrics?.elapsedSeconds ?? elapsedSeconds
        let existingScreenshotPath = existingMessage?.screenshotPath
        let metrics = MessageMetrics(
            higScore: Int((epoch.higScore * 100).rounded()),
            archetype: epoch.archetype ?? "",
            targetFile: epoch.targetFile,
            deviationCost: epoch.deviationCost,
            elapsedSeconds: existingElapsed
        )

        chatThread.updateMessageContent(id: completionID) { message in
            message.text = Self.completionText(
                targetFile: epoch.targetFile,
                archetype: epoch.archetype,
                higScore: metrics.higScore,
                elapsedSeconds: existingElapsed
            )
            message.detailText = epoch.summary
            message.screenshotPath = epoch.screenshotPath ?? existingScreenshotPath
            message.metrics = metrics
            message.epochID = epoch.id
            message.packetID = epoch.packetID
        }
    }

    @MainActor
    func cancel() async {
        if let cancellationTask {
            await cancellationTask.value
            return
        }

        let hadWorkToCancel =
            activeProcess != nil
            || activeAgenticTask != nil
            || currentStreamingMessageID != nil
            || isRunning
            || deployment.state.isVisible
            || chatThread.isThinking

        guard hadWorkToCancel else { return }

        let agenticTask = activeAgenticTask

        isCancelling = true
        statusMessage = "Cancelling..."
        activeProcess?.terminate()
        activeProcess = nil
        activeAgenticTask?.cancel()
        activeAgenticTask = nil
        if let currentStreamingMessageID {
            let contentState = chatThread.visibleContentState(forMessageID: currentStreamingMessageID)
            if contentState.hasText {
                chatThread.markPartial(messageID: currentStreamingMessageID)
                chatThread.finalizeStreaming(messageID: currentStreamingMessageID, finalKind: .assistant)
            } else {
                chatThread.removeMessage(id: currentStreamingMessageID)
                currentRunMessageIDs.removeAll { $0 == currentStreamingMessageID }
            }
        }

        let runner = self
        let traceCollector = activeTraceCollector
        let sessionSpanID = activeSessionSpanID
        let cleanupTask = Task.detached(priority: .userInitiated) { [runner, agenticTask, traceCollector, sessionSpanID] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await StatefulTerminalEngine.shared.interruptActiveCommand()
                }
                group.addTask {
                    await FastlaneDeploymentRunner.shared.cancel()
                }
            }

            if let agenticTask {
                await agenticTask.value
            }

            if let tracer = traceCollector,
               let sessionSpanID {
                _ = await runner.ingestArchitectureEvent(
                    .cancelled,
                    tracer: tracer,
                    sessionSpanID: sessionSpanID
                )
                let residualOpenSpans = max(0, await tracer.activeSpanCount() - 1)
                _ = await runner.ingestArchitectureEvent(
                    .traceSnapshot(openSpanCount: residualOpenSpans),
                    tracer: tracer,
                    sessionSpanID: sessionSpanID
                )
                await tracer.end(sessionSpanID, error: "cancelled")
                let summary = await tracer.summary()
                await MainActor.run {
                    runner.traceHistory.append(summary)
                    runner.sessionInspector.stopLive()
                    runner.sessionInspector.finalizeLive(summary: summary)
                    runner.activeSessionSpanID = nil
                }
            }

            await MainActor.run {
                runner.finishCancellation()
                runner.isCancelling = false
                runner.cancellationTask = nil
            }
        }

        cancellationTask = cleanupTask
        await cleanupTask.value
    }

    @MainActor
    private func finishCancellation() {
        stage = .idle
        statusMessage = "Cancelled"
        errorMessage = nil
        activeDisplayGoal = nil
        activeSessionSpanID = nil
        currentExecutionState = ExecutionState()
        currentExecutionTreeMessageID = nil
        currentCompletionMessageID = nil
        currentStreamingMessageID = nil
        currentPacketID = nil
        emittedNarrativeKeys = []
        currentRunNarrativeCount = 0
        currentRunMessageIDs = []
        deployment.reset()
        compactionCoordinator.setPipelineActive(false)
        compactionCoordinator.setToolLoopActive(false)
        compactionCoordinator.returnToIdle()
        chatThread.setThinking(false)
        stopElapsedTimer()
    }

    @MainActor
    func reset() {
        stage = .idle
        statusMessage = "Ready"
        criticVerdict = nil
        errorMessage = nil
        approvedPacketJSON = nil
        elapsedSeconds = 0
        activeGoal = nil
        activeDisplayGoal = nil
        activeSessionSpanID = nil
        currentExecutionState = ExecutionState()
        currentRunMessageIDs = []
        currentExecutionTreeMessageID = nil
        currentCompletionMessageID = nil
        currentStreamingMessageID = nil
        currentPacketID = nil
        emittedNarrativeKeys = []
        currentRunNarrativeCount = 0
        deployment.reset()
        compactionCoordinator.setPipelineActive(false)
        compactionCoordinator.setToolLoopActive(false)
        compactionCoordinator.returnToIdle()
        chatThread.clear()
        streamCoordinator.reset()
        stopElapsedTimer()
    }

    @MainActor
    func presentAgenticFailure(messageID: UUID, goal: String, message: String) {
        stage = .failed
        statusMessage = "Failed"
        errorMessage = Self.concise(message)
        chatThread.setThinking(false)
        streamCoordinator.failRun(message: message)
        compactionCoordinator.setPipelineActive(false)
        compactionCoordinator.setToolLoopActive(false)

        let contentState = chatThread.visibleContentState(forMessageID: messageID)
        if contentState.hasText || contentState.hasThinking || contentState.hasToolCalls {
            chatThread.finalizeStreaming(messageID: messageID, finalKind: .assistant)
            if let finalizedMessage = chatThread.messages.first(where: { $0.id == messageID }) {
                chatThread.recordAssistantTurn(
                    text: finalizedMessage.text,
                    thinking: finalizedMessage.thinkingText,
                    thinkingSignature: finalizedMessage.thinkingSignature
                )
            }
            _ = postRunMessage(
                kind: .error,
                goal: goal,
                text: "The request failed: \(Self.concise(message))."
            )
            chatThread.recordAssistantTurn(
                text: "The request failed: \(Self.concise(message)).",
                thinking: nil,
                thinkingSignature: nil
            )
        } else {
            chatThread.failStreaming(
                messageID: messageID,
                errorText: "The request failed: \(Self.concise(message))."
            )
            chatThread.recordAssistantTurn(
                text: "The request failed: \(Self.concise(message)).",
                thinking: nil,
                thinkingSignature: nil
            )
        }
    }

    func ingestArchitectureEvent(
        _ eventKind: ArchitectureRuntimeEventKind,
        tracer: TraceCollector?,
        sessionSpanID: UUID?
    ) async -> String? {
        let violations = await architectureValidator.ingest(
            ArchitectureRuntimeEvent(kind: eventKind)
        )

        var firstCriticalMessage: String?
        for violation in violations {
            if firstCriticalMessage == nil, violation.severity == .critical {
                firstCriticalMessage = violation.message
            }

            guard let tracer else { continue }

            let attributes = [
                "violationKind": violation.kind.rawValue,
                "severity": violation.severity.rawValue,
                "message": String(violation.message.prefix(500))
            ]
            let violationSpanID = await tracer.begin(
                kind: .architectureViolation,
                name: "architecture_violation",
                parentID: sessionSpanID,
                attributes: attributes
            )
            if violation.severity == .critical {
                await tracer.end(violationSpanID, error: violation.message)
            } else {
                await tracer.end(violationSpanID)
            }
        }

        return firstCriticalMessage
    }

    static func architectureRuntimeEvent(for event: AgenticEvent) -> ArchitectureRuntimeEventKind {
        switch event {
        case .toolCallStart(let id, _):
            return .toolStarted(id: id)
        case .toolCallResult(let id, _, _):
            return .toolCompleted(id: id)
        case .completed:
            return .completed
        case .error(let message):
            return .failed(message)
        default:
            return .observed
        }
    }

    // MARK: - Private

    @MainActor
    private func finalizeLightweightConversationReply(
        goal: String,
        displayGoal: String?,
        attachments: [ChatAttachment],
        reply: String
    ) {
        let presentedGoal = displayGoal ?? goal

        activeGoal = goal
        activeDisplayGoal = presentedGoal
        stage = .idle
        statusMessage = "Ready"
        criticVerdict = nil
        errorMessage = nil
        approvedPacketJSON = nil
        elapsedSeconds = 0
        currentPacketID = nil
        currentExecutionState = ExecutionState()
        currentRunMessageIDs = []
        currentExecutionTreeMessageID = nil
        currentCompletionMessageID = nil
        currentStreamingMessageID = nil
        emittedNarrativeKeys = []
        currentRunNarrativeCount = 0
        deployment.reset()
        stopElapsedTimer()
        chatThread.setThinking(false)
        _ = postRunMessage(
            kind: .assistant,
            goal: goal,
            text: reply
        )

        chatThread.recordAssistantTurn(text: reply, thinking: nil, thinkingSignature: nil)
    }

    private func runLightweightConversationReply(
        goal: String,
        displayGoal: String?,
        attachments: [ChatAttachment],
        reply: String,
        delay: Duration,
        latencyRunID: String?
    ) async {
        let delayStartedAt = CFAbsoluteTimeGetCurrent()
        do {
            try await Task.sleep(for: delay)
        } catch {
            return
        }
        let delayEndedAt = CFAbsoluteTimeGetCurrent()
        await LatencyDiagnostics.shared.recordStage(
            runID: latencyRunID,
            name: "Lightweight Reply Delay",
            startedAt: delayStartedAt,
            endedAt: delayEndedAt,
            notes: "goal=\(displayGoal ?? goal)"
        )

        guard !Task.isCancelled else { return }

        let finalizeStartedAt = CFAbsoluteTimeGetCurrent()
        await MainActor.run {
            finalizeLightweightConversationReply(
                goal: goal,
                displayGoal: displayGoal,
                attachments: attachments,
                reply: reply
            )
        }
        let finalizeEndedAt = CFAbsoluteTimeGetCurrent()
        await LatencyDiagnostics.shared.recordStage(
            runID: latencyRunID,
            name: "Lightweight Reply Finalization",
            startedAt: finalizeStartedAt,
            endedAt: finalizeEndedAt,
            notes: "reply_chars=\(reply.count)"
        )
    }

    @MainActor
    private func beginAgenticPresentation(for goal: String, displayGoal: String?, attachments: [ChatAttachment]) {
        activeGoal = goal
        activeDisplayGoal = displayGoal ?? goal
        stage = .running
        statusMessage = "Working..."
        criticVerdict = nil
        errorMessage = nil
        approvedPacketJSON = nil
        elapsedSeconds = 0
        currentPacketID = nil
        currentExecutionState = ExecutionState()
        currentRunMessageIDs = []
        currentExecutionTreeMessageID = nil
        currentCompletionMessageID = nil
        currentStreamingMessageID = nil
        emittedNarrativeKeys = []
        currentRunNarrativeCount = 0
        deployment.reset()

        streamCoordinator.beginRun(goal: goal)

        _ = postRunMessage(
            kind: .userGoal,
            goal: goal,
            text: displayGoal ?? goal,
            attachments: attachments
        )
        chatThread.setThinking(true)
    }

    private func runAgentic(
        goal: String,
        attachments: [ChatAttachment],
        anthropicAPIKey: String?,
        openAIKey: String?,
        selectedModel: StudioModelDescriptor,
        routingDecision: StudioModelStrategy.RoutingDecision,
        conversationHistory: [ConversationHistoryTurn],
        latencyRunID: String?,
        planContext: String? = nil,
        dagAssessment: TaskComplexityAnalyzer.ComplexityAssessment? = nil,
        deterministicPlan: StreamPlan? = nil
    ) async {
        let orchestrator = PipelineRunOrchestrator(runner: self)
        await orchestrator.run(
            goal: goal,
            attachments: attachments,
            anthropicAPIKey: anthropicAPIKey,
            openAIKey: openAIKey,
            selectedModel: selectedModel,
            routingDecision: routingDecision,
            conversationHistory: conversationHistory,
            latencyRunID: latencyRunID,
            planContext: planContext,
            dagAssessment: dagAssessment,
            deterministicPlan: deterministicPlan
        )
    }

    // MARK: - Context Compaction

    @MainActor
    func performCompaction(
        model: StudioModelDescriptor,
        anthropicKey: String?,
        openAIKey: String?
    ) async {
        if let architectureAbortMessage = await ingestArchitectureEvent(
            .compactionStarted,
            tracer: activeTraceCollector,
            sessionSpanID: activeSessionSpanID
        ) {
            errorMessage = Self.concise(architectureAbortMessage)
            return
        }

        let context = CompactionOrchestrationContext(
            model: model,
            anthropicKey: anthropicKey,
            openAIKey: openAIKey,
            chatThread: chatThread,
            packageRoot: packageRoot,
            researcherOutputDir: researcherOutputDir,
            tracer: activeTraceCollector,
            sessionSpanID: activeSessionSpanID
        )

        let result = await compactionCoordinator.orchestrate(context: context)
        lastCompactionSummary = result.summary

        _ = await ingestArchitectureEvent(
            result.failureMessage == nil ? .compactionCompleted : .compactionFailed,
            tracer: activeTraceCollector,
            sessionSpanID: activeSessionSpanID
        )
    }

    @MainActor
    private func postNarrativeMessage(
        kind: ChatMessage.Kind,
        key: String,
        text: String,
        force: Bool = false
    ) {
        guard !emittedNarrativeKeys.contains(key) else { return }
        guard force || currentRunNarrativeCount < 2 else { return }

        emittedNarrativeKeys.insert(key)
        currentRunNarrativeCount += 1
        _ = postRunMessage(kind: kind, goal: activeGoal ?? "", text: text)
    }

    @MainActor
    @discardableResult
    private func postRunMessage(
        kind: ChatMessage.Kind,
        goal: String,
        text: String,
        detailText: String? = nil,
        screenshotPath: String? = nil,
        metrics: MessageMetrics? = nil,
        executionTree: [ExecutionStep]? = nil,
        attachments: [ChatAttachment] = []
    ) -> UUID {
        let message = ChatMessage(
            kind: kind,
            goal: goal,
            text: text,
            detailText: detailText,
            timestamp: Date(),
            screenshotPath: screenshotPath,
            metrics: metrics,
            executionTree: executionTree,
            attachments: attachments,
            epochID: nil,
            packetID: currentPacketID
        )
        currentRunMessageIDs.append(message.id)
        chatThread.post(message)
        return message.id
    }

    @MainActor
    private func refreshExecutionTreeMessage(for goal: String) {
        let tree = makeExecutionTree()
        if let messageID = currentExecutionTreeMessageID {
            chatThread.updateMessageContent(id: messageID) { message in
                message.executionTree = tree
            }
        } else {
            currentExecutionTreeMessageID = postRunMessage(
                kind: .executionTree,
                goal: goal,
                text: "Execution",
                executionTree: tree
            )
        }
    }

    @MainActor
    private func refreshExecutionTreeMessageIfPossible() {
        guard let activeGoal else { return }
        refreshExecutionTreeMessage(for: activeGoal)
    }

    private static func appendingToolLine(
        _ line: String,
        to toolCall: ToolCall?,
        maxLines: Int
    ) -> ToolCall? {
        guard let normalizedLine = normalizedToolOutput(line) else { return toolCall }
        guard var toolCall else { return nil }

        toolCall.liveOutput.append(normalizedLine)
        if toolCall.liveOutput.count > maxLines {
            toolCall.liveOutput.removeFirst(toolCall.liveOutput.count - maxLines)
        }
        return toolCall
    }

    private func makeExecutionTree() -> [ExecutionStep] {
        let councilChildren = [
            ExecutionStep(
                id: "specialist",
                title: currentExecutionState.specialistTitle,
                role: "Specialist",
                status: currentExecutionState.specialist
            ),
            ExecutionStep(
                id: "critic",
                title: currentExecutionState.criticTitle,
                role: "Critic",
                status: currentExecutionState.critic
            ),
            ExecutionStep(
                id: "architect",
                title: currentExecutionState.architectTitle,
                role: "Architect",
                status: currentExecutionState.architect
            )
        ]

        var pipelineChildren: [ExecutionStep] = [
            ExecutionStep(
                id: "researcher",
                title: "Live Apple API context",
                role: "Researcher",
                status: currentExecutionState.webSearchTool?.status ?? .pending,
                toolCall: currentExecutionState.webSearchTool
            ),
            ExecutionStep(
                id: "council",
                title: "Council review",
                role: "Council",
                status: aggregateStatus(for: councilChildren.map(\.status)),
                toolCall: currentExecutionState.councilTool,
                children: councilChildren
            ),
            ExecutionStep(
                id: "weaver",
                title: currentExecutionState.weaverTitle,
                role: "Weaver",
                status: currentExecutionState.weaver,
                toolCall: currentExecutionState.weaverTool
            )
        ]

        if let webFetchTool = currentExecutionState.webFetchTool {
            pipelineChildren.append(
                ExecutionStep(
                    id: "web-fetch",
                    title: "Web fetch",
                    role: "Web",
                    status: webFetchTool.status,
                    toolCall: webFetchTool
                )
            )
        }

        if let verify = currentExecutionState.verify {
            pipelineChildren.append(
                ExecutionStep(
                    id: "verify",
                    title: "Verify build",
                    role: "Verifier",
                    status: verify
                )
            )
        }

        if let executor = currentExecutionState.executor {
            pipelineChildren.append(
                ExecutionStep(
                    id: "executor",
                    title: "Automatic repair",
                    role: "Executor",
                    status: executor,
                    toolCall: currentExecutionState.executorTool
                )
            )
        }

        return [
            ExecutionStep(
                id: "pipeline",
                title: "Pipeline run",
                role: "Pipeline",
                status: aggregateStatus(for: pipelineChildren.map(\.status)),
                children: pipelineChildren
            )
        ]
    }

    private func aggregateStatus(for statuses: [StepStatus]) -> StepStatus {
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.active) { return .active }
        if statuses.allSatisfy({ $0 == .completed }) { return .completed }
        if statuses.contains(.warning) { return .warning }
        if statuses.contains(.completed) { return .active }
        return .pending
    }

    private static func normalizedToolOutput(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func executePersistentShellCommand(
        _ command: String,
        displayCommand: String? = nil
    ) async -> StepStatus {
        let presentedCommand = (displayCommand ?? command).trimmingCharacters(in: .whitespacesAndNewlines)
        let commandID = UUID().uuidString

        await MainActor.run {
            stage = .running
            statusMessage = "Running \(presentedCommand)..."
            currentExecutionState.executor = .active
            currentExecutionState.executorTool = ToolCall(
                toolType: .terminal,
                command: presentedCommand,
                status: .active
            )
            refreshExecutionTreeMessageIfPossible()
        }

        SimulatorShellCommandNotifier.commandDidStart(
            id: commandID,
            command: presentedCommand,
            projectRoot: packageRoot
        )

        let stream = await StatefulTerminalEngine.shared.execute(command)
        var liveOutput: [String] = []

        for await line in stream {
            liveOutput.append(line)
            await MainActor.run {
                let updatedExecutorTool = Self.appendingToolLine(
                    line,
                    to: currentExecutionState.executorTool,
                    maxLines: maxToolOutputLines
                )
                currentExecutionState.executorTool = updatedExecutorTool
                refreshExecutionTreeMessageIfPossible()
            }
        }

        let exitStatus = await StatefulTerminalEngine.shared.lastExitStatus()
        let finalStatus: StepStatus = exitStatus == 0 ? .completed : .failed

        SimulatorShellCommandNotifier.commandDidFinish(
            id: commandID,
            command: presentedCommand,
            projectRoot: packageRoot,
            output: liveOutput.joined(separator: "\n"),
            exitStatus: Int32(exitStatus ?? -1)
        )

        await MainActor.run {
            currentExecutionState.executor = finalStatus
            currentExecutionState.executorTool?.status = finalStatus

            if finalStatus == .completed {
                statusMessage = "Command finished."
            } else {
                statusMessage = "Command failed."
                errorMessage = "Command exited with status \(exitStatus ?? -1)."
            }

            refreshExecutionTreeMessageIfPossible()
        }

        return finalStatus
    }

    private static func completionText(
        targetFile: String,
        archetype: String?,
        higScore: Int,
        elapsedSeconds: Int
    ) -> String {
        let fileName = (targetFile as NSString).lastPathComponent
        let designDirection = designDirectionText(for: archetype)
        return "Done — I built \(fileName) with \(designDirection). HIG alignment is \(higScore)%. Took \(elapsedDurationText(from: elapsedSeconds))."
    }

    private static func designDirectionText(for archetype: String?) -> String {
        switch archetype?.lowercased() {
        case "athletic":
            return "an energetic, performance-led direction"
        case "financial":
            return "a sober, trust-first direction"
        case "socialreactive":
            return "a lively, reactive direction"
        case "tactical":
            return "a precise, information-forward direction"
        case "utilityminimal":
            return "a minimal, distraction-free direction"
        default:
            return "a focused, native direction"
        }
    }

    private static func elapsedDurationText(from elapsedSeconds: Int) -> String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        if minutes == 0 {
            return "\(seconds) second\(seconds == 1 ? "" : "s")"
        }
        return "\(minutes)m \(seconds)s"
    }

    static func concise(_ message: String) -> String {
        message
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? message
    }

    /// Extract JSON packet from stdout. Finds balanced braces after "APPROVED PACKET:" marker.
    nonisolated private static func extractPacketJSON(from stdout: String) -> String? {
        // Look for marker first
        let searchText: String
        if let markerRange = stdout.range(of: "APPROVED PACKET:") {
            searchText = String(stdout[markerRange.upperBound...])
        } else {
            // Fallback: try to find top-level JSON object
            searchText = stdout
        }

        guard let firstBrace = searchText.firstIndex(of: "{") else { return nil }

        var depth = 0
        var endIndex = firstBrace
        for i in searchText[firstBrace...].indices {
            switch searchText[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    endIndex = searchText.index(after: i)
                    return String(searchText[firstBrace..<endIndex])
                }
            default: break
            }
        }
        return nil
    }

    // MARK: - Telemetry Drop

    nonisolated static func resolveScreenshotPath(for packetID: UUID) -> String? {
        let telemetryDir = FactoryObserver.telemetryDir
        let candidates = [
            telemetryDir.appendingPathComponent("\(packetID.uuidString).png"),
            telemetryDir.appendingPathComponent("processed", isDirectory: true)
                .appendingPathComponent("\(packetID.uuidString).png")
        ]

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })?.path
    }

    private func dropTelemetryPacket(goal: String) {
        guard let json = approvedPacketJSON,
              let data = json.data(using: .utf8),
              let packet = try? JSONDecoder().decode(PacketSummary.self, from: data) else { return }

        // Build a TelemetryPacket with the goal context
        let telemetry = TelemetryPacket(
            goal: goal,
            displayGoal: activeDisplayGoal,
            projectName: nil,
            packetID: packet.packetID,
            sender: packet.sender,
            intent: packet.intent,
            scope: packet.scope,
            payload: TelemetryPacket.Payload(
                rationale: packet.payload.rationale,
                targetFile: packet.payload.targetFile,
                isNewFile: packet.payload.isNewFile,
                diffText: packet.payload.diffText,
                affectedTypes: packet.payload.affectedTypes,
                archetypeClassification: packet.payload.archetypeClassification.map {
                    TelemetryPacket.Payload.ArchetypeInfo(dominant: $0.dominant, confidence: $0.confidence)
                }
            ),
            metrics: TelemetryPacket.Metrics(
                higComplianceScore: packet.metrics.higComplianceScore,
                deviationBudgetCost: packet.metrics.deviationBudgetCost
            ),
            driftScore: nil,
            driftMode: nil
        )

        guard let telemetryData = try? JSONEncoder().encode(telemetry),
              let telemetryJSON = String(data: telemetryData, encoding: .utf8) else { return }

        FactoryObserver.dropTelemetry(packetJSON: telemetryJSON, packetID: packet.packetID.uuidString)
    }

    // MARK: - Timer

    @MainActor
    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedSeconds += 1
            }
        }
    }

    @MainActor
    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}

