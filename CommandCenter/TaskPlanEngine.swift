// TaskPlanEngine.swift
// Studio.92 — Command Center
//
// Invisible hybrid DAG layer. Activates ONLY for complex multi-step tasks.
// Simple tasks bypass this entirely and hit the normal run loop.
//
// Architecture:
//   1. TaskComplexityAnalyzer — decides if DAG mode is warranted
//   2. TaskPlan / TaskStep — ephemeral execution plan (never persisted)
//   3. TaskPlanExecutor — dependency-ordered execution with parallel support
//   4. Plan context injection — augments system prompt with step awareness
//
// The user never sees nodes, graphs, or dependencies.
// They see: "Analyzing project…", "Running build…", "Done."

import Foundation
import AgentCouncil

// MARK: - Task Step

/// A single unit of work in a task plan.
/// Steps define intent and ordering — the LLM still does the actual work.
struct TaskStep: Identifiable, Equatable, Sendable {
    let id: String
    let intent: String              // Human description: "Read onboarding files"
    let phase: TaskPhase            // Broad categorization for ordering
    let toolHint: TaskToolHint      // Expected primary tool class
    let canRunInParallel: Bool      // Safe to run concurrently with peer steps
    let dependsOn: [String]         // Step IDs this step must wait for
    var status: TaskStepStatus = .pending
    var failureReason: String?
    var retryCount: Int = 0
    /// When set by PlanAdaptationPolicy, overrides the default model for this step.
    var recommendedRole: StudioModelRole?

    static let maxRetries = 2
}

enum TaskPhase: String, Equatable, Sendable {
    case discovery     // File reads, searches, context gathering
    case analysis      // Understanding structure, identifying changes
    case implementation // Code writes, patches, refactors
    case verification  // Build, test, lint
    case repair        // Fix errors found during verification
}

enum TaskToolHint: String, Equatable, Sendable {
    case fileRead
    case fileWrite
    case terminal
    case search
    case build
    case mixed
}

enum TaskStepStatus: String, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
    case skipped
    case retrying
}

// MARK: - Task Plan

/// An ephemeral execution plan for a complex task.
/// Never persisted, never shown to the user, never survives the run.
struct TaskPlan: Identifiable, Sendable {
    let id: UUID
    let goal: String
    var steps: [TaskStep]
    let createdAt: Date
    var status: TaskPlanStatus = .active
    /// Number of adaptations applied during execution. Capped by PlanAdaptationPolicy.
    var adaptationCount: Int = 0
    /// Tracks which steps have been adapted to enforce per-step cap.
    var adaptedStepIDs: Set<String> = []
    /// The adaptation ID that last affected each step — for Phase 4 correlation.
    var lastAdaptationIDByStep: [String: UUID] = [:]

    init(goal: String, steps: [TaskStep]) {
        self.id = UUID()
        self.goal = goal
        self.steps = steps
        self.createdAt = Date()
    }

    /// Steps that are ready to execute: all dependencies met, not yet started.
    var readySteps: [TaskStep] {
        let completedIDs = Set(steps.filter { $0.status == .completed }.map(\.id))
        return steps.filter { step in
            step.status == .pending
            && step.dependsOn.allSatisfy { completedIDs.contains($0) }
        }
    }

    /// Steps that can be executed in parallel right now.
    var parallelReadySteps: [TaskStep] {
        let ready = readySteps
        return ready.filter(\.canRunInParallel)
    }

    /// The next sequential step that should run (first ready non-parallel, or first ready).
    var nextSequentialStep: TaskStep? {
        let ready = readySteps
        return ready.first { !$0.canRunInParallel } ?? ready.first
    }

    var isComplete: Bool {
        steps.allSatisfy { $0.status == .completed || $0.status == .skipped }
    }

    var hasFailed: Bool {
        steps.contains { $0.status == .failed && $0.retryCount >= TaskStep.maxRetries }
    }

    var completedStepCount: Int {
        steps.filter { $0.status == .completed }.count
    }

    var failedStepCount: Int {
        steps.filter { $0.status == .failed }.count
    }

    mutating func markRunning(_ stepID: String) {
        guard let idx = steps.firstIndex(where: { $0.id == stepID }) else { return }
        steps[idx].status = .running
    }

    mutating func markCompleted(_ stepID: String) {
        guard let idx = steps.firstIndex(where: { $0.id == stepID }) else { return }
        steps[idx].status = .completed
    }

    mutating func markFailed(_ stepID: String, reason: String) {
        guard let idx = steps.firstIndex(where: { $0.id == stepID }) else { return }
        steps[idx].status = .failed
        steps[idx].failureReason = reason
    }

    mutating func markRetrying(_ stepID: String) {
        guard let idx = steps.firstIndex(where: { $0.id == stepID }) else { return }
        steps[idx].status = .retrying
        steps[idx].retryCount += 1
    }

    mutating func skipDependents(of failedStepID: String) {
        let transitiveIDs = transitiveDependents(of: failedStepID)
        for id in transitiveIDs {
            if let idx = steps.firstIndex(where: { $0.id == id && $0.status == .pending }) {
                steps[idx].status = .skipped
            }
        }
    }

    /// Mark all pending steps as skipped (used by adaptation policy).
    mutating func skipAllPending(reason: String) {
        for idx in steps.indices where steps[idx].status == .pending {
            steps[idx].status = .skipped
            steps[idx].failureReason = reason
        }
    }

    /// Override the model role for a specific step (used by adaptation policy).
    mutating func setRecommendedRole(_ role: StudioModelRole, for stepID: String) {
        guard let idx = steps.firstIndex(where: { $0.id == stepID }) else { return }
        steps[idx].recommendedRole = role
    }

    private func transitiveDependents(of stepID: String) -> Set<String> {
        var result = Set<String>()
        var queue = [stepID]
        while let current = queue.popLast() {
            let dependents = steps.filter { $0.dependsOn.contains(current) }.map(\.id)
            for dep in dependents where !result.contains(dep) {
                result.insert(dep)
                queue.append(dep)
            }
        }
        return result
    }
}

enum TaskPlanStatus: String, Sendable {
    case active
    case completed
    case failed
    case abandoned   // Fell back to normal loop
}

// MARK: - Complexity Analyzer

/// Determines whether a task warrants DAG orchestration.
/// Returns nil for simple tasks — they go straight to the normal run loop.
enum TaskComplexityAnalyzer {

    /// Activation signals — any ONE triggers DAG mode.
    private static let multiStepSignals = [
        "refactor",
        "re-architect",
        "rearchitect",
        "system-wide",
        "across the app",
        "across the project",
        "multi-step",
        "multi-file",
        "overhaul",
        "untangle",
        "migrate",
        "migration",
        "rebuild",
        "restructure",
        "reorganize",
        "consolidate",
    ]

    /// Multi-phase signals — task explicitly spans build + test + fix.
    private static let multiPhaseSignals = [
        "build and test",
        "build and fix",
        "fix all",
        "fix every",
        "test and fix",
        "run tests",
        "then deploy",
        "then test",
    ]

    struct ComplexityAssessment: Sendable {
        let shouldUseDAG: Bool
        let reason: String
        let matchedSignals: [String]
        let suggestedPhases: [TaskPhase]
    }

    /// Analyze whether a task needs DAG orchestration.
    /// Returns assessment with `shouldUseDAG = false` for simple tasks.
    static func analyze(
        goal: String,
        attachmentCount: Int,
        conversationHistoryCount: Int,
        previousFailureCount: Int
    ) -> ComplexityAssessment {
        let normalized = goal.lowercased()

        // Check multi-step signals
        let matchedMultiStep = multiStepSignals.filter { normalized.contains($0) }
        if !matchedMultiStep.isEmpty {
            return ComplexityAssessment(
                shouldUseDAG: true,
                reason: "multi_step_signal",
                matchedSignals: matchedMultiStep,
                suggestedPhases: [.discovery, .analysis, .implementation, .verification]
            )
        }

        // Check multi-phase signals
        let matchedMultiPhase = multiPhaseSignals.filter { normalized.contains($0) }
        if !matchedMultiPhase.isEmpty {
            return ComplexityAssessment(
                shouldUseDAG: true,
                reason: "multi_phase_signal",
                matchedSignals: matchedMultiPhase,
                suggestedPhases: phasesFromSignals(matchedMultiPhase)
            )
        }

        // High attachment count suggests cross-file work
        if attachmentCount > 5 {
            return ComplexityAssessment(
                shouldUseDAG: true,
                reason: "high_attachment_count",
                matchedSignals: [],
                suggestedPhases: [.discovery, .implementation, .verification]
            )
        }

        // Repeated failures → structured retry via DAG
        if previousFailureCount >= 2 {
            return ComplexityAssessment(
                shouldUseDAG: true,
                reason: "repeated_failures",
                matchedSignals: [],
                suggestedPhases: [.discovery, .analysis, .repair, .verification]
            )
        }

        return ComplexityAssessment(
            shouldUseDAG: false,
            reason: "simple_task",
            matchedSignals: [],
            suggestedPhases: []
        )
    }

    private static func phasesFromSignals(_ signals: [String]) -> [TaskPhase] {
        var phases: [TaskPhase] = [.discovery]
        let combined = signals.joined(separator: " ")
        if combined.contains("build") || combined.contains("fix") {
            phases.append(.implementation)
        }
        if combined.contains("test") {
            phases.append(.verification)
        }
        if combined.contains("fix") {
            phases.append(.repair)
        }
        if phases.count == 1 {
            phases.append(contentsOf: [.implementation, .verification])
        }
        return phases
    }
}

// MARK: - Plan Generator

/// Generates a TaskPlan from the complexity assessment and goal.
/// This is deterministic — no LLM call. The plan structure comes from
/// pattern matching on the goal and assessment.
enum TaskPlanGenerator {

    static func generate(
        goal: String,
        assessment: TaskComplexityAnalyzer.ComplexityAssessment
    ) -> TaskPlan {
        let phases = assessment.suggestedPhases
        var steps: [TaskStep] = []
        var previousPhaseStepIDs: [String] = []

        for (phaseIndex, phase) in phases.enumerated() {
            let stepID = "step-\(phaseIndex)"
            let step = TaskStep(
                id: stepID,
                intent: intentDescription(for: phase, goal: goal),
                phase: phase,
                toolHint: toolHint(for: phase),
                canRunInParallel: phase == .discovery,
                dependsOn: previousPhaseStepIDs,
                status: .pending
            )
            steps.append(step)
            previousPhaseStepIDs = [stepID]
        }

        return TaskPlan(goal: goal, steps: steps)
    }

    private static func intentDescription(for phase: TaskPhase, goal: String) -> String {
        switch phase {
        case .discovery:
            return "Read and understand the relevant files and structure"
        case .analysis:
            return "Analyze the codebase and identify required changes"
        case .implementation:
            return "Implement the changes"
        case .verification:
            return "Build and verify the changes compile and work correctly"
        case .repair:
            return "Fix any errors found during verification"
        }
    }

    private static func toolHint(for phase: TaskPhase) -> TaskToolHint {
        switch phase {
        case .discovery: return .fileRead
        case .analysis: return .search
        case .implementation: return .fileWrite
        case .verification: return .build
        case .repair: return .mixed
        }
    }
}

// MARK: - Plan Context Injection

/// Generates a system prompt supplement that makes the LLM aware of
/// the current execution phase without exposing DAG internals.
/// The LLM sees phase guidance, not graph structure.
enum TaskPlanPromptInjection {

    /// Returns a system prompt section to append when DAG is active.
    /// Returns nil when no plan is active or for simple tasks.
    static func promptSupplement(
        for plan: TaskPlan,
        currentStep: TaskStep
    ) -> String? {
        guard plan.status == .active else { return nil }

        let totalSteps = plan.steps.count
        let completedSteps = plan.completedStepCount
        let progress = totalSteps > 0 ? "\(completedSteps)/\(totalSteps)" : ""

        var supplement = """

        ### EXECUTION PHASE ###
        You are currently in phase \(progress): \(currentStep.intent).
        """

        // Add phase-specific guidance
        switch currentStep.phase {
        case .discovery:
            supplement += """

            Focus on reading and understanding. Do NOT make changes yet.
            Gather the context you need, then report what you found.
            """
        case .analysis:
            supplement += """

            Analyze what needs to change. Identify files, functions, and patterns.
            Be specific about what you plan to modify.
            """
        case .implementation:
            supplement += """

            Make the changes now. You've already gathered context in earlier phases.
            Focus on correctness and completeness. Write the code.
            """
        case .verification:
            supplement += """

            Build the project and run any relevant tests.
            Report build results. If errors remain, describe them precisely.
            """
        case .repair:
            supplement += """

            Fix the errors identified in the previous phase.
            Focus ONLY on the reported errors. Do not refactor unrelated code.
            """
        }

        // If retrying, note what failed
        if currentStep.retryCount > 0, let reason = currentStep.failureReason {
            supplement += """

            Previous attempt at this phase failed: \(reason)
            Try a different approach.
            """
        }

        // Note completed phases for context
        let completedPhases = plan.steps.filter { $0.status == .completed }
        if !completedPhases.isEmpty {
            let phaseNames = completedPhases.map(\.intent).joined(separator: ", ")
            supplement += """

            Completed phases: \(phaseNames).
            """
        }

        return supplement
    }

    /// Status message for the user-facing status bar.
    /// This is what the user sees — simple, no graph jargon.
    static func userFacingStatus(for step: TaskStep) -> String {
        switch step.phase {
        case .discovery:
            return "Analyzing project…"
        case .analysis:
            return "Planning changes…"
        case .implementation:
            return "Implementing…"
        case .verification:
            return "Verifying build…"
        case .repair:
            return "Fixing errors…"
        }
    }
}

// MARK: - Plan Adaptation

/// Typed reason codes for plan adaptations.
/// Used for analytics, Phase 4 feedback loops, and deterministic policy matching.
enum PlanAdaptationReason: String, Sendable {
    case verificationPassed
    case discoveryFailed
    case implementationRetriesExhausted

    /// The phase that triggered this adaptation — for aggregate analytics.
    var triggerPhase: TaskPhase {
        switch self {
        case .verificationPassed:              return .verification
        case .discoveryFailed:                 return .discovery
        case .implementationRetriesExhausted:  return .implementation
        }
    }
}

/// Outcome-driven adaptations that the executor can apply between steps.
/// Conservative by design — start with simple cases, expand later.
/// Each non-proceed adaptation carries a stable `id` for decision → effect → outcome correlation.
enum PlanAdaptation: Equatable, Sendable {
    /// No change to the plan.
    case proceed
    /// Skip all remaining steps (e.g. verification passed, no repair needed).
    case skipRemaining(id: UUID = UUID(), reason: PlanAdaptationReason)
    /// Re-route a specific step to a different model role.
    case rerouteStep(id: UUID = UUID(), stepID: String, to: StudioModelRole, reason: PlanAdaptationReason)

    /// The stable adaptation ID, if this is a non-proceed adaptation.
    var adaptationID: UUID? {
        switch self {
        case .proceed: return nil
        case .skipRemaining(let id, _): return id
        case .rerouteStep(let id, _, _, _): return id
        }
    }
}

/// Decides how to adapt the plan after each step completes.
/// All logic is deterministic — no LLM call.
enum PlanAdaptationPolicy {

    /// Evaluate the plan after a step completes and recommend an adaptation.
    /// Maximum adaptations per plan to prevent pathological loops.
    static let maxAdaptationsPerPlan = 3

    static func evaluate(
        plan: TaskPlan,
        completedStep: TaskStep,
        result: TaskPlanExecutor.StepResult
    ) -> PlanAdaptation {
        // Cap: prevent runaway adaptation in future phases.
        guard plan.adaptationCount < maxAdaptationsPerPlan else {
            return .proceed
        }

        // Per-step cap: prevent the same step from consuming the entire budget.
        func stepAlreadyAdapted(_ stepID: String) -> Bool {
            plan.adaptedStepIDs.contains(stepID)
        }

        // Rule 1: Verification succeeded → skip repair phase.
        // If verification passed cleanly, there's nothing to repair.
        if completedStep.phase == .verification && result.succeeded {
            let pendingRepairIDs = plan.steps
                .filter { $0.phase == .repair && $0.status == .pending }
                .map(\.id)
            if !pendingRepairIDs.isEmpty {
                return .skipRemaining(reason: .verificationPassed)
            }
        }

        // Rule 2: Discovery step failed → re-route implementation to escalation.
        // If we can't even read the codebase, the task needs a stronger model.
        if completedStep.phase == .discovery && !result.succeeded {
            if let implStep = plan.steps.first(where: { $0.phase == .implementation && $0.status == .pending }) {
                // Anti-oscillation: don't reroute if already at target role or already adapted.
                guard implStep.recommendedRole != .escalation else { return .proceed }
                guard !stepAlreadyAdapted(implStep.id) else { return .proceed }
                return .rerouteStep(stepID: implStep.id, to: .escalation, reason: .discoveryFailed)
            }
        }

        // Rule 3: Implementation failed after retry → re-route verification to escalation.
        // The implementation was already attempted — escalate the verification/fix pass.
        if completedStep.phase == .implementation && !result.succeeded && completedStep.retryCount >= TaskStep.maxRetries {
            if let verifyStep = plan.steps.first(where: { $0.phase == .verification && $0.status == .pending }) {
                // Anti-oscillation: don't reroute if already at target role or already adapted.
                guard verifyStep.recommendedRole != .escalation else { return .proceed }
                guard !stepAlreadyAdapted(verifyStep.id) else { return .proceed }
                return .rerouteStep(stepID: verifyStep.id, to: .escalation, reason: .implementationRetriesExhausted)
            }
        }

        return .proceed
    }
}

// MARK: - Plan Executor

/// Drives a TaskPlan through its steps, invoking runAgentic for each phase.
/// Handles dependency ordering, retries, and fallback to normal execution.
actor TaskPlanExecutor {

    enum ExecutionOutcome: Sendable {
        case completed               // All steps finished
        case failed(reason: String)  // Unrecoverable failure
        case abandoned               // Fell back to normal loop
    }

    struct StepResult: Sendable {
        let stepID: String
        let succeeded: Bool
        let failureReason: String?
    }

    private var plan: TaskPlan
    private let tracer: TraceCollector
    private let parentSpanID: UUID
    private var dagSpanID: UUID?

    init(plan: TaskPlan, tracer: TraceCollector, parentSpanID: UUID) {
        self.plan = plan
        self.tracer = tracer
        self.parentSpanID = parentSpanID
    }

    /// Execute all steps in dependency order.
    /// Returns the outcome and the final plan state.
    func execute(
        runStep: @escaping @Sendable (TaskStep, String?) async -> StepResult
    ) async -> (outcome: ExecutionOutcome, plan: TaskPlan) {
        let spanID = await tracer.begin(
            kind: .session,
            name: "dag_orchestration",
            parentID: parentSpanID,
            attributes: [
                "dag.step_count": "\(plan.steps.count)",
                "dag.goal": String(plan.goal.prefix(200))
            ]
        )
        dagSpanID = spanID

        while !plan.isComplete && !plan.hasFailed {
            if Task.isCancelled {
                plan.status = .abandoned
                await endSpan(spanID, error: "cancelled")
                return (.abandoned, plan)
            }

            let ready = plan.readySteps
            guard !ready.isEmpty else {
                // Deadlock detection — no ready steps but plan not complete
                plan.status = .failed
                await endSpan(spanID, error: "deadlock: no ready steps")
                return (.failed(reason: "Plan deadlocked — no steps can proceed"), plan)
            }

            // Check for parallel-safe steps
            let parallelSteps = plan.parallelReadySteps
            if parallelSteps.count > 1 {
                await executeParallel(steps: parallelSteps, runStep: runStep)
            } else if let step = plan.nextSequentialStep {
                let result = await executeSequential(step: step, runStep: runStep)

                // Adaptive plan refinement — evaluate and apply post-step.
                if let result {
                    let currentStep = plan.steps.first(where: { $0.id == result.stepID })
                    if let currentStep {
                        let adaptation = PlanAdaptationPolicy.evaluate(
                            plan: plan,
                            completedStep: currentStep,
                            result: result
                        )
                        await applyAdaptation(adaptation, spanID: spanID)
                    }
                }
            }
        }

        if plan.hasFailed {
            plan.status = .failed
            let failedSteps = plan.steps.filter { $0.status == .failed }
            let reasons = failedSteps.compactMap(\.failureReason).joined(separator: "; ")
            await tracer.setAttribute("dag.failures", value: "\(plan.failedStepCount)", on: spanID)
            await endSpan(spanID, error: reasons)
            return (.failed(reason: reasons), plan)
        }

        plan.status = .completed
        await tracer.setAttribute("dag.failures", value: "0", on: spanID)
        await endSpan(spanID, error: nil)
        return (.completed, plan)
    }

    /// Get the current prompt supplement for the active step.
    func promptSupplement(for stepID: String) -> String? {
        guard let step = plan.steps.first(where: { $0.id == stepID }) else { return nil }
        return TaskPlanPromptInjection.promptSupplement(for: plan, currentStep: step)
    }

    /// Get the user-facing status for a step.
    func userStatus(for stepID: String) -> String {
        guard let step = plan.steps.first(where: { $0.id == stepID }) else { return "Working…" }
        return TaskPlanPromptInjection.userFacingStatus(for: step)
    }

    /// Snapshot of the current plan (for telemetry).
    func currentPlan() -> TaskPlan {
        plan
    }

    // MARK: - Private Execution

    private func executeSequential(
        step: TaskStep,
        runStep: @escaping @Sendable (TaskStep, String?) async -> StepResult
    ) async -> StepResult? {
        plan.markRunning(step.id)
        let supplement = TaskPlanPromptInjection.promptSupplement(for: plan, currentStep: step)

        let stepSpanID = await tracer.begin(
            kind: .toolExecution,
            name: "dag_step_\(step.phase.rawValue)",
            parentID: dagSpanID,
            attributes: [
                "dag.step.id": step.id,
                "dag.step.phase": step.phase.rawValue,
                "dag.step.intent": step.intent,
                "dag.step.retry": "\(step.retryCount)",
                "dag.step.rerouted": step.recommendedRole.map(\.rawValue) ?? "none",
                "dag.step.adaptation_id": plan.lastAdaptationIDByStep[step.id]?.uuidString ?? "none"
            ]
        )

        let result = await runStep(step, supplement)

        if result.succeeded {
            plan.markCompleted(step.id)
            await tracer.end(stepSpanID)
            return result
        } else {
            // Retry logic
            if step.retryCount < TaskStep.maxRetries {
                plan.markRetrying(step.id)
                await tracer.setAttribute("dag.step.retrying", value: "true", on: stepSpanID)
                await tracer.end(stepSpanID, error: result.failureReason ?? "Unknown error")

                // Re-run with retry context
                let retryStep = plan.steps.first(where: { $0.id == step.id })!
                plan.markRunning(step.id)
                let retrySupplement = TaskPlanPromptInjection.promptSupplement(for: plan, currentStep: retryStep)

                let retrySpanID = await tracer.begin(
                    kind: .retry,
                    name: "dag_step_retry_\(step.phase.rawValue)",
                    parentID: dagSpanID,
                    attributes: [
                        "dag.step.id": step.id,
                        "dag.step.retry": "\(retryStep.retryCount)"
                    ]
                )

                let retryResult = await runStep(retryStep, retrySupplement)
                if retryResult.succeeded {
                    plan.markCompleted(step.id)
                    await tracer.end(retrySpanID)
                    return retryResult
                } else {
                    plan.markFailed(step.id, reason: retryResult.failureReason ?? "Unknown error")
                    plan.skipDependents(of: step.id)
                    await tracer.end(retrySpanID, error: retryResult.failureReason ?? "Unknown error")
                    return retryResult
                }
            } else {
                plan.markFailed(step.id, reason: result.failureReason ?? "Unknown error")
                plan.skipDependents(of: step.id)
                await tracer.end(stepSpanID, error: result.failureReason ?? "Unknown error")
                return result
            }
        }
    }

    private func executeParallel(
        steps: [TaskStep],
        runStep: @escaping @Sendable (TaskStep, String?) async -> StepResult
    ) async {
        let parallelSpanID = await tracer.begin(
            kind: .toolExecution,
            name: "dag_parallel_batch",
            parentID: dagSpanID,
            attributes: [
                "dag.parallel_count": "\(steps.count)",
                "dag.parallel_phases": steps.map(\.phase.rawValue).joined(separator: ",")
            ]
        )

        for step in steps {
            plan.markRunning(step.id)
        }

        // Run all parallel steps concurrently
        await withTaskGroup(of: StepResult.self) { group in
            for step in steps {
                let supplement = TaskPlanPromptInjection.promptSupplement(for: plan, currentStep: step)
                group.addTask {
                    await runStep(step, supplement)
                }
            }

            for await result in group {
                if result.succeeded {
                    plan.markCompleted(result.stepID)
                } else {
                    plan.markFailed(result.stepID, reason: result.failureReason ?? "Unknown error")
                }
            }
        }

        await tracer.end(parallelSpanID)
    }

    /// Apply an adaptation decision to the live plan.
    private func applyAdaptation(_ adaptation: PlanAdaptation, spanID: UUID) async {
        switch adaptation {
        case .proceed:
            // Emit trace when cap suppressed a real evaluation.
            if plan.adaptationCount >= PlanAdaptationPolicy.maxAdaptationsPerPlan {
                await tracer.setAttribute("dag.adaptation.skipped_due_to_cap", value: "true", on: spanID)
            }
            return  // No mutation, no counter increment.

        case .skipRemaining(let adaptationID, let reason):
            plan.adaptationCount += 1
            let skippedCount = plan.steps.filter { $0.status == .pending }.count
            plan.skipAllPending(reason: reason.rawValue)
            await tracer.setAttribute("dag.adaptation", value: "skip_remaining", on: spanID)
            await tracer.setAttribute("dag.adaptation.id", value: adaptationID.uuidString, on: spanID)
            await tracer.setAttribute("dag.adaptation.reason", value: reason.rawValue, on: spanID)
            await tracer.setAttribute("dag.adaptation.trigger_phase", value: reason.triggerPhase.rawValue, on: spanID)
            await tracer.setAttribute("dag.adaptation.skipped_count", value: "\(skippedCount)", on: spanID)
            await tracer.setAttribute("dag.adaptation.count", value: "\(plan.adaptationCount)", on: spanID)

        case .rerouteStep(let adaptationID, let stepID, let newRole, let reason):
            let previousRole = plan.steps.first(where: { $0.id == stepID })?.recommendedRole
            plan.adaptationCount += 1
            plan.adaptedStepIDs.insert(stepID)
            plan.lastAdaptationIDByStep[stepID] = adaptationID
            plan.setRecommendedRole(newRole, for: stepID)
            await tracer.setAttribute("dag.adaptation", value: "reroute_step", on: spanID)
            await tracer.setAttribute("dag.adaptation.id", value: adaptationID.uuidString, on: spanID)
            await tracer.setAttribute("dag.adaptation.reason", value: reason.rawValue, on: spanID)
            await tracer.setAttribute("dag.adaptation.trigger_phase", value: reason.triggerPhase.rawValue, on: spanID)
            await tracer.setAttribute("dag.adaptation.step", value: stepID, on: spanID)
            await tracer.setAttribute("dag.adaptation.role_before", value: previousRole?.rawValue ?? "default", on: spanID)
            await tracer.setAttribute("dag.adaptation.role_after", value: newRole.rawValue, on: spanID)
            await tracer.setAttribute("dag.adaptation.count", value: "\(plan.adaptationCount)", on: spanID)
        }
    }

    private func endSpan(_ spanID: UUID, error: String?) async {
        let finalPlan = plan
        await tracer.setAttribute("dag.completed_steps", value: "\(finalPlan.completedStepCount)", on: spanID)
        await tracer.setAttribute("dag.failed_steps", value: "\(finalPlan.failedStepCount)", on: spanID)
        await tracer.setAttribute("dag.status", value: finalPlan.status.rawValue, on: spanID)
        if let error {
            await tracer.end(spanID, error: String(error.prefix(500)))
        } else {
            await tracer.end(spanID)
        }
    }
}

// MARK: - DAG Telemetry

/// Telemetry attributes stamped on the session span when DAG is used.
enum TaskPlanTelemetry {

    static func stamp(
        plan: TaskPlan,
        on spanID: UUID,
        tracer: TraceCollector
    ) async {
        await tracer.setAttribute("dag.used", value: "true", on: spanID)
        await tracer.setAttribute("dag.step_count", value: "\(plan.steps.count)", on: spanID)
        await tracer.setAttribute("dag.completed_steps", value: "\(plan.completedStepCount)", on: spanID)
        await tracer.setAttribute("dag.failed_steps", value: "\(plan.failedStepCount)", on: spanID)
        await tracer.setAttribute("dag.status", value: plan.status.rawValue, on: spanID)

        let parallelSteps = plan.steps.filter(\.canRunInParallel).count
        await tracer.setAttribute("dag.parallel_steps", value: "\(parallelSteps)", on: spanID)

        let totalRetries = plan.steps.map(\.retryCount).reduce(0, +)
        await tracer.setAttribute("dag.retry_count", value: "\(totalRetries)", on: spanID)

        let phases = Set(plan.steps.map(\.phase.rawValue)).sorted().joined(separator: ",")
        await tracer.setAttribute("dag.phases", value: phases, on: spanID)
    }

    static func stampSkipped(
        on spanID: UUID,
        tracer: TraceCollector
    ) async {
        await tracer.setAttribute("dag.used", value: "false", on: spanID)
    }
}

// MARK: - Deterministic Plan Bridge

/// Converts a structured TaskPlan into a StreamPlan for the UI layer.
/// This is the deterministic bridge: the InlineTaskPlanStrip gets its state
/// from the execution engine, not from regex-parsed narrative text.
enum TaskPlanBridge {

    /// Convert a TaskPlan into a StreamPlan suitable for InlineTaskPlanMonitor.
    /// The first step is marked `.inProgress` so the UI shows activity immediately.
    static func streamPlan(from plan: TaskPlan) -> StreamPlan {
        let steps = plan.steps.enumerated().map { index, step in
            StreamPlanStep(
                id: step.id,
                title: TaskPlanPromptInjection.userFacingStatus(for: step),
                ordinal: index + 1,
                status: index == 0 ? .inProgress : .pending
            )
        }
        return StreamPlan(
            title: planTitle(from: plan),
            steps: steps
        )
    }

    private static func planTitle(from plan: TaskPlan) -> String {
        let goal = plan.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        // Use the first ~50 chars of the goal as the plan title.
        if goal.count <= 50 { return goal }
        let truncated = goal.prefix(47)
        // Break at the last word boundary.
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[truncated.startIndex..<lastSpace]) + "…"
        }
        return String(truncated) + "…"
    }
}
