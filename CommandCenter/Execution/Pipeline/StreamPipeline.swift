import Foundation
import Observation
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Semantic Stream Events (retired)
// ═══════════════════════════════════════════════════════════════════════════════
//
// SemanticStreamEvent was a 13-case enum used only as internal message-passing
// between StreamPipelineCoordinator and StreamPhaseController. Both live in
// this file. The coordinator now calls named mutation methods directly on the
// controller — no intermediary enum needed.

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Supporting Models
// ═══════════════════════════════════════════════════════════════════════════════

struct StreamPlan: Equatable, Identifiable {
    let id = UUID()
    var title: String
    var steps: [StreamPlanStep]
    var isFinalized: Bool = false

    /// Update a step's status. Single mutation point — never regenerate the plan.
    mutating func updateStepStatus(_ stepID: String, _ status: StreamPlanStepStatus) {
        if let index = steps.firstIndex(where: { $0.id == stepID }) {
            steps[index].status = status
        }
    }

    /// Find the first in-progress or pending step.
    var currentStepID: String? {
        steps.first(where: { $0.status == .inProgress })?.id
            ?? steps.first(where: { $0.status == .pending })?.id
    }
}

enum StreamPlanStepStatus: String, Equatable {
    case pending
    case inProgress
    case completed
    case skipped
}

struct StreamPlanStep: Equatable, Identifiable {
    let id: String
    let title: String
    let ordinal: Int
    var substeps: [String] = []
    var status: StreamPlanStepStatus = .pending
}

struct StreamStep: Equatable, Identifiable {
    static let maxInlineRetainedOutputLines = 80
    static let collapsedInlineOutputLines = 20

    let id: String
    let toolName: String
    var kind: StreamStepKind = .other
    var title: String
    var target: String?
    var previewText: String?
    var displayCommand: String?
    var deepLink: StreamDeepLink?
    var status: StreamStepStatus = .active
    var startedAt: Date = Date()
    var completedAt: Date?
    var outputLines: [String] = []
    var isError: Bool = false
    /// Total lines received before cap truncation. Used to show "N lines hidden".
    var totalOutputLineCount: Int = 0
}

enum StreamStepKind: String, Equatable {
    case search
    case read
    case write
    case edit
    case terminal
    case build
    case delegation
    case deploy
    case screenshot
    case other
}

enum StreamStepStatus: String, Equatable {
    case active
    case completed
    case failed
    case skipped
}

struct StreamArtifact: Equatable {
    enum Kind: String, Equatable {
        case fileWrite
        case filePatch
        case screenshot
        case diff
        case build
        case test
        case gitStatus
        case multimodal
    }
    let kind: Kind
    let path: String?
    let summary: String
}

enum StreamDeepLink: Equatable {
    case inspector(spanID: UUID?)
    case file(path: String, sourceLabel: String)
    case screenshot(path: String)
}

@MainActor
final class StreamDeepLinkRouter {

    var openInspector: ((UUID?) -> Void)?
    var openFilePreview: ((String, String) -> Void)?
    var openScreenshot: ((String) -> Void)?

    func navigate(_ deepLink: StreamDeepLink) {
        switch deepLink {
        case .inspector(let spanID):
            openInspector?(spanID)
        case .file(let path, let sourceLabel):
            openFilePreview?(path, sourceLabel)
        case .screenshot(let path):
            openScreenshot?(path)
        }
    }
}

struct StreamError: Equatable {
    let message: String
    let isRecoverable: Bool
    let stepID: String?
    let timestamp: Date = Date()
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Stream Phase
// ═══════════════════════════════════════════════════════════════════════════════
//
// The phase drives what the ConversationTurnRow renders.
// Unlike TurnState (.streaming/.executing/.completed), StreamPhase
// is granular enough to show structured progress.

enum StreamPhase: Equatable {
    /// No active stream.
    case idle
    /// Request received, waiting for first signal. Shows ghost skeleton.
    case acknowledging
    /// Model is thinking (extended thinking). Shows thermal glow + optional summary.
    case thinking
    /// Intent detected. Shows intent card with summary.
    case intent(String)
    /// Plan extracted from stream. Shows structured plan checklist.
    case planning(StreamPlan)
    /// Steps are executing. Shows step tracker.
    case executing(activeStepID: String?)
    /// Stream complete. Shows final result.
    case completed
    /// Stream failed.
    case failed(StreamError)
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Stream Phase Controller
// ═══════════════════════════════════════════════════════════════════════════════
//
// Sits on MainActor. Drives phase transitions via named mutation methods.
// Owns the canonical step tracker state. The ConversationTurnRow reads this.

@MainActor
@Observable
final class StreamPhaseController {

    // MARK: Observable State

    private(set) var phase: StreamPhase = .idle
    private(set) var steps: [StreamStep] = []
    private(set) var plan: StreamPlan?
    private(set) var artifacts: [StreamArtifact] = []
    private(set) var narrativeBuffer: String = ""
    private(set) var intentSummary: String?
    private(set) var thinkingSummary: String?
    private(set) var thinkingText: String = ""
    let deepLinkRouter = StreamDeepLinkRouter()

    // MARK: Timing

    @ObservationIgnored private var phaseEnteredAt: Date = .distantPast
    @ObservationIgnored private var pendingPhaseTask: Task<Void, Never>?
    @ObservationIgnored private var renderCommitTask: Task<Void, Never>?
    @ObservationIgnored private(set) var streamStartedAt: Date?
    @ObservationIgnored private(set) var firstMeaningfulSignalAt: Date?
    @ObservationIgnored private var thinkingBuffer: String = ""
    /// Tracks whether the current phase has been visually committed
    /// (i.e., at least one frame has rendered). Used for elision.
    @ObservationIgnored private var phaseHasRendered: Bool = false
    @ObservationIgnored private var pendingElisionTarget: StreamPhase?

    // ── Per-Phase Hold Durations ──────────────────────────────────────
    //
    // Each phase has a cognitive-appropriate minimum display time.
    // These are NOT animation durations — they are the minimum time
    // a phase must remain visible before the controller will commit
    // a transition to the next phase.
    //
    //   acknowledging : 0ms  — ghost skeleton is instantaneous, never held
    //   thinking      : 0ms  — thermal glow is continuous, no hold needed
    //   intent        : 220ms — just long enough to read the summary line
    //   planning      : 600ms — user must scan the plan before steps begin
    //   executing     : 0ms  — steps drive their own pacing; no artificial hold
    //   completed     : 0ms  — terminal; commits immediately
    //   failed        : 0ms  — terminal; commits immediately
    //
    private static func minimumHold(for phase: StreamPhase) -> TimeInterval {
        switch phase {
        case .acknowledging:    return 0
        case .thinking:         return 0
        case .intent:           return 0.22
        case .planning:         return 0.60
        case .executing:        return 0
        case .completed:        return 0
        case .failed:           return 0
        case .idle:             return 0
        }
    }

    // ── Per-Transition Durations (for SwiftUI animation) ─────────────
    //
    // These define how long the visual crossfade/resolve takes.
    // Distinct from hold durations: hold = how long to wait,
    // transition = how long the visual change itself takes.
    //
    //   acknowledging → thinking  : 0.12s  — sub-perceptual; feels instant
    //   acknowledging → intent    : 0.15s  — skeleton resolves into content
    //   intent → planning         : 0.28s  — deliberate; content is replacing content
    //   intent → executing        : 0.22s  — slightly faster; action is starting
    //   planning → executing      : 0.30s  — deliberate; major mode change
    //   executing → executing     : 0.08s  — near-instant step swap; no fanfare
    //   executing → completed     : 0.18s  — brisk resolution
    //   executing → failed        : 0.22s  — slightly slower; give weight to failure
    //   * → idle                  : 0.35s  — always leisurely on wind-down
    //
    static func transitionDuration(from: StreamPhase, to: StreamPhase) -> TimeInterval {
        switch (from, to) {
        case (.acknowledging, .thinking):   return 0.12
        case (.acknowledging, .intent):     return 0.15
        case (.acknowledging, _):           return 0.15
        case (.thinking, .intent):          return 0.18
        case (.thinking, _):                return 0.18
        case (.intent, .planning):          return 0.28
        case (.intent, .executing):         return 0.22
        case (.intent, _):                  return 0.22
        case (.planning, .executing):       return 0.30
        case (.planning, _):                return 0.25
        case (.executing, .executing):      return 0.08
        case (.executing, .completed):      return 0.18
        case (.executing, .failed):         return 0.22
        case (.executing, _):               return 0.20
        case (_, .idle):                    return 0.35
        default:                            return 0.22
        }
    }

    /// Time-to-first-meaningful-output in milliseconds. Nil if not yet measured.
    var ttfmoMs: Int? {
        guard let start = streamStartedAt, let signal = firstMeaningfulSignalAt else { return nil }
        return Int(signal.timeIntervalSince(start) * 1000)
    }

    /// Seconds elapsed since the current phase was entered.
    var phaseElapsed: TimeInterval {
        Date().timeIntervalSince(phaseEnteredAt)
    }

    // MARK: - Lifecycle

    func beginStream() {
        phase = .acknowledging
        steps = []
        plan = nil
        artifacts = []
        narrativeBuffer = ""
        intentSummary = nil
        thinkingSummary = nil
        thinkingText = ""
        thinkingBuffer = ""
        phaseEnteredAt = Date()
        streamStartedAt = Date()
        firstMeaningfulSignalAt = nil
    }

    func endStream() {
        pendingPhaseTask?.cancel()
        pendingPhaseTask = nil
        StudioFeedback.completed()
        transitionPhase(to: .completed)
    }

    func failStream(_ error: StreamError) {
        pendingPhaseTask?.cancel()
        pendingPhaseTask = nil
        transitionPhase(to: .failed(error))
    }

    func reset() {
        pendingPhaseTask?.cancel()
        pendingPhaseTask = nil
        phase = .idle
        steps = []
        plan = nil
        artifacts = []
        narrativeBuffer = ""
        intentSummary = nil
        thinkingSummary = nil
        thinkingText = ""
        thinkingBuffer = ""
        streamStartedAt = nil
        firstMeaningfulSignalAt = nil
    }

    /// Mutate an existing plan step's status. Single mutation point — never regenerate.
    func updatePlanStepStatus(_ stepID: String, _ status: StreamPlanStepStatus) {
        plan?.updateStepStatus(stepID, status)
    }

    /// Advance plan: mark current step completed, activate next pending step.
    /// Returns the newly activated step ID, if any.
    @discardableResult
    func advancePlanStep(from currentStepID: String) -> String? {
        plan?.updateStepStatus(currentStepID, .completed)
        if let nextID = plan?.currentStepID {
            plan?.updateStepStatus(nextID, .inProgress)
            return nextID
        }
        return nil
    }

    // MARK: - Direct Mutation Methods

    func acknowledge(intent: String) {
        markFirstSignal()
        intentSummary = intent
        transitionPhase(to: .intent(intent))
    }

    func setPlan(_ streamPlan: StreamPlan) {
        markFirstSignal()
        plan = streamPlan
        transitionPhase(to: .planning(streamPlan))
    }

    func startStep(_ step: StreamStep) {
        markFirstSignal()
        steps.append(step)
        transitionPhase(to: .executing(activeStepID: step.id))
    }

    func progressStep(id stepID: String, lines: [String], detail: String?) {
        if let index = steps.firstIndex(where: { $0.id == stepID }) {
            steps[index].outputLines.append(contentsOf: lines)
            steps[index].totalOutputLineCount += lines.count
            if steps[index].outputLines.count > StreamStep.maxInlineRetainedOutputLines {
                steps[index].outputLines.removeFirst(
                    steps[index].outputLines.count - StreamStep.maxInlineRetainedOutputLines
                )
            }
            if let detail {
                steps[index].displayCommand = detail
            }
        }
    }

    func refineStep(id stepID: String, title: String, target: String?, preview: String?) {
        if let index = steps.firstIndex(where: { $0.id == stepID }) {
            steps[index].title = title
            steps[index].target = target
            steps[index].previewText = preview
        }
    }

    func linkStep(id stepID: String, deepLink: StreamDeepLink?) {
        if let index = steps.firstIndex(where: { $0.id == stepID }) {
            steps[index].deepLink = deepLink
        }
    }

    func completeStep(id stepID: String, status: StreamStepStatus) {
        if let index = steps.firstIndex(where: { $0.id == stepID }) {
            steps[index].status = status
            steps[index].completedAt = Date()
        }
        let nextActive = steps.first(where: { $0.status == .active })?.id
        if case .executing = phase {
            transitionPhase(to: .executing(activeStepID: nextActive))
        }
    }

    func appendNarrative(_ text: String) {
        markFirstSignal()
        narrativeBuffer += text
        if case .acknowledging = phase {
            let firstSentence = extractFirstSentence(from: narrativeBuffer)
            intentSummary = firstSentence
            transitionPhase(to: .intent(firstSentence))
        }
    }

    func appendThinking(_ text: String) {
        markFirstSignal()
        thinkingBuffer += text
        thinkingText = thinkingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        thinkingSummary = Self.summarizeThinking(thinkingBuffer)
        if case .acknowledging = phase {
            transitionPhase(to: .thinking)
        }
    }

    func addArtifact(_ artifact: StreamArtifact) {
        artifacts.append(artifact)
    }

    // MARK: - Phase Transitions
    //
    // Three-layer transition logic:
    //
    // 1. HOLD GATE — Has the current phase been displayed long enough?
    //    If not, defer the transition.
    //
    // 2. ELISION — If the current phase hasn't rendered at all (e.g.,
    //    acknowledging → intent arrived in <16ms), skip it entirely.
    //    The FSM still records the logical transition, but the UI
    //    never shows an intermediate frame. This eliminates flicker
    //    from rapid phase cascades.
    //
    // 3. COMMIT — Actually update `phase`, which triggers SwiftUI
    //    observation and a re-render.

    private func transitionPhase(to target: StreamPhase) {
        // Terminal phases always commit immediately — never defer failure/completion.
        if isTerminalPhase(target) {
            pendingPhaseTask?.cancel()
            pendingPhaseTask = nil
            commitPhase(target)
            return
        }

        // Elision: if the current phase hasn't rendered a single frame,
        // skip directly to the target. This handles rapid cascades like
        // acknowledging → intent → plan arriving within one frame.
        if !phaseHasRendered && !isTerminalPhase(phase) && phase != .idle {
            commitPhase(target)
            return
        }

        let holdRequired = Self.minimumHold(for: phase)
        let elapsed = Date().timeIntervalSince(phaseEnteredAt)
        let remaining = holdRequired - elapsed

        if remaining > 0.016 { // >1 frame remaining
            pendingPhaseTask?.cancel()
            pendingPhaseTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                self.commitPhase(target)
            }
            return
        }

        commitPhase(target)
    }

    private func commitPhase(_ target: StreamPhase) {
        pendingPhaseTask?.cancel()
        pendingPhaseTask = nil
        phase = target
        phaseEnteredAt = Date()
        phaseHasRendered = false

        // After one render cycle, mark the phase as rendered.
        // This enables elision logic for the *next* transition.
        renderCommitTask?.cancel()
        renderCommitTask = Task { @MainActor in
            // Yield to the run loop so SwiftUI commits at least one frame.
            try? await Task.sleep(for: .milliseconds(8))
            guard self.phase == target else { return }
            self.phaseHasRendered = true
        }
    }

    private func isTerminalPhase(_ phase: StreamPhase) -> Bool {
        switch phase {
        case .completed, .failed: return true
        default: return false
        }
    }

    private func markFirstSignal() {
        if firstMeaningfulSignalAt == nil {
            firstMeaningfulSignalAt = Date()
        }
    }

    // MARK: - Text Utilities

    private func extractFirstSentence(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Find first sentence-ending punctuation
        let sentenceEnders: [Character] = [".", "!", "?"]
        if let endIndex = trimmed.firstIndex(where: { sentenceEnders.contains($0) }) {
            let sentence = String(trimmed[trimmed.startIndex...endIndex])
            return sentence.count < 200 ? sentence : String(sentence.prefix(200))
        }

        // No sentence ender found — take first line or first 120 chars
        if let newline = trimmed.firstIndex(of: "\n") {
            return String(trimmed[trimmed.startIndex..<newline])
        }

        return String(trimmed.prefix(120))
    }

    private static func summarizeThinking(_ text: String) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let candidate = lines.last else { return nil }

        let normalized = candidate
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))

        guard !normalized.isEmpty else { return nil }
        return normalized.count <= 140 ? normalized : String(normalized.prefix(137)) + "..."
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Semantic Event Transformer
// ═══════════════════════════════════════════════════════════════════════════════
//
// Transforms raw tool call names and streaming patterns into structured steps.
// This is where the intelligence lives — classifying tool calls into steps,
// detecting plan structure in narrative text, and deciding when to emit intent.

struct SemanticEventTransformer {

    struct ToolPresentation: Equatable {
        let kind: StreamStepKind
        let title: String
        let target: String?
        let preview: String?
    }

    /// Classify a tool call start into a semantic step.
    static func stepFromToolCall(id: String, name: String) -> StreamStep {
        let presentation = humanizeTool(
            named: name,
            inputJSON: nil,
            displayCommand: nil,
            result: nil,
            status: .active,
            previewLine: nil
        )

        return StreamStep(
            id: id,
            toolName: name,
            kind: presentation.kind,
            title: presentation.title,
            target: presentation.target,
            previewText: presentation.preview,
            displayCommand: Self.humanLabel(forToolNamed: name),
            status: .active
        )
    }

    static func humanizeTool(
        named name: String,
        inputJSON: String?,
        displayCommand: String?,
        result: String?,
        status: StreamStepStatus,
        previewLine: String?
    ) -> ToolPresentation {
        let input = inputJSON.flatMap(parsedJSON)
        let normalizedName = normalizedToolName(name)

        switch normalizedName {
        case "file_read":
            let path = toolPath(from: input, displayCommand: displayCommand)
            return ToolPresentation(
                kind: .read,
                title: fileActionTitle(activeVerb: "Reading", completedVerb: "Read", status: status, path: path),
                target: displayPath(path),
                preview: previewLine ?? summarize(result)
            )

        case "file_write":
            let path = toolPath(from: input, displayCommand: displayCommand)
            return ToolPresentation(
                kind: .write,
                title: fileActionTitle(activeVerb: "Writing", completedVerb: "Wrote", status: status, path: path),
                target: displayPath(path),
                preview: previewLine ?? summarize(result)
            )

        case "file_patch":
            let path = toolPath(from: input, displayCommand: displayCommand)
            return ToolPresentation(
                kind: .edit,
                title: fileActionTitle(activeVerb: "Editing", completedVerb: "Edited", status: status, path: path),
                target: displayPath(path),
                preview: previewLine ?? summarize(result)
            )

        case "list_files":
            let path = toolPath(from: input, displayCommand: displayCommand) ?? "."
            return ToolPresentation(
                kind: .search,
                title: status == .completed ? "Scanned directory" : "Scanning directory",
                target: truncate(path, limit: 68),
                preview: previewLine ?? summarize(result)
            )

        case "web_search":
            return ToolPresentation(
                kind: .search,
                title: status == .completed ? "Searched web" : "Searching web",
                target: truncate((input?["query"] as? String) ?? displayCommand ?? "the web", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        case "web_fetch":
            return ToolPresentation(
                kind: .read,
                title: status == .completed ? "Fetched page" : "Fetching page",
                target: truncate((input?["url"] as? String) ?? displayCommand ?? "resource", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        case "delegate_to_explorer":
            return ToolPresentation(
                kind: .delegation,
                title: status == .completed ? "Workspace explored" : "Exploring workspace",
                target: truncate((input?["objective"] as? String) ?? "Gathering codebase context", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        case "delegate_to_reviewer":
            let files = stringArray(from: input?["files_to_review"])
            let target = files.isEmpty
                ? truncate((input?["focus_area"] as? String) ?? "Reviewing code", limit: 88)
                : displayPath(files[0])! + (files.count > 1 ? " +\(files.count - 1) more" : "")
            return ToolPresentation(
                kind: .delegation,
                title: status == .completed ? "Code review completed" : "Reviewing code",
                target: target,
                preview: previewLine ?? summarize(result)
            )

        case "delegate_to_worktree":
            return ToolPresentation(
                kind: .delegation,
                title: status == .completed ? "Background job completed" : "Running background job",
                target: truncate((input?["task_prompt"] as? String) ?? "Isolated worktree task", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        case "deploy_to_testflight":
            return ToolPresentation(
                kind: .deploy,
                title: status == .completed ? "Deployment completed" : "Deploying to TestFlight",
                target: nil,
                preview: previewLine ?? summarize(result)
            )

        case "terminal":
            let command = displayCommand ?? (input?["command"] as? String) ?? (input?["starting_command"] as? String)
            let kind = terminalKind(for: command)
            return ToolPresentation(
                kind: kind,
                title: terminalTitle(kind: kind, status: status),
                target: truncate(command ?? "Running command", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        case "screenshot_simulator":
            return ToolPresentation(
                kind: .screenshot,
                title: status == .completed ? "Screenshot captured" : "Capturing screenshot",
                target: nil,
                preview: previewLine ?? summarize(result)
            )

        case "xcode_build":
            return ToolPresentation(
                kind: .build,
                title: status == .completed ? "Build completed" : "Building project",
                target: truncate((input?["scheme"] as? String) ?? (input?["command"] as? String) ?? "swift build", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        case "xcode_test":
            return ToolPresentation(
                kind: .build,
                title: status == .completed ? "Tests completed" : "Running tests",
                target: truncate((input?["filter"] as? String) ?? (input?["command"] as? String) ?? "swift test", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        case "xcode_preview":
            return ToolPresentation(
                kind: .screenshot,
                title: status == .completed ? "Preview captured" : "Building & previewing",
                target: truncate((input?["bundle_id"] as? String) ?? "app", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        case "multimodal_analyze":
            return ToolPresentation(
                kind: .read,
                title: status == .completed ? "Image analyzed" : "Analyzing image",
                target: truncate((input?["question"] as? String) ?? "visual inspection", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        case "git_status":
            return ToolPresentation(
                kind: .read,
                title: status == .completed ? "Status checked" : "Checking git status",
                target: nil,
                preview: previewLine ?? summarize(result)
            )

        case "git_diff":
            let isStaged = (input?["staged"] as? Bool) ?? false
            return ToolPresentation(
                kind: .read,
                title: status == .completed ? "Diff retrieved" : "Reading diff",
                target: isStaged ? "staged changes" : ((input?["path"] as? String).map { displayPath($0) ?? $0 } ?? "working tree"),
                preview: previewLine ?? summarize(result)
            )

        case "git_commit":
            return ToolPresentation(
                kind: .write,
                title: status == .completed ? "Committed" : "Committing changes",
                target: truncate((input?["message"] as? String) ?? "commit", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        case "simulator_launch_app":
            return ToolPresentation(
                kind: .terminal,
                title: status == .completed ? "App launched" : "Launching app",
                target: truncate((input?["bundle_id"] as? String) ?? "app", limit: 88),
                preview: previewLine ?? summarize(result)
            )

        default:
            return ToolPresentation(
                kind: .other,
                title: humanLabel(forToolNamed: name),
                target: nil,
                preview: previewLine ?? summarize(result)
            )
        }
    }

    /// Convert a tool name into a human-readable label.
    static func humanLabel(forToolNamed name: String) -> String {
        switch normalizedToolName(name) {
        case "file_read":                   return "Reading file"
        case "file_write":                  return "Writing file"
        case "file_patch":                  return "Patching file"
        case "list_files":                  return "Scanning directory"
        case "terminal":                    return "Running command"
        case "web_search":                  return "Searching the web"
        case "web_fetch":                   return "Fetching page"
        case "delegate_to_explorer":        return "Dispatching explorer"
        case "delegate_to_reviewer":        return "Dispatching reviewer"
        case "delegate_to_worktree":        return "Dispatching background worker"
        case "deploy_to_testflight":        return "Deploying to TestFlight"
        case "screenshot_simulator":        return "Capturing screenshot"
        case "xcode_build":                 return "Building project"
        case "xcode_test":                  return "Running tests"
        case "xcode_preview":               return "Launching preview"
        case "multimodal_analyze":          return "Analyzing image"
        case "git_status":                  return "Checking git status"
        case "git_diff":                    return "Reading diff"
        case "git_commit":                  return "Committing changes"
        case "simulator_launch_app":        return "Launching app"
        default:
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Detect whether narrative text contains a structured plan.
    /// Marker-first plan detection: parses explicit [PLAN title="..."]...[/PLAN] blocks
    /// emitted by the model. Takes priority over heuristic detection.
    private static func detectMarkedPlan(in text: String) -> StreamPlan? {
        // Require both opening and closing markers.
        guard let openRange = text.range(of: #"\[PLAN(?:\s+title="([^"]*)")?\]"#, options: .regularExpression),
              let closeRange = text.range(of: "[/PLAN]"),
              openRange.upperBound <= closeRange.lowerBound else { return nil }

        // Extract optional title attribute.
        var title = "Plan"
        let markerText = String(text[openRange])
        if let titleCapture = markerText.range(of: #"title="([^"]*)"#, options: .regularExpression) {
            let raw = String(markerText[titleCapture])           // title="Foo"
            if let first = raw.firstIndex(of: "\""),
               let last  = raw.lastIndex(of: "\""),
               first < last {
                title = String(raw[raw.index(after: first)..<last])
            }
        }

        let body = String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var steps: [StreamPlanStep] = []
        var ordinal = 0

        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Checklist items: - [ ] or - [x]
            if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                ordinal += 1
                steps.append(StreamPlanStep(id: "plan-step-\(ordinal)", title: String(trimmed.dropFirst(6)), ordinal: ordinal))
            }
            // Numbered items: 1. or 1)
            else if let range = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                ordinal += 1
                steps.append(StreamPlanStep(id: "plan-step-\(ordinal)", title: String(trimmed[range.upperBound...]), ordinal: ordinal))
            }
            // Indented sub-bullets under the last top-level step
            else if (line.hasPrefix("   ") || line.hasPrefix("\t")), !steps.isEmpty,
                    trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                steps[steps.count - 1].substeps.append(String(trimmed.dropFirst(2)))
            }
        }

        // Model explicitly marked this as a plan — accept with ≥1 step.
        guard !steps.isEmpty else { return nil }
        return StreamPlan(title: title, steps: Array(steps.prefix(8)), isFinalized: true)
    }

    /// Returns a StreamPlan if a plan block is detected in the text.
    ///
    /// Detection order:
    /// 1. Explicit [PLAN title="..."]...[/PLAN] marker block (deterministic — model intent is clear).
    /// 2. Heuristic: numbered/bulleted/checklist list that looks actionable.
    ///
    /// Heuristics to avoid false positives on informational numbered lists:
    /// - Steps must look *actionable* (short, imperative, ≤120 chars each)
    /// - Steps with heavy inline markdown (bold runs, links, long prose) are excluded
    /// - Requires ≥2 qualifying steps
    /// - Checklist syntax (`- [ ]`) is always treated as a plan
    static func detectPlan(in text: String) -> StreamPlan? {
        // Marker-first: model explicitly tagged a plan block — skip heuristics.
        if let markerPlan = detectMarkedPlan(in: text) { return markerPlan }

        let lines = text.components(separatedBy: .newlines)
        var planSteps: [StreamPlanStep] = []
        var planTitle = "Plan"
        var ordinal = 0
        var hasChecklistSyntax = false

        // Reasoning markers that should stop plan detection
        let reasoningPrefixes = ["pre-flight:", "pre-flight", "reasoning:", "thinking:", "analysis:"]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            // Stop parsing if we hit reasoning/pre-flight text
            if reasoningPrefixes.contains(where: { lower.hasPrefix($0) }) {
                break
            }

            // Detect heading as plan title
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
                let heading = trimmed.drop(while: { $0 == "#" || $0 == " " })
                if !heading.isEmpty {
                    planTitle = String(heading)
                }
                continue
            }

            // Detect checklist items: - [ ] Task or - [x] Task — always a plan
            if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                let stepText = String(trimmed.dropFirst(6))
                let stepLower = stepText.lowercased()
                if stepLower.hasPrefix("pre-flight") || stepLower.contains("pre-flight:") {
                    continue
                }
                hasChecklistSyntax = true
                ordinal += 1
                planSteps.append(StreamPlanStep(
                    id: "plan-step-\(ordinal)",
                    title: stepText,
                    ordinal: ordinal
                ))
                continue
            }

            // Detect numbered list items (top-level plan steps)
            if let range = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                let stepText = String(trimmed[range.upperBound...])
                let stepLower = stepText.lowercased()
                if stepLower.hasPrefix("pre-flight") || stepLower.contains("pre-flight:") {
                    continue
                }
                // Guard: reject items that look like informational content rather than
                // actionable plan steps. Indicators of informational content:
                //   - Very long text (>120 chars — real plan steps are concise)
                //   - Heavy bold markdown (**...**) wrapping whole phrases
                //   - Contains URLs or link syntax
                //   - Contains parenthetical citations
                let stripped = stepText.replacingOccurrences(of: "**", with: "")
                if stripped.count > 120 { continue }
                if stepText.contains("](") || stepText.contains("http") { continue }
                // Bold wrapping at the start (e.g. "**AI assistants are mainstream**") signals content, not a step
                if stepText.hasPrefix("**") && stepText.contains(".**") { continue }
                if stepText.hasPrefix("**") && stripped.count > 60 { continue }

                ordinal += 1
                planSteps.append(StreamPlanStep(
                    id: "plan-step-\(ordinal)",
                    title: stepText,
                    ordinal: ordinal
                ))
                continue
            }

            // Detect indented sub-items as substeps of the last top-level step
            let indentedBullet = line.hasPrefix("   ") || line.hasPrefix("\t")
            if indentedBullet, !planSteps.isEmpty,
               (trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")) {
                let subText = String(trimmed.dropFirst(2))
                planSteps[planSteps.count - 1].substeps.append(subText)
                continue
            }

            // Detect bulleted list items (only if we haven't found numbered ones)
            if planSteps.isEmpty, trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let stepText = String(trimmed.dropFirst(2))
                let stripped = stepText.replacingOccurrences(of: "**", with: "")
                // Same guards as numbered items
                if stripped.count > 120 { continue }
                if stepText.contains("](") || stepText.contains("http") { continue }
                if stepText.hasPrefix("**") && stepText.contains(".**") { continue }
                if stepText.hasPrefix("**") && stripped.count > 60 { continue }

                ordinal += 1
                planSteps.append(StreamPlanStep(
                    id: "plan-step-\(ordinal)",
                    title: stepText,
                    ordinal: ordinal
                ))
            }
        }

        guard planSteps.count >= 2 else { return nil }
        // Require ≥3 steps for numbered/bulleted lists (not checklists) to reduce false positives.
        // Checklists (- [ ]) are always intentional plan syntax.
        if !hasChecklistSyntax && planSteps.count < 3 { return nil }

        // Cap at 8 steps — strip shows 6 visible rows with an overflow hint for the rest.
        let cappedSteps = Array(planSteps.prefix(8))

        return StreamPlan(
            title: planTitle,
            steps: cappedSteps,
            isFinalized: true
        )
    }

    /// Detect an artifact from a completed tool call.
    static func detectArtifact(toolName: String, result: String, isError: Bool) -> StreamArtifact? {
        guard !isError else { return nil }

        switch normalizedToolName(toolName) {
        case "file_write":
            return StreamArtifact(kind: .fileWrite, path: extractPath(from: result), summary: "File written")
        case "file_patch":
            return StreamArtifact(kind: .filePatch, path: extractPath(from: result), summary: "File patched")
        case "screenshot_simulator":
            return StreamArtifact(kind: .screenshot, path: extractPath(from: result), summary: "Screenshot captured")
        case "xcode_build":
            return StreamArtifact(kind: .build, path: nil, summary: "Build succeeded")
        case "xcode_test":
            return StreamArtifact(kind: .test, path: nil, summary: "Tests completed")
        case "xcode_preview":
            return StreamArtifact(kind: .screenshot, path: extractPath(from: result), summary: "Preview captured")
        case "multimodal_analyze":
            return StreamArtifact(kind: .multimodal, path: extractPath(from: result), summary: "Image analyzed")
        case "git_status":
            return StreamArtifact(kind: .gitStatus, path: nil, summary: "Repository status")
        default:
            return nil
        }
    }

    static func deepLinkForTool(
        named toolName: String,
        inputJSON: String?,
        result: String?,
        status: StreamStepStatus,
        spanID: UUID?
    ) -> StreamDeepLink? {
        if status == .failed {
            return .inspector(spanID: spanID)
        }

        let input = inputJSON.flatMap(parsedJSON)
        let normalizedName = normalizedToolName(toolName)

        switch normalizedName {
        case "file_read", "file_write", "file_patch":
            if let path = toolPath(from: input, displayCommand: nil) ?? extractPath(from: result ?? "") {
                return .file(path: path, sourceLabel: artifactSourceLabel(forToolNamed: toolName))
            }
        case "screenshot_simulator", "xcode_preview":
            if let path = extractPath(from: result ?? "") {
                return .screenshot(path: path)
            }
        case "multimodal_analyze":
            if let path = input?["image_path"] as? String {
                return .screenshot(path: path)
            }
        default:
            break
        }

        if let spanID {
            return .inspector(spanID: spanID)
        }

        return nil
    }

    /// Generate an intent summary from the goal text.
    static func intentFromGoal(_ goal: String) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        // Truncate to first sentence or 80 chars
        if let dot = trimmed.prefix(80).lastIndex(of: ".") {
            return String(trimmed[trimmed.startIndex...dot])
        }
        return String(trimmed.prefix(77)) + "..."
    }

    private static func extractPath(from result: String) -> String? {
        // Look for a file path pattern in the result
        let lines = result.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/") && !trimmed.contains(" ") {
                return trimmed
            }
        }
        return nil
    }

    private static func parsedJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func stringArray(from value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func displayPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let lastComponent = URL(fileURLWithPath: path).lastPathComponent
        return lastComponent.isEmpty ? path : lastComponent
    }

    private static func toolPath(from input: [String: Any]?, displayCommand: String?) -> String? {
        if let path = (input?["path"] as? String) ?? (input?["filePath"] as? String) ?? (input?["file_path"] as? String) {
            return path
        }
        guard let displayCommand, !displayCommand.isEmpty else { return nil }
        return extractPath(from: displayCommand)
    }

    private static func fileActionTitle(
        activeVerb: String,
        completedVerb: String,
        status: StreamStepStatus,
        path: String?
    ) -> String {
        let verb = status == .completed ? completedVerb : activeVerb
        let object = displayPath(path) ?? "file"
        return "\(verb) \(object)"
    }

    private static func artifactSourceLabel(forToolNamed toolName: String) -> String {
        switch normalizedToolName(toolName) {
        case "file_read":
            return "Read file"
        case "file_write":
            return "Written file"
        case "file_patch":
            return "Patched file"
        default:
            return humanLabel(forToolNamed: toolName)
        }
    }

    private static func summarize(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let line = trimmed.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return truncate(line.trimmingCharacters(in: .whitespacesAndNewlines), limit: 96)
        }
        return truncate(trimmed, limit: 96)
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 3)) + "..."
    }

    private static func terminalKind(for command: String?) -> StreamStepKind {
        let context = (command ?? "").lowercased()
        if context.contains("screenshot") || context.contains("simctl io") {
            return .screenshot
        }
        if context.contains("xcodebuild")
            || context.contains("swift build")
            || context.contains("swift test")
            || context.contains("build")
            || context.contains("compile")
            || context.contains("verify")
            || context.contains("test") {
            return .build
        }
        return .terminal
    }

    private static func terminalTitle(kind: StreamStepKind, status: StreamStepStatus) -> String {
        switch kind {
        case .build:
            return status == .completed ? "Build completed" : "Building project"
        case .screenshot:
            return status == .completed ? "Screenshot captured" : "Capturing screenshot"
        default:
            return status == .completed ? "Command completed" : "Running command"
        }
    }

    private static func normalizedToolName(_ name: String) -> String {
        switch name {
        case "read_file":
            return "file_read"
        case "create_file", "write_file":
            return "file_write"
        case "apply_patch":
            return "file_patch"
        case "list_dir":
            return "list_files"
        case "fetch_webpage":
            return "web_fetch"
        case "run_in_terminal":
            return "terminal"
        case "take_screenshot", "capture_screenshot":
            return "screenshot_simulator"
        case "build", "swift_build":
            return "xcode_build"
        case "test", "swift_test":
            return "xcode_test"
        case "analyze_image", "vision":
            return "multimodal_analyze"
        default:
            return name
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Narrative Chunker
// ═══════════════════════════════════════════════════════════════════════════════
//
// Upgrades the existing StreamingTextBuffer with semantic chunking.
// Instead of flushing on char count, groups text into semantic units:
// - sentences (for prose)
// - code blocks (entire block at once)
// - list items (complete item)

actor NarrativeChunker {

    private var buffer = ""
    private var isInsideCodeBlock = false
    private var codeBlockAccumulator = ""
    private var hasFlushedFirstChunk = false
    private var totalCharsFlushed = 0
    private var lastFlushTime: ContinuousClock.Instant?

    /// Minimum chars to accumulate before considering a flush for non-code text.
    private static let minFlushThreshold = 20
    /// Maximum chars before forcing a flush regardless.
    private static let maxFlushThreshold = 120
    /// For the very first chunk, flush aggressively for TTFMO.
    private static let firstChunkThreshold = 8
    /// Minimum interval between flushes for very large responses (>8K chars).
    private static let largeResponseThrottleInterval: ContinuousClock.Duration = .milliseconds(50)
    /// Threshold after which throttling kicks in.
    private static let largeResponseCharThreshold = 8_000

    func append(_ text: String) -> String? {
        buffer += text

        // If inside a code block, accumulate until close fence
        if isInsideCodeBlock {
            codeBlockAccumulator += text
            if codeBlockAccumulator.contains("\n```") {
                isInsideCodeBlock = false
                let block = codeBlockAccumulator
                codeBlockAccumulator = ""
                buffer = ""
                return block
            }
            return nil
        }

        // Check for code block start. Only enter code-block mode when we have
        // seen an unmatched opening fence; complete blocks should flush normally.
        let fenceCount = buffer.components(separatedBy: "```").count - 1
        if fenceCount > 0, fenceCount.isMultiple(of: 2) == false,
           let openingFenceRange = buffer.range(of: "```") {
            let preCode = String(buffer[..<openingFenceRange.lowerBound])
            isInsideCodeBlock = true
            codeBlockAccumulator = String(buffer[openingFenceRange.lowerBound...])
            buffer = ""
            hasFlushedFirstChunk = true
            return preCode.isEmpty ? nil : preCode
        }

        let threshold = hasFlushedFirstChunk ? Self.minFlushThreshold : Self.firstChunkThreshold

        // For very large responses, throttle flushes to avoid overwhelming the UI.
        let shouldThrottle = totalCharsFlushed >= Self.largeResponseCharThreshold
            && !isInsideCodeBlock
        if shouldThrottle, let last = lastFlushTime,
           ContinuousClock.now - last < Self.largeResponseThrottleInterval,
           buffer.count < Self.maxFlushThreshold {
            return nil
        }

        // Force flush on max threshold
        if buffer.count >= Self.maxFlushThreshold {
            return flush()
        }

        // Flush on sentence boundary
        if buffer.count >= threshold {
            if let lastSentenceEnd = findLastSentenceBoundary(in: buffer) {
                let chunk = String(buffer[buffer.startIndex...lastSentenceEnd])
                buffer = String(buffer[buffer.index(after: lastSentenceEnd)...])
                hasFlushedFirstChunk = true
                return chunk
            }
        }

        // Flush on newline for list items
        if buffer.contains("\n") && buffer.count >= threshold {
            return flush()
        }

        return nil
    }

    func flush() -> String {
        let output = buffer
        buffer = ""
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasFlushedFirstChunk = true
            totalCharsFlushed += output.count
            lastFlushTime = .now
        }
        return output
    }

    func flushAll() -> String {
        var all = buffer
        if isInsideCodeBlock {
            all += codeBlockAccumulator
            codeBlockAccumulator = ""
            isInsideCodeBlock = false
        }
        buffer = ""
        return all
    }

    private func findLastSentenceBoundary(in text: String) -> String.Index? {
        let sentenceEnders: Set<Character> = [".", "!", "?", "\n"]
        var lastBoundary: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if sentenceEnders.contains(text[index]) {
                lastBoundary = index
            }
            index = text.index(after: index)
        }
        return lastBoundary
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Stream Pipeline Coordinator
// ═══════════════════════════════════════════════════════════════════════════════
//
// Orchestrates the full pipeline:
//   AgentEvent → SemanticEventTransformer → NarrativeChunker → StreamPhaseController
//
// The coordinator calls named methods directly on StreamPhaseController.
// PipelineRunner calls into this instead of directly mutating ChatThread.

@MainActor
@Observable
final class StreamPipelineCoordinator {

    let phaseController = StreamPhaseController()
    var deepLinkRouter: StreamDeepLinkRouter { phaseController.deepLinkRouter }

    /// Reference to the viewport surface for synchronized phase transitions.
    /// Set by the wiring layer (CommandCenterView) on appear.
    var viewportModel: ViewportStreamModel?

    /// Inline terminal strip that slides up below the chat column.
    let terminalMonitor = InlineTerminalMonitor()
    /// Inline task plan strip that slides up below the chat column when a plan is detected.
    let taskPlanMonitor = InlineTaskPlanMonitor()

    @ObservationIgnored private let chunker = NarrativeChunker()
    @ObservationIgnored private var activeToolCalls: [String: String] = [:]
    @ObservationIgnored private var activeToolInputs: [String: String] = [:]
    @ObservationIgnored private var activeToolSpans: [String: UUID] = [:]
    @ObservationIgnored private var accumulatedNarrative = ""
    @ObservationIgnored private var planDetected = false
    /// True while the stream is inside a [PLAN]...[/PLAN] block emitted by the model.
    /// Text is suppressed from the narrative chunker until the block closes.
    @ObservationIgnored private var awaitingPlanMarkerClose = false
    @ObservationIgnored private var chunkFlushTask: Task<Void, Never>?
    /// When true, the deterministic plan from TaskPlanBridge is already driving the
    /// InlineTaskPlanMonitor. Narrative-detected plans still render in the viewport
    /// but do NOT overwrite the monitor.
    @ObservationIgnored var hasDeterministicPlan = false

    /// Called on the main actor immediately after a plan is first detected.
    /// Set by PipelineSupport to convert the streaming message to a viewport card.
    var onPlanDetected: (() -> Void)?
    /// Set to true once the plan is detected; signals PipelineSupport to stop flushing text to chat.
    private(set) var didDetectPlan: Bool = false
    /// Tracks the current plan step ID for tool→plan linking.
    @ObservationIgnored private var activePlanStepID: String?

    // Viewport terminal tracking
    @ObservationIgnored private var activeTerminalToolID: String?
    @ObservationIgnored private var activeTerminalLines: [String] = []
    @ObservationIgnored private var activeTerminalCommand: String = ""
    @ObservationIgnored private var terminalLineFlushCounter = 0
    /// Maximum retained lines in the terminal model (10x the UI cap of 50).
    private static let maxTerminalLines = 500
    /// Flush viewport update every N lines to reduce @Observable churn.
    private static let terminalLineFlushInterval = 5

    /// Call when a new streaming run begins.
    func beginRun(goal: String) {
        phaseController.beginStream()
        activeToolCalls = [:]
        activeToolInputs = [:]
        activeToolSpans = [:]
        accumulatedNarrative = ""
        planDetected = false
        activePlanStepID = nil
        activeTerminalToolID = nil
        activeTerminalLines = []
        activeTerminalCommand = ""
        terminalLineFlushCounter = 0
        terminalMonitor.reset()
        taskPlanMonitor.reset()

        let intent = SemanticEventTransformer.intentFromGoal(goal)
        phaseController.acknowledge(intent: intent)

        // Drive viewport to intent phase — both surfaces acknowledge simultaneously.
        viewportModel?.requestTransition(
            to: .intent,
            content: .none,
            title: "Preparing",
            status: "Resolving"
        )

        startPeriodicFlush()
    }

    /// Call when the streaming run completes successfully.
    func completeRun() {
        chunkFlushTask?.cancel()
        chunkFlushTask = nil
        Task {
            let remaining = await chunker.flushAll()
            if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                phaseController.appendNarrative(remaining)
            }
        }
        phaseController.endStream()

        // Drive viewport: dismiss any active terminal, then settle.
        // If the viewport is already showing a preview artifact, leave it.
        // Otherwise return to idle.
        if activeTerminalToolID != nil {
            activeTerminalToolID = nil
            viewportModel?.dismissTerminalActivity()
            terminalMonitor.finish()
        }
        if let viewport = viewportModel, viewport.phase == .executing {
            viewport.requestTransition(to: .idle, content: .none)
        }
        taskPlanMonitor.finish()
    }

    /// Call when the streaming run fails.
    func failRun(message: String) {
        chunkFlushTask?.cancel()
        chunkFlushTask = nil
        phaseController.failStream(StreamError(
            message: message,
            isRecoverable: true,
            stepID: activeToolCalls.values.first
        ))

        // Drive viewport to error — both surfaces reflect failure.
        if activeTerminalToolID != nil {
            activeTerminalToolID = nil
            viewportModel?.dismissTerminalActivity()
            terminalMonitor.finish()
        }
        viewportModel?.showError(message: message)
        taskPlanMonitor.finish()
    }

    /// Reset to idle state.
    func reset() {
        chunkFlushTask?.cancel()
        chunkFlushTask = nil
        phaseController.reset()
        activeToolCalls = [:]
        activeToolInputs = [:]
        activeToolSpans = [:]
        accumulatedNarrative = ""
        planDetected = false
        awaitingPlanMarkerClose = false
        hasDeterministicPlan = false
        didDetectPlan = false
        onPlanDetected = nil
        activePlanStepID = nil
        activeTerminalToolID = nil
        activeTerminalLines = []
        activeTerminalCommand = ""
        terminalLineFlushCounter = 0
        terminalMonitor.reset()
        taskPlanMonitor.reset()
    }

    func handleTextDelta(_ text: String) {
        accumulatedNarrative += text

        // When narrative arrives after tool calls, advance plan step and refresh viewport.
        if let currentStep = activePlanStepID,
           activeToolCalls.isEmpty {
            activePlanStepID = phaseController.advancePlanStep(from: currentStep)
            refreshViewportPlan()
        }

        // Track whether we're inside a [PLAN]...[/PLAN] marker block.
        // Suppress text to the narrative chunker while inside the block so partial plan
        // content doesn't leak into the chat thread.
        if !planDetected {
            if !awaitingPlanMarkerClose && accumulatedNarrative.contains("[PLAN") {
                awaitingPlanMarkerClose = true
            }
        }

        // Try to detect plan in accumulated text (once).
        // Cap scan window to avoid O(n²) re-scanning on every token.
        if !planDetected && accumulatedNarrative.count > 60 {
            let scanWindow: String
            if accumulatedNarrative.count > 2000 {
                scanWindow = String(accumulatedNarrative.suffix(2000))
            } else {
                scanWindow = accumulatedNarrative
            }
            if let plan = SemanticEventTransformer.detectPlan(in: scanWindow) {
                planDetected = true
                awaitingPlanMarkerClose = false
                phaseController.setPlan(plan)
                driveViewportPlan(plan)
            }
        }

        // Don't forward plan-marker content to the narrative chunker — it belongs
        // in the task panel, not the chat thread.
        guard !awaitingPlanMarkerClose else { return }

        Task {
            if let chunk = await chunker.append(text) {
                phaseController.appendNarrative(chunk)
            }
        }
    }

    func handleThinkingDelta(_ text: String) {
        phaseController.appendThinking(text)
    }

    func associateToolSpan(id: String, spanID: UUID) {
        activeToolSpans[id] = spanID
        refineStepDeepLink(stepID: id, result: nil, status: .active)
    }

    func handleToolCallStart(id: String, name: String) {
        activeToolCalls[id] = name
        activeToolInputs[id] = ""
        let step = SemanticEventTransformer.stepFromToolCall(id: id, name: name)
        phaseController.startStep(step)
        refineStepDeepLink(stepID: id, result: nil, status: .active)

        // Link tool to current plan step. If no step is active, activate the first pending one.
        if let plan = phaseController.plan {
            if activePlanStepID == nil {
                activePlanStepID = plan.currentStepID
                if let sid = activePlanStepID {
                    phaseController.updatePlanStepStatus(sid, .inProgress)
                }
            }
        }

        // Drive viewport terminal for terminal-type tools.
        if Self.isTerminalTool(name) {
            activeTerminalToolID = id
            activeTerminalCommand = SemanticEventTransformer.humanLabel(forToolNamed: name)
            activeTerminalLines = []
            terminalLineFlushCounter = 0
            viewportModel?.showTerminalActivity(ViewportTerminalModel(
                command: activeTerminalCommand,
                lines: [],
                isRunning: true
            ))
            terminalMonitor.start(command: activeTerminalCommand)
        }
    }

    func handleToolCallInputDelta(id: String, partialJSON: String) {
        guard activeToolCalls[id] != nil else { return }
        activeToolInputs[id, default: ""] += partialJSON
        refineStepPresentation(stepID: id, previewLine: nil, result: nil, status: .active)
        refineStepDeepLink(stepID: id, result: nil, status: .active)
    }

    func handleToolCallCommand(id: String, command: String) {
        phaseController.progressStep(id: id, lines: [], detail: command)
        refineStepPresentation(stepID: id, previewLine: nil, result: nil, status: .active, displayCommand: command)

        // Update viewport terminal command label.
        if id == activeTerminalToolID {
            activeTerminalCommand = command
            viewportModel?.updateTerminalActivity(ViewportTerminalModel(
                command: command,
                lines: activeTerminalLines,
                isRunning: true
            ))
            terminalMonitor.updateCommand(command)
        }
    }

    func handleToolCallOutput(id: String, line: String) {
        phaseController.progressStep(id: id, lines: [line], detail: nil)
        refineStepPresentation(stepID: id, previewLine: line, result: nil, status: .active)
        refineStepDeepLink(stepID: id, result: nil, status: .active)

        // Stream terminal output to viewport process layer.
        if id == activeTerminalToolID {
            activeTerminalLines.append(line)
            // Cap retained lines to prevent unbounded memory growth.
            if activeTerminalLines.count > Self.maxTerminalLines {
                activeTerminalLines.removeFirst(activeTerminalLines.count - Self.maxTerminalLines)
            }
            // Throttle @Observable updates — push every N lines (always push first 10 for fast feedback).
            terminalLineFlushCounter += 1
            let shouldFlush = terminalLineFlushCounter <= 10
                || terminalLineFlushCounter % Self.terminalLineFlushInterval == 0
            if shouldFlush {
                viewportModel?.updateTerminalActivity(ViewportTerminalModel(
                    command: activeTerminalCommand,
                    lines: activeTerminalLines,
                    isRunning: true
                ))
            }
            // Feed inline terminal strip — always push (lightweight, no viewport overhead).
            terminalMonitor.appendLine(line)
        }
    }

    func handleToolCallResult(id: String, result: String, isError: Bool) {
        let status: StreamStepStatus = isError ? .failed : .completed
        refineStepPresentation(stepID: id, previewLine: nil, result: result, status: status)
        refineStepDeepLink(stepID: id, result: result, status: status)
        phaseController.completeStep(id: id, status: status)

        // Dismiss viewport terminal if this was the active terminal tool.
        if id == activeTerminalToolID {
            activeTerminalToolID = nil
            viewportModel?.dismissTerminalActivity()
            terminalMonitor.finish()
        }

        // Detect artifacts and drive both surfaces.
        if let toolName = activeToolCalls[id],
           let artifact = SemanticEventTransformer.detectArtifact(toolName: toolName, result: result, isError: isError) {
            phaseController.addArtifact(artifact)
            driveViewportArtifact(artifact)
        }

        activeToolCalls.removeValue(forKey: id)
        activeToolInputs.removeValue(forKey: id)
        activeToolSpans.removeValue(forKey: id)
    }

    private func refineStepPresentation(
        stepID: String,
        previewLine: String?,
        result: String?,
        status: StreamStepStatus,
        displayCommand: String? = nil
    ) {
        guard let toolName = activeToolCalls[stepID] else { return }
        let presentation = SemanticEventTransformer.humanizeTool(
            named: toolName,
            inputJSON: activeToolInputs[stepID],
            displayCommand: displayCommand,
            result: result,
            status: status,
            previewLine: previewLine
        )

        phaseController.refineStep(
            id: stepID,
            title: presentation.title,
            target: presentation.target,
            preview: presentation.preview
        )
    }

    private func refineStepDeepLink(
        stepID: String,
        result: String?,
        status: StreamStepStatus
    ) {
        guard let toolName = activeToolCalls[stepID] else { return }
        let deepLink = SemanticEventTransformer.deepLinkForTool(
            named: toolName,
            inputJSON: activeToolInputs[stepID],
            result: result,
            status: status,
            spanID: activeToolSpans[stepID]
        )
        phaseController.linkStep(id: stepID, deepLink: deepLink)
    }

    // MARK: - Viewport Phase Sync

    private static func isTerminalTool(_ name: String) -> Bool {
        switch name {
        case "terminal", "run_in_terminal", "xcode_build", "xcode_preview", "deploy_to_testflight":
            return true
        default:
            return false
        }
    }

    private func driveViewportPlan(_ plan: StreamPlan) {
        var lines: [String] = []
        for step in plan.steps {
            let checkbox = (step.status == .completed || step.status == .skipped) ? "- [x] " : "- [ ] "
            lines.append("\(checkbox)\(step.title)")
            for sub in step.substeps {
                lines.append("  - \(sub)")
            }
        }
        let completedCount = plan.steps.filter { $0.status == .completed || $0.status == .skipped }.count
        let subtitle = completedCount > 0
            ? "\(completedCount)/\(plan.steps.count) steps done"
            : "\(plan.steps.count) steps"
        let markdown = lines.joined(separator: "\n")
        let viewportPlan = ViewportPlanModel(
            title: plan.title,
            subtitle: subtitle,
            markdown: markdown,
            agentName: nil,
            timestamp: Date()
        )
        viewportModel?.showPlanDocument(viewportPlan)
        // Auto-open the viewport if it is currently hidden.
        viewportModel?.onRequestReveal?()
        // Drive inline task plan strip in the chat column — but only when no
        // deterministic plan is already driving the monitor.
        if !hasDeterministicPlan {
            if taskPlanMonitor.isRevealed {
                taskPlanMonitor.refresh(plan)
            } else {
                taskPlanMonitor.setPlan(plan)
            }
        }
        // Signal PipelineSupport to replace the streaming message with a plan card.
        if !didDetectPlan {
            didDetectPlan = true
            onPlanDetected?()
        }
    }

    /// Re-drive the viewport plan document from current step statuses.
    /// Called whenever a plan step advances so the viewport reflects live completion state.
    private func refreshViewportPlan() {
        guard let plan = phaseController.plan else { return }
        driveViewportPlan(plan)
    }

    private func driveViewportArtifact(_ artifact: StreamArtifact) {
        guard let viewport = viewportModel else { return }
        switch artifact.kind {
        case .fileWrite, .filePatch:
            if let path = artifact.path {
                viewport.showFilePreview(path: path, sourceLabel: artifact.summary)
            }
        case .screenshot, .multimodal:
            if let path = artifact.path {
                viewport.imagePath = path
                viewport.requestTransition(to: .preview, content: .artifactImage(path: path))
            }
        case .diff, .build, .test, .gitStatus:
            break
        }
    }

    // MARK: - Periodic Flush

    private func startPeriodicFlush() {
        chunkFlushTask?.cancel()
        chunkFlushTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                let flushed = await chunker.flush()
                if !flushed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    phaseController.appendNarrative(flushed)
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Stream Narrative Partitioner (existing, preserved)
// ═══════════════════════════════════════════════════════════════════════════════

/// Joins stable and live narrative text with clean boundaries.
/// Already exists in Models.swift as StreamingNarrativePartitioner — re-exported here
/// for reference. The actual implementation lives in Models.swift.
///
/// Usage:
///   let joined = StreamingNarrativePartitioner.join(stable: msg.text, live: msg.streamingText)
