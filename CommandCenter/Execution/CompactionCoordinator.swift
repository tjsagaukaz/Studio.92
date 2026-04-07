// CompactionCoordinator.swift
// Studio.92 — CommandCenter
// Manages context window pressure tracking and compaction for long-running sessions.
// Provider-aware: OpenAI uses native /responses/compact, Anthropic uses structured self-summarization.

import Foundation
import Observation
import AgentCouncil

// MARK: - Context Window Definitions

enum ModelContextWindow {
    static func maxTokens(for identifier: String) -> Int {
        let normalized = identifier.lowercased()
        if normalized.contains("gpt-5.4") || normalized.contains("gpt-5") {
            return 1_048_576  // 1M
        }
        if normalized.contains("gpt-4.1") {
            return 1_048_576
        }
        if normalized.contains("gpt-4o") {
            return 128_000
        }
        if normalized.contains("claude-opus") {
            return 200_000
        }
        if normalized.contains("claude-sonnet") {
            return 200_000
        }
        if normalized.contains("claude-haiku") {
            return 200_000
        }
        return 128_000  // Conservative default
    }
}

// MARK: - Compaction State

enum CompactionPhase: Equatable {
    case idle
    case ready           // Soft anticipation at ~65%, internal preparation
    case optimizing      // Active compaction in progress, UI shows "Optimizing My Memory"
    case completed       // Just finished, UI shows "Memory Optimized" divider
}

// MARK: - Structured Summary (Anthropic)

struct CompactionSummary: Codable {
    let goals: [String]
    let decisions: [String]
    let artifacts: [String]
    let preferences: [String]
    let openTasks: [String]

    enum CodingKeys: String, CodingKey {
        case goals, decisions, artifacts, preferences
        case openTasks = "open_tasks"
    }

    func toSyntheticContext() -> String {
        var sections: [String] = []

        if !goals.isEmpty {
            sections.append("Goals:\n" + goals.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !decisions.isEmpty {
            sections.append("Decisions made:\n" + decisions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !artifacts.isEmpty {
            sections.append("Artifacts created/modified:\n" + artifacts.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !preferences.isEmpty {
            sections.append("User preferences (treat as suggestions, not rules):\n" + preferences.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !openTasks.isEmpty {
            sections.append("Open tasks:\n" + openTasks.map { "- \($0)" }.joined(separator: "\n"))
        }

        return "[Session Context — Compacted]\n\n" + sections.joined(separator: "\n\n")
    }
}

// MARK: - Compaction Coordinator

@MainActor
@Observable
final class CompactionCoordinator {

    // MARK: - Observable State

    var phase: CompactionPhase = .idle
    var contextTokensUsed: Int = 0
    var contextTokensMax: Int = 128_000
    var compactionCount: Int = 0

    var contextPressure: Double {
        guard contextTokensMax > 0 else { return 0 }
        return Double(contextTokensUsed) / Double(contextTokensMax)
    }

    // MARK: - Configuration

    /// Threshold at which compaction triggers (default: 0.75).
    var compactionThreshold: Double = 0.75

    /// Soft readiness threshold (default: 0.65).
    var readinessThreshold: Double = 0.65

    /// Number of recent user turns to always retain after compaction.
    var retainedTurnCount: Int = 3

    // MARK: - Internal State

    @ObservationIgnored private var lastCompactedAt: Date?
    @ObservationIgnored private var isPipelineActive = false
    @ObservationIgnored private var isToolLoopActive = false
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var optimizingWatchdog: Task<Void, Never>?

    deinit {
        optimizingWatchdog?.cancel()
    }

    /// Minimum seconds between compaction attempts. Doubles on each consecutive failure.
    private static let baseCooldownSeconds: TimeInterval = 30
    /// Cap the backoff at 10 minutes.
    private static let maxCooldownSeconds: TimeInterval = 600
    /// Maximum time the coordinator may remain in .optimizing before auto-resetting.
    private static let optimizingTimeoutSeconds: TimeInterval = 120

    // MARK: - Model Configuration

    func configureForModel(_ model: StudioModelDescriptor) {
        contextTokensMax = ModelContextWindow.maxTokens(for: model.identifier)
    }

    // MARK: - Token Tracking

    func updateTokenUsage(input: Int, output: Int) {
        contextTokensUsed = input + output
        updatePhaseFromPressure()
    }

    func accumulateUsage(input: Int, output: Int) {
        contextTokensUsed += input + output
        updatePhaseFromPressure()
    }

    // MARK: - Phase Safety

    func setPipelineActive(_ active: Bool) {
        isPipelineActive = active
    }

    func setToolLoopActive(_ active: Bool) {
        isToolLoopActive = active
    }

    var isSafeForCompaction: Bool {
        !isPipelineActive && !isToolLoopActive && phase != .optimizing && !isCoolingDown
    }

    /// Whether the cooldown window is still active after a failure.
    private var isCoolingDown: Bool {
        guard consecutiveFailures > 0, let last = lastCompactedAt else { return false }
        let cooldown = min(
            Self.baseCooldownSeconds * pow(2.0, Double(consecutiveFailures - 1)),
            Self.maxCooldownSeconds
        )
        return Date().timeIntervalSince(last) < cooldown
    }

    /// Call after a successful compaction to reset the circuit breaker.
    func compactionSucceeded() {
        consecutiveFailures = 0
    }

    /// Call after a failed compaction to engage the cooldown backoff.
    func compactionFailed() {
        consecutiveFailures += 1
        lastCompactedAt = Date()
    }

    // MARK: - Compaction Decision

    func shouldCompact() -> Bool {
        contextPressure >= compactionThreshold && isSafeForCompaction
    }

    /// Start a watchdog that auto-resets .optimizing after a timeout to prevent deadlock.
    private func armOptimizingWatchdog() {
        optimizingWatchdog?.cancel()
        optimizingWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.optimizingTimeoutSeconds * 1_000_000_000))
            } catch { return }
            guard let self, self.phase == .optimizing else { return }
            print("[CompactionCoordinator] Optimizing phase timed out after \(Int(Self.optimizingTimeoutSeconds))s — auto-resetting to idle.")
            self.phase = .idle
            self.compactionFailed()
        }
    }

    private func disarmOptimizingWatchdog() {
        optimizingWatchdog?.cancel()
        optimizingWatchdog = nil
    }

    private func updatePhaseFromPressure() {
        guard phase != .optimizing else { return }
        if contextPressure >= compactionThreshold && isSafeForCompaction {
            // Will be triggered by the pipeline at a safe boundary
            phase = .ready
        } else if contextPressure >= readinessThreshold {
            phase = .ready
        } else {
            phase = .idle
        }
    }

    // MARK: - Compaction Execution (OpenAI)

    func compactOpenAI(
        instructions: String,
        inputItems: [Any],
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> CompactedOpenAIResult {
        phase = .optimizing
        armOptimizingWatchdog()
        var didComplete = false
        defer {
            disarmOptimizingWatchdog()
            if !didComplete { phase = .idle; compactionFailed() }
        }

        var body: [String: Any] = [
            "model": model,
            "input": inputItems
        ]
        if !instructions.isEmpty {
            body["instructions"] = instructions
        }

        let url = StudioAPIConfig.openAIBaseURL.appendingPathComponent("v1/responses/compact")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorBody = String(decoding: data, as: UTF8.self)
            throw CompactionError.apiFailed(errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [Any] else {
            throw CompactionError.invalidResponse
        }

        let usage = json["usage"] as? [String: Any]
        let outputTokens = usage?["output_tokens"] as? Int ?? 0

        phase = .completed
        didComplete = true
        compactionCount += 1
        lastCompactedAt = Date()
        compactionSucceeded()

        return CompactedOpenAIResult(
            outputItems: output,
            tokensAfterCompaction: outputTokens
        )
    }

    // MARK: - Compaction Execution (Anthropic — Structured Summarization)

    func compactAnthropic(
        conversationTurns: [ConversationHistoryTurn],
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> CompactedAnthropicResult {
        phase = .optimizing
        armOptimizingWatchdog()
        var didComplete = false
        defer {
            disarmOptimizingWatchdog()
            if !didComplete { phase = .idle; compactionFailed() }
        }

        let turnsToSummarize = Array(conversationTurns.dropLast(retainedTurnCount))
        let retainedTurns = Array(conversationTurns.suffix(retainedTurnCount))

        guard !turnsToSummarize.isEmpty else {
            throw CompactionError.nothingToCompact
        }

        let transcript = turnsToSummarize.map { turn in
            var parts: [String] = []
            if let blocks = turn.contentBlocks {
                for block in blocks {
                    switch block {
                    case .thinking(let text, _):
                        parts.append("[thinking] \(text)")
                    case .text(let text):
                        parts.append(text)
                    }
                }
            } else {
                parts.append(turn.text)
            }
            return "\(turn.role.rawValue): \(parts.joined(separator: "\n"))"
        }.joined(separator: "\n\n")

        let summarizationPrompt = """
        Extract the execution state from this conversation into a structured JSON object.
        Return ONLY the JSON object, no other text.

        Schema:
        {
          "goals": ["active goals the user is working toward — be specific, not generic"],
          "decisions": ["decisions that were made and should be preserved, with enough context to act on them"],
          "artifacts": ["files created or modified — use exact paths as they appear in the conversation, noting status: created/modified"],
          "preferences": ["confirmed user preferences about code style, tooling, or working style — only if explicitly stated, not inferred"],
          "open_tasks": ["tasks that are still pending or in progress — ordered by relevance to current context"]
        }

        Rules:
        - Preserve exact file paths. Do not truncate or paraphrase paths.
        - Only include preferences the user explicitly stated. Do not infer preferences from behavior.
        - Open tasks should reflect actual blocking items, not vague "continue working" entries.
        - Omit empty arrays rather than including them as [].

        Conversation:
        \(transcript)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": "You are a precise conversation state extractor. Output only valid JSON matching the requested schema. Rules: preserve exact file paths as they appear in the conversation; mark artifact completion state (created, modified, or referenced); do not paraphrase user statements as preferences; distinguish open tasks from completed ones; omit empty arrays. Preserve execution state, not narrative.",
            "messages": [
                ["role": "user", "content": summarizationPrompt]
            ]
        ]

        var request = URLRequest(url: StudioAPIConfig.anthropicMessagesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(StudioAPIConfig.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorBody = String(decoding: data, as: UTF8.self)
            throw CompactionError.apiFailed(errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]],
              let textBlock = contentBlocks.first(where: { $0["type"] as? String == "text" }),
              let summaryText = textBlock["text"] as? String else {
            throw CompactionError.invalidResponse
        }

        // Parse structured summary — extract JSON payload robustly.
        let trimmedSummary = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonPayload: String
        if let firstBrace = trimmedSummary.firstIndex(of: "{"),
           let lastBrace = trimmedSummary.lastIndex(of: "}"),
           firstBrace < lastBrace {
            jsonPayload = String(trimmedSummary[firstBrace...lastBrace])
        } else {
            // Fallback: try the old string-replacement approach.
            jsonPayload = trimmedSummary
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let summaryData = jsonPayload.data(using: .utf8),
              let summary = try? JSONDecoder().decode(CompactionSummary.self, from: summaryData) else {
            throw CompactionError.summaryParseFailed
        }

        // Build synthetic context turn
        let syntheticContext = summary.toSyntheticContext()
        var compactedTurns: [ConversationHistoryTurn] = [
            ConversationHistoryTurn(
                role: .user,
                text: syntheticContext,
                timestamp: Date()
            )
        ]
        compactedTurns.append(contentsOf: retainedTurns)

        let usage = json["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int ?? 0

        phase = .completed
        didComplete = true
        compactionCount += 1
        lastCompactedAt = Date()
        compactionSucceeded()

        return CompactedAnthropicResult(
            compactedTurns: compactedTurns,
            summary: summary,
            tokensConsumedBySummarization: inputTokens
        )
    }

    // MARK: - Token Counting (Pre-flight)

    func countOpenAITokens(
        instructions: String,
        inputItems: [Any],
        model: String,
        apiKey: String,
        tools: [[String: Any]]? = nil,
        session: URLSession = .shared
    ) async -> Int? {
        var body: [String: Any] = [
            "model": model,
            "input": inputItems
        ]
        if !instructions.isEmpty {
            body["instructions"] = instructions
        }
        if let tools, !tools.isEmpty {
            body["tools"] = tools
        }

        let url = StudioAPIConfig.openAIBaseURL.appendingPathComponent("v1/responses/input_tokens")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["input_tokens"] as? Int else {
            return nil
        }

        return tokens
    }

    func countAnthropicTokens(
        system: String,
        messages: [[String: Any]],
        model: String,
        apiKey: String,
        tools: [[String: Any]]? = nil,
        session: URLSession = .shared
    ) async -> Int? {
        var body: [String: Any] = [
            "model": model,
            "system": system,
            "messages": messages
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = tools
        }

        let url = StudioAPIConfig.anthropicCountTokensURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(StudioAPIConfig.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["input_tokens"] as? Int else {
            return nil
        }

        return tokens
    }

    // MARK: - Reset

    func reset() {
        phase = .idle
        contextTokensUsed = 0
        compactionCount = 0
        lastCompactedAt = nil
        isPipelineActive = false
        isToolLoopActive = false
    }

    func markCompleted() {
        phase = .completed
    }

    func returnToIdle() {
        if phase == .completed {
            phase = .idle
        }
    }
}

// MARK: - Result Types

struct CompactedOpenAIResult {
    let outputItems: [Any]
    let tokensAfterCompaction: Int
}

struct CompactedAnthropicResult {
    let compactedTurns: [ConversationHistoryTurn]
    let summary: CompactionSummary
    let tokensConsumedBySummarization: Int
}

// MARK: - Orchestration Context

/// Bundles the external dependencies needed to run the full compaction sequence.
struct CompactionOrchestrationContext {
    let model: StudioModelDescriptor
    let anthropicKey: String?
    let openAIKey: String?
    let chatThread: ChatThread
    let packageRoot: String
    let researcherOutputDir: URL?
    let tracer: TraceCollector?
    let sessionSpanID: UUID?
}

/// Captures outputs that PipelineRunner needs after compaction completes.
struct CompactionOrchestrationResult {
    let summary: CompactionSummary?
    let failureMessage: String?
}

// MARK: - Orchestration

extension CompactionCoordinator {

    /// Runs the full compaction sequence: tracing, thinking indicator, provider-specific
    /// compaction, chat thread updates, and divider posting.
    ///
    /// Returns the result so the caller can persist the summary or surface the error.
    func orchestrate(context: CompactionOrchestrationContext) async -> CompactionOrchestrationResult {
        let compactionSpanID = await context.tracer?.begin(
            kind: .compaction,
            name: "context_compaction",
            parentID: context.sessionSpanID,
            attributes: [
                "provider": context.model.provider.rawValue,
                "model": context.model.identifier,
                "retainedTurns": "\(retainedTurnCount)"
            ]
        )

        // Post a temporary "Optimizing My Memory" thinking indicator.
        let thinkingMessage = ChatMessage(
            kind: .thinking,
            goal: "",
            text: "Optimizing My Memory",
            timestamp: Date()
        )
        context.chatThread.post(thinkingMessage)

        var compactionFailureMessage: String?
        var compactionSummary: CompactionSummary?

        do {
            switch context.model.provider {
            case .openAI:
                guard let key = context.openAIKey, !key.isEmpty else { break }
                let conversationHistory = context.chatThread.completedTurns
                let inputItems = PipelineMemoryPackStager.compactionSafePayload(from: conversationHistory)
                let systemPrompt = PipelineMemoryPackStager.agenticSystemPrompt(
                    projectRoot: context.packageRoot,
                    model: context.model,
                    researcherOutputDir: context.researcherOutputDir
                )
                let result = try await compactOpenAI(
                    instructions: systemPrompt,
                    inputItems: inputItems,
                    model: context.model.identifier,
                    apiKey: key
                )
                let retainedTurns = Array(context.chatThread.completedTurns.suffix(retainedTurnCount))
                context.chatThread.replaceHistoryWithCompactionMarker(retainedTurns: retainedTurns)
                contextTokensUsed = result.tokensAfterCompaction
                if let compactionSpanID {
                    await context.tracer?.setAttribute(
                        "tokensAfterCompaction",
                        value: "\(result.tokensAfterCompaction)",
                        on: compactionSpanID
                    )
                }

            case .anthropic:
                guard let key = context.anthropicKey, !key.isEmpty else { break }
                let conversationHistory = context.chatThread.completedTurns
                let result = try await compactAnthropic(
                    conversationTurns: conversationHistory,
                    model: context.model.identifier,
                    apiKey: key
                )
                context.chatThread.replaceHistory(with: result.compactedTurns)
                compactionSummary = result.summary
                let estimatedNewTokens = result.tokensConsumedBySummarization / 4
                contextTokensUsed = estimatedNewTokens
                if let compactionSpanID {
                    await context.tracer?.setAttribute(
                        "tokensAfterCompaction",
                        value: "\(estimatedNewTokens)",
                        on: compactionSpanID
                    )
                }
            }
        } catch {
            compactionFailureMessage = error.localizedDescription
            compactionFailed()
            print("[CompactionCoordinator] compaction failed: \(error.localizedDescription)")
        }

        // Remove the thinking indicator and post the permanent divider.
        context.chatThread.removeMessage(id: thinkingMessage.id)
        if compactionFailureMessage == nil {
            context.chatThread.postCompactionDivider()
        } else {
            context.chatThread.postCompactionDivider(text: "Memory optimization skipped")
        }
        returnToIdle()

        if let compactionSpanID {
            if let compactionFailureMessage {
                await context.tracer?.end(compactionSpanID, error: compactionFailureMessage)
            } else {
                await context.tracer?.end(compactionSpanID)
            }
        }

        return CompactionOrchestrationResult(
            summary: compactionSummary,
            failureMessage: compactionFailureMessage
        )
    }
}

// MARK: - Errors

enum CompactionError: LocalizedError {
    case apiFailed(String)
    case invalidResponse
    case nothingToCompact
    case summaryParseFailed

    var errorDescription: String? {
        switch self {
        case .apiFailed(let detail):
            return "Compaction API call failed: \(detail)"
        case .invalidResponse:
            return "Invalid compaction response"
        case .nothingToCompact:
            return "Not enough conversation history to compact"
        case .summaryParseFailed:
            return "Failed to parse structured summary from Anthropic"
        }
    }
}
