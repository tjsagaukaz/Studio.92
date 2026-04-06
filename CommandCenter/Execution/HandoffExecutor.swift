// HandoffExecutor.swift
// Studio.92 — CommandCenter
// Lightweight handoff runner. Wraps a subagent call with file tracking,
// guardrail enforcement, and structured outcome reporting.
//
// NOTE: The Explorer and Reviewer prompts in this file have a mirror in
// Sources/AgentCouncil/Handoffs/HandoffExecutor.swift. Keep both in sync,
// or resolve by making CommandCenter import AgentCouncil (Phase 2).

import Foundation
import AgentCouncil

enum HandoffExecutor {

    /// Signature of the provider-agnostic subagent runner that AgenticClient supplies.
    typealias SubagentRunner = @Sendable (
        _ system: String,
        _ prompt: String,
        _ model: StudioModelDescriptor,
        _ tools: [[String: Any]],
        _ maxIterations: Int,
        _ maxTokens: Int,
        _ toolHandler: (@Sendable (String, [String: Any]) async -> ToolExecutionOutcome)?
    ) async throws -> String

    // MARK: - Explorer

    static func runExplorer(
        objective: String,
        targetDirectories: [String],
        projectRoot: URL,
        model: StudioModelDescriptor,
        guardrails: SubagentGuardrails,
        memoryContext: String? = nil,
        runner: @escaping SubagentRunner,
        toolHandler: @escaping @Sendable (String, [String: Any]) async -> ToolExecutionOutcome
    ) async -> HandoffOutcome {
        let scopedDirectories = targetDirectories.isEmpty
            ? "- \(projectRoot.path)"
            : targetDirectories.map { "- \($0)" }.joined(separator: "\n")

        let userPrompt = """
        Objective:
        \(objective)

        Target directories to inspect first:
        \(scopedDirectories)
        """

        return await runSubagent(
            systemPrompt: """
            You are Workspace Explorer, a fast read-only codebase scout.
            \(memoryContext.map { "\n" + $0 + "\n" } ?? "")
            Rules:
            1. Stay read-only. Never propose patches or write files.
            2. Be thorough. Read as many files as needed to fully answer the objective.

            Execution order:
            1. Start with list_files on the target directories.
            2. Use file_read on the most relevant files identified.
            3. Use web_search only if the objective requires external context.
            4. Build your summary from grounded findings.

            Output:
            - Return a high-density summary of structure, data flow, mismatches, and risks.
            - Do not dump raw file content or transcripts.
            - Do not ask follow-up questions.
            """,
            userPrompt: userPrompt,
            model: model,
            tools: DefaultToolSchemas.explorerTools,
            guardrails: guardrails,
            runner: runner,
            toolHandler: toolHandler
        )
    }

    // MARK: - Reviewer

    static func runReviewer(
        filesToReview: [String],
        focusArea: String,
        model: StudioModelDescriptor,
        guardrails: SubagentGuardrails,
        memoryContext: String? = nil,
        runner: @escaping SubagentRunner,
        toolHandler: @escaping @Sendable (String, [String: Any]) async -> ToolExecutionOutcome
    ) async -> HandoffOutcome {
        let files = filesToReview.map { "- \($0)" }.joined(separator: "\n")
        let userPrompt = """
        Focus area:
        \(focusArea)

        Files to review:
        \(files)
        """

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let isoDate = formatter.string(from: Date())
        let timeZone = TimeZone.current.identifier

        return await runSubagent(
            systemPrompt: """
            You are Studio.92 Code Reviewer, a senior Apple-platform engineer conducting a focused audit.
            \(memoryContext.map { "\n" + $0 + "\n" } ?? "")
            PRIMARY GOAL
            Read the provided files through the requested focus area. Surface real findings — bugs, correctness issues, concurrency hazards, API misuse, performance risks, and architectural concerns. Describe what you find and how to fix it in plain language. Do NOT include code blocks, patches, or code fences in your response. Skip nitpicks and style preferences unless they cause real problems.

            REVIEW STANDARDS
            - Ground findings in what the code actually does, not what you assume it should do.
            - Do not restate what the code is doing unless it directly supports a finding.
            - Describe fixes in natural language (e.g. "wrap the mutation in a MainActor.run block", "replace the forced unwrap with a guard-let"). No code blocks.
            - Distinguish between 🔴 "this is broken" and 🟠 "this is risky" — be clear about severity.
            - If you are not confident in a finding, mark it as "⚠️ Needs Verification". Do not present uncertain claims as facts.
            - Check nearby files for context before concluding something is missing or misused.
            - When reviewing SwiftUI, pay attention to identity, state ownership, animation correctness, and view lifecycle.
            - When reviewing concurrency, check actor isolation, Sendable conformance, and data races.
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
            - Current Apple-first patterns: SwiftUI, Swift concurrency (async/await, actors), SwiftData, and native platform APIs.
            - Flag deprecated API usage, missing privacy declarations, and signing/entitlement gaps when relevant to the focus area.

            WEB RESEARCH RULE
            The current local date is \(isoDate). The local time zone is \(timeZone).
            If a finding depends on recent SDK changes, deprecations, or platform behavior you're unsure about, use web_search to verify before reporting it.

            TOOLS
            Use file_read to inspect target files, list_files to check surrounding context, and web_search to verify anything you're not certain about.

            VOICE
            Talk like yourself. Be direct, be technical, be honest. If something is wrong, say it's wrong. If something is fine, don't manufacture concerns to fill space. No code in the response.

            ESCALATION
            If the audit surfaces issues that require cross-cutting architectural judgment across many subsystems, say so clearly at the top of your summary and recommend that the parent agent escalate to a deeper analysis.
            """,
            userPrompt: userPrompt,
            model: model,
            tools: DefaultToolSchemas.reviewerTools,
            guardrails: guardrails,
            runner: runner,
            toolHandler: toolHandler
        )
    }

    // MARK: - Core Runner

    private static func runSubagent(
        systemPrompt: String,
        userPrompt: String,
        model: StudioModelDescriptor,
        tools: [[String: Any]],
        guardrails: SubagentGuardrails,
        runner: @escaping SubagentRunner,
        toolHandler: @escaping @Sendable (String, [String: Any]) async -> ToolExecutionOutcome
    ) async -> HandoffOutcome {
        let filesExamined = FileTracker()

        let trackingHandler: @Sendable (String, [String: Any]) async -> ToolExecutionOutcome = { name, input in
            if name == "file_read", let path = input["path"] as? String {
                await filesExamined.add(path)
            }
            if case .blocked(let reason) = guardrails.permissions.check(name) {
                return ToolExecutionOutcome(text: reason, isError: true)
            }
            return await toolHandler(name, input)
        }

        do {
            let summary = try await runner(
                systemPrompt, userPrompt, model, tools,
                20,   // maxIterations
                8192, // maxTokens
                trackingHandler
            )

            let examined = await filesExamined.all()

            if summary == "Sub-agent reached its iteration limit before producing a final summary." {
                return .escalated(
                    reason: "iteration_limit",
                    partialResult: HandoffResult(summary: summary, filesExamined: examined, iterationCount: 20)
                )
            }

            return .completed(HandoffResult(summary: summary, filesExamined: examined))
        } catch {
            return .failed(error: error.localizedDescription)
        }
    }
}

// MARK: - File Tracker

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
