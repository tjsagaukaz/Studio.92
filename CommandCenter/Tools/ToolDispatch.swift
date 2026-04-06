// AgenticToolDispatch.swift
// Studio.92 — Command Center
// Tool execution dispatch extracted from AgenticBridge.swift (Sprint 3).
// Keeps the agentic streaming core separate from tool implementation.

import Foundation
import AppKit
import AgentCouncil

// MARK: - Tool Dispatch

extension AgenticClient {

    func executeTool(
        name: String,
        input: [String: Any],
        progress: @escaping @Sendable (ToolProgress) -> Void = { _ in }
    ) async -> ToolExecutionOutcome {
        if case .blocked(let reason) = permissionPolicy.check(name) {
            let toolError = ToolError.permissionBlocked(tool: name, reason: reason)
            let result = await recovery.attemptRecovery(for: toolError) { nil }
            return ToolExecutionOutcome(text: result.displayText, isError: result.isError)
        }

        if let approvalRequest = approvalRequest(for: name, input: input) {
            progress(.output("[APPROVAL] Waiting for approval."))
            let approved = await CommandApprovalController.shared.requestApproval(approvalRequest)
            guard approved else {
                return ToolExecutionOutcome(
                    text: "Approval denied: \(approvalRequest.title).",
                    isError: true
                )
            }
            progress(.output("[APPROVAL] Approved."))
        }

        guard let tool = StudioToolName(normalizing: name) else {
            return ToolExecutionOutcome(text: "Unknown tool: \(name)", isError: true)
        }
        switch tool {
        case .fileRead:
            let raw = executeFileRead(input)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case .fileWrite:
            let raw = executeFileWrite(input)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case .filePatch:
            let raw = executeFilePatch(input)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case .listFiles:
            let raw = executeListFiles(input)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case .delegateToExplorer:
            return await executeDelegateToExplorer(input)
        case .delegateToReviewer:
            return await executeDelegateToReviewer(input)
        case .delegateToWorktree:
            return await executeDelegateToWorktree(input)
        case .terminal:
            return await executeTerminalWithRecovery(name: name, input: input, progress: progress)
        case .deployToTestFlight:
            let raw = await executeDeployToTestFlight(input, progress: progress)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case .webSearch:
            return await executeWebSearch(input)
        case .webFetch, .screenshotSimulator, .xcodeBuild, .xcodePreview:
            return ToolExecutionOutcome(text: "Tool not yet implemented: \(name)", isError: true)
        }
    }

    private func approvalRequest(for name: String, input: [String: Any]) -> ToolApprovalRequest? {
        let resolvedPaths = approvalPaths(for: name, input: input)
        guard runtimePolicy.requiresApproval(
            toolName: name,
            resolvedPaths: resolvedPaths,
            workspaceRoot: projectRoot.path
        ) else {
            return nil
        }

        return ToolApprovalRequest(
            toolName: name,
            title: approvalTitle(for: name),
            message: runtimePolicy.approvalMessage(
                for: name,
                resolvedPaths: resolvedPaths,
                workspaceRoot: projectRoot.path,
                summary: approvalSummary(for: name, input: input)
            ),
            intentDescription: approvalIntentDescription(for: name, input: input, resolvedPaths: resolvedPaths),
            actionPreview: approvalActionPreview(for: name, input: input, resolvedPaths: resolvedPaths)
        )
    }

    private func approvalPaths(for name: String, input: [String: Any]) -> [String] {
        guard let tool = StudioToolName(normalizing: name) else { return [] }
        switch tool {
        case .fileRead, .fileWrite, .filePatch:
            guard let path = input["path"] as? String else { return [] }
            return [sandbox.resolvedURL(for: path).path]
        case .listFiles:
            if let path = input["path"] as? String, !path.isEmpty {
                return [sandbox.resolvedURL(for: path).path]
            }
            return [projectRoot.path]
        default:
            return []
        }
    }

    private func approvalTitle(for name: String) -> String {
        guard let tool = StudioToolName(normalizing: name) else {
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
        switch tool {
        case .deployToTestFlight:    return "Deploy to TestFlight"
        case .delegateToWorktree:    return "Start Background Worktree"
        case .terminal:              return "Run Terminal Command"
        case .fileWrite:             return "Write File"
        case .filePatch:             return "Patch File"
        case .fileRead:              return "Read File"
        case .listFiles:             return "List Files"
        default:                     return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func approvalSummary(for name: String, input: [String: Any]) -> String? {
        guard let tool = StudioToolName(normalizing: name) else { return nil }
        switch tool {
        case .deployToTestFlight:
            let lane = ((input["lane"] as? String) ?? "beta").trimmingCharacters(in: .whitespacesAndNewlines)
            return "This will run the Fastlane lane '\(lane.isEmpty ? "beta" : lane)' and can upload a build to App Store Connect."
        case .delegateToWorktree:
            let branch = ((input["branch_name"] as? String) ?? "new background branch").trimmingCharacters(in: .whitespacesAndNewlines)
            return "This will create an isolated git worktree and start a detached background job on branch '\(branch)'."
        case .terminal:
            return "This will execute a shell command in the current workspace context."
        case .fileWrite, .filePatch:
            return "This will modify files in the current workspace."
        case .fileRead, .listFiles:
            return "This will inspect files using the current access scope."
        default:
            return nil
        }
    }

    private func approvalIntentDescription(for name: String, input: [String: Any], resolvedPaths: [String]) -> String {
        guard let tool = StudioToolName(normalizing: name) else { return "Run this tool action." }
        switch tool {
        case .deployToTestFlight:
            let lane = fastlaneLaneName(from: input)
            return "Build the app and upload a TestFlight build using the Fastlane lane '\(lane)'."
        case .delegateToWorktree:
            let branch = ((input["branch_name"] as? String) ?? "new background branch").trimmingCharacters(in: .whitespacesAndNewlines)
            return "Create an isolated git worktree on branch '\(branch)' and start a detached background job."
        case .terminal:
            return humanReadableTerminalIntent(from: input)
        case .fileWrite:
            return "Create or fully overwrite a file."
        case .filePatch:
            return "Apply an in-place edit to an existing file."
        case .fileRead:
            let target = resolvedPaths.first ?? "the selected file"
            return "Read the contents of \(target)."
        case .listFiles:
            let target = resolvedPaths.first ?? "the selected directory"
            return "Inspect the contents of \(target)."
        default:
            return "Run this tool action."
        }
    }

    private func approvalActionPreview(for name: String, input: [String: Any], resolvedPaths: [String]) -> String? {
        guard let tool = StudioToolName(normalizing: name) else { return nil }
        switch tool {
        case .deployToTestFlight:
            let lane = fastlaneLaneName(from: input)
            return "bundle exec fastlane \(lane)  or  fastlane \(lane)"
        case .delegateToWorktree:
            let branch = ((input["branch_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = ((input["task_prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPrompt = prompt.isEmpty ? nil : String(prompt.prefix(180))
            if let trimmedPrompt, !branch.isEmpty {
                return "Branch: \(branch)\nTask: \(trimmedPrompt)"
            }
            if !branch.isEmpty {
                return "Branch: \(branch)"
            }
            return trimmedPrompt
        case .terminal:
            let startingCommand = ((input["starting_command"] as? String) ?? (input["command"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let objective = ((input["objective"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !startingCommand.isEmpty {
                return startingCommand
            }
            return objective.isEmpty ? nil : String(objective.prefix(180))
        case .fileRead, .fileWrite, .filePatch, .listFiles:
            return resolvedPaths.first
        default:
            return nil
        }
    }

    private func fastlaneLaneName(from input: [String: Any]) -> String {
        let lane = ((input["lane"] as? String) ?? "beta").trimmingCharacters(in: .whitespacesAndNewlines)
        return lane.isEmpty ? "beta" : lane
    }

    private func humanReadableTerminalIntent(from input: [String: Any]) -> String {
        let objective = ((input["objective"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let startingCommand = ((input["starting_command"] as? String) ?? (input["command"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommand = startingCommand.lowercased()
        let normalizedObjective = objective.lowercased()

        if normalizedCommand.contains("xcodebuild") {
            return "Build the Xcode project and surface compiler, linker, or signing failures."
        }
        if normalizedCommand.contains("swift test")
            || normalizedCommand.contains("xcodebuild test")
            || normalizedCommand.contains("pytest")
            || normalizedCommand.contains("npm test")
            || normalizedCommand.contains("pnpm test")
            || normalizedCommand.contains("yarn test")
            || normalizedCommand.contains("cargo test") {
            return "Run the test suite and report failures."
        }
        if normalizedCommand.contains("git status") {
            return "Check the git working tree state."
        }
        if normalizedCommand.contains("git diff") {
            return "Inspect the current code changes."
        }
        if normalizedCommand.contains("rg ") || normalizedCommand.hasPrefix("rg") || normalizedCommand.contains("grep ") {
            return "Search the workspace for matching code or text."
        }
        if normalizedCommand.contains("find ") || normalizedCommand.hasPrefix("ls") {
            return "Inspect files in the workspace."
        }
        if normalizedCommand.contains("fastlane") {
            return "Run a Fastlane lane that may build, sign, or ship the app."
        }
        if normalizedCommand.contains("open ") {
            return "Open a local app, file, or preview on the Mac."
        }
        if !objective.isEmpty {
            return objective.prefix(1).uppercased() + objective.dropFirst()
        }
        if !startingCommand.isEmpty {
            return "Run a shell command in the current workspace."
        }
        if normalizedObjective.contains("build") {
            return "Build the project and report the result."
        }
        if normalizedObjective.contains("test") {
            return "Run tests and report the result."
        }
        return "Run a shell command in the current workspace."
    }


    func executeFileRead(_ input: [String: Any]) -> (String, Bool) {
        guard let path = input["path"] as? String else { return ("Missing: path", true) }
        let url = sandbox.resolvedURL(for: path)
        guard sandbox.check(url) else { return ("Access denied: outside project directory", true) }
        guard FileManager.default.fileExists(atPath: url.path) else { return ("File not found: \(url.path)", true) }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return ("Cannot read file", true) }
        if content.count > 100_000 {
            return (String(content.prefix(100_000)) + "\n\n[Truncated at 100K chars]", false)
        }
        return (content, false)
    }

    func executeFileWrite(_ input: [String: Any]) -> (String, Bool) {
        guard let path = input["path"] as? String,
              let content = input["content"] as? String else { return ("Missing: path, content", true) }
        let url = sandbox.resolvedURL(for: path)
        guard sandbox.check(url) else { return ("Access denied: outside project directory", true) }
        let dir = url.deletingLastPathComponent()
        let addedLines = lineHeuristic(for: content)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ("Written: \(url.path) (+\(addedLines) -0 heuristic lines, \(content.count) chars)", false)
        } catch {
            return ("Write failed: \(error.localizedDescription)", true)
        }
    }

    func executeFilePatch(_ input: [String: Any]) -> (String, Bool) {
        guard let path = input["path"] as? String,
              let oldString = input["old_string"] as? String,
              let newString = input["new_string"] as? String else { return ("Missing: path, old_string, new_string", true) }
        let url = sandbox.resolvedURL(for: path)
        guard sandbox.check(url) else { return ("Access denied: outside project directory", true) }
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return ("Cannot read file", true) }
        let occurrences = content.components(separatedBy: oldString).count - 1
        guard occurrences == 1 else { return ("old_string matched \(occurrences) times (expected 1)", true) }
        content = content.replacingOccurrences(of: oldString, with: newString)
        let removedLines = lineHeuristic(for: oldString)
        let addedLines = lineHeuristic(for: newString)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ("Patched: \(url.path) (+\(addedLines) -\(removedLines) heuristic lines)", false)
        } catch {
            return ("Patch failed: \(error.localizedDescription)", true)
        }
    }

    func executeListFiles(_ input: [String: Any]) -> (String, Bool) {
        let pathStr = input["path"] as? String
        let url = pathStr.map { sandbox.resolvedURL(for: $0) } ?? projectRoot
        guard sandbox.check(url) else { return ("Access denied: outside project directory", true) }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return ("Not a directory: \(url.path)", true)
        }
        guard let items = try? fm.contentsOfDirectory(atPath: url.path).sorted() else {
            return ("Cannot list directory", true)
        }
        let lines = items.map { name -> String in
            var childIsDir: ObjCBool = false
            fm.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &childIsDir)
            return childIsDir.boolValue ? "\(name)/" : name
        }
        return (lines.joined(separator: "\n"), false)
    }

    func executeDelegateToExplorer(_ input: [String: Any]) async -> ToolExecutionOutcome {
        guard let objective = (input["objective"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !objective.isEmpty else {
            return ToolExecutionOutcome(text: "Missing: objective", isError: true)
        }

        let targetDirectories = stringArray(from: input["target_directories"])
        let guardrails = SubagentGuardrails.forSubagent(parentSandbox: sandbox)

        let outcome = await HandoffExecutor.runExplorer(
            objective: objective,
            targetDirectories: targetDirectories,
            projectRoot: projectRoot,
            model: StudioModelStrategy.descriptor(for: .subagent, packageRoot: projectRoot.path),
            guardrails: guardrails,
            memoryContext: subagentMemoryContext,
            runner: { [weak self] system, prompt, model, tools, maxIter, maxTok, handler in
                guard let self else { throw AgenticBridgeError.missingAPIKey }
                return try await self.runSubAgent(
                    system: system, prompt: prompt, model: model,
                    tools: tools, maxIterations: maxIter, maxTokens: maxTok,
                    toolHandler: handler
                )
            },
            toolHandler: { [weak self] (name: String, input: [String: Any]) -> ToolExecutionOutcome in
                guard let self else {
                    return ToolExecutionOutcome(text: "Explorer tool handler unavailable.", isError: true)
                }
                return await self.executeSubagentTool(name: name, input: input)
            }
        )

        return toolExecutionOutcome(from: outcome, displayPrefix: "Workspace Explorer")
    }

    func executeDelegateToReviewer(_ input: [String: Any]) async -> ToolExecutionOutcome {
        let filesToReview = stringArray(from: input["files_to_review"])
        guard !filesToReview.isEmpty else {
            return ToolExecutionOutcome(text: "Missing: files_to_review", isError: true)
        }
        guard let focusArea = (input["focus_area"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !focusArea.isEmpty else {
            return ToolExecutionOutcome(text: "Missing: focus_area", isError: true)
        }

        let guardrails = SubagentGuardrails.forSubagent(parentSandbox: sandbox)

        let outcome = await HandoffExecutor.runReviewer(
            filesToReview: filesToReview,
            focusArea: focusArea,
            model: StudioModelStrategy.descriptor(for: .review, packageRoot: projectRoot.path),
            guardrails: guardrails,
            memoryContext: subagentMemoryContext,
            runner: { [weak self] system, prompt, model, tools, maxIter, maxTok, handler in
                guard let self else { throw AgenticBridgeError.missingAPIKey }
                return try await self.runSubAgent(
                    system: system, prompt: prompt, model: model,
                    tools: tools, maxIterations: maxIter, maxTokens: maxTok,
                    toolHandler: handler
                )
            },
            toolHandler: { [weak self] (name: String, input: [String: Any]) -> ToolExecutionOutcome in
                guard let self else {
                    return ToolExecutionOutcome(text: "Reviewer tool handler unavailable.", isError: true)
                }
                return await self.executeSubagentTool(name: name, input: input)
            }
        )

        return toolExecutionOutcome(from: outcome, displayPrefix: "Code Reviewer")
    }

    func executeDelegateToWorktree(_ input: [String: Any]) async -> ToolExecutionOutcome {
        guard let branchName = (input["branch_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !branchName.isEmpty else {
            return ToolExecutionOutcome(text: "Missing: branch_name", isError: true)
        }
        guard let taskPrompt = (input["task_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !taskPrompt.isEmpty else {
            return ToolExecutionOutcome(text: "Missing: task_prompt", isError: true)
        }

        do {
            let session = try await BackgroundJobRunner.shared.delegateToWorktree(
                workspaceURL: projectRoot,
                branchName: branchName,
                targetDirectoryName: (input["target_directory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                taskPrompt: taskPrompt,
                anthropicAPIKey: anthropicAPIKey,
                openAIKey: openAIKey
            )

            let payload = """
            Started background worktree job.
            Session: \(session.id.uuidString)
            Branch: \(session.branchName)
            Worktree: \(session.worktreePath)
            Model: \(session.modelDisplayName)
            """

            return ToolExecutionOutcome(
                displayText: "Background worktree job started.",
                toolResultPayload: payload,
                isError: false
            )
        } catch {
            return ToolExecutionOutcome(
                text: "Failed to create background worktree job: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    func executeTerminal(
        _ input: [String: Any],
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async -> (String, Bool) {
        let objective = ((input["objective"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let context = ((input["context"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let startingCommand = ((input["starting_command"] as? String) ?? (input["command"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutSec = min(max(input["timeout"] as? Int ?? 30, 1), 120)

        let effectiveObjective: String
        if !objective.isEmpty {
            effectiveObjective = objective
        } else if !startingCommand.isEmpty {
            effectiveObjective = "Run this terminal task and report the result: \(startingCommand)"
        } else {
            return ("Missing: objective", true)
        }

        if let openAIKey, !openAIKey.isEmpty {
            let coordinator = CodexTerminalCoordinator(
                apiKey: openAIKey,
                projectRoot: projectRoot
            )

            do {
                return try await coordinator.run(
                    objective: effectiveObjective,
                    context: context.isEmpty ? nil : context,
                    startingCommand: startingCommand.isEmpty ? nil : startingCommand,
                    timeoutSeconds: timeoutSec,
                    progress: progress
                )
            } catch {
                if !startingCommand.isEmpty {
                    progress(.output("[ERROR] OpenAI terminal executor failed. Falling back to direct terminal execution."))
                    return await executeDirectTerminalCommand(
                        startingCommand,
                        timeoutSeconds: timeoutSec,
                        progress: progress
                    )
                }
                return ("Terminal executor failed: \(error.localizedDescription)", true)
            }
        }

        guard !startingCommand.isEmpty else {
            return ("Terminal executor unavailable: configure OPENAI_API_KEY for Codex shell handling.", true)
        }

        progress(.output("[ERROR] OPENAI_API_KEY not configured. Using direct terminal fallback."))
        return await executeDirectTerminalCommand(
            startingCommand,
            timeoutSeconds: timeoutSec,
            progress: progress
        )
    }

    func executeWebSearch(_ input: [String: Any]) async -> ToolExecutionOutcome {
        guard let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return ToolExecutionOutcome(text: "Missing: query", isError: true)
        }

        do {
            let result = try await runResearcher(query: query)
            defer { try? FileManager.default.removeItem(at: result.outputDir) }
            let stderrDetails = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let contextPack = Self.readContextPack(from: result.outputDir).trimmingCharacters(in: .whitespacesAndNewlines)
            let searchResultPayloads = Self.readContextPackResults(from: result.outputDir).compactMap { result -> [String: Any]? in
                let source = result.url.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty, !title.isEmpty, !snippet.isEmpty else { return nil }
                return [
                    "type": "search_result",
                    "source": source,
                    "title": title,
                    "content": [
                        [
                            "type": "text",
                            "text": snippet
                        ]
                    ],
                    "citations": [
                        "enabled": true
                    ]
                ]
            }

            if result.exitCode != 0 {
                let message = "Web search failed with exit code \(result.exitCode)."
                if stderrDetails.isEmpty {
                    return ToolExecutionOutcome(text: message, isError: true)
                }
                return ToolExecutionOutcome(text: "\(message)\n\n\(stderrDetails)", isError: true)
            }

            if !searchResultPayloads.isEmpty || !contextPack.isEmpty {
                var contentBlocks: [[String: Any]] = []
                if !contextPack.isEmpty {
                    contentBlocks.append([
                        "type": "text",
                        "text": contextPack
                    ])
                }
                contentBlocks.append(contentsOf: searchResultPayloads)
                let summary = searchResultPayloads.isEmpty
                    ? "Web search context pack built."
                    : "Web search returned \(searchResultPayloads.count) grounded results."
                return ToolExecutionOutcome(
                    displayText: summary,
                    toolResultPayload: contentBlocks,
                    isError: false
                )
            }

            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stdout.isEmpty {
                var message = "Web search completed without usable results."
                if !stdout.isEmpty {
                    message += "\n\n\(stdout)"
                }
                if !stderrDetails.isEmpty {
                    message += "\n\n\(stderrDetails)"
                }
                return ToolExecutionOutcome(text: message, isError: true)
            }

            if !stderrDetails.isEmpty {
                return ToolExecutionOutcome(text: "Web search completed without usable results.\n\n\(stderrDetails)", isError: true)
            }

            return ToolExecutionOutcome(text: "Web search completed without usable results.", isError: true)
        } catch {
            return ToolExecutionOutcome(text: "Web search failed: \(error.localizedDescription)", isError: true)
        }
    }

    func executeDeployToTestFlight(
        _ input: [String: Any],
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async -> (String, Bool) {
        let lane = ((input["lane"] as? String) ?? "beta")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLane = lane.isEmpty ? "beta" : lane
        let command = """
        if [ -f Gemfile ] && command -v bundle >/dev/null 2>&1; then
          bundle exec fastlane \(effectiveLane)
        else
          fastlane \(effectiveLane)
        fi
        """
        .trimmingCharacters(in: .whitespacesAndNewlines)

        progress(.command("fastlane \(effectiveLane)"))
        return await FastlaneDeploymentRunner.shared.run(
            projectRoot: projectRoot,
            lane: effectiveLane,
            command: command,
            progress: progress
        )
    }

    func executeDirectTerminalCommand(
        _ command: String,
        timeoutSeconds: Int,
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async -> (String, Bool) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Missing: command", true) }
        let commandID = UUID().uuidString

        await primePersistentShellToProjectRoot()
        progress(.command(trimmed))
        progress(.output("$ \(trimmed)"))
        SimulatorShellCommandNotifier.commandDidStart(
            id: commandID,
            command: trimmed,
            projectRoot: projectRoot.path
        )

        let execution = await collectShellExecution(
            command: trimmed,
            timeoutSeconds: timeoutSeconds,
            progress: progress
        )
        SimulatorShellCommandNotifier.commandDidFinish(
            id: commandID,
            command: trimmed,
            projectRoot: projectRoot.path,
            output: execution.output,
            exitStatus: Int32(execution.exitStatus)
        )

        return (
            Self.formattedShellToolResult(
                command: trimmed,
                output: execution.output,
                exitStatus: execution.exitStatus,
                didTimeout: execution.didTimeout
            ),
            execution.didTimeout || execution.exitStatus != 0
        )
    }

    // MARK: - Terminal with Recovery

    func executeTerminalWithRecovery(
        name: String,
        input: [String: Any],
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async -> ToolExecutionOutcome {
        let (result, isError) = await executeTerminal(input, progress: progress)

        guard isError else {
            return ToolExecutionOutcome(text: result, isError: false)
        }

        // Classify the failure.
        let timeoutSec = min(max(input["timeout"] as? Int ?? 30, 1), 120)
        let toolError: ToolError
        if result.contains("[timed out after") || result.contains("[terminated after") {
            toolError = .timeout(tool: name, elapsed: TimeInterval(timeoutSec))
        } else {
            let exitCode = Self.extractExitCode(from: result) ?? 1
            toolError = .executionFailed(tool: name, stderr: result, exitCode: exitCode)
        }

        let recoveryResult = await recovery.attemptRecovery(for: toolError) { [weak self] in
            guard let self else { return nil }
            return await self.executeTerminal(input, progress: progress)
        }

        return ToolExecutionOutcome(text: recoveryResult.displayText, isError: recoveryResult.isError)
    }

    static func extractExitCode(from output: String) -> Int32? {
        // Match "[exit code: N]" or "[Exit status: N]"
        guard let range = output.range(of: "[exit code: ", options: [.backwards, .caseInsensitive])
                       ?? output.range(of: "[Exit status: ", options: .backwards) else { return nil }
        let rest = output[range.upperBound...]
        guard let endBracket = rest.firstIndex(of: "]") else { return nil }
        return Int32(rest[..<endBracket])
    }


    func executeSubagentTool(
        name: String,
        input: [String: Any]
    ) async -> ToolExecutionOutcome {
        let subagentPermissions = ToolPermissionPolicy()
        if case .blocked(let reason) = subagentPermissions.check(name) {
            return ToolExecutionOutcome(text: reason, isError: true)
        }
        switch name {
        case "file_read":
            let raw = executeFileRead(input)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case "list_files":
            let raw = executeListFiles(input)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case "web_search":
            return await executeWebSearch(input)
        default:
            return ToolExecutionOutcome(text: "Sub-agent tool unavailable: \(name)", isError: true)
        }
    }

    func stringArray(from value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Convert a typed HandoffOutcome into the ToolExecutionOutcome the orchestrator expects.
    func toolExecutionOutcome(from handoff: HandoffOutcome, displayPrefix: String) -> ToolExecutionOutcome {
        switch handoff {
        case .completed(let result):
            let filesNote = result.filesExamined.isEmpty
                ? ""
                : " (\(result.filesExamined.count) files examined)"
            return ToolExecutionOutcome(
                displayText: "\(displayPrefix) returned findings.\(filesNote)",
                toolResultPayload: result.summary,
                isError: false
            )
        case .escalated(let reason, let result):
            let filesNote = result.filesExamined.isEmpty
                ? ""
                : " (\(result.filesExamined.count) files examined)"
            return ToolExecutionOutcome(
                displayText: "\(displayPrefix) escalated: \(reason).\(filesNote)",
                toolResultPayload: result.summary,
                isError: false
            )
        case .failed(let error):
            return ToolExecutionOutcome(text: "\(displayPrefix) failed: \(error)", isError: true)
        }
    }

    func summarizeSubAgentText(from blocks: [[String: Any]]) -> String {
        let fragments = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }

        if fragments.isEmpty {
            return "Sub-agent completed without a textual summary."
        }

        return fragments.joined(separator: "\n\n")
    }

    func subAgentToolUses(from blocks: [[String: Any]]) -> [(id: String, name: String, input: [String: Any])] {
        blocks.compactMap { block in
            guard (block["type"] as? String) == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String,
                  let input = block["input"] as? [String: Any] else {
                return nil
            }
            return (id: id, name: name, input: input)
        }
    }

    func primePersistentShellToProjectRoot() async {
        let bootstrapCommand = "cd \(Self.shellQuoted(projectRoot.path))"
        let stream = await StatefulTerminalEngine.shared.execute(bootstrapCommand)
        for await _ in stream {}
    }

    func collectShellExecution(
        command: String,
        timeoutSeconds: Int,
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async -> ShellExecutionCapture {
        let stream = await StatefulTerminalEngine.shared.execute(command)
        let lifecycle = ShellCommandLifecycle()

        let consumer = Task<[String], Never> {
            var lines: [String] = []
            for await line in stream {
                progress(.output(line))
                lines.append(line)
            }
            await lifecycle.markFinished()
            return lines
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            if !(await lifecycle.isFinished()) {
                await lifecycle.markTimedOut()
                await StatefulTerminalEngine.shared.interruptActiveCommand()
            }
        }

        let lines = await consumer.value
        timeoutTask.cancel()

        return ShellExecutionCapture(
            output: lines.joined(separator: "\n"),
            exitStatus: await StatefulTerminalEngine.shared.lastExitStatus() ?? 0,
            didTimeout: await lifecycle.didTimeout()
        )
    }

    func resolvedURL(for path: String) -> URL {
        sandbox.resolvedURL(for: path)
    }

    func sandboxCheck(_ url: URL) -> Bool {
        sandbox.check(url)
    }

    func lineHeuristic(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }


    func runResearcher(query: String) async throws -> (exitCode: Int32, stdout: String, stderr: String, outputDir: URL) {
        final class ResearcherOutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var stdout = Data()
            private var stderr = Data()

            func appendStdout(_ data: Data) {
                lock.lock()
                stdout.append(data)
                lock.unlock()
            }

            func appendStderr(_ data: Data) {
                lock.lock()
                stderr.append(data)
                lock.unlock()
            }

            func snapshot(stdoutTail: Data, stderrTail: Data) -> (stdout: String, stderr: String) {
                lock.lock()
                stdout.append(stdoutTail)
                stderr.append(stderrTail)
                let stdoutString = String(decoding: stdout, as: UTF8.self)
                let stderrString = String(decoding: stderr, as: UTF8.self)
                lock.unlock()
                return (stdoutString, stderrString)
            }
        }

        final class ResearcherRunState: @unchecked Sendable {
            private let lock = NSLock()
            private var didResume = false
            private var didTimeout = false

            func markTimedOut() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return false }
                didTimeout = true
                return true
            }

            func finish(_ body: (Bool) -> Void) {
                lock.lock()
                guard !didResume else {
                    lock.unlock()
                    return
                }
                didResume = true
                let timedOut = didTimeout
                lock.unlock()
                body(timedOut)
            }
        }

        let openAIKey = self.openAIKey

        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("researcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(exitCode: Int32, stdout: String, stderr: String, outputDir: URL), Error>) in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let outputBuffer = ResearcherOutputBuffer()
            let runState = ResearcherRunState()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "Factory/researcher.py", query]
            process.currentDirectoryURL = projectRoot
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var environment = ProcessInfo.processInfo.environment
            if let openAIKey, !openAIKey.isEmpty {
                environment["OPENAI_API_KEY"] = openAIKey
            }
            environment["RESEARCHER_OUTPUT_DIR"] = outputDir.path
            process.environment = environment

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outputBuffer.appendStdout(data)
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outputBuffer.appendStderr(data)
            }

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(60))
                guard runState.markTimedOut(), process.isRunning else { return }

                process.terminate()

                try? await Task.sleep(for: .seconds(5))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }

            process.terminationHandler = { process in
                timeoutTask.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let output = outputBuffer.snapshot(
                    stdoutTail: stdoutTail,
                    stderrTail: stderrTail
                )

                runState.finish { didTimeout in
                    continuation.resume(
                        returning: (
                            exitCode: didTimeout ? -1 : process.terminationStatus,
                            stdout: output.stdout,
                            stderr: output.stderr,
                            outputDir: outputDir
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                runState.finish { _ in
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func readContextPack(from directory: URL) -> String {
        let url = directory.appendingPathComponent("context_pack.txt")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func readContextPackResults(from directory: URL) -> [ResearcherSearchResult] {
        let url = directory.appendingPathComponent("context_pack_results.json")
        guard let data = FileManager.default.contents(atPath: url.path),
              let results = try? JSONDecoder().decode([ResearcherSearchResult].self, from: data) else {
            return []
        }
        return results
    }

    static func formattedShellToolResult(
        command: String,
        output: String,
        exitStatus: Int,
        didTimeout: Bool
    ) -> String {
        // Try structured extraction for build/test commands
        if let report = BuildReportBuilder.build(command: command, output: output, exitStatus: exitStatus) {
            return BuildReportFormatter.formattedToolResult(
                command: command,
                report: report,
                rawOutput: output,
                exitStatus: exitStatus,
                didTimeout: didTimeout
            )
        }

        // Fallback: raw output for non-build commands
        var sections = ["Command: \(command)"]
        sections.append("Exit status: \(exitStatus)")
        if didTimeout {
            sections.append("Timed out: true")
        }

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.isEmpty {
            sections.append("Output:\n(no output)")
        } else if trimmedOutput.count > 20_000 {
            sections.append("Output:\n\(trimmedOutput.prefix(20_000))\n[Truncated]")
        } else {
            sections.append("Output:\n\(trimmedOutput)")
        }

        return sections.joined(separator: "\n\n")
    }

    static func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }


}
