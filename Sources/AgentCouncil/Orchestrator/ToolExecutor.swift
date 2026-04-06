// ToolExecutor.swift
// Studio.92 — Agent Council
// Dispatches tool_use requests from the model to local handlers.

import Foundation

/// Thread-safe wrapper for a Process reference, used to tie process lifetime to Swift Task cancellation.
private final class CancellableProcessRef: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ p: Process) {
        lock.lock()
        process = p
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
    }
}

/// Events emitted by the tool executor, observable by the UI layer.
public enum ToolExecutionEvent: Sendable {
    case started(toolCallID: String, name: String, input: [String: AnyCodableValue])
    case output(toolCallID: String, line: String)
    case completed(toolCallID: String, result: String, isError: Bool)
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
    private let permissionPolicy: ToolPermissionPolicy
    private let sandbox: SandboxPolicy
    private let eventContinuation: AsyncStream<ToolExecutionEvent>.Continuation
    public  let events: AsyncStream<ToolExecutionEvent>
    private let tracer: TraceCollector?
    private let recovery: RecoveryExecutor
    private let apiKey: String?

    public init(projectRoot: URL, allowMachineWideAccess: Bool = true, tracer: TraceCollector? = nil, apiKey: String? = nil) {
        self.projectRoot = projectRoot
        self.permissionPolicy = ToolPermissionPolicy()
        self.sandbox = SandboxPolicy(projectRoot: projectRoot, allowMachineWideAccess: allowMachineWideAccess)
        self.tracer = tracer
        self.apiKey = apiKey
        self.recovery = RecoveryExecutor(tracer: tracer)
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

        if case .blocked(let reason) = permissionPolicy.check(name) {
            let toolError = ToolError.permissionBlocked(tool: name, reason: reason)
            let spanID = await tracer?.begin(
                kind: .permissionCheck,
                name: "permission_blocked",
                attributes: ["tool": name]
            )
            if let spanID { await tracer?.end(spanID, error: reason) }
            let result = await recovery.attemptRecovery(for: toolError) { nil }
            let outcome = ToolExecutionOutcome(text: result.displayText, isError: result.isError)
            eventContinuation.yield(.completed(toolCallID: toolCallID, result: outcome.displayText, isError: outcome.isError))
            return outcome
        }

        let outcome: ToolExecutionOutcome
        do {
            guard let tool = ToolName(normalizing: name) else {
                outcome = ToolExecutionOutcome(text: "Unknown tool: \(name)", isError: true)
                eventContinuation.yield(.completed(toolCallID: toolCallID, result: outcome.displayText, isError: outcome.isError))
                return outcome
            }
            switch tool {
            case .fileRead:
                let raw = try await executeFileRead(input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case .fileWrite:
                let raw = try await executeFileWrite(input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case .filePatch:
                let raw = try await executeFilePatch(input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case .listFiles:
                let raw = try await executeListFiles(input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case .delegateToExplorer:
                outcome = try await executeDelegateToExplorer(toolCallID: toolCallID, input)
            case .delegateToReviewer:
                outcome = try await executeDelegateToReviewer(toolCallID: toolCallID, input)
            case .terminal:
                outcome = try await executeTerminalWithRecovery(toolCallID: toolCallID, name: name, input: input)
            case .webSearch:
                outcome = try await executeWebSearch(input, toolCallID: toolCallID)
            case .deployToTestFlight:
                let raw = try await executeDeployToTestFlight(toolCallID: toolCallID, input)
                outcome = ToolExecutionOutcome(text: raw.0, isError: raw.1)
            }
        } catch let toolError as ToolError {
            let result = await recovery.attemptRecovery(for: toolError) { nil }
            outcome = ToolExecutionOutcome(text: result.displayText, isError: result.isError)
        } catch {
            outcome = ToolExecutionOutcome(text: "Tool execution error: \(error.localizedDescription)", isError: true)
        }

        eventContinuation.yield(.completed(toolCallID: toolCallID, result: outcome.displayText, isError: outcome.isError))
        return outcome
    }



    // MARK: - File Read

    private func executeFileRead(_ input: [String: AnyCodableValue]) async throws -> (String, Bool) {
        guard let path = input["path"]?.stringValue else {
            return ("Missing required parameter: path", true)
        }
        let url = sandbox.resolvedURL(for: path)
        guard sandbox.check(url) else {
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
        let url = sandbox.resolvedURL(for: path)
        guard sandbox.check(url) else {
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
        let url = sandbox.resolvedURL(for: path)
        guard sandbox.check(url) else {
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

        let url = pathStr.map { sandbox.resolvedURL(for: $0) } ?? projectRoot
        guard sandbox.check(url) else {
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

    private func executeTerminal(toolCallID: String, input: [String: AnyCodableValue]) async throws -> (String, Bool) {
        guard let command = input["command"]?.stringValue else {
            return ("Missing required parameter: command", true)
        }
        let timeoutSec: Int
        if case .int(let t) = input["timeout"] { timeoutSec = min(t, 120) } else { timeoutSec = 30 }

        let projectRoot = projectRoot
        let environment = ProcessInfo.processInfo.environment
        let eventContinuation = self.eventContinuation

        let processRef = CancellableProcessRef()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                processRef.set(process)
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let lock = NSLock()
                var outputLines: [String] = []
                var stdoutBuffer = ""
                var stderrBuffer = ""
                var didTimeout = false

                func emitBufferedLines(from buffer: inout String, isError: Bool) {
                    let parts = buffer.components(separatedBy: "\n")
                    let trailing = buffer.hasSuffix("\n") ? "" : (parts.last ?? "")
                    let completeLines = buffer.hasSuffix("\n") ? parts.dropLast() : parts.dropLast()

                    for line in completeLines where !line.isEmpty {
                        let rendered = isError ? "[stderr] \(line)" : String(line)
                        lock.lock()
                        outputLines.append(rendered)
                        lock.unlock()
                        eventContinuation.yield(.output(toolCallID: toolCallID, line: rendered))
                    }

                    buffer = trailing
                }

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = projectRoot
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.environment = environment

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    stdoutBuffer += String(decoding: data, as: UTF8.self)
                    emitBufferedLines(from: &stdoutBuffer, isError: false)
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    stderrBuffer += String(decoding: data, as: UTF8.self)
                    emitBufferedLines(from: &stderrBuffer, isError: true)
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in
                    semaphore.signal()
                }

                let waitResult = semaphore.wait(timeout: .now() + .seconds(timeoutSec))
                if waitResult == .timedOut, process.isRunning {
                    didTimeout = true
                    process.terminate()
                    _ = semaphore.wait(timeout: .now() + 5)
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                stdoutBuffer += String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                stderrBuffer += String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

                emitBufferedLines(from: &stdoutBuffer, isError: false)
                emitBufferedLines(from: &stderrBuffer, isError: true)

                if !stdoutBuffer.isEmpty {
                    lock.lock()
                    outputLines.append(stdoutBuffer)
                    lock.unlock()
                    eventContinuation.yield(.output(toolCallID: toolCallID, line: stdoutBuffer))
                }
                if !stderrBuffer.isEmpty {
                    let rendered = "[stderr] \(stderrBuffer)"
                    lock.lock()
                    outputLines.append(rendered)
                    lock.unlock()
                    eventContinuation.yield(.output(toolCallID: toolCallID, line: rendered))
                }

                lock.lock()
                var result = outputLines.joined(separator: "\n")
                lock.unlock()

                if result.isEmpty {
                    result = "(no output)"
                }

                let exitCode = didTimeout ? -1 : process.terminationStatus
                let isError = didTimeout || exitCode != 0
                if didTimeout {
                    result += "\n[terminated after \(timeoutSec)s timeout]"
                } else if exitCode != 0 {
                    result += "\n[exit code: \(exitCode)]"
                }

                if result.count > 50_000 {
                    result = String(result.prefix(50_000)) + "\n\n[Truncated — output exceeds 50,000 characters]"
                }

                continuation.resume(returning: (result, isError))
            }
        }
        } onCancel: {
            processRef.terminate()
        }
    }
    // MARK: - Terminal with Recovery

    /// Wraps `executeTerminal` with typed error classification and retry logic.
    private func executeTerminalWithRecovery(
        toolCallID: String,
        name: String,
        input: [String: AnyCodableValue]
    ) async throws -> ToolExecutionOutcome {
        guard input["command"]?.stringValue != nil else {
            throw ToolError.invalidInput(tool: name, reason: "Missing required parameter: command")
        }
        let timeoutSec: Int
        if case .int(let t) = input["timeout"] { timeoutSec = min(t, 120) } else { timeoutSec = 30 }

        let (result, isError) = try await executeTerminal(toolCallID: toolCallID, input: input)

        guard isError else {
            return ToolExecutionOutcome(text: result, isError: false)
        }

        // Classify the failure.
        let toolError: ToolError
        if result.contains("[terminated after") && result.contains("timeout]") {
            toolError = .timeout(tool: name, elapsed: TimeInterval(timeoutSec))
        } else {
            // Extract exit code from the "[exit code: N]" suffix if present.
            let exitCode = extractExitCode(from: result) ?? 1
            toolError = .executionFailed(tool: name, stderr: result, exitCode: exitCode)
        }

        // Apply recovery strategy.
        let recoveryResult = await recovery.attemptRecovery(for: toolError) { [weak self] in
            guard let self else { return nil }
            return try await self.executeTerminal(toolCallID: toolCallID, input: input)
        }

        return ToolExecutionOutcome(text: recoveryResult.displayText, isError: recoveryResult.isError)
    }

    /// Parse "[exit code: N]" from terminal output.
    private func extractExitCode(from output: String) -> Int32? {
        guard let range = output.range(of: "[exit code: ", options: .backwards) else { return nil }
        let rest = output[range.upperBound...]
        guard let endBracket = rest.firstIndex(of: "]") else { return nil }
        return Int32(rest[..<endBracket])
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
        defer { try? FileManager.default.removeItem(at: result.outputDir) }
        let stderrLines = result.stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let stderrDetails = stderrLines.joined(separator: "\n")

        if emitProgress {
            for line in stderrLines {
                eventContinuation.yield(.output(toolCallID: toolCallID ?? "", line: line))
            }
        }

        guard result.exitCode == 0 else {
            let message = "Web search failed with exit code \(result.exitCode)."
            return ToolExecutionOutcome(
                text: stderrLines.isEmpty ? message : "\(message)\n\n\(stderrDetails)",
                isError: true
            )
        }

        let contextPack = readContextPack(from: result.outputDir).trimmingCharacters(in: .whitespacesAndNewlines)
        let searchResultBlocks = readContextPackResults(from: result.outputDir).compactMap { result -> ToolResultContentBlock? in
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
            var message = "Web search completed without usable results."
            message += "\n\n\(stdout)"
            if !stderrDetails.isEmpty {
                message += "\n\n\(stderrDetails)"
            }
            return ToolExecutionOutcome(text: message, isError: true)
        }

        if !stderrDetails.isEmpty {
            return ToolExecutionOutcome(text: "Web search completed without usable results.\n\n\(stderrDetails)", isError: true)
        }

        return ToolExecutionOutcome(text: "Web search completed without usable results.", isError: true)
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

        let handoffContext = HandoffContext(
            role: .explorer,
            guardrails: SubagentGuardrails.forSubagent(parentSandbox: sandbox),
            tracer: tracer,
            parentSpanID: nil,
            apiKey: apiKey
        )

        let executor = HandoffExecutor(projectRoot: projectRoot, context: handoffContext)
        let outcome = await executor.runExplorer(
            objective: objective,
            targetDirectories: targetDirectories,
            model: .haiku,
            toolHandler: { [weak self] name, nestedInput in
                guard let self else {
                    return ToolExecutionOutcome(text: "Explorer tool handler unavailable.", isError: true)
                }
                return await self.executeSubagentTool(name: name, input: nestedInput)
            }
        )

        // If the subagent hit its iteration limit, escalate: Haiku → Sonnet → Opus.
        if case .escalated = outcome {
            eventContinuation.yield(.output(toolCallID: toolCallID, line: "Explorer hit iteration limit — escalating to Sonnet."))
            let sonnetSpanID = await tracer?.begin(
                kind: .retry,
                name: "subagent_escalation",
                attributes: [
                    "routing.reason": "retry_escalation",
                    "escalation.from_model": "haiku",
                    "escalation.to_model": "sonnet",
                    "escalation.trigger": "iteration_limit",
                    "escalation.role": "explorer"
                ]
            )
            let sonnetOutcome = await executor.runExplorer(
                objective: objective,
                targetDirectories: targetDirectories,
                model: .sonnet,
                toolHandler: { [weak self] name, nestedInput in
                    guard let self else {
                        return ToolExecutionOutcome(text: "Explorer tool handler unavailable.", isError: true)
                    }
                    return await self.executeSubagentTool(name: name, input: nestedInput)
                }
            )
            if let sonnetSpanID {
                if case .escalated = sonnetOutcome {
                    await tracer?.end(sonnetSpanID, error: "sonnet_escalated")
                } else if case .failed = sonnetOutcome {
                    await tracer?.end(sonnetSpanID, error: "sonnet_failed")
                } else {
                    await tracer?.end(sonnetSpanID)
                }
            }

            // If Sonnet also hit its limit, final escalation to Opus.
            if case .escalated = sonnetOutcome {
                eventContinuation.yield(.output(toolCallID: toolCallID, line: "Sonnet also hit limit — final escalation to Opus."))
                let opusSpanID = await tracer?.begin(
                    kind: .retry,
                    name: "subagent_escalation",
                    attributes: [
                        "routing.reason": "retry_escalation",
                        "escalation.from_model": "sonnet",
                        "escalation.to_model": "opus",
                        "escalation.trigger": "iteration_limit",
                        "escalation.role": "explorer"
                    ]
                )
                let opusOutcome = await executor.runExplorer(
                    objective: objective,
                    targetDirectories: targetDirectories,
                    model: .opus,
                    toolHandler: { [weak self] name, nestedInput in
                        guard let self else {
                            return ToolExecutionOutcome(text: "Explorer tool handler unavailable.", isError: true)
                        }
                        return await self.executeSubagentTool(name: name, input: nestedInput)
                    }
                )
                if let opusSpanID {
                    if case .failed = opusOutcome {
                        await tracer?.end(opusSpanID, error: "escalation_failed")
                    } else {
                        await tracer?.end(opusSpanID)
                    }
                }
                return toolExecutionOutcome(from: opusOutcome, displayPrefix: "Workspace Explorer (Opus)")
            }

            // Sonnet completed (not escalated) — return its result.
            return toolExecutionOutcome(from: sonnetOutcome, displayPrefix: "Workspace Explorer (Sonnet)")
        }

        return toolExecutionOutcome(from: outcome, displayPrefix: "Workspace Explorer")
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

        let handoffContext = HandoffContext(
            role: .reviewer,
            guardrails: SubagentGuardrails.forSubagent(parentSandbox: sandbox),
            tracer: tracer,
            parentSpanID: nil,
            apiKey: apiKey
        )

        let executor = HandoffExecutor(projectRoot: projectRoot, context: handoffContext)
        let outcome = await executor.runReviewer(
            filesToReview: filesToReview,
            focusArea: focusArea,
            model: .sonnet,
            toolHandler: { [weak self] name, nestedInput in
                guard let self else {
                    return ToolExecutionOutcome(text: "Reviewer tool handler unavailable.", isError: true)
                }
                return await self.executeSubagentTool(name: name, input: nestedInput)
            }
        )

        // If the subagent hit its iteration limit, retry with Opus.
        if case .escalated = outcome {
            eventContinuation.yield(.output(toolCallID: toolCallID, line: "Reviewer hit iteration limit — escalating to Opus."))
            let escalationSpanID = await tracer?.begin(
                kind: .retry,
                name: "subagent_escalation",
                attributes: [
                    "routing.reason": "retry_escalation",
                    "escalation.from_model": "sonnet",
                    "escalation.to_model": "opus",
                    "escalation.trigger": "iteration_limit",
                    "escalation.role": "reviewer"
                ]
            )
            let retryOutcome = await executor.runReviewer(
                filesToReview: filesToReview,
                focusArea: focusArea,
                model: .opus,
                toolHandler: { [weak self] name, nestedInput in
                    guard let self else {
                        return ToolExecutionOutcome(text: "Reviewer tool handler unavailable.", isError: true)
                    }
                    return await self.executeSubagentTool(name: name, input: nestedInput)
                }
            )
            if let escalationSpanID {
                if case .failed = retryOutcome {
                    await tracer?.end(escalationSpanID, error: "escalation_failed")
                } else {
                    await tracer?.end(escalationSpanID)
                }
            }
            return toolExecutionOutcome(from: retryOutcome, displayPrefix: "Code Reviewer (Opus)")
        }

        return toolExecutionOutcome(from: outcome, displayPrefix: "Code Reviewer")
    }

    /// Convert a typed HandoffOutcome into the ToolExecutionOutcome the orchestrator expects.
    private func toolExecutionOutcome(from handoff: HandoffOutcome, displayPrefix: String) -> ToolExecutionOutcome {
        switch handoff {
        case .completed(let result):
            let filesNote = result.filesExamined.isEmpty
                ? ""
                : " (\(result.filesExamined.count) files examined)"
            return ToolExecutionOutcome(
                displayText: "\(displayPrefix) returned findings.\(filesNote)",
                toolResultContent: .text(result.summary),
                isError: false
            )
        case .escalated(let reason, let result):
            let filesNote = result.filesExamined.isEmpty
                ? ""
                : " (\(result.filesExamined.count) files examined)"
            return ToolExecutionOutcome(
                displayText: "\(displayPrefix) escalated: \(reason).\(filesNote)",
                toolResultContent: .text(result.summary),
                isError: false
            )
        case .failed(let error):
            return ToolExecutionOutcome(text: "\(displayPrefix) failed: \(error)", isError: true)
        }
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

        let processRef = CancellableProcessRef()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuationResult in
            DispatchQueue.global(qos: .userInitiated).async { [projectRoot] in
                let process = Process()
                processRef.set(process)
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

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in
                    semaphore.signal()
                }

                let deployTimeoutSec = 600 // 10 minutes
                let waitResult = semaphore.wait(timeout: .now() + .seconds(deployTimeoutSec))
                var didTimeout = false
                if waitResult == .timedOut, process.isRunning {
                    didTimeout = true
                    process.terminate()
                    _ = semaphore.wait(timeout: .now() + 5)
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                emitBufferedLines(from: &stdoutBuffer, isError: false)
                emitBufferedLines(from: &stderrBuffer, isError: true)

                lock.lock()
                let combinedOutput = outputLines.joined(separator: "\n")
                lock.unlock()

                let exitCode = didTimeout ? Int32(-1) : process.terminationStatus
                let summary: String
                if didTimeout {
                    summary = "Fastlane \(effectiveLane) timed out after \(deployTimeoutSec) seconds."
                } else if exitCode == 0 {
                    summary = "Fastlane \(effectiveLane) completed successfully."
                } else {
                    summary = "Fastlane \(effectiveLane) failed with exit code \(exitCode)."
                }
                let result = combinedOutput.isEmpty ? summary : "\(summary)\n\n\(combinedOutput)"
                continuationResult.resume(returning: (result, exitCode != 0))
            }
        }
        } onCancel: {
            processRef.terminate()
        }
    }



    private func lineHeuristic(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    private func runResearcher(query: String) async throws -> (exitCode: Int32, stdout: String, stderr: String, outputDir: URL) {
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("researcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let processRef = CancellableProcessRef()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [projectRoot] in
                let process = Process()
                processRef.set(process)
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", "Factory/researcher.py", query]
                process.currentDirectoryURL = projectRoot
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                var environment = ProcessInfo.processInfo.environment
                environment["RESEARCHER_OUTPUT_DIR"] = outputDir.path
                process.environment = environment
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
                continuation.resume(returning: (exitCode, stdout, stderr, outputDir))
            }
        }
        } onCancel: {
            processRef.terminate()
        }
    }

    private func readContextPack(from directory: URL) -> String {
        let url = directory.appendingPathComponent("context_pack.txt")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func readContextPackResults(from directory: URL) -> [ResearcherSearchResult] {
        let url = directory.appendingPathComponent("context_pack_results.json")
        guard let data = FileManager.default.contents(atPath: url.path),
              let results = try? JSONDecoder().decode([ResearcherSearchResult].self, from: data) else {
            return []
        }
        return results
    }

    private func executeSubagentTool(
        name: String,
        input: [String: AnyCodableValue]
    ) async -> ToolExecutionOutcome {
        let subagentPermissions = ToolPermissionPolicy()
        if case .blocked(let reason) = subagentPermissions.check(name) {
            return ToolExecutionOutcome(text: reason, isError: true)
        }
        guard let tool = ToolName(normalizing: name) else {
            return ToolExecutionOutcome(text: "Sub-agent tool unavailable: \(name)", isError: true)
        }
        do {
            switch tool {
            case .fileRead:
                let raw = try await executeFileRead(input)
                return ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case .listFiles:
                let raw = try await executeListFiles(input)
                return ToolExecutionOutcome(text: raw.0, isError: raw.1)
            case .webSearch:
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

}

private struct ResearcherSearchResult: Decodable {
    let query: String
    let title: String
    let url: String
    let snippet: String
}
