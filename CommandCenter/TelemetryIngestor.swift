// TelemetryIngestor.swift
// Studio.92 — Command Center
// Decodes telemetry JSON files and ingests them into SwiftData on a background context.
// Notifies LiveStateEngine on the MainActor when new data is available.

import Foundation
import SwiftData

/// Telemetry packet format dropped by run_factory.sh into ~/.darkfactory/telemetry/.
/// This is the full packet with project context — richer than PacketSummary
/// because the CLI has access to the goal and project name.
struct TelemetryPacket: Codable {

    /// The original goal string.
    var goal: String

    /// User-facing goal text without appended file reference context.
    var displayGoal: String?

    /// Human-readable project name (derived from goal if not set).
    var projectName: String?

    /// The core packet fields (same as PacketSummary).
    var packetID: UUID
    var sender: String
    var intent: String
    var scope: String
    var payload: Payload
    var metrics: Metrics

    /// Optional drift snapshot at time of merge.
    var driftScore: Double?
    var driftMode: String?

    /// File path to the Simulator screenshot for this epoch.
    var screenshotPath: String?

    struct Payload: Codable {
        struct ASTDelta: Codable {
            var delta: String
            var targetFile: String
            var isNewFile: Bool
            var affectedTypes: [String]?
        }

        var rationale: String
        var targetFile: String
        var isNewFile: Bool
        var diffText: String?
        var affectedTypes: [String]
        var archetypeClassification: ArchetypeInfo?

        struct ArchetypeInfo: Codable {
            var dominant: String
            var confidence: Double
        }

        enum CodingKeys: String, CodingKey {
            case rationale
            case targetFile
            case isNewFile
            case diffText
            case affectedTypes
            case archetypeClassification
            case astDelta
        }

        init(
            rationale: String,
            targetFile: String,
            isNewFile: Bool,
            diffText: String? = nil,
            affectedTypes: [String] = [],
            archetypeClassification: ArchetypeInfo? = nil
        ) {
            self.rationale = rationale
            self.targetFile = targetFile
            self.isNewFile = isNewFile
            self.diffText = diffText
            self.affectedTypes = affectedTypes
            self.archetypeClassification = archetypeClassification
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
            archetypeClassification = try container.decodeIfPresent(ArchetypeInfo.self, forKey: .archetypeClassification)

            let delta = try container.decodeIfPresent(ASTDelta.self, forKey: .astDelta)
            targetFile = try container.decodeIfPresent(String.self, forKey: .targetFile)
                ?? delta?.targetFile
                ?? ""
            isNewFile = try container.decodeIfPresent(Bool.self, forKey: .isNewFile)
                ?? delta?.isNewFile
                ?? false
            diffText = try container.decodeIfPresent(String.self, forKey: .diffText)
                ?? delta?.delta
            affectedTypes = try container.decodeIfPresent([String].self, forKey: .affectedTypes)
                ?? delta?.affectedTypes
                ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rationale, forKey: .rationale)
            try container.encode(targetFile, forKey: .targetFile)
            try container.encode(isNewFile, forKey: .isNewFile)
            try container.encodeIfPresent(diffText, forKey: .diffText)
            if !affectedTypes.isEmpty {
                try container.encode(affectedTypes, forKey: .affectedTypes)
            }
            try container.encodeIfPresent(archetypeClassification, forKey: .archetypeClassification)
        }
    }

    struct Metrics: Codable {
        var higComplianceScore: Double
        var deviationBudgetCost: Double
    }

    /// Validate before ingestion.
    func validate() -> String? {
        if payload.targetFile.isEmpty { return "Missing targetFile" }
        guard (0...1).contains(metrics.higComplianceScore) else { return "higComplianceScore out of range" }
        guard (0...1).contains(metrics.deviationBudgetCost) else { return "deviationBudgetCost out of range" }
        return nil
    }
}

/// Handles background SwiftData ingestion from telemetry files.
/// Uses a background ModelContext — never touches the main context directly.
final class TelemetryIngestor {

    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Ingest

    /// Parse a telemetry JSON file and ingest into SwiftData.
    /// Returns the project ID on success.
    /// This runs entirely on a background context — safe to call from any queue.
    func ingest(fileURL: URL) async -> UUID? {
        // 1. Read and decode
        guard let data = try? Data(contentsOf: fileURL) else {
            print("[TelemetryIngestor] Failed to read: \(fileURL.lastPathComponent)")
            return nil
        }

        var packet: TelemetryPacket
        do {
            packet = try JSONDecoder().decode(TelemetryPacket.self, from: data)
        } catch {
            print("[TelemetryIngestor] Failed to decode \(fileURL.lastPathComponent): \(error)")
            return nil
        }

        // 2. Validate
        if let validationError = packet.validate() {
            print("[TelemetryIngestor] Invalid packet \(fileURL.lastPathComponent): \(validationError)")
            return nil
        }

        // 3. Discover companion screenshot (.png with same basename)
        //    Set path to the ARCHIVED location (where it will be after archiving)
        let screenshotURL = fileURL.deletingPathExtension().appendingPathExtension("png")
        if FileManager.default.fileExists(atPath: screenshotURL.path) {
            let processedDir = fileURL.deletingLastPathComponent()
                .appendingPathComponent("processed", isDirectory: true)
            let archivedPath = processedDir.appendingPathComponent(screenshotURL.lastPathComponent).path
            packet.screenshotPath = archivedPath
            print("[TelemetryIngestor] Found companion screenshot: \(screenshotURL.lastPathComponent)")
        }

        // 4. Ingest on background context (persists Epoch with correct archived path)
        let projectID = await ingestOnBackground(packet: packet)

        // 5. Archive the file (move to processed/) — AFTER persistence
        archiveFile(fileURL)

        return projectID
    }

    // MARK: - Background SwiftData

    @ModelActor
    actor BackgroundIngestor {

        /// Ingest a telemetry packet into SwiftData.
        /// Returns the project UUID on success.
        func ingest(packet: TelemetryPacket) -> UUID? {
            // Check for duplicate packetID
            let targetID = packet.packetID
            let epochDescriptor = FetchDescriptor<Epoch>(
                predicate: #Predicate { $0.packetID == targetID }
            )
            if let existing = try? modelContext.fetch(epochDescriptor), !existing.isEmpty {
                print("[TelemetryIngestor] Duplicate packetID: \(packet.packetID) — skipping")
                return nil
            }

            // Find or create project
            let goal = packet.goal
            let projectDescriptor = FetchDescriptor<AppProject>(
                predicate: #Predicate { $0.goal == goal }
            )

            let project: AppProject
            if let existing = try? modelContext.fetch(projectDescriptor).first {
                project = existing
            } else {
                let name = packet.projectName ?? String(packet.goal.prefix(40)).trimmingCharacters(in: .whitespaces)
                project = AppProject(name: name, goal: packet.goal)
                modelContext.insert(project)
            }
            project.displayGoal = packet.displayGoal ?? project.displayGoal ?? packet.goal

            // Create epoch
            let epochIndex = project.epochs.count
            let epoch = Epoch(
                index: epochIndex,
                summary: packet.payload.rationale,
                archetype: packet.payload.archetypeClassification?.dominant,
                higScore: packet.metrics.higComplianceScore,
                deviationCost: packet.metrics.deviationBudgetCost,
                driftScore: packet.driftScore ?? 0.0,
                targetFile: packet.payload.targetFile,
                isNewFile: packet.payload.isNewFile,
                packetID: packet.packetID,
                diffText: packet.payload.diffText,
                componentsBuilt: max(packet.payload.affectedTypes.count, packet.payload.diffText == nil ? 0 : 1)
            )
            epoch.screenshotPath = packet.screenshotPath
            epoch.project = project
            modelContext.insert(epoch)
            project.epochs.append(epoch)

            // Update project metrics
            project.dominantArchetype = packet.payload.archetypeClassification?.dominant
            project.confidenceScore = Int(packet.metrics.higComplianceScore * 100)
            project.deviationBudgetRemaining = max(0, project.deviationBudgetRemaining - packet.metrics.deviationBudgetCost)
            project.latestCriticVerdict = "Critic approved — \(Int((packet.metrics.higComplianceScore * 100).rounded()))% HIG alignment."
            project.lastActivityAt = Date()

            do {
                try modelContext.save()
                return project.id
            } catch {
                print("[TelemetryIngestor] Failed to save: \(error)")
                return nil
            }
        }
    }

    private func ingestOnBackground(packet: TelemetryPacket) async -> UUID? {
        let actor = BackgroundIngestor(modelContainer: container)
        return await actor.ingest(packet: packet)
    }

    // MARK: - Archive

    private func archiveFile(_ url: URL) {
        let processedDir = url.deletingLastPathComponent().appendingPathComponent("processed", isDirectory: true)
        let fm = FileManager.default

        if !fm.fileExists(atPath: processedDir.path) {
            try? fm.createDirectory(at: processedDir, withIntermediateDirectories: true)
        }

        // Archive the JSON file
        let dest = processedDir.appendingPathComponent(url.lastPathComponent)
        try? fm.moveItem(at: url, to: dest)

        // Also archive companion screenshot if it exists
        let screenshotURL = url.deletingPathExtension().appendingPathExtension("png")
        if fm.fileExists(atPath: screenshotURL.path) {
            let screenshotDest = processedDir.appendingPathComponent(screenshotURL.lastPathComponent)
            try? fm.moveItem(at: screenshotURL, to: screenshotDest)
        }
    }
}
