// DeploymentCoordinator.swift
// Studio.92 — CommandCenter
// Owns deployment lifecycle state and mutations for TestFlight/Fastlane tool executions.

import Foundation
import Observation

@MainActor
@Observable
final class DeploymentCoordinator {

    var state = DeploymentState()

    func reset() {
        state = DeploymentState()
    }

    func begin(toolCallID: String, packageRoot: String) {
        state = DeploymentState(
            phase: .running,
            toolCallID: toolCallID,
            lane: "beta",
            command: nil,
            targetDirectory: packageRoot,
            lines: [],
            startedAt: Date(),
            finishedAt: nil,
            summary: "Preparing TestFlight deployment"
        )
    }

    func updateCommand(toolCallID: String, command: String) {
        guard state.toolCallID == toolCallID else { return }
        var updated = state
        updated.command = command
        updated.summary = command
        state = updated
    }

    func appendLine(toolCallID: String, line: String, maxLines: Int = 500) {
        guard state.toolCallID == toolCallID else { return }
        var updated = state
        updated.lines.append(line)
        if updated.lines.count > maxLines {
            updated.lines.removeFirst(updated.lines.count - maxLines)
        }
        state = updated
    }

    func complete(toolCallID: String, result: String, isError: Bool) {
        guard state.toolCallID == toolCallID else { return }
        var updated = state
        updated.phase = isError ? .failed : .completed
        updated.finishedAt = Date()
        updated.summary = isError ? "TestFlight deployment failed" : "TestFlight deployment complete"
        if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = result
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty {
                updated.lines = Array((updated.lines + lines).suffix(500))
            }
        }
        state = updated
    }
}
