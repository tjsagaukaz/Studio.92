import Foundation
import Observation
import SwiftUI

// MARK: - Viewport Phase (Finite State Machine)

/// The viewport has exactly six phases. Every visual change flows through this.
/// No phase can be skipped. Transitions are gated by the controller.
enum ViewportPhase: Equatable, CaseIterable {
    /// Nothing happening. Surface shows ghost silhouette.
    case idle
    /// System has received intent but content isn't ready. Shows preparing state.
    case intent
    /// A plan document is the dominant surface.
    case plan
    /// Active execution. Terminal process layer is visible.
    case executing
    /// A result is displayed (diff, file, image, screenshot).
    case preview
    /// Something failed. Shows error with continuity.
    case error
}

/// Content that the viewport can display within a phase.
enum ViewportContent: Equatable {
    case none
    case simulatorScreenshot
    case artifactImage(path: String)
    case diffPreview(ViewportDiffModel)
    case filePreview(ViewportFileModel)
    case planDocument(ViewportPlanModel)
    case simulatorBooting
    case errorCard(ViewportBuildErrorModel)
    case approvalGate(ViewportApprovalModel)
    case temporalRevert(TemporalRevertModel)
}

// MARK: - Transition Rules

/// Every legal transition and its timing.
/// Durations are calibrated per cognitive expectation:
///  - Forward momentum (idle→intent→plan→exec): brisk, resolving
///  - Mode changes (plan→exec, exec→preview): deliberate, weighted
///  - Wind-down (→idle): always leisurely, no urgency
///  - Error: slightly slower than success, gives weight to failure
///  - Same-phase updates (preview→preview): near-instant, just content swap
struct ViewportTransition: Equatable {
    let from: ViewportPhase
    let to: ViewportPhase
    let duration: TimeInterval
    let curve: TransitionCurve

    enum TransitionCurve: Equatable {
        case easeOut
        case linear
        case spring
    }

    /// The canonical transition table.
    static let table: [ViewportTransition] = [
        // ── From idle ──────────────────────────────────────────────────
        .init(from: .idle,      to: .intent,     duration: 0.12, curve: .easeOut),   // sub-perceptual snap
        .init(from: .idle,      to: .plan,       duration: 0.25, curve: .easeOut),   // content arriving
        .init(from: .idle,      to: .preview,    duration: 0.25, curve: .easeOut),   // content arriving
        .init(from: .idle,      to: .executing,  duration: 0.18, curve: .easeOut),   // action starting
        // ── From intent ────────────────────────────────────────────────
        .init(from: .intent,    to: .plan,       duration: 0.28, curve: .easeOut),   // deliberate resolve
        .init(from: .intent,    to: .executing,  duration: 0.22, curve: .easeOut),   // action starting
        .init(from: .intent,    to: .preview,    duration: 0.25, curve: .easeOut),   // content resolve
        .init(from: .intent,    to: .idle,       duration: 0.35, curve: .easeOut),   // leisurely wind-down
        .init(from: .intent,    to: .error,      duration: 0.25, curve: .easeOut),   // weighted failure
        // ── From plan ──────────────────────────────────────────────────
        .init(from: .plan,      to: .executing,  duration: 0.30, curve: .easeOut),   // major mode change
        .init(from: .plan,      to: .preview,    duration: 0.28, curve: .easeOut),   // content resolve
        .init(from: .plan,      to: .idle,       duration: 0.40, curve: .easeOut),   // leisurely wind-down
        .init(from: .plan,      to: .error,      duration: 0.25, curve: .easeOut),   // weighted failure
        // ── From executing ─────────────────────────────────────────────
        .init(from: .executing, to: .preview,    duration: 0.22, curve: .easeOut),   // result arriving
        .init(from: .executing, to: .error,      duration: 0.25, curve: .easeOut),   // weighted failure
        .init(from: .executing, to: .idle,       duration: 0.40, curve: .easeOut),   // leisurely wind-down
        .init(from: .executing, to: .plan,       duration: 0.28, curve: .easeOut),   // step back
        // ── From preview ───────────────────────────────────────────────
        .init(from: .preview,   to: .idle,       duration: 0.40, curve: .easeOut),   // leisurely wind-down
        .init(from: .preview,   to: .intent,     duration: 0.15, curve: .easeOut),   // new request snap
        .init(from: .preview,   to: .executing,  duration: 0.22, curve: .easeOut),   // re-entering action
        .init(from: .preview,   to: .plan,       duration: 0.28, curve: .easeOut),   // step back
        .init(from: .preview,   to: .preview,    duration: 0.12, curve: .easeOut),   // content swap; near-instant
        // ── From error ─────────────────────────────────────────────────
        .init(from: .error,     to: .idle,       duration: 0.40, curve: .easeOut),   // leisurely recovery
        .init(from: .error,     to: .intent,     duration: 0.15, curve: .easeOut),   // new request snap
    ]

    static func find(from: ViewportPhase, to: ViewportPhase) -> ViewportTransition? {
        table.first { $0.from == from && $0.to == to }
    }
}

// MARK: - Process Layer State

/// The terminal is not a content type or a phase — it is a persistent process layer
/// that composites over whatever phase the viewport is in.
struct ViewportProcessLayer: Equatable {
    var terminal: ViewportTerminalModel?
    var isRevealed: Bool = false
}

// MARK: - Source Models

enum SimulatorPreviewStatus: Equatable {
    case idle
    case booting
    case attached
}

struct ViewportDiffModel: Equatable {
    let title: String
    let subtitle: String
    let state: CodeDiffPreviewState
    let canApply: Bool

    init(
        title: String = "Diff Preview",
        state: CodeDiffPreviewState,
        canApply: Bool? = nil
    ) {
        self.title = title
        self.state = state
        self.subtitle = state.viewportSubtitle
        self.canApply = canApply ?? state.supportsApply
    }
}

enum ViewportFileState: Equatable {
    case loading
    case ready(String)
    case failed(String)
}

struct ViewportFileModel: Equatable {
    let path: String
    let displayName: String
    let language: String?
    let sourceLabel: String
    let state: ViewportFileState
}

struct ViewportPlanModel: Equatable {
    let title: String
    let subtitle: String
    let markdown: String
    let agentName: String?
    let timestamp: Date
}

struct ViewportTerminalModel: Equatable {
    let command: String
    var lines: [String]
    var isRunning: Bool
}

struct ViewportBuildErrorModel: Equatable {
    /// The command (or tool name) that failed.
    let command: String
    /// Fully parsed diagnostics, if available.
    let report: BuildReport?
    /// Last ~50 lines of raw output for context.
    let rawTail: String
    /// How many auto-recovery attempts have been triggered.
    var triageAttempts: Int = 0
}

struct ViewportApprovalModel: Equatable {
    let title: String
    let toolName: String
    let intentDescription: String
    let actionPreview: String?

    var isTerminalCommand: Bool { toolName == "terminal" }
    var isFileOperation: Bool { ["file_write", "file_patch", "file_read", "list_files"].contains(toolName) }
}

// MARK: - Temporal Revert Model

struct TemporalRevertModel: Equatable {
    let anchorID: UUID
    let title: String
    let actionPreview: String?
    let anchorSHA: String
    let anchorTimestamp: Date
    /// True when the revert is in-flight (shows spinner on the CTA).
    var isReverting: Bool = false
}

// MARK: - Action Context

struct ViewportActionContext {
    var showDiffPreview: (ViewportDiffModel, ((CodeDiffSession) -> Void)?) -> Void = { _, _ in }
    var showFilePreview: (String) -> Void = { _ in }
    var showPlanDocument: (ViewportPlanModel) -> Void = { _ in }
    var showTerminalActivity: (ViewportTerminalModel) -> Void = { _ in }
    var updateTerminalActivity: (ViewportTerminalModel) -> Void = { _ in }
    var dismissTerminalActivity: () -> Void = {}
    var showErrorCard: (ViewportBuildErrorModel) -> Void = { _ in }
    var showApprovalGate: (ViewportApprovalModel) -> Void = { _ in }
    var dismissApprovalGate: () -> Void = {}
    var showTemporalRevert: (TemporalRevertModel) -> Void = { _ in }
    var dismissTemporalRevert: () -> Void = {}
    /// Called when a diff is successfully applied. The closure creates a Git anchor
    /// and returns the new `ActionAnchor`, or nil if the repo is unavailable.
    var createAnchor: (_ title: String, _ preview: String?) async -> ActionAnchor? = { _, _ in nil }
}

private struct ViewportActionContextKey: EnvironmentKey {
    static let defaultValue = ViewportActionContext()
}

extension EnvironmentValues {
    var viewportActionContext: ViewportActionContext {
        get { self[ViewportActionContextKey.self] }
        set { self[ViewportActionContextKey.self] = newValue }
    }
}

// MARK: - Stream Model (State Machine Controller)

@MainActor
@Observable
final class ViewportStreamModel {

    // MARK: Observable State

    private(set) var phase: ViewportPhase = .idle
    private(set) var content: ViewportContent = .none
    var processLayer = ViewportProcessLayer()
    private(set) var lockedTitle: String = "Viewport"
    private(set) var statusLabel: String = "Idle"
    private(set) var errorMessage: String?

    /// Whether the pipeline is currently running. Set by the wiring layer.
    var isPipelineActive: Bool = false
    /// Current pipeline stage label for anticipation display.
    var pipelineStageLabel: String = ""
    /// Active bounding box overlays from multimodal "Locate Region" results.
    var bboxOverlays: [NormalizedBBox] = []
    /// Source image URL for the bbox overlay (to enable crop-rerun).
    var bboxSourceImageURL: URL?

    // MARK: Public (non-observable) state

    var imagePath: String?
    var simulatorStatus: SimulatorPreviewStatus = .idle
    var artifactSubtitle: String?

    // MARK: Internal

    @ObservationIgnored private var diffAcceptHandler: ((CodeDiffSession) -> Void)?
    @ObservationIgnored private var fileLoadTask: Task<Void, Never>?
    @ObservationIgnored private var usesAutomaticContent = true
    @ObservationIgnored private static let minimumPhaseDisplayTime: TimeInterval = 0.45
    @ObservationIgnored private var phaseEnteredAt: Date = .distantPast
    @ObservationIgnored private var pendingTransitionTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// Called when the viewport needs to become visible (e.g. terminal activity started).
    /// Set by the wiring layer (CommandCenterView).
    var onRequestReveal: (() -> Void)?

    // MARK: - Phase Transitions (Core State Machine)

    func requestTransition(
        to targetPhase: ViewportPhase,
        content newContent: ViewportContent,
        title: String? = nil,
        status: String? = nil
    ) {
        if targetPhase == phase && newContent == self.content { return }

        if targetPhase == phase {
            self.content = newContent
            if let title { lockedTitle = title }
            if let status { statusLabel = status }
            return
        }

        guard ViewportTransition.find(from: phase, to: targetPhase) != nil else {
            return
        }

        let elapsed = Date().timeIntervalSince(phaseEnteredAt)
        let remaining = Self.minimumPhaseDisplayTime - elapsed

        if remaining > 0 {
            pendingTransitionTask?.cancel()
            pendingTransitionTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                self.executeTransition(to: targetPhase, content: newContent, title: title, status: status)
            }
            return
        }

        executeTransition(to: targetPhase, content: newContent, title: title, status: status)
    }

    private func executeTransition(
        to targetPhase: ViewportPhase,
        content newContent: ViewportContent,
        title: String?,
        status: String?
    ) {
        pendingTransitionTask?.cancel()
        pendingTransitionTask = nil

        let previousPhase = phase
        phase = targetPhase
        self.content = newContent
        phaseEnteredAt = Date()
        errorMessage = nil

        lockedTitle = title ?? Self.defaultTitle(for: targetPhase, content: newContent)
        statusLabel = status ?? Self.defaultStatus(for: targetPhase, previousPhase: previousPhase)
    }

    // MARK: - Title & Status Defaults

    private static func defaultTitle(for phase: ViewportPhase, content: ViewportContent) -> String {
        switch content {
        case .diffPreview:         return "Diff Preview"
        case .filePreview(let f):  return f.displayName
        case .planDocument(let p): return p.title
        case .simulatorScreenshot, .artifactImage: return "Preview"
        case .simulatorBooting:    return "Simulator"
        case .errorCard(let e):    return e.command.isEmpty ? "Build Failed" : e.command
        case .approvalGate(let a): return a.title
        case .temporalRevert(let r): return "Revert to \(r.title)"
        case .none:                break
        }
        switch phase {
        case .idle:      return "Viewport"
        case .intent:    return "Preparing"
        case .plan:      return "Plan"
        case .executing: return "Executing"
        case .preview:   return "Preview"
        case .error:     return "Error"
        }
    }

    private static func defaultStatus(for phase: ViewportPhase, previousPhase: ViewportPhase) -> String {
        switch phase {
        case .idle:      return "Idle"
        case .intent:    return "Resolving"
        case .plan:      return "Reviewing"
        case .executing: return "Running"
        case .preview:   return "Attached"
        case .error:     return "Failed"
        }
    }

    // MARK: - Transition Animation

    func transitionAnimation(to target: ViewportPhase) -> Animation {
        guard let t = ViewportTransition.find(from: phase, to: target) else {
            return StudioMotion.emphasisFade
        }
        switch t.curve {
        case .easeOut: return .easeOut(duration: t.duration)
        case .linear:  return .linear(duration: t.duration)
        case .spring:  return .spring(response: t.duration, dampingFraction: 0.86)
        }
    }

    // MARK: - Public API

    func sync(selectedEpoch _: Epoch?, previewService: SimulatorPreviewService) {
        simulatorStatus = previewService.status
        guard usesAutomaticContent else { return }

        artifactSubtitle = nil
        diffAcceptHandler = nil

        if let screenshotPath = previewService.latestScreenshotPath,
           FileManager.default.fileExists(atPath: screenshotPath) {
            imagePath = screenshotPath
            requestTransition(to: .preview, content: .simulatorScreenshot)
            return
        }

        imagePath = nil
        switch previewService.status {
        case .booting:
            requestTransition(to: .intent, content: .simulatorBooting, title: "Simulator", status: "Booting")
        case .idle:
            requestTransition(to: .idle, content: .none)
        case .attached:
            requestTransition(to: .intent, content: .simulatorBooting, title: "Simulator", status: "Attaching")
        }
    }

    func resetToAutomatic(selectedEpoch: Epoch?, previewService: SimulatorPreviewService) {
        usesAutomaticContent = true
        diffAcceptHandler = nil
        fileLoadTask?.cancel()
        sync(selectedEpoch: selectedEpoch, previewService: previewService)
    }

    func showEpochArtifact(_ epoch: Epoch?, mode: ArtifactCanvasLaunchMode) {
        usesAutomaticContent = false
        diffAcceptHandler = nil
        fileLoadTask?.cancel()

        guard let epoch else {
            requestTransition(to: .idle, content: .none)
            imagePath = nil
            artifactSubtitle = nil
            return
        }

        switch mode {
        case .codeDiff:
            imagePath = nil
            artifactSubtitle = nil
            let diffModel = ViewportDiffModel(
                title: "Code Diff",
                state: .archived(epoch.diffText),
                canApply: false
            )
            requestTransition(to: .preview, content: .diffPreview(diffModel))
        case .preview, .inspector, .deployment:
            if let screenshotPath = epoch.screenshotPath,
               FileManager.default.fileExists(atPath: screenshotPath) {
                imagePath = screenshotPath
                artifactSubtitle = "Showing artifact screenshot for epoch \(epoch.index)"
                requestTransition(to: .preview, content: .artifactImage(path: screenshotPath))
            } else {
                imagePath = nil
                artifactSubtitle = "No artifact screenshot found for epoch \(epoch.index)"
                requestTransition(to: .idle, content: .none)
            }
        }
    }

    func showDiffPreview(_ model: ViewportDiffModel, onAccept: ((CodeDiffSession) -> Void)? = nil) {
        usesAutomaticContent = false
        fileLoadTask?.cancel()
        diffAcceptHandler = onAccept
        artifactSubtitle = nil
        imagePath = nil
        requestTransition(to: .preview, content: .diffPreview(model))
    }

    func applyCurrentDiff() {
        guard case .diffPreview(let model) = content,
              model.canApply,
              case .ready(let session) = model.state else { return }
        diffAcceptHandler?(session)
    }

    func showFilePreview(path: String, sourceLabel: String = "File preview") {
        usesAutomaticContent = false
        diffAcceptHandler = nil
        fileLoadTask?.cancel()
        artifactSubtitle = nil
        imagePath = nil

        let url = URL(fileURLWithPath: path)
        let language = url.pathExtension.isEmpty ? nil : url.pathExtension

        let loadingModel = ViewportFileModel(
            path: path,
            displayName: url.lastPathComponent,
            language: language,
            sourceLabel: sourceLabel,
            state: .loading
        )
        requestTransition(
            to: .intent,
            content: .filePreview(loadingModel),
            title: url.lastPathComponent,
            status: "Loading"
        )

        fileLoadTask = Task {
            let state: ViewportFileState = await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: path) else {
                    return .failed("The selected file no longer exists at \(path).")
                }
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return .failed("Studio.92 couldn't load this file as UTF-8 text.")
                }
                return .ready(content)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let resolvedModel = ViewportFileModel(
                    path: path,
                    displayName: url.lastPathComponent,
                    language: language,
                    sourceLabel: sourceLabel,
                    state: state
                )
                switch state {
                case .ready:
                    self.requestTransition(to: .preview, content: .filePreview(resolvedModel))
                case .failed(let msg):
                    self.errorMessage = msg
                    self.requestTransition(
                        to: .error,
                        content: .filePreview(resolvedModel),
                        title: url.lastPathComponent,
                        status: "Failed"
                    )
                case .loading:
                    break
                }
            }
        }
    }

    func showPlanDocument(_ plan: ViewportPlanModel) {
        usesAutomaticContent = false
        diffAcceptHandler = nil
        fileLoadTask?.cancel()
        artifactSubtitle = nil
        imagePath = nil
        requestTransition(to: .plan, content: .planDocument(plan))
    }

    func showError(message: String) {
        errorMessage = message
        requestTransition(to: .error, content: .none, title: "Error", status: "Failed")
    }

    func showErrorCard(_ errorModel: ViewportBuildErrorModel) {
        usesAutomaticContent = false
        diffAcceptHandler = nil
        fileLoadTask?.cancel()
        artifactSubtitle = nil
        imagePath = nil
        requestTransition(to: .error, content: .errorCard(errorModel), title: nil, status: "Failed")
    }

    func showApprovalGate(_ approvalModel: ViewportApprovalModel) {
        usesAutomaticContent = false
        diffAcceptHandler = nil
        fileLoadTask?.cancel()
        artifactSubtitle = nil
        imagePath = nil
        requestTransition(to: .intent, content: .approvalGate(approvalModel), title: approvalModel.title, status: "Waiting")
    }

    func dismissApprovalGate() {
        guard case .approvalGate = content else { return }
        usesAutomaticContent = false
        requestTransition(to: .idle, content: .none, title: "Viewport", status: "Idle")
    }

    func showTemporalRevert(_ model: TemporalRevertModel) {
        usesAutomaticContent = false
        diffAcceptHandler = nil
        fileLoadTask?.cancel()
        imagePath = nil
        requestTransition(to: .preview, content: .temporalRevert(model), title: "Revert to \(model.title)", status: "Reviewing")
    }

    func updateTemporalRevertState(isReverting: Bool) {
        guard case .temporalRevert(var m) = content else { return }
        m.isReverting = isReverting
        content = .temporalRevert(m)
    }

    func dismissTemporalRevert() {
        guard case .temporalRevert = content else { return }
        requestTransition(to: .idle, content: .none, title: "Viewport", status: "Idle")
    }

    // MARK: - Process Layer (Terminal)
    //
    // The terminal is a process running inside the machine.
    // It does not "appear" — it is revealed. The debounce ensures
    // it never flashes for instant commands. The dismiss fade is
    // long enough that it feels like the process completed and
    // the surface settled, not like a panel was closed.

    func showTerminalActivity(_ terminal: ViewportTerminalModel) {
        processLayer.terminal = terminal
        // Terminal activity is shown inline in the execution pane.
        // Don't auto-open the viewport just for terminal output.
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            // 280ms: long enough that instant-completion commands
            // never flash the terminal at all.
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            if self.processLayer.terminal != nil {
                self.processLayer.isRevealed = true
            }
        }
    }

    func updateTerminalActivity(_ terminal: ViewportTerminalModel) {
        processLayer.terminal = terminal
    }

    func dismissTerminalActivity() {
        debounceTask?.cancel()
        debounceTask = nil
        processLayer.isRevealed = false
        // 400ms: the terminal settles away. Not snapped closed.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !self.processLayer.isRevealed else { return }
            self.processLayer.terminal = nil
        }
        if phase == .executing {
            requestTransition(to: .idle, content: .none)
        }
    }

    // MARK: - BBox Overlay Support

    func showBBoxOverlays(_ boxes: [NormalizedBBox], sourceImageURL: URL?) {
        bboxOverlays = boxes.filter(\.isValid)
        bboxSourceImageURL = sourceImageURL
        if let imagePath = sourceImageURL?.path {
            requestTransition(to: .preview, content: .artifactImage(path: imagePath))
        }
    }

    func clearBBoxOverlays() {
        bboxOverlays = []
        bboxSourceImageURL = nil
    }

    var activeTerminalModel: ViewportTerminalModel? {
        get { processLayer.terminal }
        set {
            if let newValue { showTerminalActivity(newValue) }
            else { dismissTerminalActivity() }
        }
    }
}
