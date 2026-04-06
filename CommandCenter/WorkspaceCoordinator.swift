// WorkspaceCoordinator.swift
// Studio.92 — Command Center
// Owns engine, project/epoch selection, runner, repository monitor, and workspace operations.

import SwiftUI
import SwiftData
import AppKit

@Observable @MainActor
final class WorkspaceCoordinator {

    // MARK: - Owned State

    var engine = LiveStateEngine()
    var selectedProjectID: UUID?
    var selectedEpochID: UUID?
    var recentWorkspacePaths: [String] = []

    // MARK: - Shared References

    let runner: PipelineRunner
    let repositoryMonitor: RepositoryMonitor

    // MARK: - Cross-coordinator & View References (set via configure)

    weak var threads: ThreadCoordinator?
    private(set) var viewportModel: ViewportStreamModel?
    private(set) var simulatorPreviewService: SimulatorPreviewService?
    private(set) var templateEngine: SessionTemplateEngine?

    private static let recentWorkspacesDefaultsKey = "recentWorkspacePaths"

    init(runner: PipelineRunner, repositoryMonitor: RepositoryMonitor) {
        self.runner = runner
        self.repositoryMonitor = repositoryMonitor
    }

    func configure(
        viewportModel: ViewportStreamModel,
        previewService: SimulatorPreviewService,
        templateEngine: SessionTemplateEngine
    ) {
        self.viewportModel = viewportModel
        self.simulatorPreviewService = previewService
        self.templateEngine = templateEngine
    }

    // MARK: - Computed Properties

    var selectedProject: AppProject? {
        guard let id = selectedProjectID else { return nil }
        return engine.project(for: id)
    }

    var selectedEpoch: Epoch? {
        guard let selectedProjectID, let selectedEpochID else { return nil }
        return engine.epoch(for: selectedEpochID, in: selectedProjectID)
    }

    var sortedProjects: [AppProject] {
        engine.projects.sorted { $0.confidenceScore > $1.confidenceScore }
    }

    // MARK: - Project Selection

    func selectProject(_ projectID: UUID) {
        threads?.selectedSessionID = nil
        selectedProjectID = projectID
        if let simulatorPreviewService {
            viewportModel?.resetToAutomatic(selectedEpoch: selectedEpoch, previewService: simulatorPreviewService)
        }
        threads?.rehydrateThread(forProject: projectID)
    }

    func deleteProject(_ projectID: UUID, modelContext: ModelContext) {
        guard let project = engine.project(for: projectID) else { return }
        if selectedProjectID == projectID {
            selectedProjectID = nil
            threads?.conversationStore.reset()
            runner.reset()
        }
        modelContext.delete(project)
        modelContext.saveWithLogging()
        engine.load(from: modelContext)
        threads?.refreshSidebarThreads()
    }

    // MARK: - Workspace Selection

    func openWorkspacePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open Workspace"
        panel.message = "Choose the workspace folder Studio.92 should operate on."
        panel.directoryURL = URL(fileURLWithPath: runner.packageRoot, isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            await selectWorkspace(url)
        }
    }

    func selectWorkspace(_ url: URL) async {
        let normalizedURL = url.standardizedFileURL
        UserDefaults.standard.set(normalizedURL.path, forKey: "packageRoot")
        rememberWorkspace(path: normalizedURL.path)
        await runner.updatePackageRoot(normalizedURL.path)
        repositoryMonitor.updateWorkspace(normalizedURL)
        threads?.jobMonitor.updateWorkspace(normalizedURL)
        templateEngine?.updateWorkspace(normalizedURL.path)
        threads?.goalText = ""
        threads?.composerAttachments = []
        selectedProjectID = nil
        selectedEpochID = nil
        threads?.selectedSessionID = nil
        threads?.conversationStore.reset()
        if let simulatorPreviewService {
            viewportModel?.resetToAutomatic(selectedEpoch: selectedEpoch, previewService: simulatorPreviewService)
        }
    }

    func reopenWorkspace(path: String) {
        let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: normalizedPath) else {
            openWorkspacePanel()
            return
        }
        Task { @MainActor in
            await selectWorkspace(URL(fileURLWithPath: normalizedPath, isDirectory: true))
        }
    }

    // MARK: - Recent Workspaces

    func loadRecentWorkspaces() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.recentWorkspacesDefaultsKey) ?? []
        recentWorkspacePaths = normalizedRecentWorkspaces(from: [repositoryMonitor.workspaceURL.path] + stored)
    }

    func rememberWorkspace(path: String) {
        let updated = normalizedRecentWorkspaces(from: [path] + recentWorkspacePaths)
        recentWorkspacePaths = updated
        UserDefaults.standard.set(updated, forKey: Self.recentWorkspacesDefaultsKey)
    }

    private func normalizedRecentWorkspaces(from rawPaths: [String]) -> [String] {
        var seen = Set<String>()
        return rawPaths.compactMap { rawPath in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { return nil }
            guard FileManager.default.fileExists(atPath: normalized) else { return nil }
            return normalized
        }
    }

    // MARK: - Repository Operations

    func refreshRepositoryStatus() {
        repositoryMonitor.refreshNow()
    }

    func initializeGitRepository() {
        repositoryMonitor.initializeRepository()
    }
}
