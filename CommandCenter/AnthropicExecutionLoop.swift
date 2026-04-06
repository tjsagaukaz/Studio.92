// AnthropicExecutionLoop.swift
// Studio.92 — Command Center
// Anthropic-specific agentic execution loop extracted from AgenticBridge.

import Foundation

/// Drives the Anthropic streaming agentic loop: SSE consumption via
/// ``AgenticClient/streamRequest(…)``, tool dispatch with bounded concurrency,
/// and message-history construction for multi-turn iteration.
final class AnthropicExecutionLoop: ExecutionLoopEngine, @unchecked Sendable {

    private weak var client: AgenticClient?
    private let system: String
    private let userMessage: String
    private let userContentBlocks: [[String: Any]]?
    private let initialMessages: [[String: Any]]
    private let model: StudioModelDescriptor
    private let maxTokens: Int
    private let temperature: Double?
    private let outputEffort: String?
    private let tools: [[String: Any]]?
    private let thinking: [String: Any]?
    private let cacheControl: [String: Any]?
    private let maxIterations: Int
    private let latencyRunID: String?

    init(
        client: AgenticClient,
        system: String,
        userMessage: String,
        userContentBlocks: [[String: Any]]?,
        initialMessages: [[String: Any]],
        model: StudioModelDescriptor,
        maxTokens: Int,
        temperature: Double?,
        outputEffort: String?,
        tools: [[String: Any]]?,
        thinking: [String: Any]?,
        cacheControl: [String: Any]?,
        maxIterations: Int,
        latencyRunID: String?
    ) {
        self.client = client
        self.system = system
        self.userMessage = userMessage
        self.userContentBlocks = userContentBlocks
        self.initialMessages = initialMessages
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.outputEffort = outputEffort
        self.tools = tools
        self.thinking = thinking
        self.cacheControl = cacheControl
        self.maxIterations = maxIterations
        self.latencyRunID = latencyRunID
    }

    func execute() -> AsyncStream<AgenticEvent> {
        let (stream, continuation) = AsyncStream<AgenticEvent>.makeStream()

        let task = Task { [weak client, system, userMessage, userContentBlocks, initialMessages,
                           model, maxTokens, temperature, outputEffort, tools, thinking,
                           cacheControl, maxIterations, latencyRunID] in
            guard let client else { continuation.finish(); return }

            var messages = initialMessages
            if let userContentBlocks, !userContentBlocks.isEmpty {
                messages.append(["role": "user", "content": userContentBlocks])
            } else {
                messages.append(["role": "user", "content": userMessage])
            }
            var iteration = 0

            do {
                while iteration < maxIterations {
                    iteration += 1
                    if Task.isCancelled { break }

                    let llmCallKey = "anthropic.iteration.\(iteration)"
                    let llmCallStartedAt = CFAbsoluteTimeGetCurrent()
                    await LatencyDiagnostics.shared.beginLLMCall(
                        runID: latencyRunID,
                        key: llmCallKey,
                        provider: "anthropic",
                        model: model.identifier,
                        iteration: iteration,
                        startedAt: llmCallStartedAt,
                        notes: "messages=\(messages.count) tools=\(tools?.count ?? 0)"
                    )
                    var assistantText    = ""
                    var assistantBlocksByIndex: [Int: AssistantBlockAccumulator] = [:]
                    var stopReason: String?

                    // Stream one model turn.
                    let events = try await client.streamRequest(
                        system:      system,
                        messages:    messages,
                        model:       model.identifier,
                        maxTokens:   maxTokens,
                        temperature: temperature,
                        outputEffort: outputEffort,
                        tools:       tools,
                        thinking:    thinking,
                        cacheControl: cacheControl,
                        latencyRunID: latencyRunID,
                        llmCallKey: llmCallKey
                    )

                    for try await event in events {
                        if Task.isCancelled { break }

                        switch event {
                        case .textDelta(let index, let text):
                            await LatencyDiagnostics.shared.markLLMFirstTextDelta(
                                runID: latencyRunID,
                                key: llmCallKey
                            )
                            assistantText += text
                            if assistantBlocksByIndex[index] == nil {
                                assistantBlocksByIndex[index] = .text("")
                            }
                            assistantBlocksByIndex[index]?.appendTextDelta(text)
                            continuation.yield(.textDelta(text))

                        case .thinkingDelta(let index, let text):
                            if assistantBlocksByIndex[index] == nil {
                                assistantBlocksByIndex[index] = .thinking(text: "", signature: nil)
                            }
                            assistantBlocksByIndex[index]?.appendThinkingDelta(text)
                            continuation.yield(.thinkingDelta(text))

                        case .toolCallStart(let index, let id, let name):
                            assistantBlocksByIndex[index] = .toolUse(id: id, name: name, inputJSON: "")
                            continuation.yield(.toolCallStart(id: id, name: name))

                        case .toolCallInputDelta(let index, let json):
                            if let id = assistantBlocksByIndex[index]?.appendInputJSONDelta(json) {
                                continuation.yield(.toolCallInputDelta(id: id, partialJSON: json))
                            }

                        case .thinkingSignature(let index, let signature):
                            if assistantBlocksByIndex[index] == nil {
                                assistantBlocksByIndex[index] = .thinking(text: "", signature: nil)
                            }
                            assistantBlocksByIndex[index]?.setThinkingSignature(signature)
                            continuation.yield(.thinkingSignature(signature))

                        case .usage(let input, let output):
                            await LatencyDiagnostics.shared.updateLLMUsage(
                                runID: latencyRunID,
                                key: llmCallKey,
                                inputTokens: input,
                                outputTokens: output
                            )
                            continuation.yield(.usage(inputTokens: input, outputTokens: output))

                        case .stopReason(let reason):
                            stopReason = reason

                        case .error(let msg):
                            await LatencyDiagnostics.shared.endLLMCall(
                                runID: latencyRunID,
                                key: llmCallKey,
                                endedAt: CFAbsoluteTimeGetCurrent(),
                                stopReason: "error",
                                notes: msg
                            )
                            continuation.yield(.error(msg))
                            continuation.finish()
                            return
                        }
                    }

                    if Task.isCancelled { break }
                    await LatencyDiagnostics.shared.endLLMCall(
                        runID: latencyRunID,
                        key: llmCallKey,
                        endedAt: CFAbsoluteTimeGetCurrent(),
                        stopReason: stopReason
                    )

                    // Build the assistant content blocks for conversation history.
                    var assistantContent: [Any] = assistantBlocksByIndex
                        .keys
                        .sorted()
                        .compactMap { assistantBlocksByIndex[$0]?.assistantContentBlock }

                    if assistantContent.isEmpty {
                        assistantContent.append(["type": "text", "text": assistantText])
                    }
                    messages.append(["role": "assistant", "content": assistantContent])

                    let pendingToolCalls = assistantBlocksByIndex
                        .keys
                        .sorted()
                        .compactMap { assistantBlocksByIndex[$0]?.pendingTool }

                    // No tool calls → done.
                    if pendingToolCalls.isEmpty || stopReason == "end_turn" {
                        continuation.yield(.completed(stopReason: stopReason ?? "end_turn"))
                        continuation.finish()
                        return
                    }

                    // Execute tools — parallel where safe, sequential otherwise.
                    let partitioned = ToolParallelism.partition(
                        pendingToolCalls,
                        name: { $0.name },
                        inputJSON: { $0.inputJSON }
                    )
                    let maxParallel = StudioModelStrategy.shipMaxParallelTools(packageRoot: await client.projectRoot.path)
                    var toolResults = Array<[String: Any]?>(repeating: nil, count: pendingToolCalls.count)
                    let currentIteration = iteration

                    // --- Parallel batch (bounded concurrency) ---
                    if !partitioned.parallel.isEmpty {
                        let runTool: @Sendable (Int, PendingTool) async -> (Int, [String: Any]) = { [weak client] idx, tc in
                            guard let client else {
                                return (idx, AgenticClient.toolResultPayload(
                                    toolUseID: tc.id,
                                    outcome: ToolExecutionOutcome(text: "Tool cancelled", isError: true)
                                ))
                            }
                            if Task.isCancelled {
                                let cancelled = ToolExecutionOutcome(text: "Tool cancelled", isError: true)
                                continuation.yield(.toolCallResult(id: tc.id, output: cancelled.displayText, isError: true))
                                return (idx, AgenticClient.toolResultPayload(toolUseID: tc.id, outcome: cancelled))
                            }
                            let input = AgenticClient.parseJSON(tc.inputJSON) ?? [:]
                            let toolStartedAt = CFAbsoluteTimeGetCurrent()
                            let outcome = await client.executeTool(
                                name: tc.name,
                                input: input
                            ) { progress in
                                switch progress {
                                case .command(let command):
                                    continuation.yield(.toolCallCommand(id: tc.id, command: command))
                                case .output(let line):
                                    continuation.yield(.toolCallOutput(id: tc.id, line: line))
                                }
                            }
                            let toolEndedAt = CFAbsoluteTimeGetCurrent()
                            await LatencyDiagnostics.shared.recordToolLoop(
                                runID: latencyRunID,
                                key: "\(llmCallKey).tool.\(tc.id)",
                                loopIndex: currentIteration,
                                action: tc.name,
                                startedAt: toolStartedAt,
                                endedAt: toolEndedAt,
                                notes: "tool_use_id=\(tc.id) is_error=\(outcome.isError) parallel=true"
                            )
                            continuation.yield(.toolCallResult(id: tc.id, output: outcome.displayText, isError: outcome.isError))
                            return (idx, AgenticClient.toolResultPayload(toolUseID: tc.id, outcome: outcome))
                        }
                        await withTaskGroup(of: (Int, [String: Any]).self) { group in
                            var iter = partitioned.parallel.makeIterator()
                            for _ in 0..<min(maxParallel, partitioned.parallel.count) {
                                guard let (idx, tc) = iter.next() else { break }
                                group.addTask { await runTool(idx, tc) }
                            }
                            for await (idx, payload) in group {
                                toolResults[idx] = payload
                                if let (nextIdx, nextTc) = iter.next() {
                                    group.addTask { await runTool(nextIdx, nextTc) }
                                }
                            }
                        }
                    }

                    // --- Sequential batch ---
                    for (idx, tc) in partitioned.sequential {
                        if Task.isCancelled {
                            let cancelled = ToolExecutionOutcome(text: "Tool cancelled", isError: true)
                            continuation.yield(.toolCallResult(id: tc.id, output: cancelled.displayText, isError: true))
                            toolResults[idx] = AgenticClient.toolResultPayload(toolUseID: tc.id, outcome: cancelled)
                            continue
                        }
                        let input = AgenticClient.parseJSON(tc.inputJSON) ?? [:]
                        let toolStartedAt = CFAbsoluteTimeGetCurrent()
                        let outcome = await client.executeTool(
                            name: tc.name,
                            input: input
                        ) { progress in
                            switch progress {
                            case .command(let command):
                                continuation.yield(.toolCallCommand(id: tc.id, command: command))
                            case .output(let line):
                                continuation.yield(.toolCallOutput(id: tc.id, line: line))
                            }
                        }
                        let toolEndedAt = CFAbsoluteTimeGetCurrent()
                        await LatencyDiagnostics.shared.recordToolLoop(
                            runID: latencyRunID,
                            key: "\(llmCallKey).tool.\(tc.id)",
                            loopIndex: iteration,
                            action: tc.name,
                            startedAt: toolStartedAt,
                            endedAt: toolEndedAt,
                            notes: "tool_use_id=\(tc.id) is_error=\(outcome.isError)"
                        )
                        continuation.yield(.toolCallResult(id: tc.id, output: outcome.displayText, isError: outcome.isError))
                        toolResults[idx] = AgenticClient.toolResultPayload(toolUseID: tc.id, outcome: outcome)
                    }

                    messages.append(["role": "user", "content": toolResults.compactMap { $0 }])
                }

                continuation.yield(.error("Reached max iterations (\(maxIterations))"))
                continuation.finish()
            } catch {
                continuation.yield(.error("Agentic error: \(error.localizedDescription)"))
                continuation.finish()
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Supporting Types

    private struct PendingTool: Sendable {
        let id: String
        let name: String
        var inputJSON: String
    }

    private enum AssistantBlockAccumulator {
        case text(String)
        case thinking(text: String, signature: String?)
        case toolUse(id: String, name: String, inputJSON: String)

        mutating func appendTextDelta(_ text: String) {
            guard case .text(let current) = self else { return }
            self = .text(current + text)
        }

        mutating func appendThinkingDelta(_ text: String) {
            guard case .thinking(let current, let signature) = self else { return }
            self = .thinking(text: current + text, signature: signature)
        }

        mutating func setThinkingSignature(_ signature: String) {
            guard case .thinking(let text, _) = self else { return }
            self = .thinking(text: text, signature: signature)
        }

        mutating func appendInputJSONDelta(_ json: String) -> String? {
            guard case .toolUse(let id, let name, let inputJSON) = self else { return nil }
            self = .toolUse(id: id, name: name, inputJSON: inputJSON + json)
            return id
        }

        var pendingTool: PendingTool? {
            guard case .toolUse(let id, let name, let inputJSON) = self else { return nil }
            return PendingTool(id: id, name: name, inputJSON: inputJSON)
        }

        var assistantContentBlock: [String: Any]? {
            switch self {
            case .text(let text):
                return [
                    "type": "text",
                    "text": text
                ]
            case .thinking(let text, let signature):
                var payload: [String: Any] = [
                    "type": "thinking",
                    "thinking": text
                ]
                if let signature {
                    payload["signature"] = signature
                }
                return payload
            case .toolUse(let id, let name, let inputJSON):
                return [
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": AgenticClient.parseJSON(inputJSON) ?? [:]
                ]
            }
        }
    }
}
