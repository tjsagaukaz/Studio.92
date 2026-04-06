import CoreServices
import Foundation

enum GitRepositoryPhase: String, Equatable {
    case loading
    case missingWorkspace
    case notRepository
    case ready
    case failed
}

struct GitChange: Identifiable, Equatable {

    enum Kind: String, Equatable {
        case ordinary
        case renamed
        case copied
        case unmerged
        case untracked
        case ignored
    }

    let path: String
    let originalPath: String?
    let stagedCode: Character
    let unstagedCode: Character
    let kind: Kind

    var id: String {
        originalPath.map { "\($0)->\(path)" } ?? path
    }

    var isStaged: Bool {
        stagedCode != "." && stagedCode != "?"
    }

    var isUnstaged: Bool {
        unstagedCode != "." && unstagedCode != "?"
    }

    var isConflicted: Bool {
        kind == .unmerged || stagedCode == "U" || unstagedCode == "U"
    }

    var isUntracked: Bool {
        kind == .untracked || stagedCode == "?" || unstagedCode == "?"
    }
}

struct GitChangeSummary: Equatable {
    var stagedCount: Int
    var unstagedCount: Int
    var untrackedCount: Int
    var conflictedCount: Int
    var totalCount: Int

    init(changes: [GitChange]) {
        stagedCount = changes.filter(\.isStaged).count
        unstagedCount = changes.filter(\.isUnstaged).count
        untrackedCount = changes.filter(\.isUntracked).count
        conflictedCount = changes.filter(\.isConflicted).count
        totalCount = changes.count
    }
}

struct GitWorktree: Identifiable, Equatable {
    let path: String
    let branchName: String?
    let headOID: String?
    let isBare: Bool
    let isDetached: Bool
    let isCurrent: Bool
    let isLocked: Bool
    let lockReason: String?

    var id: String { path }

    var displayName: String {
        if let branchName, !branchName.isEmpty {
            return branchName
        }
        return isDetached ? "Detached HEAD" : (URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent)
    }
}

struct GitWorktreeReservation: Equatable {
    let repositoryRootURL: URL
    let worktreeURL: URL
    let branchName: String
}

struct GitRepositoryState: Equatable {
    let phase: GitRepositoryPhase
    let workspacePath: String
    let repositoryRootPath: String?
    let gitDirectoryPath: String?
    let gitCommonDirectoryPath: String?
    let currentBranchName: String?
    let headOID: String?
    let upstreamBranchName: String?
    let aheadCount: Int
    let behindCount: Int
    let changes: [GitChange]
    let worktrees: [GitWorktree]
    let detailMessage: String
    let lastRefreshedAt: Date?

    static func loading(workspaceURL: URL) -> GitRepositoryState {
        GitRepositoryState(
            phase: .loading,
            workspacePath: workspaceURL.standardizedFileURL.path,
            repositoryRootPath: nil,
            gitDirectoryPath: nil,
            gitCommonDirectoryPath: nil,
            currentBranchName: nil,
            headOID: nil,
            upstreamBranchName: nil,
            aheadCount: 0,
            behindCount: 0,
            changes: [],
            worktrees: [],
            detailMessage: "Reading workspace state…",
            lastRefreshedAt: nil
        )
    }

    static func missingWorkspace(workspaceURL: URL) -> GitRepositoryState {
        GitRepositoryState(
            phase: .missingWorkspace,
            workspacePath: workspaceURL.standardizedFileURL.path,
            repositoryRootPath: nil,
            gitDirectoryPath: nil,
            gitCommonDirectoryPath: nil,
            currentBranchName: nil,
            headOID: nil,
            upstreamBranchName: nil,
            aheadCount: 0,
            behindCount: 0,
            changes: [],
            worktrees: [],
            detailMessage: "The selected workspace is unavailable on disk.",
            lastRefreshedAt: Date()
        )
    }

    static func notRepository(workspaceURL: URL) -> GitRepositoryState {
        GitRepositoryState(
            phase: .notRepository,
            workspacePath: workspaceURL.standardizedFileURL.path,
            repositoryRootPath: nil,
            gitDirectoryPath: nil,
            gitCommonDirectoryPath: nil,
            currentBranchName: nil,
            headOID: nil,
            upstreamBranchName: nil,
            aheadCount: 0,
            behindCount: 0,
            changes: [],
            worktrees: [],
            detailMessage: "Git-backed review, worktrees, and safe handoff need this workspace to be a repository.",
            lastRefreshedAt: Date()
        )
    }

    static func failed(workspaceURL: URL, message: String) -> GitRepositoryState {
        GitRepositoryState(
            phase: .failed,
            workspacePath: workspaceURL.standardizedFileURL.path,
            repositoryRootPath: nil,
            gitDirectoryPath: nil,
            gitCommonDirectoryPath: nil,
            currentBranchName: nil,
            headOID: nil,
            upstreamBranchName: nil,
            aheadCount: 0,
            behindCount: 0,
            changes: [],
            worktrees: [],
            detailMessage: message,
            lastRefreshedAt: Date()
        )
    }

    static func ready(
        workspaceURL: URL,
        repositoryRootURL: URL,
        gitDirectoryURL: URL,
        gitCommonDirectoryURL: URL,
        currentBranchName: String?,
        headOID: String?,
        upstreamBranchName: String?,
        aheadCount: Int,
        behindCount: Int,
        changes: [GitChange],
        worktrees: [GitWorktree]
    ) -> GitRepositoryState {
        let summary = GitChangeSummary(changes: changes)
        let branch = currentBranchName ?? "Detached HEAD"
        let detail = summary.totalCount == 0
            ? "\(branch) is clean across \(max(worktrees.count, 1)) worktree\(worktrees.count == 1 ? "" : "s")."
            : "\(branch) has \(summary.totalCount) pending change\(summary.totalCount == 1 ? "" : "s") across \(max(worktrees.count, 1)) worktree\(worktrees.count == 1 ? "" : "s")."

        return GitRepositoryState(
            phase: .ready,
            workspacePath: workspaceURL.standardizedFileURL.path,
            repositoryRootPath: repositoryRootURL.standardizedFileURL.path,
            gitDirectoryPath: gitDirectoryURL.standardizedFileURL.path,
            gitCommonDirectoryPath: gitCommonDirectoryURL.standardizedFileURL.path,
            currentBranchName: currentBranchName,
            headOID: headOID,
            upstreamBranchName: upstreamBranchName,
            aheadCount: aheadCount,
            behindCount: behindCount,
            changes: changes,
            worktrees: worktrees,
            detailMessage: detail,
            lastRefreshedAt: Date()
        )
    }

    var isRepository: Bool {
        phase == .ready
    }

    var workspaceDisplayName: String {
        let name = URL(fileURLWithPath: workspacePath).lastPathComponent
        return name.isEmpty ? workspacePath : name
    }

    var repositoryDisplayName: String {
        guard let repositoryRootPath else { return workspaceDisplayName }
        let name = URL(fileURLWithPath: repositoryRootPath).lastPathComponent
        return name.isEmpty ? repositoryRootPath : name
    }

    var currentWorktree: GitWorktree? {
        worktrees.first(where: \.isCurrent)
    }

    var changeSummary: GitChangeSummary {
        GitChangeSummary(changes: changes)
    }

    var branchDisplayName: String {
        currentBranchName ?? "Detached HEAD"
    }

    var worktreeCount: Int {
        max(worktrees.count, isRepository ? 1 : 0)
    }
}

actor GitService {

    private struct CommandOutput {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    private struct RepositoryContext {
        let workspaceURL: URL
        let repositoryRootURL: URL
        let gitDirectoryURL: URL
        let gitCommonDirectoryURL: URL
    }

    enum GitServiceError: LocalizedError {
        case processLaunchFailed(String)
        case commandFailed(arguments: [String], code: Int32, stderr: String)
        case invalidUTF8(String)
        case malformedRepositoryContext

        var errorDescription: String? {
            switch self {
            case .processLaunchFailed(let message):
                return "Failed to launch git: \(message)"
            case .commandFailed(let arguments, let code, let stderr):
                let renderedCommand = (["git"] + arguments).joined(separator: " ")
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return "\(renderedCommand) exited with status \(code)."
                }
                return "\(renderedCommand) exited with status \(code): \(detail)"
            case .invalidUTF8(let label):
                return "Git returned non-UTF8 \(label) output."
            case .malformedRepositoryContext:
                return "Git returned an unexpected repository context."
            }
        }
    }

    func repositoryState(for workspaceURL: URL) async -> GitRepositoryState {
        let normalizedWorkspace = workspaceURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedWorkspace.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missingWorkspace(workspaceURL: normalizedWorkspace)
        }

        let probe = await runGitAllowingFailure(arguments: ["rev-parse", "--is-inside-work-tree"], in: normalizedWorkspace)
        guard probe.exitCode == 0,
              Self.trimmedString(from: probe.stdout) == "true" else {
            return .notRepository(workspaceURL: normalizedWorkspace)
        }

        do {
            let context = try await resolveRepositoryContext(from: normalizedWorkspace)
            let statusOutput = try await runGit(
                arguments: ["status", "--porcelain=v2", "--branch", "-z"],
                in: context.workspaceURL
            )
            let worktreeOutput = try await runGit(arguments: ["worktree", "list", "--porcelain", "-z"], in: context.repositoryRootURL)

            let (branchState, changes) = try parseStatus(data: statusOutput.stdout)
            let worktrees = try parseWorktrees(
                data: worktreeOutput.stdout,
                currentWorkspaceURL: context.workspaceURL
            )

            return .ready(
                workspaceURL: context.workspaceURL,
                repositoryRootURL: context.repositoryRootURL,
                gitDirectoryURL: context.gitDirectoryURL,
                gitCommonDirectoryURL: context.gitCommonDirectoryURL,
                currentBranchName: branchState.branchName,
                headOID: branchState.headOID,
                upstreamBranchName: branchState.upstreamBranchName,
                aheadCount: branchState.aheadCount,
                behindCount: branchState.behindCount,
                changes: changes,
                worktrees: worktrees
            )
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed(workspaceURL: normalizedWorkspace, message: detail)
        }
    }

    func initializeRepository(at workspaceURL: URL) async -> GitRepositoryState {
        let normalizedWorkspace = workspaceURL.standardizedFileURL
        do {
            _ = try await runGit(arguments: ["init"], in: normalizedWorkspace)
            return await repositoryState(for: normalizedWorkspace)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed(workspaceURL: normalizedWorkspace, message: detail)
        }
    }

    func createWorktree(
        from workspaceURL: URL,
        branchName requestedBranchName: String,
        targetDirectoryName: String?
    ) async throws -> GitWorktreeReservation {
        let normalizedWorkspace = workspaceURL.standardizedFileURL
        let context = try await resolveRepositoryContext(from: normalizedWorkspace)

        let worktreesRoot = context.repositoryRootURL
            .appendingPathComponent(".studio92", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)

        let branchName = try await availableBranchName(
            requestedBranchName,
            in: context.repositoryRootURL
        )
        let baseDirectoryName = Self.sanitizedPathComponent(
            (targetDirectoryName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? targetDirectoryName!
                : branchName
        )
        let worktreeURL = uniqueWorktreeDirectory(
            baseName: baseDirectoryName,
            in: worktreesRoot
        )

        _ = try await runGit(
            arguments: ["worktree", "add", "-b", branchName, worktreeURL.path],
            in: context.repositoryRootURL
        )

        return GitWorktreeReservation(
            repositoryRootURL: context.repositoryRootURL,
            worktreeURL: worktreeURL,
            branchName: branchName
        )
    }

    // MARK: - Temporal Anchor (Revert Protocol)

    /// Enum describing the result of a dirty-state check before a revert.
    enum RevertResult: Sendable {
        case clean
        /// Uncommitted changes were stashed. The stash label is provided for display.
        case stashedDirtyState(stashLabel: String)
    }

    /// Creates a lightweight Git ref anchor under `refs/studio92/anchors/<anchorID>`.
    /// Points to current HEAD — invisible to `git log`, branch-safe, survives crashes.
    /// Returns the HEAD commit SHA.
    func createAnchor(id: UUID, workspaceURL: URL) async throws -> String {
        let root = workspaceURL.standardizedFileURL

        let headOutput = try await runGit(arguments: ["rev-parse", "HEAD"], in: root)
        guard let sha = String(data: headOutput.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty else {
            throw GitServiceError.invalidUTF8("HEAD sha")
        }

        let refName = "refs/studio92/anchors/\(id.uuidString)"
        _ = try await runGit(arguments: ["update-ref", refName, sha], in: root)
        return sha
    }

    /// Reverts workspace to the commit stored in an anchor SHA.
    ///
    /// Safety sequence (Dirty Revert protection):
    ///   1. Stash any uncommitted edits under a timestamped salvage label.
    ///   2. `git reset --hard <sha>` — execute the time jump.
    ///   3. Return `.stashedDirtyState` if anything was saved, `.clean` otherwise.
    func revertToAnchor(sha: String, workspaceURL: URL) async throws -> RevertResult {
        let root = workspaceURL.standardizedFileURL
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let stashLabel = "studio92:pre-revert-salvage-\(timestamp)"

        // Attempt salvage stash — fails gracefully if working tree is clean.
        let stashOut = await runGitAllowingFailure(
            arguments: ["stash", "push", "--include-untracked", "-m", stashLabel],
            in: root
        )
        let stashMsg = String(data: stashOut.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let didStash = stashOut.exitCode == 0 && !stashMsg.hasPrefix("No local changes")

        // Time jump.
        _ = try await runGit(arguments: ["reset", "--hard", sha], in: root)

        return didStash ? .stashedDirtyState(stashLabel: stashLabel) : .clean
    }

    func reviewDiffContexts(for workspaceURL: URL) async throws -> [ReviewDiffContext] {
        let state = await repositoryState(for: workspaceURL)
        guard state.phase == .ready else { return [] }

        let rootURL = workspaceURL.standardizedFileURL

        var contexts: [ReviewDiffContext] = []
        for change in state.changes {
            let diffText = try await diffText(for: change, in: rootURL)
            contexts.append(
                ReviewDiffContext(
                    path: change.path,
                    originalPath: change.originalPath,
                    changeSummary: changeSummary(for: change),
                    diffText: diffText,
                    updatedAt: Date()
                )
            )
        }

        return contexts.sorted { lhs, rhs in
            lhs.path < rhs.path
        }
    }

    private func resolveRepositoryContext(from workspaceURL: URL) async throws -> RepositoryContext {
        let output = try await runGit(arguments: ["rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir"], in: workspaceURL)
        guard let rawString = String(data: output.stdout, encoding: .utf8) else {
            throw GitServiceError.invalidUTF8("stdout")
        }

        let lines = rawString
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        guard lines.count >= 3 else {
            throw GitServiceError.malformedRepositoryContext
        }

        let repositoryRootURL = URL(fileURLWithPath: lines[0], isDirectory: true).standardizedFileURL
        let gitDirectoryURL = Self.resolvePath(lines[1], relativeTo: workspaceURL)
        let gitCommonDirectoryURL = Self.resolvePath(lines[2], relativeTo: workspaceURL)

        return RepositoryContext(
            workspaceURL: workspaceURL,
            repositoryRootURL: repositoryRootURL,
            gitDirectoryURL: gitDirectoryURL,
            gitCommonDirectoryURL: gitCommonDirectoryURL
        )
    }

    private struct BranchState {
        var branchName: String?
        var headOID: String?
        var upstreamBranchName: String?
        var aheadCount = 0
        var behindCount = 0
    }

    private func parseStatus(data: Data) throws -> (BranchState, [GitChange]) {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw GitServiceError.invalidUTF8("status")
        }

        let tokens = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        var branchState = BranchState()
        var changes: [GitChange] = []

        while index < tokens.count {
            let token = tokens[index]

            if token.hasPrefix("# ") {
                if token.hasPrefix("# branch.oid ") {
                    branchState.headOID = String(token.dropFirst("# branch.oid ".count))
                } else if token.hasPrefix("# branch.head ") {
                    let head = String(token.dropFirst("# branch.head ".count))
                    branchState.branchName = head == "(detached)" ? nil : head
                } else if token.hasPrefix("# branch.upstream ") {
                    branchState.upstreamBranchName = String(token.dropFirst("# branch.upstream ".count))
                } else if token.hasPrefix("# branch.ab ") {
                    let parts = token.split(separator: " ")
                    if parts.count >= 4 {
                        branchState.aheadCount = Int(parts[2].dropFirst()) ?? 0
                        branchState.behindCount = Int(parts[3].dropFirst()) ?? 0
                    }
                }
                index += 1
                continue
            }

            if token.hasPrefix("1 ") {
                let fields = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                if fields.count >= 9 {
                    let xy = String(fields[1])
                    changes.append(
                        GitChange(
                            path: String(fields[8]),
                            originalPath: nil,
                            stagedCode: xy.first ?? ".",
                            unstagedCode: xy.last ?? ".",
                            kind: .ordinary
                        )
                    )
                }
                index += 1
                continue
            }

            if token.hasPrefix("2 ") {
                let fields = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
                let originalPath = index + 1 < tokens.count ? tokens[index + 1] : nil
                if fields.count >= 10 {
                    let xy = String(fields[1])
                    let kind: GitChange.Kind = String(fields[8]).hasPrefix("C") ? .copied : .renamed
                    changes.append(
                        GitChange(
                            path: String(fields[9]),
                            originalPath: originalPath,
                            stagedCode: xy.first ?? ".",
                            unstagedCode: xy.last ?? ".",
                            kind: kind
                        )
                    )
                }
                index += 2
                continue
            }

            if token.hasPrefix("u ") {
                let fields = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                if fields.count >= 11 {
                    let xy = String(fields[1])
                    changes.append(
                        GitChange(
                            path: String(fields[10]),
                            originalPath: nil,
                            stagedCode: xy.first ?? "U",
                            unstagedCode: xy.last ?? "U",
                            kind: .unmerged
                        )
                    )
                }
                index += 1
                continue
            }

            if token.hasPrefix("? ") {
                changes.append(
                    GitChange(
                        path: String(token.dropFirst(2)),
                        originalPath: nil,
                        stagedCode: "?",
                        unstagedCode: "?",
                        kind: .untracked
                    )
                )
                index += 1
                continue
            }

            if token.hasPrefix("! ") {
                changes.append(
                    GitChange(
                        path: String(token.dropFirst(2)),
                        originalPath: nil,
                        stagedCode: "!",
                        unstagedCode: "!",
                        kind: .ignored
                    )
                )
                index += 1
                continue
            }

            index += 1
        }

        return (branchState, changes)
    }

    private func parseWorktrees(data: Data, currentWorkspaceURL: URL) throws -> [GitWorktree] {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw GitServiceError.invalidUTF8("worktree")
        }

        let tokens = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var records: [[String]] = []
        var current: [String] = []

        for token in tokens {
            if token.isEmpty {
                if !current.isEmpty {
                    records.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(token)
            }
        }

        if !current.isEmpty {
            records.append(current)
        }

        let currentRoot = currentWorkspaceURL.standardizedFileURL.path

        return records.compactMap { record in
            guard let worktreeLine = record.first(where: { $0.hasPrefix("worktree ") }) else {
                return nil
            }

            let path = String(worktreeLine.dropFirst("worktree ".count))
            let headOID = record.first(where: { $0.hasPrefix("HEAD ") }).map { String($0.dropFirst("HEAD ".count)) }
            let branchRef = record.first(where: { $0.hasPrefix("branch ") }).map { String($0.dropFirst("branch ".count)) }
            let branchName = branchRef.map(Self.branchDisplayName(from:))
            let isDetached = record.contains("detached")
            let isBare = record.contains("bare")
            let lockLine = record.first(where: { $0.hasPrefix("locked") })
            let lockReason: String?
            if let lockLine {
                let reason = lockLine.dropFirst("locked".count).trimmingCharacters(in: .whitespaces)
                lockReason = reason.isEmpty ? nil : reason
            } else {
                lockReason = nil
            }

            return GitWorktree(
                path: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path,
                branchName: branchName,
                headOID: headOID,
                isBare: isBare,
                isDetached: isDetached,
                isCurrent: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == currentRoot,
                isLocked: lockLine != nil,
                lockReason: lockReason
            )
        }
        .sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent {
                return lhs.isCurrent && !rhs.isCurrent
            }
            return lhs.path < rhs.path
        }
    }

    private func runGitAllowingFailure(
        arguments: [String],
        in directory: URL
    ) async -> CommandOutput {
        do {
            return try await runGit(arguments: arguments, in: directory)
        } catch let error as GitServiceError {
            let detail = error.localizedDescription.data(using: .utf8) ?? Data()
            let exitCode: Int32
            switch error {
            case .commandFailed(_, let code, _):
                exitCode = code
            default:
                exitCode = 1
            }
            return CommandOutput(stdout: Data(), stderr: detail, exitCode: exitCode)
        } catch {
            let detail = error.localizedDescription.data(using: .utf8) ?? Data()
            return CommandOutput(stdout: Data(), stderr: detail, exitCode: 1)
        }
    }

    private func runGit(arguments: [String], in directory: URL) async throws -> CommandOutput {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment

        let stdoutTask = Task { try await Self.readAll(from: stdoutPipe.fileHandleForReading) }
        let stderrTask = Task { try await Self.readAll(from: stderrPipe.fileHandleForReading) }

        do {
            try process.run()
        } catch {
            stdoutTask.cancel()
            stderrTask.cancel()
            throw GitServiceError.processLaunchFailed(error.localizedDescription)
        }

        // Timeout watchdog: terminate if git hangs longer than 30 seconds.
        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(30))
            guard process.isRunning else { return }
            process.terminate()
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        let exitCode = await Task.detached(priority: .utility) {
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        timeoutTask.cancel()

        let stdout = try await stdoutTask.value
        let stderr = try await stderrTask.value

        guard exitCode == 0 else {
            let stderrText = String(data: stderr, encoding: .utf8) ?? ""
            throw GitServiceError.commandFailed(arguments: arguments, code: exitCode, stderr: stderrText)
        }

        return CommandOutput(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    private static let maxOutputBytes = 10 * 1024 * 1024 // 10 MB

    private static func readAll(from handle: FileHandle) async throws -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4096)
        for try await byte in handle.bytes {
            bytes.append(byte)
            if bytes.count >= maxOutputBytes {
                bytes.append(contentsOf: Array("\n[output truncated at 10 MB]".utf8))
                break
            }
        }
        return Data(bytes)
    }

    private static func trimmedString(from data: Data) -> String {
        (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolvePath(_ rawPath: String, relativeTo baseURL: URL) -> URL {
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
        }
        return baseURL.appendingPathComponent(rawPath).standardizedFileURL
    }

    private static func branchDisplayName(from reference: String) -> String {
        reference.hasPrefix("refs/heads/")
            ? String(reference.dropFirst("refs/heads/".count))
            : reference
    }

    private func diffText(for change: GitChange, in repositoryRootURL: URL) async throws -> String {
        var sections: [String] = []

        if change.isStaged {
            let staged = await runGitAllowingFailure(
                arguments: ["diff", "--cached", "--no-color", "--", change.path],
                in: repositoryRootURL
            )
            let stagedText = Self.trimmedString(from: staged.stdout)
            if !stagedText.isEmpty {
                sections.append(stagedText)
            }
        }

        if change.isUnstaged {
            let unstaged = await runGitAllowingFailure(
                arguments: ["diff", "--no-color", "--", change.path],
                in: repositoryRootURL
            )
            let unstagedText = Self.trimmedString(from: unstaged.stdout)
            if !unstagedText.isEmpty {
                sections.append(unstagedText)
            }
        }

        if change.isUntracked && sections.isEmpty {
            let fileURL = repositoryRootURL.appendingPathComponent(change.path)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                sections.append(
                    """
                    Untracked file: \(change.path)

                    \(String(content.prefix(12_000)))
                    """
                )
            }
        }

        let rendered = sections.joined(separator: "\n\n")
        if rendered.count <= 18_000 {
            return rendered
        }
        return String(rendered.prefix(18_000)) + "\n\n[Diff truncated]"
    }

    private func availableBranchName(
        _ requestedBranchName: String,
        in repositoryRootURL: URL
    ) async throws -> String {
        let sanitized = Self.sanitizedBranchName(requestedBranchName)
        var candidate = sanitized
        var suffix = 2

        while true {
            let probe = await runGitAllowingFailure(
                arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"],
                in: repositoryRootURL
            )
            if probe.exitCode != 0 {
                return candidate
            }
            candidate = "\(sanitized)-\(suffix)"
            suffix += 1
        }
    }

    private func uniqueWorktreeDirectory(
        baseName: String,
        in directory: URL
    ) -> URL {
        var candidate = baseName
        var suffix = 2

        while true {
            let url = directory.appendingPathComponent(candidate, isDirectory: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            candidate = "\(baseName)-\(suffix)"
            suffix += 1
        }
    }

    private func changeSummary(for change: GitChange) -> String {
        var parts: [String] = []
        if change.isStaged {
            parts.append("staged")
        }
        if change.isUnstaged {
            parts.append("unstaged")
        }
        if change.isUntracked {
            parts.append("untracked")
        }
        if change.isConflicted {
            parts.append("conflicted")
        }
        if parts.isEmpty {
            parts.append(change.kind.rawValue)
        }
        return parts.joined(separator: " · ")
    }

    private static func sanitizedBranchName(_ raw: String) -> String {
        let lowered = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let replaced = lowered.replacingOccurrences(
            of: #"[^a-z0-9._/\-]+"#,
            with: "-",
            options: .regularExpression
        )
        let collapsed = replaced.replacingOccurrences(
            of: #"-{2,}"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "./-"))
        return trimmed.isEmpty ? "studio92-job" : trimmed
    }

    private static func sanitizedPathComponent(_ raw: String) -> String {
        let replaced = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"-{2,}"#,
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return replaced.isEmpty ? "job" : replaced
    }
}

final class PathEventMonitor {

    typealias Handler = @Sendable ([String]) -> Void

    private let path: String
    private let latency: CFTimeInterval
    private let callback: Handler
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?

    init(path: String, label: String, latency: CFTimeInterval = 0.3, callback: @escaping Handler) {
        self.path = path
        self.latency = latency
        self.callback = callback
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    func start() {
        guard stream == nil else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let monitor = Unmanaged<PathEventMonitor>.fromOpaque(info).takeUnretainedValue()
                let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
                monitor.callback(paths)
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
