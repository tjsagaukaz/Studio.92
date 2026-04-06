// OpenAIExecutionLoop.swift
// Studio.92 — Command Center
// OpenAI-specific agentic execution loop extracted from AgenticBridge.

import Foundation

/// Drives the OpenAI Responses-API agentic loop: streaming events via
/// ``AgenticClient/streamOpenAIResponseWithFallback(…)``, model fallback with retry,
/// tool dispatch with bounded concurrency, and response-chaining for multi-turn iteration.
final class OpenAIExecutionLoop: ExecutionLoopEngine, @unchecked Sendable {

    private weak var client: AgenticClient?
    private let system: String
    private let userMessage: String
    private let userContentBlocks: [[String: Any]]?
    private let initialMessages: [[String: Any]]
    private let model: StudioModelDescriptor
    private let maxTokens: Int
    private let outputEffort: String?
    private let verbosity: String?
    private let tools: [[String: Any]]?
    private let allowedToolNames: [String]?
    private let responseFormat: [String: Any]?
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
        outputEffort: String?,
        verbosity: String?,
        tools: [[String: Any]]?,
        allowedToolNames: [String]?,
        responseFormat: [String: Any]?,
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
        self.outputEffort = outputEffort
        self.verbosity = verbosity
        self.tools = tools
        self.allowedToolNames = allowedToolNames
        self.responseFormat = responseFormat
        self.maxIterations = maxIterations
        self.latencyRunID = latencyRunID
    }

    func execute() -> AsyncStream<AgenticEvent> {
        let (stream, continuation) = AsyncStream<AgenticEvent>.makeStream()

        let task = Task { [weak client, system, userMessage, userContentBlocks, initialMessages,
                           model, maxTokens, outputEffort, verbosity, tools, allowedToolNames,
                           responseFormat, maxIterations, latencyRunID] in
            guard let client else { continuation.finish(); return }

            struct PendingFunctionCallState {
                var name: String
                var arguments: String
            }

            var previousResponseID: String?
            var resolvedModelIdentifier: String?
            var pendingInput: [Any] = AgenticClient.openAIInputMessages(
                initialMessages: initialMessages,
                userMessage: userMessage,
                userContentBlocks: userContentBlocks
            )

            do {
                for iteration in 1...maxIterations {
                    if Task.isCancelled { break }

                    let llmCallKey = "openai.iteration.\(iteration)"
                    var iterationPreferredModelIdentifier = resolvedModelIdentifier

                    retryIteration: while true {
                        let llmCallStartedAt = CFAbsoluteTimeGetCurrent()
                        await LatencyDiagnostics.shared.beginLLMCall(
                            runID: latencyRunID,
                            key: llmCallKey,
                            provider: "openai",
                            model: iterationPreferredModelIdentifier ?? model.identifier,
                            iteration: iteration,
                            startedAt: llmCallStartedAt,
                            notes: "input_items=\(pendingInput.count) tools=\(tools?.count ?? 0)"
                        )

                        let (events, selectedModelIdentifier) = try await client.streamOpenAIResponseWithFallback(
                            instructions: system,
                            input: pendingInput,
                            previousResponseID: previousResponseID,
                            model: model,
                            preferredModelIdentifier: iterationPreferredModelIdentifier,
                            maxOutputTokens: maxTokens,
                            reasoningEffort: outputEffort,
                            verbosity: verbosity,
                            tools: AgenticClient.openAIToolSchemas(from: tools),
                            allowedToolNames: allowedToolNames,
                            responseFormat: responseFormat,
                            latencyRunID: latencyRunID,
                            llmCallKey: llmCallKey
                        )
                        resolvedModelIdentifier = selectedModelIdentifier

                        var finalResponse: AgenticClient.OpenAIResponseEnvelope?
                        var stopReason: String?
                        var startedToolCallIDs: Set<String> = []
                        var streamedFunctionCalls: [String: PendingFunctionCallState] = [:]
                        var streamedFunctionOrder: [String] = []
                        var streamedWebSearchIDs: Set<String> = []
                        var retryModelIdentifier: String?

                        func recordFunctionCallOrder(_ callID: String) {
                            guard !callID.isEmpty else { return }
                            if !streamedFunctionOrder.contains(callID) {
                                streamedFunctionOrder.append(callID)
                            }
                        }

                        func startToolCallIfNeeded(callID: String, name: String) {
                            guard !callID.isEmpty else { return }
                            guard !startedToolCallIDs.contains(callID) else { return }
                            startedToolCallIDs.insert(callID)
                            continuation.yield(.toolCallStart(id: callID, name: name.isEmpty ? "function_call" : name))
                        }

                        eventLoop: for try await event in events {
                            if Task.isCancelled { break }

                            switch event {
                            case .responseCreated(let responseID):
                                previousResponseID = responseID

                            case .textDelta(let fragment):
                                continuation.yield(.textDelta(fragment))

                            case .reasoningDelta(let fragment):
                                continuation.yield(.thinkingDelta(fragment))

                            case .functionCallStarted(let callID, let name, let arguments):
                                recordFunctionCallOrder(callID)
                                startToolCallIfNeeded(callID: callID, name: name)

                                let existing = streamedFunctionCalls[callID] ?? PendingFunctionCallState(
                                    name: "",
                                    arguments: ""
                                )
                                streamedFunctionCalls[callID] = PendingFunctionCallState(
                                    name: name.isEmpty ? existing.name : name,
                                    arguments: existing.arguments + arguments
                                )

                                if !arguments.isEmpty {
                                    continuation.yield(.toolCallInputDelta(id: callID, partialJSON: arguments))
                                }

                            case .functionCallArgumentsDelta(let callID, let delta):
                                recordFunctionCallOrder(callID)
                                let existing = streamedFunctionCalls[callID] ?? PendingFunctionCallState(
                                    name: "",
                                    arguments: ""
                                )
                                streamedFunctionCalls[callID] = PendingFunctionCallState(
                                    name: existing.name,
                                    arguments: existing.arguments + delta
                                )
                                if !delta.isEmpty {
                                    continuation.yield(.toolCallInputDelta(id: callID, partialJSON: delta))
                                }

                            case .webSearchStarted(let id):
                                startToolCallIfNeeded(callID: id, name: "web_search")
                                streamedWebSearchIDs.insert(id)

                            case .webSearchDone(let id, _):
                                streamedWebSearchIDs.insert(id)

                            case .functionCallDone(let call):
                                recordFunctionCallOrder(call.callID)
                                startToolCallIfNeeded(callID: call.callID, name: call.name)
                                streamedFunctionCalls[call.callID] = PendingFunctionCallState(
                                    name: call.name,
                                    arguments: call.arguments
                                )

                            case .completed(let response):
                                finalResponse = response
                                if let response {
                                    previousResponseID = response.id
                                    stopReason = response.stopReason
                                } else if stopReason == nil {
                                    stopReason = "completed"
                                }

                            case .error(let message):
                                if openAIShouldFallbackModel(statusCode: 400, body: message),
                                   let nextModelIdentifier = AgenticClient.nextOpenAIModelCandidate(
                                    for: model,
                                    after: selectedModelIdentifier
                                   ) {
                                    await LatencyDiagnostics.shared.endLLMCall(
                                        runID: latencyRunID,
                                        key: llmCallKey,
                                        endedAt: CFAbsoluteTimeGetCurrent(),
                                        stopReason: "model_fallback",
                                        notes: message
                                    )
                                    retryModelIdentifier = nextModelIdentifier
                                    previousResponseID = nil
                                    break eventLoop
                                }

                                await LatencyDiagnostics.shared.endLLMCall(
                                    runID: latencyRunID,
                                    key: llmCallKey,
                                    endedAt: CFAbsoluteTimeGetCurrent(),
                                    stopReason: "error",
                                    notes: message
                                )
                                continuation.yield(.error(message))
                                continuation.finish()
                                return
                            }
                        }

                        if let retryModelIdentifier {
                            iterationPreferredModelIdentifier = retryModelIdentifier
                            continue retryIteration
                        }

                        if let usage = finalResponse?.usage {
                            await LatencyDiagnostics.shared.updateLLMUsage(
                                runID: latencyRunID,
                                key: llmCallKey,
                                inputTokens: usage.inputTokens,
                                outputTokens: usage.outputTokens
                            )
                            continuation.yield(
                                .usage(
                                    inputTokens: usage.inputTokens,
                                    outputTokens: usage.outputTokens
                                )
                            )
                        }

                        for searchCall in finalResponse?.webSearchCalls ?? [] {
                            // Skip if already streamed in real-time via output_item.added
                            guard !streamedWebSearchIDs.contains(searchCall.id) else {
                                // Still emit the result for already-streamed searches
                                continuation.yield(
                                    .toolCallResult(
                                        id: searchCall.id,
                                        output: searchCall.summary,
                                        isError: searchCall.isError
                                    )
                                )
                                continue
                            }
                            continuation.yield(.toolCallStart(id: searchCall.id, name: "web_search"))
                            if let actionJSON = searchCall.actionJSON, !actionJSON.isEmpty {
                                continuation.yield(.toolCallInputDelta(id: searchCall.id, partialJSON: actionJSON))
                            }
                            continuation.yield(
                                .toolCallResult(
                                    id: searchCall.id,
                                    output: searchCall.summary,
                                    isError: searchCall.isError
                                )
                            )
                        }

                        var functionCalls: [AgenticClient.OpenAIFunctionCall] = finalResponse?.functionCalls ?? []
                        if !functionCalls.isEmpty {
                            var seenFunctionCallIDs = Set(functionCalls.map(\.callID))
                            for call in functionCalls {
                                startToolCallIfNeeded(callID: call.callID, name: call.name)
                                if let streamed = streamedFunctionCalls[call.callID],
                                   streamed.arguments.isEmpty,
                                   !call.arguments.isEmpty {
                                    continuation.yield(.toolCallInputDelta(id: call.callID, partialJSON: call.arguments))
                                }
                            }
                            for callID in streamedFunctionOrder where !seenFunctionCallIDs.contains(callID) {
                                guard let streamed = streamedFunctionCalls[callID],
                                      !streamed.name.isEmpty else { continue }
                                functionCalls.append(
                                    AgenticClient.OpenAIFunctionCall(
                                        callID: callID,
                                        name: streamed.name,
                                        arguments: streamed.arguments
                                    )
                                )
                                seenFunctionCallIDs.insert(callID)
                            }
                        } else {
                            functionCalls = streamedFunctionOrder.compactMap { callID in
                                guard let streamed = streamedFunctionCalls[callID],
                                      !streamed.name.isEmpty else { return nil }
                                return AgenticClient.OpenAIFunctionCall(
                                    callID: callID,
                                    name: streamed.name,
                                    arguments: streamed.arguments
                                )
                            }
                        }

                        await LatencyDiagnostics.shared.endLLMCall(
                            runID: latencyRunID,
                            key: llmCallKey,
                            endedAt: CFAbsoluteTimeGetCurrent(),
                            stopReason: stopReason
                        )
                        if functionCalls.isEmpty {
                            continuation.yield(.completed(stopReason: stopReason ?? "completed"))
                            continuation.finish()
                            return
                        }

                        // Execute tools — parallel where safe, sequential otherwise.
                        let oaiPartitioned = ToolParallelism.partition(
                            functionCalls,
                            name: { $0.name },
                            inputJSON: { $0.arguments }
                        )
                        let oaiMaxParallel = StudioModelStrategy.shipMaxParallelTools(packageRoot: await client.projectRoot.path)
                        var functionOutputs = Array<Any?>(repeating: nil, count: functionCalls.count)

                        // --- Parallel batch (bounded concurrency) ---
                        if !oaiPartitioned.parallel.isEmpty {
                            let runCall: @Sendable (Int, AgenticClient.OpenAIFunctionCall) async -> (Int, Any) = { [weak client] idx, call in
                                guard let client else {
                                    let cancelled = ToolExecutionOutcome(text: "Tool cancelled", isError: true)
                                    return (idx, AgenticClient.openAIFunctionCallOutput(callID: call.callID, outcome: cancelled))
                                }
                                if Task.isCancelled {
                                    let cancelled = ToolExecutionOutcome(text: "Tool cancelled", isError: true)
                                    continuation.yield(.toolCallResult(id: call.callID, output: cancelled.displayText, isError: true))
                                    return (idx, AgenticClient.openAIFunctionCallOutput(callID: call.callID, outcome: cancelled))
                                }
                                let input = AgenticClient.parseJSON(call.arguments) ?? [:]
                                let toolStartedAt = CFAbsoluteTimeGetCurrent()
                                let outcome = await client.executeTool(
                                    name: call.name,
                                    input: input
                                ) { progress in
                                    switch progress {
                                    case .command(let command):
                                        continuation.yield(.toolCallCommand(id: call.callID, command: command))
                                    case .output(let line):
                                        continuation.yield(.toolCallOutput(id: call.callID, line: line))
                                    }
                                }
                                let toolEndedAt = CFAbsoluteTimeGetCurrent()
                                await LatencyDiagnostics.shared.recordToolLoop(
                                    runID: latencyRunID,
                                    key: "\(llmCallKey).tool.\(call.callID)",
                                    loopIndex: iteration,
                                    action: call.name,
                                    startedAt: toolStartedAt,
                                    endedAt: toolEndedAt,
                                    notes: "tool_call_id=\(call.callID) is_error=\(outcome.isError) parallel=true"
                                )
                                continuation.yield(.toolCallResult(id: call.callID, output: outcome.displayText, isError: outcome.isError))
                                return (idx, AgenticClient.openAIFunctionCallOutput(callID: call.callID, outcome: outcome))
                            }
                            await withTaskGroup(of: (Int, Any).self) { group in
                                var iter = oaiPartitioned.parallel.makeIterator()
                                for _ in 0..<min(oaiMaxParallel, oaiPartitioned.parallel.count) {
                                    guard let (idx, call) = iter.next() else { break }
                                    group.addTask { await runCall(idx, call) }
                                }
                                for await (idx, output) in group {
                                    functionOutputs[idx] = output
                                    if let (nextIdx, nextCall) = iter.next() {
                                        group.addTask { await runCall(nextIdx, nextCall) }
                                    }
                                }
                            }
                        }

                        // --- Sequential batch ---
                        for (idx, call) in oaiPartitioned.sequential {
                            if Task.isCancelled {
                                let cancelled = ToolExecutionOutcome(text: "Tool cancelled", isError: true)
                                continuation.yield(.toolCallResult(id: call.callID, output: cancelled.displayText, isError: true))
                                functionOutputs[idx] = AgenticClient.openAIFunctionCallOutput(callID: call.callID, outcome: cancelled)
                                continue
                            }
                            let input = AgenticClient.parseJSON(call.arguments) ?? [:]
                            let toolStartedAt = CFAbsoluteTimeGetCurrent()
                            let outcome = await client.executeTool(
                                name: call.name,
                                input: input
                            ) { progress in
                                switch progress {
                                case .command(let command):
                                    continuation.yield(.toolCallCommand(id: call.callID, command: command))
                                case .output(let line):
                                    continuation.yield(.toolCallOutput(id: call.callID, line: line))
                                }
                            }
                            let toolEndedAt = CFAbsoluteTimeGetCurrent()
                            await LatencyDiagnostics.shared.recordToolLoop(
                                runID: latencyRunID,
                                key: "\(llmCallKey).tool.\(call.callID)",
                                loopIndex: iteration,
                                action: call.name,
                                startedAt: toolStartedAt,
                                endedAt: toolEndedAt,
                                notes: "tool_call_id=\(call.callID) is_error=\(outcome.isError)"
                            )
                            continuation.yield(.toolCallResult(id: call.callID, output: outcome.displayText, isError: outcome.isError))
                            functionOutputs[idx] = AgenticClient.openAIFunctionCallOutput(callID: call.callID, outcome: outcome)
                        }

                        pendingInput = functionOutputs.compactMap { $0 }
                        break retryIteration
                    }
                }

                continuation.yield(.error("Reached max iterations (\(maxIterations))"))
                continuation.finish()
            } catch let error as AgenticBridgeError {
                continuation.yield(.error(AgenticClient.userFacingOpenAIErrorMessage(for: error)))
                continuation.finish()
            } catch {
                continuation.yield(.error("Agentic error: \(error.localizedDescription)"))
                continuation.finish()
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
