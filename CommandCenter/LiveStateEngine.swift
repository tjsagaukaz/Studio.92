// LiveStateEngine.swift
// CommandCenter
//
// In-memory cache that drives the UI from SwiftData.

import Foundation
import SwiftData
import Observation

// MARK: - LiveStateEngine

/// In-memory cache that drives the UI.
/// Fetches from SwiftData on load and on pipeline events.
/// The UI reads from this — never from @Query directly.
@Observable
final class LiveStateEngine {

    /// The current set of active projects. Sorted in the View layer, not here.
    var projects: [AppProject] = []

    /// Load all projects from the SwiftData store.
    func load(from context: ModelContext) {
        let descriptor = FetchDescriptor<AppProject>(
            sortBy: [SortDescriptor(\.lastActivityAt, order: .reverse)]
        )
        do {
            projects = try context.fetch(descriptor)
        } catch {
            projects = []
        }
    }

    /// Find a project by ID.
    func project(for id: UUID) -> AppProject? {
        projects.first { $0.id == id }
    }

    /// Find an epoch by ID within a project.
    func epoch(for epochID: UUID, in projectID: UUID) -> Epoch? {
        project(for: projectID)?.sortedEpochs.first { $0.id == epochID }
    }

    /// Ingest a pipeline result into SwiftData.
    /// Returns the project ID on success, or an error string on failure.
    @discardableResult
    func ingestPipelineResult(
        goal: String,
        displayGoal: String? = nil,
        packet: PacketSummary,
        context: ModelContext
    ) -> Result<UUID, PipelineError> {
        // Validate
        if let err = packet.validate() {
            return .failure(PipelineError(message: err))
        }

        let packetID = packet.packetID
        let duplicateDescriptor = FetchDescriptor<Epoch>(
            predicate: #Predicate { $0.packetID == packetID }
        )
        if let existingEpoch = try? context.fetch(duplicateDescriptor).first,
           let projectID = existingEpoch.project?.id {
            load(from: context)
            return .success(projectID)
        }

        // Find existing project by goal or create new
        let project: AppProject
        if let existing = projects.first(where: { $0.goal == goal }) {
            project = existing
        } else {
            let name = goal.prefix(40).trimmingCharacters(in: .whitespaces)
            project = AppProject(name: String(name), goal: goal)
            context.insert(project)
        }
        project.displayGoal = displayGoal ?? project.displayGoal ?? goal

        // Create epoch
        let epochIndex = project.sortedEpochs.count
        let epoch = Epoch(
            index: epochIndex,
            summary: packet.payload.rationale,
            archetype: packet.payload.archetypeClassification?.dominant,
            higScore: packet.metrics.higComplianceScore,
            deviationCost: packet.metrics.deviationBudgetCost,
            targetFile: packet.payload.targetFile,
            isNewFile: packet.payload.isNewFile,
            packetID: packet.packetID,
            diffText: packet.payload.diffText,
            componentsBuilt: max(packet.payload.affectedTypes.count, packet.payload.diffText == nil ? 0 : 1)
        )
        epoch.screenshotPath = PipelineRunner.resolveScreenshotPath(for: packet.packetID)
        epoch.project = project
        context.insert(epoch)
        project.epochs.append(epoch)

        // Update project metrics
        project.dominantArchetype = packet.payload.archetypeClassification?.dominant
        project.confidenceScore = Int(packet.metrics.higComplianceScore * 100)
        project.deviationBudgetRemaining = max(0, project.deviationBudgetRemaining - packet.metrics.deviationBudgetCost)
        project.latestCriticVerdict = "Critic approved — \(Int((packet.metrics.higComplianceScore * 100).rounded()))% HIG alignment."
        project.lastActivityAt = Date()

        do {
            try context.save()
        } catch {
            return .failure(PipelineError(message: "Failed to save: \(error.localizedDescription)"))
        }

        load(from: context)
        return .success(project.id)
    }
}
