import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class RepositoryMonitor {

    var workspaceURL: URL
    var repositoryState: GitRepositoryState
    var isRefreshing = false

    @ObservationIgnored private let gitService = GitService()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceWatcher: PathEventMonitor?
    @ObservationIgnored private var gitWatcher: PathEventMonitor?
    @ObservationIgnored private var gitCommonWatcher: PathEventMonitor?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []

    init(workspaceURL: URL) {
        let normalizedWorkspace = workspaceURL.standardizedFileURL
        self.workspaceURL = normalizedWorkspace
        self.repositoryState = .loading(workspaceURL: normalizedWorkspace)
    }

    func start() {
        installLifecycleObserversIfNeeded()
        startPollingIfNeeded()
        scheduleRefresh(immediate: true)
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        pollTask?.cancel()
        pollTask = nil
        teardownWatchers()
        removeLifecycleObservers()
    }

    func updateWorkspace(_ newWorkspaceURL: URL) {
        workspaceURL = newWorkspaceURL.standardizedFileURL
        repositoryState = .loading(workspaceURL: workspaceURL)
        teardownWatchers()
        scheduleRefresh(immediate: true)
    }

    func refreshNow() {
        scheduleRefresh(immediate: true)
    }

    func initializeRepository() {
        refreshTask?.cancel()
        refreshTask = Task { [workspaceURL, gitService] in
            await MainActor.run {
                self.isRefreshing = true
            }

            let refreshedState = await gitService.initializeRepository(at: workspaceURL)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.isRefreshing = false
                self.apply(refreshedState)
            }
        }
    }

    private func scheduleRefresh(immediate: Bool) {
        refreshTask?.cancel()
        refreshTask = Task { [workspaceURL, gitService] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.isRefreshing = true
            }

            let refreshedState = await gitService.repositoryState(for: workspaceURL)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.isRefreshing = false
                self.apply(refreshedState)
            }
        }
    }

    private func apply(_ state: GitRepositoryState) {
        repositoryState = state
        configureWatchers(for: state)
    }

    private func configureWatchers(for state: GitRepositoryState) {
        let workspacePath = workspaceURL.path
        let gitPath = state.gitDirectoryPath
        let gitCommonPath = state.gitCommonDirectoryPath

        if workspaceWatcher == nil || workspaceWatcherPath != workspacePath {
            workspaceWatcher?.stop()
            workspaceWatcher = PathEventMonitor(
                path: workspacePath,
                label: "com.studio92.git.workspace"
            ) { [weak self] paths in
                Task { @MainActor in
                    self?.handleWorkspaceEvents(paths)
                }
            }
            workspaceWatcher?.start()
            workspaceWatcherPath = workspacePath
        }

        if let gitPath {
            if gitWatcher == nil || gitWatcherPath != gitPath {
                gitWatcher?.stop()
                gitWatcher = PathEventMonitor(
                    path: gitPath,
                    label: "com.studio92.git.metadata"
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleRefresh(immediate: false)
                    }
                }
                gitWatcher?.start()
                gitWatcherPath = gitPath
            }
        } else {
            gitWatcher?.stop()
            gitWatcher = nil
            gitWatcherPath = nil
        }

        if let gitCommonPath, gitCommonPath != gitPath {
            if gitCommonWatcher == nil || gitCommonWatcherPath != gitCommonPath {
                gitCommonWatcher?.stop()
                gitCommonWatcher = PathEventMonitor(
                    path: gitCommonPath,
                    label: "com.studio92.git.common"
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleRefresh(immediate: false)
                    }
                }
                gitCommonWatcher?.start()
                gitCommonWatcherPath = gitCommonPath
            }
        } else {
            gitCommonWatcher?.stop()
            gitCommonWatcher = nil
            gitCommonWatcherPath = nil
        }
    }

    @ObservationIgnored private var workspaceWatcherPath: String?
    @ObservationIgnored private var gitWatcherPath: String?
    @ObservationIgnored private var gitCommonWatcherPath: String?

    private func handleWorkspaceEvents(_ paths: [String]) {
        guard !paths.isEmpty else { return }

        if repositoryState.phase != .ready {
            scheduleRefresh(immediate: false)
            return
        }

        let ignoredFragments = [
            "/.git/",
            "/.studio92/sessions/",
            "/.studio92/worktrees/",
            "/.build/",
            "/DerivedData/",
            "/build/",
            "/dist/",
            "/node_modules/"
        ]

        let shouldRefresh = paths.contains { rawPath in
            let normalized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            return !ignoredFragments.contains(where: normalized.contains)
        }

        guard shouldRefresh else { return }
        scheduleRefresh(immediate: false)
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = await MainActor.run { self?.currentPollInterval ?? 30 }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.scheduleRefresh(immediate: true)
                }
            }
        }
    }

    private var currentPollInterval: Int {
        if NSApplication.shared.isActive {
            return 15
        }
        if NSApplication.shared.isHidden {
            return 60
        }
        return 30
    }

    private func installLifecycleObserversIfNeeded() {
        guard notificationTokens.isEmpty else { return }

        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(immediate: true)
                }
            }
        )

        notificationTokens.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(immediate: true)
                }
            }
        )
    }

    private func removeLifecycleObservers() {
        notificationTokens.forEach { token in
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll(keepingCapacity: false)
    }

    private func teardownWatchers() {
        workspaceWatcher?.stop()
        gitWatcher?.stop()
        gitCommonWatcher?.stop()
        workspaceWatcher = nil
        gitWatcher = nil
        gitCommonWatcher = nil
        workspaceWatcherPath = nil
        gitWatcherPath = nil
        gitCommonWatcherPath = nil
    }

    deinit {
        refreshTask?.cancel()
        pollTask?.cancel()
        workspaceWatcher?.stop()
        gitWatcher?.stop()
        gitCommonWatcher?.stop()
        notificationTokens.forEach { token in
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}
