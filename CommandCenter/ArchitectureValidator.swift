import Foundation

enum ArchitectureViolationKind: String, Codable, Sendable {
    case multipleActiveRuns
    case eventOutOfOrder
    case missingTerminalEvent
    case toolUnpaired
    case compactionDuringExecution
    case illegalViewportMutation
    case spanNotClosed
    case secondTimelineDetected
}

struct ArchitectureViolation: Identifiable, Codable, Sendable, Equatable {
    enum Severity: String, Codable, Sendable {
        case warning
        case error
        case critical
    }

    let id: UUID
    let timestamp: Date
    let runID: UUID
    let kind: ArchitectureViolationKind
    let message: String
    let severity: Severity
}

enum ArchitectureRuntimeEventKind: Sendable {
    case observed
    case beginRun(runID: UUID)
    case toolStarted(id: String)
    case toolCompleted(id: String)
    case compactionStarted
    case compactionCompleted
    case compactionFailed
    case completed
    case failed(String)
    case cancelled
    case traceSnapshot(openSpanCount: Int)
}

struct ArchitectureRuntimeEvent: Sendable {
    let timestamp: Date
    let kind: ArchitectureRuntimeEventKind

    init(
        timestamp: Date = Date(),
        kind: ArchitectureRuntimeEventKind
    ) {
        self.timestamp = timestamp
        self.kind = kind
    }
}

actor ArchitectureValidator {

    struct RunState: Sendable {
        var runID: UUID
        var isRunning = false
        var openToolCalls: Set<String> = []
        var hasTerminalEvent = false
        var lastEventTimestamp: Date?
        var isCompacting = false
    }

    private var currentRun: RunState?
    private var recentViolations: [ArchitectureViolation] = []
    private let maxStoredViolations = 50

    func ingest(_ event: ArchitectureRuntimeEvent) -> [ArchitectureViolation] {
        var violations: [ArchitectureViolation] = []

        if case let .beginRun(runID) = event.kind {
            violations.append(contentsOf: handleBeginRun(runID: runID, timestamp: event.timestamp))
        }

        violations.append(contentsOf: validateOrdering(event))

        switch event.kind {
        case .observed, .beginRun:
            break
        case .toolStarted(let id):
            violations.append(contentsOf: handleToolStarted(id: id))
        case .toolCompleted(let id):
            violations.append(contentsOf: handleToolCompleted(id: id))
        case .compactionStarted:
            violations.append(contentsOf: handleCompactionStarted())
        case .compactionCompleted, .compactionFailed:
            handleCompactionFinished()
        case .completed, .failed, .cancelled:
            violations.append(contentsOf: handleTerminalEvent())
        case .traceSnapshot(let openSpanCount):
            violations.append(contentsOf: handleTraceSnapshot(openSpanCount: openSpanCount))
        }

        if !violations.isEmpty {
            recentViolations.append(contentsOf: violations)
            if recentViolations.count > maxStoredViolations {
                recentViolations.removeFirst(recentViolations.count - maxStoredViolations)
            }
        }

        return violations
    }

    func violationsSnapshot() -> [ArchitectureViolation] {
        recentViolations
    }

    private func handleBeginRun(runID: UUID, timestamp: Date) -> [ArchitectureViolation] {
        var violations: [ArchitectureViolation] = []

        if let existing = currentRun {
            if existing.isRunning {
                violations.append(
                    makeViolation(
                        runID: runID,
                        kind: .multipleActiveRuns,
                        message: "A new run started while another run was still active.",
                        severity: .critical
                    )
                )
            }
            if !existing.hasTerminalEvent {
                violations.append(
                    makeViolation(
                        runID: existing.runID,
                        kind: .missingTerminalEvent,
                        message: "The previous run was replaced before a terminal event was recorded.",
                        severity: .error
                    )
                )
            }
        }

        currentRun = RunState(
            runID: runID,
            isRunning: true,
            lastEventTimestamp: timestamp
        )
        return violations
    }

    private func validateOrdering(_ event: ArchitectureRuntimeEvent) -> [ArchitectureViolation] {
        guard var run = currentRun else { return [] }
        defer {
            run.lastEventTimestamp = event.timestamp
            currentRun = run
        }

        guard let lastEventTimestamp = run.lastEventTimestamp else { return [] }
        guard event.timestamp < lastEventTimestamp else { return [] }

        return [
            makeViolation(
                runID: run.runID,
                kind: .eventOutOfOrder,
                message: "A runtime event arrived with a timestamp earlier than the prior event.",
                severity: .error
            )
        ]
    }

    private func handleToolStarted(id: String) -> [ArchitectureViolation] {
        guard var run = currentRun else { return [] }
        run.openToolCalls.insert(id)
        currentRun = run
        return []
    }

    private func handleToolCompleted(id: String) -> [ArchitectureViolation] {
        guard var run = currentRun else { return [] }
        let removed = run.openToolCalls.remove(id)
        currentRun = run

        guard removed != nil else {
            return [
                makeViolation(
                    runID: run.runID,
                    kind: .toolUnpaired,
                    message: "A tool completed without a matching tool start for ID \(id).",
                    severity: .error
                )
            ]
        }

        return []
    }

    private func handleCompactionStarted() -> [ArchitectureViolation] {
        guard var run = currentRun else {
            return [
                makeViolation(
                    runID: UUID(),
                    kind: .secondTimelineDetected,
                    message: "Compaction started without an active recorded run state.",
                    severity: .error
                )
            ]
        }

        var violations: [ArchitectureViolation] = []
        if run.isRunning {
            violations.append(
                makeViolation(
                    runID: run.runID,
                    kind: .compactionDuringExecution,
                    message: "Compaction began before the active execution fully terminated.",
                    severity: .critical
                )
            )
        }
        run.isCompacting = true
        currentRun = run
        return violations
    }

    private func handleCompactionFinished() {
        guard var run = currentRun else { return }
        run.isCompacting = false
        currentRun = run
    }

    private func handleTerminalEvent() -> [ArchitectureViolation] {
        guard var run = currentRun else { return [] }

        var violations: [ArchitectureViolation] = []
        if !run.openToolCalls.isEmpty {
            let dangling = run.openToolCalls.sorted().joined(separator: ", ")
            violations.append(
                makeViolation(
                    runID: run.runID,
                    kind: .toolUnpaired,
                    message: "The run ended with open tool calls: \(dangling).",
                    severity: .error
                )
            )
        }

        run.hasTerminalEvent = true
        run.isRunning = false
        currentRun = run
        return violations
    }

    private func handleTraceSnapshot(openSpanCount: Int) -> [ArchitectureViolation] {
        guard let run = currentRun, openSpanCount > 0 else { return [] }
        return [
            makeViolation(
                runID: run.runID,
                kind: .spanNotClosed,
                message: "The run finished with \(openSpanCount) unclosed trace spans.",
                severity: .error
            )
        ]
    }

    private func makeViolation(
        runID: UUID,
        kind: ArchitectureViolationKind,
        message: String,
        severity: ArchitectureViolation.Severity
    ) -> ArchitectureViolation {
        ArchitectureViolation(
            id: UUID(),
            timestamp: Date(),
            runID: runID,
            kind: kind,
            message: message,
            severity: severity
        )
    }
}