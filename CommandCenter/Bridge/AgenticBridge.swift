// AgenticBridge.swift
// Studio.92 — Command Center
// In-process streaming client for the agentic loop.
// Self-contained — calls Anthropic or OpenAI directly via URLSession,
// parses SSE events where available, and executes tool calls. No SPM dependency required.

import Foundation
import AppKit
import AgentCouncil
import Darwin

// MARK: - Centralized API Configuration

/// Single source of truth for API endpoints, versions, and timeouts.
/// Override via environment variables for staging/testing without recompile.
enum StudioAPIConfig {

    // MARK: Anthropic

    static let anthropicAPIVersion: String =
        ProcessInfo.processInfo.environment["STUDIO_ANTHROPIC_API_VERSION"] ?? "2023-06-01"

    static let anthropicBaseURL: URL =
        URL(string: ProcessInfo.processInfo.environment["STUDIO_ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com")!

    static var anthropicMessagesURL: URL {
        anthropicBaseURL.appendingPathComponent("v1/messages")
    }

    static var anthropicCountTokensURL: URL {
        anthropicBaseURL.appendingPathComponent("v1/messages/count_tokens")
    }

    static let anthropicBetaVersion = "interleaved-thinking-2025-05-14"

    // MARK: OpenAI

    static let openAIBaseURL: URL =
        URL(string: ProcessInfo.processInfo.environment["STUDIO_OPENAI_BASE_URL"] ?? "https://api.openai.com")!

    static var openAIResponsesURL: URL {
        openAIBaseURL.appendingPathComponent("v1/responses")
    }

    static var openAIChatCompletionsURL: URL {
        openAIBaseURL.appendingPathComponent("v1/chat/completions")
    }

    // MARK: Timeouts

    static let requestTimeout: TimeInterval = 300
    static let resourceTimeout: TimeInterval = 900

    // MARK: Retry

    static let transientStatusCodes: Set<Int> = [429, 500, 502, 503, 504, 529]
    static let maxRetryAttempts = 3
    static let maxRetryDelay: TimeInterval = 12
}

// MARK: - Agentic Client


final class URLSessionTaskMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onMetrics: @Sendable (URLSessionTaskMetrics) -> Void

    init(onMetrics: @escaping @Sendable (URLSessionTaskMetrics) -> Void) {
        self.onMetrics = onMetrics
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        onMetrics(metrics)
    }
}

final class UTF8StreamDecoder {

    private var buffer = Data()
    private static let maxPendingBytes = 1_048_576 // 1MB

    func append(_ chunk: Data) -> String? {
        buffer.append(chunk)

        if buffer.count > Self.maxPendingBytes {
            print("[UTF8StreamDecoder] Pending buffer exceeded 1MB (\(buffer.count) bytes) without valid decode — draining.")
            buffer.removeAll(keepingCapacity: false)
            return nil
        }

        guard let string = String(data: buffer, encoding: .utf8) else {
            return nil
        }

        buffer.removeAll(keepingCapacity: true)
        return string
    }

    /// Single-byte fast path — avoids a heap-allocated Data per byte.
    func append(_ byte: UInt8) -> String? {
        buffer.append(byte)

        if buffer.count > Self.maxPendingBytes {
            print("[UTF8StreamDecoder] Pending buffer exceeded 1MB (\(buffer.count) bytes) without valid decode — draining.")
            buffer.removeAll(keepingCapacity: false)
            return nil
        }

        guard let string = String(data: buffer, encoding: .utf8) else {
            return nil
        }

        buffer.removeAll(keepingCapacity: true)
        return string
    }

    func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        guard let string = String(data: buffer, encoding: .utf8) else {
            buffer.removeAll(keepingCapacity: true)
            return nil
        }

        buffer.removeAll(keepingCapacity: true)
        return string
    }
}

/// Drives a streaming agentic conversation loop in-process.
/// Replaces the subprocess model for interactive CommandCenter use.
actor AgenticClient {

    let anthropicAPIKey: String?
    let openAIKey:       String?
    let projectRoot: URL
    let allowMachineWideAccess: Bool
    let runtimePolicy: CommandRuntimePolicy
    let permissionPolicy: ToolPermissionPolicy
    let sandbox: SandboxPolicy
    let recovery: RecoveryExecutor
    let session:     URLSession

    /// Scoped memory context for subagent delegation (explorer/reviewer).
    var subagentMemoryContext: String?

    func injectSubagentMemory(_ context: String) {
        subagentMemoryContext = context
    }

    static let apiVersion   = StudioAPIConfig.anthropicAPIVersion
    static let messagesURL  = StudioAPIConfig.anthropicMessagesURL
    static let responsesURL = StudioAPIConfig.openAIResponsesURL
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = StudioAPIConfig.requestTimeout
        configuration.timeoutIntervalForResource = StudioAPIConfig.resourceTimeout
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    init(
        apiKey: String?,
        projectRoot: URL,
        openAIKey: String? = nil,
        runtimePolicy: CommandRuntimePolicy? = nil,
        permissionPolicy: ToolPermissionPolicy = ToolPermissionPolicy(),
        allowMachineWideAccess: Bool = true,
        session: URLSession = AgenticClient.defaultSession
    ) {
        self.anthropicAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openAIKey       = openAIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectRoot     = projectRoot
        self.allowMachineWideAccess = allowMachineWideAccess
        self.runtimePolicy = runtimePolicy ?? CommandRuntimePolicy(
            accessScope: allowMachineWideAccess ? .fullMacAccess : .workspaceOnly,
            approvalMode: .neverAsk
        )
        self.permissionPolicy = permissionPolicy
        self.sandbox = SandboxPolicy(projectRoot: projectRoot, allowMachineWideAccess: allowMachineWideAccess)
        self.recovery = RecoveryExecutor()
        self.session     = session
    }

    /// Run the agentic loop. Returns an AsyncStream of events for real-time UI updates.
    /// Cancelling the consuming Task tears down the entire loop.
    func run(
        system:        String,
        userMessage:   String,
        userContentBlocks: [[String: Any]]? = nil,
        initialMessages: [[String: Any]] = [],
        model:         StudioModelDescriptor = StudioModelStrategy.review,
        maxTokens:     Int    = 8192,
        temperature:   Double? = nil,
        outputEffort:  String? = nil,
        verbosity:     String? = nil,
        tools:         [[String: Any]]? = nil,
        allowedToolNames: [String]? = nil,
        thinking:      [String: Any]? = nil,
        cacheControl:  [String: Any]? = nil,
        responseFormat: [String: Any]? = nil,
        maxIterations: Int = 25,
        latencyRunID:  String? = nil
    ) -> AsyncStream<AgenticEvent> {
        let engine: ExecutionLoopEngine

        switch model.provider {
        case .anthropic:
            guard let anthropicAPIKey, !anthropicAPIKey.isEmpty else {
                return Self.errorStream("Anthropic API key missing for \(model.displayName).")
            }
            engine = AnthropicExecutionLoop(
                client: self,
                system: system,
                userMessage: userMessage,
                userContentBlocks: userContentBlocks,
                initialMessages: initialMessages,
                model: model,
                maxTokens: maxTokens,
                temperature: temperature,
                outputEffort: outputEffort,
                tools: tools,
                thinking: thinking,
                cacheControl: cacheControl,
                maxIterations: maxIterations,
                latencyRunID: latencyRunID
            )
        case .openAI:
            guard let openAIKey, !openAIKey.isEmpty else {
                return Self.errorStream("OpenAI API key missing for \(model.displayName).")
            }
            engine = OpenAIExecutionLoop(
                client: self,
                system: system,
                userMessage: userMessage,
                userContentBlocks: userContentBlocks,
                initialMessages: initialMessages,
                model: model,
                maxTokens: maxTokens,
                outputEffort: outputEffort,
                verbosity: verbosity,
                tools: tools,
                allowedToolNames: allowedToolNames,
                responseFormat: responseFormat,
                maxIterations: maxIterations,
                latencyRunID: latencyRunID
            )
        }

        return engine.execute()
    }

    // MARK: - Helpers

    func runSubAgent(
        system: String,
        prompt: String,
        model: StudioModelDescriptor,
        tools: [[String: Any]],
        maxIterations: Int = 8,
        maxTokens: Int = 3072,
        toolHandler: (@Sendable (String, [String: Any]) async -> ToolExecutionOutcome)? = nil
    ) async throws -> String {
        switch model.provider {
        case .anthropic:
            guard let anthropicAPIKey, !anthropicAPIKey.isEmpty else {
                throw AgenticBridgeError.missingAPIKey
            }
            return try await runAnthropicSubAgent(
                system: system,
                prompt: prompt,
                model: model,
                tools: tools,
                maxIterations: maxIterations,
                maxTokens: maxTokens,
                toolHandler: toolHandler
            )
        case .openAI:
            guard let openAIKey, !openAIKey.isEmpty else {
                throw AgenticBridgeError.missingAPIKey
            }
            return try await runOpenAISubAgent(
                system: system,
                prompt: prompt,
                model: model,
                tools: tools,
                maxIterations: maxIterations,
                maxTokens: maxTokens,
                toolHandler: toolHandler
            )
        }
    }

    private func runAnthropicSubAgent(
        system: String,
        prompt: String,
        model: StudioModelDescriptor,
        tools: [[String: Any]],
        maxIterations: Int,
        maxTokens: Int,
        toolHandler: (@Sendable (String, [String: Any]) async -> ToolExecutionOutcome)? = nil
    ) async throws -> String {
        var messages: [[String: Any]] = [
            ["role": "user", "content": prompt]
        ]

        for _ in 0..<maxIterations {
            let response = try await completeSubAgentRequest(
                system: system,
                messages: messages,
                model: model.identifier,
                maxTokens: maxTokens,
                tools: tools
            )

            let contentBlocks = (response["content"] as? [[String: Any]]) ?? []
            let summary = summarizeSubAgentText(from: contentBlocks)
            let pendingToolCalls = subAgentToolUses(from: contentBlocks)

            messages.append([
                "role": "assistant",
                "content": contentBlocks.isEmpty
                    ? [["type": "text", "text": summary]]
                    : contentBlocks
            ])

            guard !pendingToolCalls.isEmpty else {
                return summary
            }

            var toolResults: [[String: Any]] = []
            for toolCall in pendingToolCalls {
                let outcome: ToolExecutionOutcome
                if let toolHandler {
                    outcome = await toolHandler(toolCall.name, toolCall.input)
                } else {
                    outcome = await executeSubagentTool(name: toolCall.name, input: toolCall.input)
                }
                toolResults.append(Self.toolResultPayload(toolUseID: toolCall.id, outcome: outcome))
            }

            messages.append([
                "role": "user",
                "content": toolResults
            ])
        }

        return "Sub-agent reached its iteration limit before producing a final summary."
    }

    private func runOpenAISubAgent(
        system: String,
        prompt: String,
        model: StudioModelDescriptor,
        tools: [[String: Any]],
        maxIterations: Int,
        maxTokens: Int,
        toolHandler: (@Sendable (String, [String: Any]) async -> ToolExecutionOutcome)? = nil
    ) async throws -> String {
        var previousResponseID: String?
        var resolvedModelIdentifier: String?
        var pendingInput: [Any] = [
            Self.openAIInputMessage(role: "user", text: prompt, anthropicContentBlocks: nil)
        ]

        for _ in 0..<maxIterations {
            let (response, selectedModelIdentifier) = try await createOpenAIResponseWithFallback(
                instructions: system,
                input: pendingInput,
                previousResponseID: previousResponseID,
                model: model,
                preferredModelIdentifier: resolvedModelIdentifier,
                maxOutputTokens: maxTokens,
                reasoningEffort: model.defaultReasoningEffort,
                verbosity: model.defaultVerbosity,
                tools: Self.openAIToolSchemas(from: tools)
            )
            resolvedModelIdentifier = selectedModelIdentifier
            previousResponseID = response.id

            let summary = response.textFragments
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pendingToolCalls = response.functionCalls

            guard !pendingToolCalls.isEmpty else {
                return summary.isEmpty
                    ? "Sub-agent completed without a textual summary."
                    : summary
            }

            var toolResults: [Any] = []
            for toolCall in pendingToolCalls {
                let input = Self.parseJSON(toolCall.arguments) ?? [:]
                let outcome: ToolExecutionOutcome
                if let toolHandler {
                    outcome = await toolHandler(toolCall.name, input)
                } else {
                    outcome = await executeSubagentTool(name: toolCall.name, input: input)
                }
                toolResults.append(
                    Self.openAIFunctionCallOutput(
                        callID: toolCall.callID,
                        outcome: outcome
                    )
                )
            }

            pendingInput = toolResults
        }

        return "Sub-agent reached its iteration limit before producing a final summary."
    }

    private static let subAgentRetryStatusCodes = StudioAPIConfig.transientStatusCodes
    private static let subAgentMaxRetryAttempts = StudioAPIConfig.maxRetryAttempts

    private func completeSubAgentRequest(
        system: String,
        messages: [[String: Any]],
        model: String,
        maxTokens: Int,
        tools: [[String: Any]]
    ) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }

        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AgenticBridgeError.noHTTPResponse
            }
            guard http.statusCode == 200 else {
                let errorBody = String(decoding: data, as: UTF8.self)
                if Self.subAgentRetryStatusCodes.contains(http.statusCode),
                   attempt < Self.subAgentMaxRetryAttempts {
                    let jitter = Double.random(in: 0.75...1.25)
                    let delay = min(pow(2, Double(max(0, attempt - 1))) * jitter, 12)
                    try await Task.sleep(nanoseconds: UInt64(max(0.5, delay) * 1_000_000_000))
                    continue
                }
                throw AgenticBridgeError.apiError(statusCode: http.statusCode, body: errorBody)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgenticBridgeError.apiError(statusCode: -1, body: "Invalid sub-agent response")
            }
            return object
        }
    }

    static func toolResultPayload(toolUseID: String, outcome: ToolExecutionOutcome) -> [String: Any] {
        var block: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": toolUseID,
            "content": outcome.toolResultPayload
        ]
        if outcome.isError {
            block["is_error"] = true
        }
        return block
    }

    private static func errorStream(_ message: String) -> AsyncStream<AgenticEvent> {
        AsyncStream { continuation in
            continuation.yield(.error(message))
            continuation.finish()
        }
    }

    static func primaryTransactionMetric(from metrics: URLSessionTaskMetrics) -> URLSessionTaskTransactionMetrics? {
        metrics.transactionMetrics.last ?? metrics.transactionMetrics.first
    }

    static func absoluteTime(from date: Date?) -> CFAbsoluteTime? {
        date?.timeIntervalSinceReferenceDate
    }

    static func requestTTFBMilliseconds(from metrics: URLSessionTaskMetrics) -> Double? {
        guard let transaction = primaryTransactionMetric(from: metrics),
              let requestStart = transaction.requestStartDate ?? transaction.fetchStartDate,
              let responseStart = transaction.responseStartDate else {
            return nil
        }
        return responseStart.timeIntervalSince(requestStart) * 1000
    }

    static func responseTransferMilliseconds(from metrics: URLSessionTaskMetrics) -> Double? {
        guard let transaction = primaryTransactionMetric(from: metrics),
              let responseStart = transaction.responseStartDate,
              let responseEnd = transaction.responseEndDate else {
            return nil
        }
        return responseEnd.timeIntervalSince(responseStart) * 1000
    }

    static func responseStartAbsoluteTime(from metrics: URLSessionTaskMetrics) -> CFAbsoluteTime? {
        guard let transaction = primaryTransactionMetric(from: metrics) else { return nil }
        return absoluteTime(from: transaction.responseStartDate)
    }

    static func responseEndAbsoluteTime(from metrics: URLSessionTaskMetrics) -> CFAbsoluteTime? {
        guard let transaction = primaryTransactionMetric(from: metrics) else { return nil }
        return absoluteTime(from: transaction.responseEndDate)
    }

    #if DEBUG
    private static func debugElapsed(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    private static func debugLogUsage(from data: String) {
        guard let json = parseJSON(data),
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return
        }

        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0

        print(
            "[AgenticLatency] usage " +
            "input=\(input) " +
            "output=\(output) " +
            "cache_read=\(cacheRead) " +
            "cache_write=\(cacheWrite)"
        )
    }
    #endif

    struct ShellExecutionCapture {
        let output: String
        let exitStatus: Int
        let didTimeout: Bool
    }

    static func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
