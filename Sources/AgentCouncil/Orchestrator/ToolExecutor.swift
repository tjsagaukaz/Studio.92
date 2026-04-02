// ToolExecutor.swift
// Studio.92 — Agent Council
// Dispatches tool_use requests from the model to local handlers.
// Plan/review modes stay scoped to the project root. Full-send mode can reach
// the wider machine when the user explicitly enables it.

import Foundation

/// Events emitted by the tool executor, observable by the UI layer.
public enum ToolExecutionEvent: Sendable {
    case started(toolCallID: String, name: String, input: [String: AnyCodableValue])
    case output(toolCallID: String, line: String)
    case completed(toolCallID: String, result: String, isError: Bool)
}

public enum AutonomyMode: String, CaseIterable, Sendable {
    case plan
    case review
    case fullSend
}

public struct ToolExecutionOutcome: Sendable {
    public let displayText: String
    public let toolResultContent: ToolResultContent
    public let isError: Bool

    public init(displayText: String, toolResultContent: ToolResultContent, isError: Bool) {
        self.displayText = displayText
        self.toolResultContent = toolResultContent
        self.isError = isError
    }

    public init(text: String, isError: Bool) {
        self.init(displayText: text, toolResultContent: .text(text), isError: isError)
    }
}

public actor ToolExecutor {

    private let projectRoot: URL
    private let autonomyMode: AutonomyMode
    private let eventContinuation: AsyncStream<ToolExecutionEvent>.Continuation
    public  let events: AsyncStream<ToolExecutionEvent>

    public init(projectRoot: URL, autonomyMode: AutonomyMode = .review) {
        self.projectRoot = projectRoot
        self.autonomyMode = autonomyMode
        let (stream, continuation) = AsyncStream<ToolExecutionEvent>.makeStream()
        self.events = stream
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    /// Execute a tool_use block and return the result string for the next API turn.
    public func execute(
        toolCallID: String,
        name:       String,
        input:      [String: AnyCodableValue]
    ) async -> ToolExecutionOutcome {
        eventContinuation.yield(.started(toolCallID: toolCallID, name: name, input: input))

        if let permissionError = permissionError(for: name) {
            eventContinuation.yield(.completed(toolCallID: toolCallID, result: permissionError, isError: true))
            return ToolExecutionOutcome(text: permissionError, isError: true)
        }

        let outcome: ToolExecutionOutcome
        do {
            switch name {
            case "file_read":
                let raw = try await executeFileRead(input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case "file_write":
                let raw = try await executeFileWrite(input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case "file_patch":
                let raw = try await executeFilePatch(input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case "list_files":
                let raw = try await executeListFiles(input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case "delegate_to_explorer":
                outcome = try await executeDelegateToExplorer(toolCallID: toolCallID, input)
            case "delegate_to_reviewer":
                outcome = try await executeDelegateToReviewer(toolCallID: toolCallID, input)
            case "terminal":
                let raw = try await executeTerminal(input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case "web_search":
                outcome = try await executeWebSearch(input, toolCallID: toolCallID)
            case "deploy_to_testflight":
                let raw = try await executeDeployToTestFlight(toolCallID: toolCallID, input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            default:
                outcome = ToolExecutionOutcome(text: "Unknown tool: \(name)", isError: true)
            }
        } catch {
            outcome = ToolExecutionOutcome(text: "Tool execution error: \(error.localizedDescription)", isError: true)
        }

        eventContinuation.yield(.completed(toolCallID: toolCallID, result: outcome.displayText, isError: outcome.isError))
        return outcome
    }

    private func permissionError(for toolName: String) -> String? {
        switch autonomyMode {
        case .plan:
            if ["file_write", "file_patch", "terminal", "deploy_to_testflight"].contains(toolName) {
                return "System Error: User has restricted your permissions to Plan mode. You cannot execute this action."
            }
            return nil
        case .review:
            if ["file_write", "file_patch", "deploy_to_testflight"].contains(toolName) {
                return "System Error: User has restricted your permissions to Review mode. You cannot execute this action. Present the proposed code in the conversation for manual diff approval instead."
            }
            return nil
        case .fullSend:
            return nil
        }
    }

    // MARK: - File Read

    private func executeFileRead(_ input: [String: AnyCodableValue]) async throws -> (String, Bool) {
        guard let path = input["path"]?.stringValue else {
            return ("Missing required parameter: path", true)
        }
        let url = resolvedURL(for: path)
        guard sandboxCheck(url) else {
            return ("Access denied: path is outside the project directory.", true)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ("File not found: \(url.path)", true)
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        // Truncate very large files to avoid blowing up context.
        if content.count > 100_000 {
            let truncated = String(content.prefix(100_000))
            return (truncated + "\n\n[Truncated — file exceeds 100,000 characters]", false)
        }
        return (content, false)
    }

    // MARK: - File Write

    private func executeFileWrite(_ input: [String: AnyCodableValue]) async throws -> (String, Bool) {
        guard let path = input["path"]?.stringValue,
              let content = input["content"]?.stringValue else {
            return ("Missing required parameters: path, content", true)
        }
        let url = resolvedURL(for: path)
        guard sandboxCheck(url) else {
            return ("Access denied: path is outside the project directory.", true)
        }
        // Create intermediate directories.
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let addedLines = lineHeuristic(for: content)
        return ("File written: \(url.path) (+\(addedLines) -0 heuristic lines, \(content.count) characters)", false)
    }

    // MARK: - File Patch

    private func executeFilePatch(_ input: [String: AnyCodableValue]) async throws -> (String, Bool) {
        guard let path = input["path"]?.stringValue,
              let oldString = input["old_string"]?.stringValue,
              let newString = input["new_string"]?.stringValue else {
            return ("Missing required parameters: path, old_string, new_string", true)
        }
        let url = resolvedURL(for: path)
        guard sandboxCheck(url) else {
            return ("Access denied: path is outside the project directory.", true)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ("File not found: \(url.path)", true)
        }
        var content = try String(contentsOf: url, encoding: .utf8)
        let occurrences = content.components(separatedBy: oldString).count - 1
        guard occurrences == 1 else {
            return ("old_string matched \(occurrences) times (expected exactly 1). Provide more context to make the match unique.", true)
        }
        content = content.replacingOccurrences(of: oldString, with: newString)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let removedLines = lineHeuristic(for: oldString)
        let addedLines = lineHeuristic(for: newString)
        return ("Patch applied to \(url.path) (+\(addedLines) -\(removedLines) heuristic lines)", false)
    }

    // MARK: - List Files

    private func executeListFiles(_ input: [String: AnyCodableValue]) async throws -> (String, Bool) {
        let pathStr = input["path"]?.stringValue
        let recursive: Bool
        if case .bool(let b) = input["recursive"] { recursive = b } else { recursive = false }

        let url = pathStr.map { resolvedURL(for: $0) } ?? projectRoot
        guard sandboxCheck(url) else {
            return ("Access denied: path is outside the project directory.", true)
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return ("Not a directory: \(url.path)", true)
        }

        if recursive {
            return try listRecursive(url: url, depth: 0, maxDepth: 3)
        } else {
            let items = try fm.contentsOfDirectory(atPath: url.path).sorted()
            let lines = items.map { name -> String in
                var childIsDir: ObjCBool = false
                fm.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &childIsDir)
                return childIsDir.boolValue ? "\(name)/" : name
            }
            return (lines.joined(separator: "\n"), false)
        }
    }

    private func listRecursive(url: URL, depth: Int, maxDepth: Int) throws -> (String, Bool) {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(atPath: url.path).sorted()
        var lines: [String] = []
        let indent = String(repeating: "  ", count: depth)
        for name in items {
            let child = url.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: child.path, isDirectory: &isDir)
            if isDir.boolValue {
                lines.append("\(indent)\(name)/")
                if depth < maxDepth {
                    let (sub, _) = try listRecursive(url: child, depth: depth + 1, maxDepth: maxDepth)
                    lines.append(sub)
                }
            } else {
                lines.append("\(indent)\(name)")
            }
        }
        return (lines.joined(separator: "\n"), false)
    }

    // MARK: - Terminal

    private func executeTerminal(_ input: [String: AnyCodableValue]) async throws -> (String, Bool) {
        guard let command = input["command"]?.stringValue else {
            return ("Missing required parameter: command", true)
        }
        let timeoutSec: Int
        if case .int(let t) = input["timeout"] { timeoutSec = min(t, 120) } else { timeoutSec = 30 }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = projectRoot
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe
        process.environment = ProcessInfo.processInfo.environment

        try process.run()

        // Timeout handling.
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeoutSec) * 1_000_000_000)
            if process.isRunning { process.terminate() }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(decoding: stdoutData, as: UTF8.self)
        let stderr = String(decoding: stderrData, as: UTF8.self)

        let exitCode = process.terminationStatus

        var result = ""
        if !stdout.isEmpty { result += stdout }
        if !stderr.isEmpty { result += (result.isEmpty ? "" : "\n") + "[stderr]\n" + stderr }
        if result.isEmpty  { result = "(no output)" }

        // Emit output lines for UI.
        for line in result.components(separatedBy: "\n") {
            eventContinuation.yield(.output(toolCallID: "", line: line))
        }

        let isError = exitCode != 0
        if isError {
            result += "\n[exit code: \(exitCode)]"
        }

        // Truncate massive output.
        if result.count > 50_000 {
            result = String(result.prefix(50_000)) + "\n\n[Truncated — output exceeds 50,000 characters]"
        }

        return (result, isError)
    }

    // MARK: - Web Search

    private func executeWebSearch(
        _ input: [String: AnyCodableValue],
        toolCallID: String? = nil,
        emitProgress: Bool = true
    ) async throws -> ToolExecutionOutcome {
        guard let query = input["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return ToolExecutionOutcome(text: "Missing required parameter: query", isError: true)
        }

        let result = try await runResearcher(query: query)
        let stderrLines = result.stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if emitProgress {
            for line in stderrLines {
                eventContinuation.yield(.output(toolCallID: toolCallID ?? "", line: line))
            }
        }

        guard result.exitCode == 0 else {
            let message = "Web search failed, please rely on internal knowledge."
            return ToolExecutionOutcome(
                text: stderrLines.isEmpty ? message : "\(message)\n\n\(stderrLines.joined(separator: "\n"))",
                isError: true
            )
        }

        let contextPack = readContextPack().trimmingCharacters(in: .whitespacesAndNewlines)
        let searchResultBlocks = readContextPackResults().compactMap { result -> ToolResultContentBlock? in
            let source = result.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !title.isEmpty, !snippet.isEmpty else { return nil }
            return .searchResult(
                ToolResultSearchResult(
                    source: source,
                    title: title,
                    texts: [snippet],
                    citationsEnabled: true
                )
            )
        }

        if !searchResultBlocks.isEmpty || !contextPack.isEmpty {
            var blocks: [ToolResultContentBlock] = []
            if !contextPack.isEmpty {
                blocks.append(.text(contextPack))
            }
            blocks.append(contentsOf: searchResultBlocks)
            let summary = searchResultBlocks.isEmpty
                ? "Web search context pack built."
                : "Web search returned \(searchResultBlocks.count) grounded results."
            return ToolExecutionOutcome(
                displayText: summary,
                toolResultContent: .blocks(blocks),
                isError: false
            )
        }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return ToolExecutionOutcome(text: stdout, isError: false)
        }

        return ToolExecutionOutcome(text: "Web search failed, please rely on internal knowledge.", isError: true)
    }

    // MARK: - Delegation

    private func executeDelegateToExplorer(
        toolCallID: String,
        _ input: [String: AnyCodableValue]
    ) async throws -> ToolExecutionOutcome {
        guard let objective = input["objective"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !objective.isEmpty else {
            return ToolExecutionOutcome(text: "Missing required parameter: objective", isError: true)
        }

        let targetDirectories = stringArray(from: input["target_directories"])
        let displayTargets = targetDirectories.isEmpty
            ? projectRoot.lastPathComponent
            : targetDirectories.joined(separator: ", ")
        eventContinuation.yield(.output(toolCallID: toolCallID, line: "Spawning Workspace Explorer for \(displayTargets)"))

        let client = try ClaudeAPIClient()
        let manager = SubAgentManager(client: client)
        let summary = try await manager.run(
            spec: .init(
                systemPrompt: """
                You are Workspace Explorer, a fast read-only codebase scout.
                Stay focused on the objective and read only what materially helps. Prefer file_read, list_files, and web_search when they reduce guesswork.
                Return a concise, high-density summary of structure, data flow, mismatches, and risks. Keep it practical. Do not propose patches or dump raw transcripts.
                """,
                userPrompt: explorerPrompt(
                    objective: objective,
                    targetDirectories: targetDirectories
                ),
                model: .haiku,
                tools: [AgentTools.fileRead, AgentTools.listFiles, AgentTools.webSearch]
            ),
            toolHandler: { [weak self] name, nestedInput in
                guard let self else {
                    return ToolExecutionOutcome(text: "Explorer tool handler unavailable.", isError: true)
                }
                return await self.executeSubagentTool(name: name, input: nestedInput)
            }
        )

        return ToolExecutionOutcome(
            displayText: "Workspace Explorer returned findings.",
            toolResultContent: .text(summary),
            isError: false
        )
    }

    private func executeDelegateToReviewer(
        toolCallID: String,
        _ input: [String: AnyCodableValue]
    ) async throws -> ToolExecutionOutcome {
        let filesToReview = stringArray(from: input["files_to_review"])
        guard !filesToReview.isEmpty else {
            return ToolExecutionOutcome(text: "Missing required parameter: files_to_review", isError: true)
        }
        guard let focusArea = input["focus_area"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !focusArea.isEmpty else {
            return ToolExecutionOutcome(text: "Missing required parameter: focus_area", isError: true)
        }

        let focusTarget = filesToReview.count == 1 ? filesToReview[0] : "\(filesToReview.count) files"
        eventContinuation.yield(.output(toolCallID: toolCallID, line: "Code Reviewer auditing \(focusTarget)"))

        let client = try ClaudeAPIClient()
        let manager = SubAgentManager(client: client)
        let summary = try await manager.run(
            spec: .init(
                systemPrompt: """
                You are Code Reviewer, a sharp senior iOS reviewer.
                Audit only the provided files through the requested lens and return a short list of the most important findings.
                Stay read-only. Use file_read to inspect the files and list_files only for a tiny amount of nearby context. Do not rewrite code, and only quote tiny snippets when they are essential to explain a real issue.
                """,
                userPrompt: reviewerPrompt(
                    filesToReview: filesToReview,
                    focusArea: focusArea
                ),
                model: .sonnet,
                tools: [AgentTools.fileRead, AgentTools.listFiles]
            ),
            toolHandler: { [weak self] name, nestedInput in
                guard let self else {
                    return ToolExecutionOutcome(text: "Reviewer tool handler unavailable.", isError: true)
                }
                return await self.executeSubagentTool(name: name, input: nestedInput)
            }
        )

        return ToolExecutionOutcome(
            displayText: "Code Reviewer returned findings.",
            toolResultContent: .text(summary),
            isError: false
        )
    }

    // MARK: - Deployment

    private func executeDeployToTestFlight(
        toolCallID: String,
        _ input: [String: AnyCodableValue]
    ) async throws -> (String, Bool) {
        let lane = input["lane"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLane = (lane?.isEmpty == false ? lane! : "beta")
        let launchCommand = """
        if [ -f Gemfile ] && command -v bundle >/dev/null 2>&1; then
          bundle exec fastlane \(effectiveLane)
        else
          fastlane \(effectiveLane)
        fi
        """
        .trimmingCharacters(in: .whitespacesAndNewlines)

        let continuation = eventContinuation
        continuation.yield(.output(toolCallID: toolCallID, line: "$ fastlane \(effectiveLane)"))

        return try await withCheckedThrowingContinuation { continuationResult in
            DispatchQueue.global(qos: .userInitiated).async { [projectRoot] in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                var outputLines: [String] = []
                var stdoutBuffer = ""
                var stderrBuffer = ""
                let lock = NSLock()

                func emitBufferedLines(from buffer: inout String, isError: Bool) {
                    while let newlineIndex = buffer.firstIndex(of: "\n") {
                        let line = String(buffer[..<newlineIndex]).trimmingCharacters(in: .newlines)
                        buffer = String(buffer[buffer.index(after: newlineIndex)...])
                        guard !line.isEmpty else { continue }
                        let presented = isError ? "[ERROR] \(line)" : line
                        lock.lock()
                        outputLines.append(presented)
                        lock.unlock()
                        continuation.yield(.output(toolCallID: toolCallID, line: presented))
                    }
                }

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", launchCommand]
                process.currentDirectoryURL = projectRoot
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.environment = ProcessInfo.processInfo.environment

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    stdoutBuffer += chunk
                    emitBufferedLines(from: &stdoutBuffer, isError: false)
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    stderrBuffer += chunk
                    emitBufferedLines(from: &stderrBuffer, isError: true)
                }

                do {
                    try process.run()
                } catch {
                    continuationResult.resume(throwing: error)
                    return
                }

                process.waitUntilExit()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                emitBufferedLines(from: &stdoutBuffer, isError: false)
                emitBufferedLines(from: &stderrBuffer, isError: true)

                lock.lock()
                let combinedOutput = outputLines.joined(separator: "\n")
                lock.unlock()

                let exitCode = process.terminationStatus
                let summary = exitCode == 0
                    ? "Fastlane \(effectiveLane) completed successfully."
                    : "Fastlane \(effectiveLane) failed with exit code \(exitCode)."
                let result = combinedOutput.isEmpty ? summary : "\(summary)\n\n\(combinedOutput)"
                continuationResult.resume(returning: (result, exitCode != 0))
            }
        }
    }

    // MARK: - Sandboxing

    private func resolvedURL(for path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return projectRoot.appendingPathComponent(path)
    }

    private func sandboxCheck(_ url: URL) -> Bool {
        if autonomyMode == .fullSend {
            return true
        }
        let resolved = url.standardized.path
        let root     = projectRoot.standardized.path
        return resolved.hasPrefix(root)
    }

    private func lineHeuristic(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    private func runResearcher(query: String) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [projectRoot] in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", "Factory/researcher.py", query]
                process.currentDirectoryURL = projectRoot
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.environment = ProcessInfo.processInfo.environment
                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in
                    semaphore.signal()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let waitResult = semaphore.wait(timeout: .now() + 60)
                if waitResult == .timedOut, process.isRunning {
                    process.terminate()
                    _ = semaphore.wait(timeout: .now() + 5)
                }

                let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let exitCode = waitResult == .timedOut ? -1 : process.terminationStatus
                continuation.resume(returning: (exitCode, stdout, stderr))
            }
        }
    }

    private func readContextPack() -> String {
        let path = NSString(string: "~/.darkfactory/context_pack.txt").expandingTildeInPath
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func readContextPackResults() -> [ResearcherSearchResult] {
        let path = NSString(string: "~/.darkfactory/context_pack_results.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let results = try? JSONDecoder().decode([ResearcherSearchResult].self, from: data) else {
            return []
        }
        return results
    }

    private func executeSubagentTool(
        name: String,
        input: [String: AnyCodableValue]
    ) async -> ToolExecutionOutcome {
        do {
            switch name {
            case "file_read":
                let raw = try await executeFileRead(input)
                return ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case "list_files":
                let raw = try await executeListFiles(input)
                return ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case "web_search":
                return try await executeWebSearch(input, emitProgress: false)
            default:
                return ToolExecutionOutcome(text: "Sub-agent tool unavailable: \(name)", isError: true)
            }
        } catch {
            return ToolExecutionOutcome(text: "Sub-agent tool error: \(error.localizedDescription)", isError: true)
        }
    }

    private func stringArray(from value: AnyCodableValue?) -> [String] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func explorerPrompt(objective: String, targetDirectories: [String]) -> String {
        let scopedDirectories = targetDirectories.isEmpty
            ? "- \(projectRoot.path)"
            : targetDirectories.map { "- \($0)" }.joined(separator: "\n")

        return """
        Objective:
        \(objective)

        Target directories to inspect first:
        \(scopedDirectories)
        """
    }

    private func reviewerPrompt(filesToReview: [String], focusArea: String) -> String {
        let files = filesToReview.map { "- \($0)" }.joined(separator: "\n")
        return """
        Focus area:
        \(focusArea)

        Files to review:
        \(files)
        """
    }

}

private struct ResearcherSearchResult: Decodable {
    let query: String
    let title: String
    let url: String
    let snippet: String
}
