// HandoffExecutor.swift
// Studio.92 — Agent Council
// Single entry point for typed agent-to-agent delegation.
// Wraps SubAgentManager with HandoffContext, tracks files examined,
// and returns structured HandoffOutcome instead of raw strings.
//
// NOTE: The Explorer and Reviewer prompts in this file have a mirror in
// CommandCenter/HandoffExecutor.swift. Keep both in sync, or resolve by
// making CommandCenter import AgentCouncil (Phase 2).

import Foundation

public actor HandoffExecutor {

    private let projectRoot: URL
    private let context: HandoffContext

    public init(projectRoot: URL, context: HandoffContext) {
        self.projectRoot = projectRoot
        self.context = context
    }

    // MARK: - Explorer

    public func runExplorer(
        objective: String,
        targetDirectories: [String],
        model: ClaudeModel,
        toolHandler: @escaping @Sendable (String, [String: AnyCodableValue]) async -> ToolExecutionOutcome
    ) async -> HandoffOutcome {
        let userPrompt = Self.explorerPrompt(objective: objective, targetDirectories: targetDirectories, projectRoot: projectRoot)

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let isoDate = formatter.string(from: Date())
        let timeZone = TimeZone.current.identifier

        return await runSubagent(
            systemPrompt: """
            You are Workspace Explorer, a focused read-only codebase scout.
            The current date is \(isoDate). The local time zone is \(timeZone).
            Workspace root: \(projectRoot.path)

            RULES
            - Stay read-only. Never propose patches, write files, or modify any state.
            - Be thorough — read as many files as needed to fully answer the objective.
            - Ground every claim in what you actually read. Do not speculate.
            - If the objective depends on Apple SDK behavior, library versions, or external facts, use web_search to verify.

            EXECUTION ORDER
            1. list_files on each target directory first.
            2. file_read the most relevant files to the objective.
            3. web_search only when external context is required and cannot be inferred from local files.
            4. Build your summary from grounded findings only.

            OUTPUT
            - One structured summary: key structure, data flow, mismatches, and risks relevant to the objective.
            - Do not dump raw file content or transcripts.
            - Do not ask follow-up questions.

            ESCALATION
            If the task requires cross-cutting architectural judgment across many subsystems, say so clearly at the top of your summary and recommend that the parent agent escalate to a deeper analysis. Do not pretend to have certainty you don't have.
            """,
            userPrompt: userPrompt,
            model: model,
            tools: [AgentTools.fileRead, AgentTools.listFiles, AgentTools.webSearch],
            toolHandler: toolHandler
        )
    }

    // MARK: - Reviewer

    public func runReviewer(
        filesToReview: [String],
        focusArea: String,
        model: ClaudeModel,
        toolHandler: @escaping @Sendable (String, [String: AnyCodableValue]) async -> ToolExecutionOutcome
    ) async -> HandoffOutcome {
        let userPrompt = Self.reviewerPrompt(filesToReview: filesToReview, focusArea: focusArea)

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let isoDate = formatter.string(from: Date())
        let timeZone = TimeZone.current.identifier

        return await runSubagent(
            systemPrompt: """
            You are Studio.92 Code Reviewer, a senior Apple-platform engineer conducting a focused audit.

            PRIMARY GOAL
            Read the provided files through the requested focus area. Surface real findings — bugs, correctness issues, concurrency hazards, API misuse, performance risks, and architectural concerns. Describe what you find and how to fix it in plain language. Do NOT include code blocks, patches, or code fences in your response. Skip nitpicks and style preferences unless they cause real problems.

            REVIEW STANDARDS
            - Ground findings in what the code actually does, not what you assume it should do.
            - Do not restate what the code is doing unless it directly supports a finding.
            - Describe fixes in natural language (e.g. "wrap the mutation in a MainActor.run block", "replace the forced unwrap with a guard-let"). No code blocks.
            - Distinguish between 🔴 "this is broken" and 🟠 "this is risky" — be clear about severity.
            - If you are not confident in a finding, mark it as "⚠️ Needs Verification". Do not present uncertain claims as facts.
            - Check nearby files for context before concluding something is missing or misused.
            - When reviewing SwiftUI, pay attention to identity, state ownership (`@Observable` vs `@State` vs `@StateObject`), animation correctness, `.task` modifier lifetime and cancellation, and view lifecycle.
            - When reviewing concurrency, check actor isolation, `Sendable` conformance, Swift 6 data-race safety, and whether async task captures are properly bounded.
            - When you see a clear improvement — a simpler approach, a removed footgun, a better pattern — propose it.
            - If there are more than 5 findings, prioritize the highest impact ones.
            - If the code is solid, say so and stop. Do not invent issues to fill space.

            OUTPUT FORMAT
            Write your audit as clean, readable prose. Use emojis for severity and section headers.
            1. 📋 Verdict (1–2 sentences)
            2. 🔴 Critical Issues (if any)
            3. 🟠 High-Risk Issues
            4. 🟡 Medium Issues (optional)
            5. 💡 Improvements (optional)

            Each finding: a short title, severity emoji, why it matters, where it is (file + function name), and what to do about it — all in natural language. No code fences.

            APPLE PLATFORM AWARENESS
            - Current Apple-first patterns: SwiftUI, `@Observable` macro (iOS 17+/macOS 14+), Swift concurrency (async/await, actors, Swift 6 strict concurrency), SwiftData, SwiftTesting, and native platform APIs.
            - Flag deprecated API usage (e.g. `@ObservableObject` where `@Observable` applies, old `XCTest` patterns where SwiftTesting is available), missing privacy declarations, and signing/entitlement gaps when relevant to the focus area.

            WEB RESEARCH RULE
            The current local date is \(isoDate). The local time zone is \(timeZone).
            If a finding depends on recent SDK changes, deprecations, or platform behavior you're unsure about, use web_search to verify before reporting it.

            TOOLS
            Use file_read to inspect target files, list_files to check surrounding context, terminal to run builds or tests when verification strengthens a finding, and web_search to verify anything you're not certain about. Use file_write or file_patch when you have a concrete fix worth applying.

            VOICE
            Talk like yourself. Be direct, be technical, be honest. If something is wrong, say it's wrong. If something is fine, don't manufacture concerns to fill space. No code in the response.

            WORKSPACE
            Primary workspace root: \(projectRoot.path)
            """,
            userPrompt: userPrompt,
            model: model,
            tools: [AgentTools.fileRead, AgentTools.fileWrite, AgentTools.filePatch, AgentTools.listFiles, AgentTools.webSearch],
            toolHandler: toolHandler
        )
    }

    // MARK: - Core Runner

    private func runSubagent(
        systemPrompt: String,
        userPrompt: String,
        model: ClaudeModel,
        tools: [ToolDefinition],
        toolHandler: @escaping @Sendable (String, [String: AnyCodableValue]) async -> ToolExecutionOutcome
    ) async -> HandoffOutcome {
        let filesExamined = FileTracker()

        do {
            let client: ClaudeAPIClient
            if let apiKey = context.apiKey {
                client = try ClaudeAPIClient(apiKey: apiKey)
            } else {
                client = try ClaudeAPIClient()
            }
            let manager = SubAgentManager(
                client: client,
                tracer: context.tracer,
                parentSpanID: context.parentSpanID
            )

            let trackingHandler: @Sendable (String, [String: AnyCodableValue]) async -> ToolExecutionOutcome = { name, input in
                // Track files examined
                if name == "file_read", let path = input["path"]?.stringValue {
                    await filesExamined.add(path)
                }
                // Enforce subagent guardrails
                if case .blocked(let reason) = self.context.guardrails.permissions.check(name) {
                    return ToolExecutionOutcome(text: reason, isError: true)
                }
                return await toolHandler(name, input)
            }

            let result = try await manager.run(
                spec: .init(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: model,
                    tools: tools
                ),
                toolHandler: trackingHandler
            )

            let iterationLimit = result.summary == "Sub-agent reached its iteration limit before producing a final summary."
            let examined = await filesExamined.all()
            let traceID = context.tracer != nil ? UUID() : nil

            if iterationLimit {
                return .escalated(
                    reason: "iteration_limit",
                    partialResult: HandoffResult(
                        summary: result.summary,
                        filesExamined: examined,
                        traceID: traceID,
                        iterationCount: result.iterations
                    )
                )
            }

            return .completed(HandoffResult(
                summary: result.summary,
                filesExamined: examined,
                traceID: traceID,
                iterationCount: result.iterations
            ))
        } catch {
            return .failed(error: error.localizedDescription)
        }
    }

    // MARK: - Prompt Construction

    private static func explorerPrompt(objective: String, targetDirectories: [String], projectRoot: URL) -> String {
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

    private static func reviewerPrompt(filesToReview: [String], focusArea: String) -> String {
        let files = filesToReview.map { "- \($0)" }.joined(separator: "\n")
        return """
        Focus area:
        \(focusArea)

        Files to review:
        \(files)
        """
    }
}

// MARK: - File Tracker

/// Thread-safe collector for files a subagent reads during execution.
private actor FileTracker {
    private var paths: [String] = []

    func add(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !paths.contains(trimmed) {
            paths.append(trimmed)
        }
    }

    func all() -> [String] { paths }
}
