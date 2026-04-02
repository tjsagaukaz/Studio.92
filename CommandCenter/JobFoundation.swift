import Foundation
import Observation

enum AgentSessionStatus: String, Codable, CaseIterable, Equatable {
    case queued
    case preparing
    case running
    case reviewing
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued:
            return "Queued"
        case .preparing:
            return "Preparing"
        case .running:
            return "Running"
        case .reviewing:
            return "Reviewing"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var symbolName: String {
        switch self {
        case .queued:
            return "clock"
        case .preparing:
            return "wrench.and.screwdriver"
        case .running:
            return "bolt.circle"
        case .reviewing:
            return "doc.text.magnifyingglass"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "xmark.circle"
        case .cancelled:
            return "slash.circle"
        }
    }
}

struct ReviewDiffContext: Identifiable, Codable, Equatable {
    let path: String
    let originalPath: String?
    let changeSummary: String
    let diffText: String
    let updatedAt: Date

    var id: String {
        originalPath.map { "\($0)->\(path)" } ?? path
    }
}

struct ReviewThread: Codable, Equatable {
    var commentaryMarkdown: String
    var diffContexts: [ReviewDiffContext]
    var updatedAt: Date
}

struct AgentSession: Identifiable, Codable, Equatable {
    let id: UUID
    var parentSessionID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var repoRootPath: String
    var executionDirectoryPath: String
    var worktreePath: String
    var branchName: String
    var taskPrompt: String
    var modelIdentifier: String
    var modelDisplayName: String
    var status: AgentSessionStatus
    var progressSummary: String
    var latestMessage: String?
    var eventLog: [String]
    var reviewThread: ReviewThread?
    var errorMessage: String?

    var displayTitle: String {
        let trimmed = taskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return branchName }
        if trimmed.count <= 72 {
            return trimmed
        }
        return String(trimmed.prefix(72)) + "…"
    }

    var worktreeDisplayName: String {
        let url = URL(fileURLWithPath: worktreePath)
        return url.lastPathComponent.isEmpty ? worktreePath : url.lastPathComponent
    }
}

actor SessionStore {

    static let shared = SessionStore()

    func sessionsDirectory(for repoRootURL: URL) -> URL {
        repoRootURL
            .appendingPathComponent(".studio92", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func ensureSessionsDirectory(for repoRootURL: URL) throws -> URL {
        let directory = sessionsDirectory(for: repoRootURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func save(_ session: AgentSession) throws -> URL {
        let repoRootURL = URL(fileURLWithPath: session.repoRootPath, isDirectory: true)
        let directory = try ensureSessionsDirectory(for: repoRootURL)
        let fileURL = directory.appendingPathComponent("\(session.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    func loadSessions(in repoRootURL: URL) -> [AgentSession] {
        let directory = sessionsDirectory(for: repoRootURL)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(AgentSession.self, from: data)
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
    }
}

@MainActor
@Observable
final class JobMonitor {

    var workspaceURL: URL
    var sessions: [AgentSession] = []
    var isRefreshing = false

    @ObservationIgnored private let sessionStore = SessionStore.shared
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: PathEventMonitor?
    @ObservationIgnored private var watcherPath: String?

    init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL.standardizedFileURL
    }

    func start() {
        configureWatcherIfNeeded()
        startPollingIfNeeded()
        refreshNow()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        pollTask?.cancel()
        pollTask = nil
        watcher?.stop()
        watcher = nil
        watcherPath = nil
    }

    func updateWorkspace(_ newWorkspaceURL: URL) {
        workspaceURL = newWorkspaceURL.standardizedFileURL
        sessions = []
        configureWatcherIfNeeded()
        refreshNow()
    }

    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = Task { [workspaceURL, sessionStore] in
            await MainActor.run {
                self.isRefreshing = true
            }

            let repoRootURL = workspaceURL.standardizedFileURL
            _ = try? await sessionStore.ensureSessionsDirectory(for: repoRootURL)
            let sessions = await sessionStore.loadSessions(in: repoRootURL)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.isRefreshing = false
                self.sessions = sessions
                self.configureWatcherIfNeeded()
            }
        }
    }

    func session(id: UUID?) -> AgentSession? {
        guard let id else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    private func configureWatcherIfNeeded() {
        let directory = workspaceURL
            .appendingPathComponent(".studio92", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.path

        if watcher == nil || watcherPath != path {
            watcher?.stop()
            watcher = PathEventMonitor(
                path: path,
                label: "com.studio92.jobs.sessions"
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh()
                }
            }
            watcher?.start()
            watcherPath = path
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.refreshNow()
            }
        }
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.refreshNow()
                }
            }
        }
    }
}

actor BackgroundJobRunner {

    static let shared = BackgroundJobRunner()

    private let gitService = GitService()
    private let sessionStore = SessionStore.shared
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    func delegateToWorktree(
        workspaceURL: URL,
        branchName: String,
        targetDirectoryName: String?,
        taskPrompt: String,
        anthropicAPIKey: String?,
        openAIKey: String?
    ) async throws -> AgentSession {
        let worktree = try await gitService.createWorktree(
            from: workspaceURL,
            branchName: branchName,
            targetDirectoryName: targetDirectoryName
        )

        var session = AgentSession(
            id: UUID(),
            parentSessionID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            repoRootPath: worktree.repositoryRootURL.path,
            executionDirectoryPath: worktree.worktreeURL.path,
            worktreePath: worktree.worktreeURL.path,
            branchName: worktree.branchName,
            taskPrompt: taskPrompt,
            modelIdentifier: StudioModelStrategy.subagent.identifier,
            modelDisplayName: StudioModelStrategy.subagent.displayName,
            status: .queued,
            progressSummary: "Queued in an isolated worktree.",
            latestMessage: nil,
            eventLog: [],
            reviewThread: nil,
            errorMessage: nil
        )
        _ = try await sessionStore.save(session)

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runSession(
                session: session,
                worktreeURL: worktree.worktreeURL,
                anthropicAPIKey: anthropicAPIKey,
                openAIKey: openAIKey
            )
        }
        activeTasks[session.id] = task

        session.status = .preparing
        session.progressSummary = "Worktree created. Starting GPT-5.4 mini."
        session.updatedAt = Date()
        _ = try await sessionStore.save(session)
        return session
    }

    private func runSession(
        session: AgentSession,
        worktreeURL: URL,
        anthropicAPIKey: String?,
        openAIKey: String?
    ) async {
        var session = session

        func persist() async {
            session.updatedAt = Date()
            _ = try? await sessionStore.save(session)
        }

        func appendEvent(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            session.eventLog.append(trimmed)
            if session.eventLog.count > 80 {
                session.eventLog.removeFirst(session.eventLog.count - 80)
            }
            session.latestMessage = trimmed
        }

        guard let openAIKey = StudioModelStrategy.credential(provider: .openAI, storedValue: openAIKey) else {
            session.status = .failed
            session.progressSummary = "Background job could not start."
            session.errorMessage = "OPENAI_API_KEY is required for background worktree jobs."
            appendEvent("OpenAI access is required for GPT-5.4 mini worktree jobs.")
            await persist()
            return
        }

        session.status = .running
        session.progressSummary = "Background worker is editing inside the worktree."
        appendEvent("Started \(session.modelDisplayName) in \(session.worktreeDisplayName).")
        await persist()

        let client = AgenticClient(
            apiKey: anthropicAPIKey,
            projectRoot: worktreeURL,
            openAIKey: openAIKey,
            autonomyMode: .fullSend,
            allowMachineWideAccess: false
        )

        let stream = await client.run(
            system: Self.workerSystemPrompt(for: worktreeURL),
            userMessage: session.taskPrompt,
            initialMessages: [],
            model: StudioModelStrategy.subagent,
            outputEffort: StudioModelStrategy.subagent.defaultReasoningEffort,
            tools: DefaultToolSchemas.backgroundWorker,
            cacheControl: ["type": "ephemeral"],
            maxIterations: 20
        )

        var workerMarkdown = ""
        var didFail = false

        for await event in stream {
            switch event {
            case .textDelta(let text):
                workerMarkdown += text
                let snippet = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !snippet.isEmpty {
                    session.progressSummary = "Worker is drafting the handoff summary."
                    appendEvent(snippet)
                    await persist()
                }
            case .toolCallStart(_, let name):
                session.progressSummary = Self.progressSummary(forToolNamed: name)
                appendEvent("Started \(name.replacingOccurrences(of: "_", with: " ")).")
                await persist()
            case .toolCallCommand(_, let command):
                appendEvent("$ \(command)")
                await persist()
            case .toolCallOutput(_, let line):
                appendEvent(line)
                await persist()
            case .toolCallResult(_, let output, let isError):
                appendEvent(output)
                if isError {
                    session.progressSummary = "A tool reported an error."
                }
                await persist()
            case .completed:
                appendEvent("Worker finished. Preparing review context.")
                session.progressSummary = "Building the review thread."
                await persist()
            case .error(let message):
                didFail = true
                session.status = .failed
                session.progressSummary = "Background job failed."
                session.errorMessage = message
                appendEvent(message)
                await persist()
            case .thinkingDelta, .thinkingSignature, .toolCallInputDelta, .usage:
                break
            }
        }

        if didFail {
            activeTasks.removeValue(forKey: session.id)
            return
        }

        let diffContexts = (try? await gitService.reviewDiffContexts(for: worktreeURL)) ?? []
        let reviewMarkdown = await makeReviewMarkdown(
            worktreeURL: worktreeURL,
            files: diffContexts.map(\.path),
            fallbackMarkdown: workerMarkdown,
            anthropicAPIKey: anthropicAPIKey,
            openAIKey: openAIKey,
            taskPrompt: session.taskPrompt
        )

        session.reviewThread = ReviewThread(
            commentaryMarkdown: reviewMarkdown,
            diffContexts: diffContexts,
            updatedAt: Date()
        )
        session.progressSummary = diffContexts.isEmpty
            ? "Background job finished without file changes."
            : "Changes are ready for review."
        session.status = diffContexts.isEmpty ? .completed : .reviewing
        if session.latestMessage == nil {
            session.latestMessage = session.progressSummary
        }
        await persist()
        activeTasks.removeValue(forKey: session.id)
    }

    private func makeReviewMarkdown(
        worktreeURL: URL,
        files: [String],
        fallbackMarkdown: String,
        anthropicAPIKey: String?,
        openAIKey: String?,
        taskPrompt: String
    ) async -> String {
        let reviewerKey = StudioModelStrategy.credential(provider: .anthropic, storedValue: anthropicAPIKey)
        guard let reviewerKey, !files.isEmpty else {
            let trimmed = fallbackMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Background worker finished. Open the diff to inspect the isolated changes." : trimmed
        }

        let client = AgenticClient(
            apiKey: reviewerKey,
            projectRoot: worktreeURL,
            openAIKey: openAIKey,
            autonomyMode: .review,
            allowMachineWideAccess: false
        )

        let filesList = files.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        Review this isolated worktree run.

        Original task:
        \(taskPrompt)

        Changed files:
        \(filesList)

        Return concise markdown with:
        - Findings or notable risks first
        - What changed second
        - Any ship blockers or follow-ups last
        """

        let stream = await client.run(
            system: """
            You are Studio.92 Review Specialist operating inside an isolated git worktree.
            Stay read-only. Review the changed files for correctness, Apple-platform quality, regressions, and shipping risk.
            Keep the response concise and grounded in the actual changed files.
            """,
            userMessage: prompt,
            initialMessages: [],
            model: StudioModelStrategy.review,
            outputEffort: StudioModelStrategy.review.defaultReasoningEffort,
            tools: DefaultToolSchemas.reviewerTools,
            cacheControl: ["type": "ephemeral"],
            maxIterations: 8
        )

        var markdown = ""
        for await event in stream {
            switch event {
            case .textDelta(let text):
                markdown += text
            case .error:
                break
            default:
                continue
            }
        }

        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let fallback = fallbackMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? "Review finished. Inspect the diff for the isolated worktree changes." : fallback
        }
        return trimmed
    }

    private static func workerSystemPrompt(for worktreeURL: URL) -> String {
        """
        You are Studio.92 Background Worker operating in an isolated git worktree.
        Work only inside this execution directory: \(worktreeURL.path)

        Rules:
        - Complete the task directly and leave the branch ready for review.
        - Prefer precise file edits and focused verification.
        - Use the web when recency matters, especially for Apple docs, App Store policy, or current SDK guidance.
        - Do not create another worktree from inside this job.
        - Do not rely on hidden orchestration or mention internal routing.
        - End with a concise summary of what changed and what still needs human review.
        """
    }

    private static func progressSummary(forToolNamed toolName: String) -> String {
        switch toolName {
        case "file_read":
            return "Inspecting files in the worktree."
        case "file_write":
            return "Writing new files inside the worktree."
        case "file_patch":
            return "Patching existing files inside the worktree."
        case "list_files":
            return "Scanning the worktree."
        case "terminal":
            return "Running verification inside the worktree."
        case "web_search":
            return "Checking current external guidance."
        case "delegate_to_explorer":
            return "Collecting broader read-only context."
        case "delegate_to_reviewer":
            return "Requesting a second-pass review."
        default:
            return "Working inside the isolated worktree."
        }
    }
}
