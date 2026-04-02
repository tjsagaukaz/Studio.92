// AgenticBridge.swift
// Studio.92 — Command Center
// In-process streaming client for the agentic loop.
// Self-contained — calls Anthropic or OpenAI directly via URLSession,
// parses SSE events where available, and executes tool calls. No SPM dependency required.

import Foundation
import AppKit
import ImageIO

// MARK: - Agentic Client

private final class UTF8StreamDecoder {

    private var buffer = Data()

    func append(_ chunk: Data) -> String? {
        buffer.append(chunk)

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

    private let anthropicAPIKey: String?
    private let openAIKey:       String?
    private let projectRoot: URL
    private let autonomyMode: AutonomyMode
    private let allowMachineWideAccess: Bool
    private let session:     URLSession

    private static let apiVersion   = "2023-06-01"
    private static let messagesURL  = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    init(
        apiKey: String?,
        projectRoot: URL,
        openAIKey: String? = nil,
        autonomyMode: AutonomyMode = .review,
        allowMachineWideAccess: Bool = true,
        session: URLSession = AgenticClient.defaultSession
    ) {
        self.anthropicAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openAIKey       = openAIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectRoot     = projectRoot
        self.autonomyMode = autonomyMode
        self.allowMachineWideAccess = allowMachineWideAccess
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
        tools:         [[String: Any]]? = nil,
        thinking:      [String: Any]? = nil,
        cacheControl:  [String: Any]? = nil,
        maxIterations: Int = 25
    ) -> AsyncStream<AgenticEvent> {
        switch model.provider {
        case .anthropic:
            guard let anthropicAPIKey, !anthropicAPIKey.isEmpty else {
                return Self.errorStream("Anthropic API key missing for \(model.displayName).")
            }
            return runAnthropic(
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
                maxIterations: maxIterations
            )
        case .openAI:
            guard let openAIKey, !openAIKey.isEmpty else {
                return Self.errorStream("OpenAI API key missing for \(model.displayName).")
            }
            return runOpenAI(
                system: system,
                userMessage: userMessage,
                userContentBlocks: userContentBlocks,
                initialMessages: initialMessages,
                model: model,
                maxTokens: maxTokens,
                outputEffort: outputEffort,
                tools: tools,
                maxIterations: maxIterations
            )
        }
    }

    private func runAnthropic(
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
        maxIterations: Int
    ) -> AsyncStream<AgenticEvent> {
        let (stream, continuation) = AsyncStream<AgenticEvent>.makeStream()

        let task = Task { [weak self] in
            guard let self else { continuation.finish(); return }

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

                    var assistantText    = ""
                    var assistantBlocksByIndex: [Int: AssistantBlockAccumulator] = [:]
                    var stopReason: String?

                    // Stream one model turn.
                    let events = try await self.streamRequest(
                        system:      system,
                        messages:    messages,
                        model:       model.identifier,
                        maxTokens:   maxTokens,
                        temperature: temperature,
                        outputEffort: outputEffort,
                        tools:       tools,
                        thinking:    thinking,
                        cacheControl: cacheControl
                    )

                    for try await event in events {
                        if Task.isCancelled { break }

                        switch event {
                        case .textDelta(let index, let text):
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
                            continuation.yield(.usage(inputTokens: input, outputTokens: output))

                        case .stopReason(let reason):
                            stopReason = reason

                        case .error(let msg):
                            continuation.yield(.error(msg))
                            continuation.finish()
                            return
                        }
                    }

                    if Task.isCancelled { break }

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

                    // Execute tools and build result blocks.
                    var toolResults: [[String: Any]] = []
                    for tc in pendingToolCalls {
                        let input = Self.parseJSON(tc.inputJSON) ?? [:]
                        let outcome = await self.executeTool(
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
                        continuation.yield(.toolCallResult(id: tc.id, output: outcome.displayText, isError: outcome.isError))
                        toolResults.append(
                            Self.toolResultPayload(
                                toolUseID: tc.id,
                                outcome: outcome
                            )
                        )
                    }
                    messages.append(["role": "user", "content": toolResults])
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

    private func runOpenAI(
        system: String,
        userMessage: String,
        userContentBlocks: [[String: Any]]?,
        initialMessages: [[String: Any]],
        model: StudioModelDescriptor,
        maxTokens: Int,
        outputEffort: String?,
        tools: [[String: Any]]?,
        maxIterations: Int
    ) -> AsyncStream<AgenticEvent> {
        let (stream, continuation) = AsyncStream<AgenticEvent>.makeStream()

        let task = Task { [weak self] in
            guard let self else { continuation.finish(); return }

            var previousResponseID: String?
            var pendingInput: [Any] = Self.openAIInputMessages(
                initialMessages: initialMessages,
                userMessage: userMessage,
                userContentBlocks: userContentBlocks
            )

            do {
                for _ in 0..<maxIterations {
                    if Task.isCancelled { break }

                    let response = try await self.createOpenAIResponse(
                        instructions: system,
                        input: pendingInput,
                        previousResponseID: previousResponseID,
                        model: model.identifier,
                        maxOutputTokens: maxTokens,
                        reasoningEffort: outputEffort,
                        tools: Self.openAIToolSchemas(from: tools)
                    )
                    previousResponseID = response.id

                    if let usage = response.usage {
                        continuation.yield(
                            .usage(
                                inputTokens: usage.inputTokens,
                                outputTokens: usage.outputTokens
                            )
                        )
                    }

                    for fragment in response.textFragments {
                        continuation.yield(.textDelta(fragment))
                    }

                    let functionCalls = response.functionCalls
                    if functionCalls.isEmpty {
                        continuation.yield(.completed(stopReason: response.stopReason ?? "end_turn"))
                        continuation.finish()
                        return
                    }

                    var functionOutputs: [Any] = []
                    for call in functionCalls {
                        continuation.yield(.toolCallStart(id: call.callID, name: call.name))
                        continuation.yield(.toolCallInputDelta(id: call.callID, partialJSON: call.arguments))

                        let input = Self.parseJSON(call.arguments) ?? [:]
                        let outcome = await self.executeTool(
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
                        continuation.yield(
                            .toolCallResult(
                                id: call.callID,
                                output: outcome.displayText,
                                isError: outcome.isError
                            )
                        )
                        functionOutputs.append(
                            Self.openAIFunctionCallOutput(
                                callID: call.callID,
                                outcome: outcome
                            )
                        )
                    }

                    pendingInput = functionOutputs
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

    // MARK: - HTTP Streaming

    private func streamRequest(
        system:      String,
        messages:    [[String: Any]],
        model:       String,
        maxTokens:   Int,
        temperature: Double?,
        outputEffort: String?,
        tools:       [[String: Any]]?,
        thinking:    [String: Any]?,
        cacheControl: [String: Any]?
    ) async throws -> AsyncThrowingStream<SSEEvent, Error> {
        let systemPayload: [[String: Any]] = [[
            "type": "text",
            "text": system
        ]]

        var body: [String: Any] = [
            "model":      model,
            "max_tokens": maxTokens,
            "system":     systemPayload,
            "messages":   messages,
            "stream":     true
        ]
        if let outputEffort {
            body["output_config"] = ["effort": outputEffort]
        }
        if let thinking {
            body["thinking"] = thinking
            // temperature must be omitted when thinking is enabled
        } else if let temperature {
            body["temperature"] = temperature
        }
        if let tools, !tools.isEmpty { body["tools"] = tools }
        if let cacheControl {
            body["cache_control"] = cacheControl
        }

        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(anthropicAPIKey,    forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion,    forHTTPHeaderField: "anthropic-version")
        if let betaHeader = Self.anthropicBetaHeader(for: model, thinking: thinking) {
            request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        }
        let requestBody = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = requestBody

        #if DEBUG
        let requestStartedAt = Date()
        #endif

        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AgenticBridgeError.noHTTPResponse
        }
        guard http.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let errorBody = String(decoding: errorData, as: UTF8.self)
            throw AgenticBridgeError.apiError(statusCode: http.statusCode, body: errorBody)
        }

        #if DEBUG
        print(
            "[AgenticLatency] headers_received " +
            "model=\(model) " +
            "effort=\(outputEffort ?? "default") " +
            "thinking=\(thinking != nil) " +
            "tools=\(tools?.count ?? 0) " +
            "body_bytes=\(requestBody.count) " +
            "elapsed=\(Self.debugElapsed(since: requestStartedAt))"
        )
        #endif

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lineBuffer = ""
                    var eventType  = ""
                    var eventData  = ""
                    let decoder = UTF8StreamDecoder()
                    #if DEBUG
                    var didLogFirstEvent = false
                    var didLogUsage = false
                    #endif

                    func emitParsedEventIfNeeded() {
                        guard !eventData.isEmpty else {
                            eventType = ""
                            return
                        }

                        #if DEBUG
                        if !didLogUsage, eventType == "message_start" {
                            Self.debugLogUsage(from: eventData)
                            didLogUsage = true
                        }
                        #endif

                        if let event = Self.parseSSE(type: eventType, data: eventData) {
                            #if DEBUG
                            if !didLogFirstEvent {
                                didLogFirstEvent = true
                                print(
                                    "[AgenticLatency] first_event " +
                                    "type=\(Self.debugLabel(for: event)) " +
                                    "elapsed=\(Self.debugElapsed(since: requestStartedAt))"
                                )
                            }
                            #endif
                            continuation.yield(event)
                        }

                        eventType = ""
                        eventData = ""
                    }

                    func consumeLine(_ rawLine: String) {
                        var line = rawLine
                        if line.hasSuffix("\r") {
                            line.removeLast()
                        }

                        if line.isEmpty {
                            emitParsedEventIfNeeded()
                            return
                        }

                        if line.hasPrefix("event:") {
                            eventType = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .init(charactersIn: " "))
                            if eventData.isEmpty {
                                eventData = payload
                            } else {
                                eventData += "\n" + payload
                            }
                        }
                    }

                    func consumeDecoded(_ decoded: String) {
                        for character in decoded {
                            if character == "\n" {
                                consumeLine(lineBuffer)
                                lineBuffer.removeAll(keepingCapacity: true)
                            } else {
                                lineBuffer.append(character)
                            }
                        }
                    }

                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if let decoded = decoder.append(Data([byte])) {
                            consumeDecoded(decoded)
                        }
                    }

                    if let decodedTail = decoder.flush(), !decodedTail.isEmpty {
                        consumeDecoded(decodedTail)
                    }
                    if !lineBuffer.isEmpty {
                        consumeLine(lineBuffer)
                        lineBuffer.removeAll(keepingCapacity: true)
                    }
                    emitParsedEventIfNeeded()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func createOpenAIResponse(
        instructions: String,
        input: [Any],
        previousResponseID: String?,
        model: String,
        maxOutputTokens: Int,
        reasoningEffort: String?,
        tools: [[String: Any]]
    ) async throws -> OpenAIResponseEnvelope {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "max_output_tokens": maxOutputTokens,
            "parallel_tool_calls": false
        ]
        if let previousResponseID, !previousResponseID.isEmpty {
            body["previous_response_id"] = previousResponseID
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }
        if let reasoningEffort, !reasoningEffort.isEmpty {
            body["reasoning"] = ["effort": reasoningEffort]
        }

        var request = URLRequest(url: Self.responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(openAIKey ?? "")", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgenticBridgeError.noHTTPResponse
        }
        guard http.statusCode == 200 else {
            let errorBody = String(decoding: data, as: UTF8.self)
            throw AgenticBridgeError.apiError(statusCode: http.statusCode, body: errorBody)
        }
        return try OpenAIResponseEnvelope(data: data)
    }

    // MARK: - SSE Parsing

    private enum SSEEvent {
        case textDelta(index: Int, String)
        case thinkingDelta(index: Int, String)
        case thinkingSignature(index: Int, String)
        case toolCallStart(index: Int, id: String, name: String)
        case toolCallInputDelta(index: Int, json: String)
        case usage(input: Int, output: Int)
        case stopReason(String)
        case error(String)
    }

    private static func parseSSE(type: String, data: String) -> SSEEvent? {
        guard data != "[DONE]" else { return nil }
        guard let json = parseJSON(data) else { return nil }

        switch type {
        case "message_start":
            if let msg = json["message"] as? [String: Any],
               let usage = msg["usage"] as? [String: Any],
               let input = usage["input_tokens"] as? Int,
               let output = usage["output_tokens"] as? Int {
                return .usage(input: input, output: output)
            }
            return nil

        case "content_block_start":
            guard let block = json["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else { return nil }
            if blockType == "tool_use" {
                let index = json["index"] as? Int ?? 0
                let id   = block["id"]   as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "unknown"
                return .toolCallStart(index: index, id: id, name: name)
            }
            return nil

        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return nil }
            let index = json["index"] as? Int ?? 0
            switch deltaType {
            case "text_delta":
                return .textDelta(index: index, delta["text"] as? String ?? "")
            case "input_json_delta":
                let partialJSON = delta["partial_json"] as? String ?? ""
                return .toolCallInputDelta(index: index, json: partialJSON)
            case "thinking_delta":
                return .thinkingDelta(index: index, delta["thinking"] as? String ?? "")
            case "signature_delta":
                return .thinkingSignature(index: index, delta["signature"] as? String ?? "")
            default:
                return nil
            }

        case "message_delta":
            if let delta = json["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                return .stopReason(reason)
            }
            if let usage = json["usage"] as? [String: Any],
               let output = usage["output_tokens"] as? Int {
                return .usage(input: 0, output: output)
            }
            return nil

        case "error":
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return .error(message)
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: - Tool Execution

    private func executeTool(
        name: String,
        input: [String: Any],
        progress: @escaping @Sendable (ToolProgress) -> Void = { _ in }
    ) async -> ToolExecutionOutcome {
        if let permissionError = permissionError(for: name) {
            return ToolExecutionOutcome(text: permissionError, isError: true)
        }

        switch name {
        case "file_read":
            let raw = executeFileRead(input)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case "file_write":
            let raw = executeFileWrite(input)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case "file_patch":
            let raw = executeFilePatch(input)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case "list_files":
            let raw = executeListFiles(input)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case "delegate_to_explorer":
            return await executeDelegateToExplorer(input)
        case "delegate_to_reviewer":
            return await executeDelegateToReviewer(input)
        case "delegate_to_worktree":
            return await executeDelegateToWorktree(input)
        case "terminal":
            let raw = await executeTerminal(input, progress: progress)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case "deploy_to_testflight":
            let raw = await executeDeployToTestFlight(input, progress: progress)
            return ToolExecutionOutcome(text: raw.0, isError: raw.1)
        case "web_search":
            return await executeWebSearch(input)
        default:
            return ToolExecutionOutcome(text: "Unknown tool: \(name)", isError: true)
        }
    }

    private func permissionError(for toolName: String) -> String? {
        switch autonomyMode {
        case .plan:
            if ["file_write", "file_patch", "terminal", "deploy_to_testflight", "delegate_to_worktree"].contains(toolName) {
                return "System Error: User has restricted your permissions to Plan mode. You cannot execute this action."
            }
            return nil
        case .review:
            if ["file_write", "file_patch", "deploy_to_testflight", "delegate_to_worktree"].contains(toolName) {
                return "System Error: User has restricted your permissions to Review mode. You cannot execute this action. Present the proposed code in the conversation for manual diff approval instead."
            }
            return nil
        case .fullSend:
            return nil
        }
    }

    private func executeFileRead(_ input: [String: Any]) -> (String, Bool) {
        guard let path = input["path"] as? String else { return ("Missing: path", true) }
        let url = resolvedURL(for: path)
        guard sandboxCheck(url) else { return ("Access denied: outside project directory", true) }
        guard FileManager.default.fileExists(atPath: url.path) else { return ("File not found: \(url.path)", true) }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return ("Cannot read file", true) }
        if content.count > 100_000 {
            return (String(content.prefix(100_000)) + "\n\n[Truncated at 100K chars]", false)
        }
        return (content, false)
    }

    private func executeFileWrite(_ input: [String: Any]) -> (String, Bool) {
        guard let path = input["path"] as? String,
              let content = input["content"] as? String else { return ("Missing: path, content", true) }
        let url = resolvedURL(for: path)
        guard sandboxCheck(url) else { return ("Access denied: outside project directory", true) }
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

    private func executeFilePatch(_ input: [String: Any]) -> (String, Bool) {
        guard let path = input["path"] as? String,
              let oldString = input["old_string"] as? String,
              let newString = input["new_string"] as? String else { return ("Missing: path, old_string, new_string", true) }
        let url = resolvedURL(for: path)
        guard sandboxCheck(url) else { return ("Access denied: outside project directory", true) }
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

    private func executeListFiles(_ input: [String: Any]) -> (String, Bool) {
        let pathStr = input["path"] as? String
        let url = pathStr.map { resolvedURL(for: $0) } ?? projectRoot
        guard sandboxCheck(url) else { return ("Access denied: outside project directory", true) }
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

    private func executeDelegateToExplorer(_ input: [String: Any]) async -> ToolExecutionOutcome {
        guard let objective = (input["objective"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !objective.isEmpty else {
            return ToolExecutionOutcome(text: "Missing: objective", isError: true)
        }

        let targetDirectories = stringArray(from: input["target_directories"])

        do {
            let summary = try await runSubAgent(
                system: """
                You are Workspace Explorer, a fast read-only codebase scout.
                Stay focused on the objective and read only what materially helps. Prefer file_read, list_files, and web_search when they reduce guesswork.
                Return a concise, high-density summary of structure, data flow, mismatches, and risks. Keep it practical. Do not propose patches or dump raw transcripts.
                """,
                prompt: explorerPrompt(
                    objective: objective,
                    targetDirectories: targetDirectories
                ),
                model: StudioModelStrategy.subagent,
                tools: DefaultToolSchemas.explorerTools
            )

            return ToolExecutionOutcome(
                displayText: "Workspace Explorer returned findings.",
                toolResultPayload: summary,
                isError: false
            )
        } catch {
            return ToolExecutionOutcome(
                text: "Workspace Explorer failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func executeDelegateToReviewer(_ input: [String: Any]) async -> ToolExecutionOutcome {
        let filesToReview = stringArray(from: input["files_to_review"])
        guard !filesToReview.isEmpty else {
            return ToolExecutionOutcome(text: "Missing: files_to_review", isError: true)
        }
        guard let focusArea = (input["focus_area"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !focusArea.isEmpty else {
            return ToolExecutionOutcome(text: "Missing: focus_area", isError: true)
        }

        do {
            let summary = try await runSubAgent(
                system: """
                You are Code Reviewer, a sharp senior iOS reviewer.
                Audit only the provided files through the requested lens and return a short list of the most important findings.
                Stay read-only. Use file_read to inspect the files and list_files only for a tiny amount of nearby context. Do not rewrite code, and only quote tiny snippets when they are essential to explain a real issue.
                """,
                prompt: reviewerPrompt(
                    filesToReview: filesToReview,
                    focusArea: focusArea
                ),
                model: StudioModelStrategy.review,
                tools: DefaultToolSchemas.reviewerTools
            )

            return ToolExecutionOutcome(
                displayText: "Code Reviewer returned findings.",
                toolResultPayload: summary,
                isError: false
            )
        } catch {
            return ToolExecutionOutcome(
                text: "Code Reviewer failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func executeDelegateToWorktree(_ input: [String: Any]) async -> ToolExecutionOutcome {
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

    private func executeTerminal(
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

    private func executeWebSearch(_ input: [String: Any]) async -> ToolExecutionOutcome {
        guard let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return ToolExecutionOutcome(text: "Missing: query", isError: true)
        }

        do {
            let result = try await runResearcher(query: query)
            let contextPack = Self.readContextPack().trimmingCharacters(in: .whitespacesAndNewlines)
            let searchResultPayloads = Self.readContextPackResults().compactMap { result -> [String: Any]? in
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
                let details = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if details.isEmpty {
                    return ToolExecutionOutcome(text: "Web search failed, please rely on internal knowledge.", isError: true)
                }
                return ToolExecutionOutcome(text: "Web search failed, please rely on internal knowledge.\n\n\(details)", isError: true)
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
                return ToolExecutionOutcome(text: stdout, isError: false)
            }

            return ToolExecutionOutcome(text: "Web search failed, please rely on internal knowledge.", isError: true)
        } catch {
            return ToolExecutionOutcome(text: "Web search failed, please rely on internal knowledge.", isError: true)
        }
    }

    private func executeDeployToTestFlight(
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

    private func executeDirectTerminalCommand(
        _ command: String,
        timeoutSeconds: Int,
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async -> (String, Bool) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Missing: command", true) }

        await primePersistentShellToProjectRoot()
        progress(.command(trimmed))
        progress(.output("$ \(trimmed)"))

        let execution = await collectShellExecution(
            command: trimmed,
            timeoutSeconds: timeoutSeconds,
            progress: progress
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

    // MARK: - Helpers

    private func runSubAgent(
        system: String,
        prompt: String,
        model: StudioModelDescriptor,
        tools: [[String: Any]],
        maxIterations: Int = 8,
        maxTokens: Int = 3072
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
                maxTokens: maxTokens
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
                maxTokens: maxTokens
            )
        }
    }

    private func runAnthropicSubAgent(
        system: String,
        prompt: String,
        model: StudioModelDescriptor,
        tools: [[String: Any]],
        maxIterations: Int,
        maxTokens: Int
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
                let outcome = await executeSubagentTool(name: toolCall.name, input: toolCall.input)
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
        maxTokens: Int
    ) async throws -> String {
        var previousResponseID: String?
        var pendingInput: [Any] = [
            Self.openAIInputMessage(role: "user", text: prompt, anthropicContentBlocks: nil)
        ]

        for _ in 0..<maxIterations {
            let response = try await createOpenAIResponse(
                instructions: system,
                input: pendingInput,
                previousResponseID: previousResponseID,
                model: model.identifier,
                maxOutputTokens: maxTokens,
                reasoningEffort: model.defaultReasoningEffort,
                tools: Self.openAIToolSchemas(from: tools)
            )
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
                let outcome = await executeSubagentTool(name: toolCall.name, input: input)
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
        body["cache_control"] = ["type": "ephemeral"]

        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgenticBridgeError.noHTTPResponse
        }
        guard http.statusCode == 200 else {
            let errorBody = String(decoding: data, as: UTF8.self)
            throw AgenticBridgeError.apiError(statusCode: http.statusCode, body: errorBody)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgenticBridgeError.apiError(statusCode: -1, body: "Invalid sub-agent response")
        }
        return object
    }

    private func executeSubagentTool(
        name: String,
        input: [String: Any]
    ) async -> ToolExecutionOutcome {
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

    private func stringArray(from value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
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

    private func summarizeSubAgentText(from blocks: [[String: Any]]) -> String {
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

    private func subAgentToolUses(from blocks: [[String: Any]]) -> [(id: String, name: String, input: [String: Any])] {
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

    private func primePersistentShellToProjectRoot() async {
        let bootstrapCommand = "cd \(Self.shellQuoted(projectRoot.path))"
        let stream = await StatefulTerminalEngine.shared.execute(bootstrapCommand)
        for await _ in stream {}
    }

    private func collectShellExecution(
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

    private func resolvedURL(for path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : projectRoot.appendingPathComponent(path)
    }

    private func sandboxCheck(_ url: URL) -> Bool {
        if autonomyMode == .fullSend && allowMachineWideAccess {
            return true
        }
        return url.standardized.path.hasPrefix(projectRoot.standardized.path)
    }

    private func lineHeuristic(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    private func runResearcher(query: String) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let openAIKey = self.openAIKey

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(exitCode: Int32, stdout: String, stderr: String), Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [projectRoot, openAIKey] in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", "Factory/researcher.py", query]
                process.currentDirectoryURL = projectRoot
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var environment = ProcessInfo.processInfo.environment
                if let openAIKey, !openAIKey.isEmpty {
                    environment["OPENAI_API_KEY"] = openAIKey
                }
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
                let exitCode: Int32 = waitResult == .timedOut ? -1 : process.terminationStatus
                continuation.resume(returning: (exitCode, stdout, stderr))
            }
        }
    }

    private static func readContextPack() -> String {
        let path = NSString(string: "~/.darkfactory/context_pack.txt").expandingTildeInPath
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private static func readContextPackResults() -> [ResearcherSearchResult] {
        let path = NSString(string: "~/.darkfactory/context_pack_results.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let results = try? JSONDecoder().decode([ResearcherSearchResult].self, from: data) else {
            return []
        }
        return results
    }

    private static func formattedShellToolResult(
        command: String,
        output: String,
        exitStatus: Int,
        didTimeout: Bool
    ) -> String {
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

    private static func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func toolResultPayload(toolUseID: String, outcome: ToolExecutionOutcome) -> [String: Any] {
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

    private static func openAIToolSchemas(from tools: [[String: Any]]?) -> [[String: Any]] {
        guard let tools, !tools.isEmpty else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String,
                  let description = tool["description"] as? String,
                  let parameters = tool["input_schema"] as? [String: Any] else {
                return nil
            }

            return [
                "type": "function",
                "name": name,
                "description": description,
                "parameters": parameters,
                "strict": tool["strict"] as? Bool ?? true
            ]
        }
    }

    private static func openAIInputMessages(
        initialMessages: [[String: Any]],
        userMessage: String,
        userContentBlocks: [[String: Any]]?
    ) -> [Any] {
        var items: [Any] = initialMessages.map { openAIInputMessage(from: $0) }
        items.append(
            openAIInputMessage(
                role: "user",
                text: (userContentBlocks?.isEmpty == false) ? nil : userMessage,
                anthropicContentBlocks: userContentBlocks
            )
        )
        return items
    }

    private static func openAIInputMessage(from payload: [String: Any]) -> [String: Any] {
        let role = (payload["role"] as? String) ?? "user"

        if let content = payload["content"] as? String {
            return openAIInputMessage(role: role, text: content, anthropicContentBlocks: nil)
        }

        let anthropicBlocks = payload["content"] as? [[String: Any]]
        return openAIInputMessage(role: role, text: nil, anthropicContentBlocks: anthropicBlocks)
    }

    private static func openAIInputMessage(
        role: String,
        text: String?,
        anthropicContentBlocks: [[String: Any]]?
    ) -> [String: Any] {
        var content: [[String: Any]] = []

        if let text, !text.isEmpty {
            content.append([
                "type": "input_text",
                "text": text
            ])
        }

        if let anthropicContentBlocks {
            content.append(contentsOf: openAIContentBlocks(from: anthropicContentBlocks))
        }

        if content.isEmpty {
            content.append([
                "type": "input_text",
                "text": ""
            ])
        }

        return [
            "role": role,
            "content": content
        ]
    }

    private static func openAIContentBlocks(from anthropicBlocks: [[String: Any]]) -> [[String: Any]] {
        anthropicBlocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String else { return nil }
                return [
                    "type": "input_text",
                    "text": text
                ]
            case "image":
                guard let source = block["source"] as? [String: Any],
                      let mediaType = source["media_type"] as? String,
                      let data = source["data"] as? String else {
                    return nil
                }
                return [
                    "type": "input_image",
                    "image_url": "data:\(mediaType);base64,\(data)"
                ]
            default:
                return nil
            }
        }
    }

    private static func openAIFunctionCallOutput(
        callID: String,
        outcome: ToolExecutionOutcome
    ) -> [String: Any] {
        [
            "type": "function_call_output",
            "call_id": callID,
            "output": serializedOpenAIFunctionOutput(from: outcome)
        ]
    }

    private static func serializedOpenAIFunctionOutput(from outcome: ToolExecutionOutcome) -> String {
        if let text = outcome.toolResultPayload as? String {
            return text
        }

        if JSONSerialization.isValidJSONObject(outcome.toolResultPayload),
           let data = try? JSONSerialization.data(
                withJSONObject: outcome.toolResultPayload,
                options: [.prettyPrinted]
           ),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return outcome.displayText
    }

    private static func anthropicBetaHeader(for model: String, thinking: [String: Any]?) -> String? {
        _ = model
        _ = thinking
        return nil
    }

    #if DEBUG
    private static func debugElapsed(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    private static func debugLabel(for event: SSEEvent) -> String {
        switch event {
        case .textDelta:
            return "text_delta"
        case .thinkingDelta:
            return "thinking_delta"
        case .thinkingSignature:
            return "thinking_signature"
        case .toolCallStart:
            return "tool_call_start"
        case .toolCallInputDelta:
            return "tool_call_input_delta"
        case .usage:
            return "usage"
        case .stopReason:
            return "stop_reason"
        case .error:
            return "error"
        }
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

    private struct PendingTool {
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

    private struct OpenAIUsage {
        let inputTokens: Int
        let outputTokens: Int
    }

    private struct OpenAIFunctionCall {
        let callID: String
        let name: String
        let arguments: String
    }

    private struct OpenAIResponseEnvelope {
        let id: String
        let outputItems: [[String: Any]]
        let usage: OpenAIUsage?
        let stopReason: String?

        init(data: Data) throws {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String else {
                throw AgenticBridgeError.apiError(statusCode: -1, body: "Invalid OpenAI response envelope")
            }

            self.id = id
            self.outputItems = json["output"] as? [[String: Any]] ?? []
            if let usageObject = json["usage"] as? [String: Any] {
                self.usage = OpenAIUsage(
                    inputTokens: usageObject["input_tokens"] as? Int ?? 0,
                    outputTokens: usageObject["output_tokens"] as? Int ?? 0
                )
            } else {
                self.usage = nil
            }
            self.stopReason = json["status"] as? String
        }

        var functionCalls: [OpenAIFunctionCall] {
            outputItems.compactMap { item in
                guard (item["type"] as? String) == "function_call",
                      let callID = item["call_id"] as? String,
                      let name = item["name"] as? String,
                      let arguments = item["arguments"] as? String else {
                    return nil
                }
                return OpenAIFunctionCall(callID: callID, name: name, arguments: arguments)
            }
        }

        var textFragments: [String] {
            outputItems.flatMap { item -> [String] in
                guard (item["type"] as? String) == "message",
                      let content = item["content"] as? [[String: Any]] else {
                    return []
                }

                return content.compactMap { fragment -> String? in
                    switch fragment["type"] as? String {
                    case "output_text":
                        return fragment["text"] as? String
                    case "text":
                        return fragment["text"] as? String
                    default:
                        return nil
                    }
                }
            }
        }
    }

    private struct ShellExecutionCapture {
        let output: String
        let exitStatus: Int
        let didTimeout: Bool
    }

    private static func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}

enum VisionPayloadBuilder {

    static func imageContentBlock(from url: URL, maxDimension: CGFloat = 1024) async -> [String: Any]? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = thumbnail(from: source, maxDimension: maxDimension) else {
                return nil
            }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionFactor: 0.82
            ]
            guard let jpegData = bitmap.representation(using: .jpeg, properties: properties) else {
                return nil
            }

            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": jpegData.base64EncodedString()
                ]
            ]
        }.value
    }

    private static func thumbnail(
        from source: CGImageSource,
        maxDimension: CGFloat
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

actor FastlaneDeploymentRunner {

    static let shared = FastlaneDeploymentRunner()

    private var activeProcess: Process?

    fileprivate func run(
        projectRoot: URL,
        lane: String,
        command: String,
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async -> (String, Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
                        progress(.output(presented))
                    }
                }

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
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

                Task {
                    await self?.setActiveProcess(process)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ("Failed to launch fastlane \(lane): \(error.localizedDescription)", true))
                    return
                }

                process.waitUntilExit()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                emitBufferedLines(from: &stdoutBuffer, isError: false)
                emitBufferedLines(from: &stderrBuffer, isError: true)

                Task {
                    await self?.clearActiveProcess()
                }

                lock.lock()
                let combined = outputLines.joined(separator: "\n")
                lock.unlock()

                let status = process.terminationStatus
                let summary = status == 0
                    ? "Fastlane \(lane) completed successfully."
                    : "Fastlane \(lane) failed with exit code \(status)."
                let result = combined.isEmpty ? summary : "\(summary)\n\n\(combined)"
                continuation.resume(returning: (result, status != 0))
            }
        }
    }

    func cancel() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    private func setActiveProcess(_ process: Process) {
        activeProcess = process
    }

    private func clearActiveProcess() {
        activeProcess = nil
    }
}

// MARK: - Agentic Event (UI-facing)

fileprivate enum ToolProgress: Sendable {
    case command(String)
    case output(String)
}

private struct ToolExecutionOutcome {
    let displayText: String
    let toolResultPayload: Any
    let isError: Bool

    init(displayText: String, toolResultPayload: Any, isError: Bool) {
        self.displayText = displayText
        self.toolResultPayload = toolResultPayload
        self.isError = isError
    }

    init(text: String, isError: Bool) {
        self.init(displayText: text, toolResultPayload: text, isError: isError)
    }
}

private struct ResearcherSearchResult: Decodable {
    let query: String
    let title: String
    let url: String
    let snippet: String
}

private actor ShellCommandLifecycle {
    private var finished = false
    private var timedOut = false

    func markFinished() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }

    func markTimedOut() {
        timedOut = true
    }

    func didTimeout() -> Bool {
        timedOut
    }
}

private actor CodexTerminalCoordinator {

    private struct FunctionCall {
        let callID: String
        let name: String
        let arguments: String
    }

    private struct ResponseEnvelope {
        let id: String
        let outputItems: [[String: Any]]

        var functionCalls: [FunctionCall] {
            outputItems.compactMap { item in
                guard (item["type"] as? String) == "function_call",
                      let callID = item["call_id"] as? String,
                      let name = item["name"] as? String,
                      let arguments = item["arguments"] as? String else {
                    return nil
                }
                return FunctionCall(callID: callID, name: name, arguments: arguments)
            }
        }

        var textOutput: String {
            outputItems
                .compactMap { item -> String? in
                    guard (item["type"] as? String) == "message",
                          let content = item["content"] as? [[String: Any]] else {
                        return nil
                    }

                    let fragments = content.compactMap { fragment -> String? in
                        guard (fragment["type"] as? String) == "output_text" else { return nil }
                        return fragment["text"] as? String
                    }

                    guard !fragments.isEmpty else { return nil }
                    return fragments.joined()
                }
                .joined(separator: "\n")
        }
    }

    private struct ShellCapture {
        let output: String
        let exitStatus: Int
        let didTimeout: Bool
    }

    private enum CoordinatorError: LocalizedError {
        case invalidResponse
        case api(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Terminal coordinator returned an invalid response."
            case .api(let statusCode, let body):
                return "OpenAI terminal API error (\(statusCode)): \(body.prefix(200))"
            }
        }
    }

    private let apiKey: String
    private let projectRoot: URL
    private let session: URLSession

    private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let modelCandidates = ["gpt-5.4-mini", "gpt-5.4", "gpt-5-codex"]

    init(apiKey: String, projectRoot: URL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.projectRoot = projectRoot
        self.session = session
    }

    func run(
        objective: String,
        context: String?,
        startingCommand: String?,
        timeoutSeconds: Int,
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async throws -> (String, Bool) {
        await primeProjectRoot()

        var previousResponseID: String?
        var pendingInput: [Any] = [Self.initialInput(
            objective: objective,
            context: context,
            startingCommand: startingCommand,
            projectRoot: projectRoot.path
        )]

        for _ in 0..<8 {
            let response = try await createResponse(
                input: pendingInput,
                previousResponseID: previousResponseID
            )
            previousResponseID = response.id

            let functionCalls = response.functionCalls
            if functionCalls.isEmpty {
                let summary = response.textOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                return (summary.isEmpty ? "Terminal session complete." : summary, false)
            }

            var functionOutputs: [[String: Any]] = []

            for call in functionCalls {
                guard call.name == "run_shell_command" else {
                    functionOutputs.append(
                        Self.functionCallOutput(
                            callID: call.callID,
                            output: "Unsupported function: \(call.name)"
                        )
                    )
                    continue
                }

                let payload = Self.parseJSONObject(from: call.arguments) ?? [:]
                let command = ((payload["command"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let callTimeout = min(max(payload["timeout_seconds"] as? Int ?? timeoutSeconds, 1), 120)

                guard !command.isEmpty else {
                    functionOutputs.append(
                        Self.functionCallOutput(
                            callID: call.callID,
                            output: "Missing required command argument."
                        )
                    )
                    continue
                }

                progress(.command(command))
                progress(.output("$ \(command)"))

                let shellCapture = await executeShellCommand(
                    command,
                    timeoutSeconds: callTimeout,
                    progress: progress
                )

                let shellOutput = Self.serializedToolOutput(
                    command: command,
                    output: shellCapture.output,
                    exitStatus: shellCapture.exitStatus,
                    didTimeout: shellCapture.didTimeout
                )
                functionOutputs.append(
                    Self.functionCallOutput(
                        callID: call.callID,
                        output: shellOutput
                    )
                )
            }

            pendingInput = functionOutputs
        }

        return ("Terminal session reached the maximum number of command turns before finishing.", true)
    }

    private func createResponse(
        input: [Any],
        previousResponseID: String?
    ) async throws -> ResponseEnvelope {
        var lastError: Error = CoordinatorError.invalidResponse

        for model in Self.modelCandidates {
            do {
                return try await createResponse(
                    model: model,
                    input: input,
                    previousResponseID: previousResponseID
                )
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func createResponse(
        model: String,
        input: [Any],
        previousResponseID: String?
    ) async throws -> ResponseEnvelope {
        var body: [String: Any] = [
            "model": model,
            "instructions": Self.instructions(projectRoot: projectRoot.path),
            "input": input,
            "tools": [Self.runShellTool],
            "reasoning": ["effort": "medium"],
            "max_output_tokens": 1_200
        ]
        if let previousResponseID, !previousResponseID.isEmpty {
            body["previous_response_id"] = previousResponseID
        }

        var request = URLRequest(url: Self.responsesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoordinatorError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let bodyText = String(decoding: data, as: UTF8.self)
            throw CoordinatorError.api(statusCode: http.statusCode, body: bodyText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let outputItems = json["output"] as? [[String: Any]] else {
            throw CoordinatorError.invalidResponse
        }

        return ResponseEnvelope(id: id, outputItems: outputItems)
    }

    private func primeProjectRoot() async {
        let bootstrapCommand = "cd \(Self.shellQuoted(projectRoot.path))"
        let stream = await StatefulTerminalEngine.shared.execute(bootstrapCommand)
        for await _ in stream {}
    }

    private func executeShellCommand(
        _ command: String,
        timeoutSeconds: Int,
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async -> ShellCapture {
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

        return ShellCapture(
            output: lines.joined(separator: "\n"),
            exitStatus: await StatefulTerminalEngine.shared.lastExitStatus() ?? 0,
            didTimeout: await lifecycle.didTimeout()
        )
    }

    private static var runShellTool: [String: Any] {
        [
            "type": "function",
            "name": "run_shell_command",
            "description": "Execute a non-destructive shell command in the project workspace and return its output.",
            "strict": true,
            "parameters": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The shell command to run."],
                    "timeout_seconds": ["type": "integer", "description": "Command timeout in seconds (max 120)."],
                    "reason": ["type": "string", "description": "Why this command is the right next step."]
                ] as [String: Any],
                "required": ["command"],
                "additionalProperties": false
            ] as [String: Any]
        ]
    }

    private static func instructions(projectRoot: String) -> String {
        """
        You are the terminal execution specialist inside Studio.92.

        You control a local persistent zsh shell through the run_shell_command tool.
        The shell has already been positioned at the project root for this session: \(projectRoot)

        Work like a calm senior engineer at the terminal:
        - Use shell commands for inspection, builds, tests, git status, and targeted verification.
        - Prefer the smallest useful sequence of commands and inspect before making conclusions.
        - Keep moving; you do not need to narrate every step.
        - Do not edit files through the shell. Other tools handle file changes.
        - Avoid destructive commands, including rm -rf, git reset --hard, git checkout --, sudo, or broad deletes.
        - Stop once you have enough evidence to answer the objective clearly.
        - Return a short grounded summary of what you verified, what failed, and the next best step if relevant.
        """
    }

    private static func initialInput(
        objective: String,
        context: String?,
        startingCommand: String?,
        projectRoot: String
    ) -> [String: Any] {
        var text = """
        Objective:
        \(objective)

        Project root:
        \(projectRoot)
        """

        if let context, !context.isEmpty {
            text += "\n\nRelevant context:\n\(context)"
        }

        if let startingCommand, !startingCommand.isEmpty {
            text += "\n\nSuggested first command:\n\(startingCommand)"
        }

        return [
            "role": "user",
            "content": [
                [
                    "type": "input_text",
                    "text": text
                ]
            ]
        ]
    }

    private static func functionCallOutput(callID: String, output: String) -> [String: Any] {
        [
            "type": "function_call_output",
            "call_id": callID,
            "output": output
        ]
    }

    private static func serializedToolOutput(
        command: String,
        output: String,
        exitStatus: Int,
        didTimeout: Bool
    ) -> String {
        var payload: [String: Any] = [
            "command": command,
            "exit_status": exitStatus,
            "timed_out": didTimeout
        ]

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            payload["output"] = "(no output)"
        } else if trimmed.count > 20_000 {
            payload["output"] = String(trimmed.prefix(20_000)) + "\n[Truncated]"
        } else {
            payload["output"] = trimmed
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return "command=\(command)\nexit_status=\(exitStatus)\ntimed_out=\(didTimeout)\noutput=\(trimmed)"
        }

        return text
    }

    private static func parseJSONObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

}

enum AgenticEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case thinkingSignature(String)
    case toolCallStart(id: String, name: String)
    case toolCallInputDelta(id: String, partialJSON: String)
    case toolCallCommand(id: String, command: String)
    case toolCallOutput(id: String, line: String)
    case toolCallResult(id: String, output: String, isError: Bool)
    case usage(inputTokens: Int, outputTokens: Int)
    case completed(stopReason: String)
    case error(String)
}

// MARK: - Errors

enum AgenticBridgeError: LocalizedError {
    case noHTTPResponse
    case apiError(statusCode: Int, body: String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .noHTTPResponse: return "No HTTP response"
        case .apiError(let code, let body): return "API error (\(code)): \(body.prefix(200))"
        case .missingAPIKey: return "No API key configured"
        }
    }
}

// MARK: - Default Tool Schemas

enum DefaultToolSchemas {

    private static func closedObjectSchema(
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    }

    static let explorerTools: [[String: Any]] = [fileRead, listFiles, webSearch]
    static let reviewerTools: [[String: Any]] = [fileRead, listFiles]
    static let backgroundWorker: [[String: Any]] = [
        fileRead,
        fileWrite,
        filePatch,
        listFiles,
        delegateToExplorer,
        delegateToReviewer,
        terminal,
        webSearch
    ]
    static let all: [[String: Any]] = [
        fileRead,
        fileWrite,
        filePatch,
        listFiles,
        delegateToExplorer,
        delegateToReviewer,
        delegateToWorktree,
        terminal,
        webSearch,
        deployToTestFlight
    ]

    static let fileRead: [String: Any] = [
        "name": "file_read",
        "description": "Read the contents of a UTF-8 text file at the given path and return the file contents. Use this when you need grounded source context before making a change or when you need to verify how an existing implementation works. Prefer targeted reads of the most relevant files instead of broad repository sweeps. This tool returns raw file text and should not be used for directories or binary assets.",
        "strict": true,
        "input_examples": [
            ["path": "Sources/AgentCouncil/AgentCouncil.swift"]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "path": ["type": "string", "description": "File path to read."]
            ],
            required: ["path"]
        )
    ]

    static let fileWrite: [String: Any] = [
        "name": "file_write",
        "description": "Create a new file or fully overwrite an existing UTF-8 text file with the provided contents. Use this when creating a new source file or intentionally replacing the entire contents of a file after you already understand the target. Do not use this for tiny edits when file_patch would be safer and more precise. Intermediate directories are created automatically when needed.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "path":    ["type": "string", "description": "File path to write."],
                "content": ["type": "string", "description": "File content."]
            ] as [String: Any],
            required: ["path", "content"]
        )
    ]

    static let filePatch: [String: Any] = [
        "name": "file_patch",
        "description": "Apply a precise search-and-replace edit to an existing file. Use this for focused modifications when you know the exact old text that should be replaced, and prefer it over file_write for small or surgical edits. The old_string must match exactly one location in the file; if it matches zero or multiple locations, the patch will fail and you should provide more specific context. This tool is ideal for anchored edits that should not disturb unrelated surrounding code.",
        "strict": true,
        "input_examples": [
            [
                "path": "Sources/App/FeatureView.swift",
                "old_string": "Text(\"Hello\")",
                "new_string": "Text(\"Hello, world\")"
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "path":       ["type": "string", "description": "File path."],
                "old_string": ["type": "string", "description": "Exact text to find."],
                "new_string": ["type": "string", "description": "Replacement text."]
            ] as [String: Any],
            required: ["path", "old_string", "new_string"]
        )
    ]

    static let listFiles: [String: Any] = [
        "name": "list_files",
        "description": "List the files and directories at the provided path, optionally walking recursively up to a shallow depth. Use this to orient yourself in a focused area of the project when you do not yet know the exact filename you need. Prefer listing a relevant subdirectory instead of scanning the whole repository. Directory names are returned with a trailing slash.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "path": ["type": "string", "description": "Directory path."]
            ] as [String: Any],
            required: []
        )
    ]

    static let delegateToExplorer: [String: Any] = [
        "name": "delegate_to_explorer",
        "description": "Spawn a focused background codebase explorer that stays read-only and gathers broad context before you write code. Use this when the task requires tracing data flow across multiple files, comparing implementations in several directories, or investigating a subsystem without polluting your main context window. Provide a concrete objective and the most relevant target directories so the explorer can stay narrow. The explorer returns only a concise, high-density findings summary, not raw file transcripts.",
        "strict": true,
        "input_examples": [
            [
                "objective": "Trace how session state flows from login to the main dashboard.",
                "target_directories": ["Sources/App/Auth", "Sources/App/Session"]
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "objective": ["type": "string", "description": "What the explorer should learn or trace through the codebase."],
                "target_directories": [
                    "type": "array",
                    "description": "Relevant directories for the explorer to inspect first.",
                    "items": ["type": "string", "description": "Absolute or project-relative directory path."]
                ]
            ] as [String: Any],
            required: ["objective", "target_directories"]
        )
    ]

    static let delegateToReviewer: [String: Any] = [
        "name": "delegate_to_reviewer",
        "description": "Spawn a specialized read-only reviewer to audit specific files for correctness, performance, security, and strict Apple-platform quality issues. Use this after meaningful code changes, when you want a second pass on risky files, or when you need a terse audit focused on one area. Provide only the files that actually matter and a concrete focus area so the reviewer stays sharp. The reviewer returns a short structured findings list rather than long explanations or raw code dumps.",
        "strict": true,
        "input_examples": [
            [
                "files_to_review": ["Sources/App/ContentView.swift", "Sources/App/AppModel.swift"],
                "focus_area": "Concurrency safety and HIG compliance"
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "files_to_review": [
                    "type": "array",
                    "description": "Files the reviewer should audit.",
                    "items": ["type": "string", "description": "Absolute or project-relative file path."]
                ],
                "focus_area": ["type": "string", "description": "The audit lens, such as performance, security, architecture, or Apple HIG compliance."]
            ] as [String: Any],
            required: ["files_to_review", "focus_area"]
        )
    ]

    static let delegateToWorktree: [String: Any] = [
        "name": "delegate_to_worktree",
        "description": "Create an isolated git worktree under .studio92/worktrees and hand a longer-running task to a background GPT-5.4 mini worker. Use this when the task should continue in parallel without polluting the main workspace, especially for broad refactors, audits, release prep, or deep implementation passes. Provide a branch name, a target worktree directory name, and the exact task prompt the background worker should execute.",
        "strict": true,
        "input_examples": [
            [
                "branch_name": "codex/app-store-audit",
                "target_directory": "app-store-audit",
                "task_prompt": "Audit the iOS app for current App Store metadata, privacy manifest, and signing gaps."
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "branch_name": ["type": "string", "description": "Branch to create for the isolated worktree job."],
                "target_directory": ["type": "string", "description": "Folder name inside .studio92/worktrees for this background job."],
                "task_prompt": ["type": "string", "description": "The exact task the background worker should complete."]
            ] as [String: Any],
            required: ["branch_name", "task_prompt"]
        )
    ]

    static let terminal: [String: Any] = [
        "name": "terminal",
        "description": "Ask the terminal executor to inspect, build, test, or verify the workspace. Use this when shell output would reduce guesswork or validate a change. Describe the outcome you want, provide any important context, and the terminal executor will choose the exact commands. This tool should not be used to narrate work; use it to actually inspect or verify the local system state.",
        "strict": true,
        "input_examples": [
            [
                "objective": "Run the test suite and report any compiler or test failures",
                "timeout": 60
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "objective": ["type": "string", "description": "What you want the terminal executor to accomplish."],
                "context": ["type": "string", "description": "Optional context that will help the terminal executor choose commands."],
                "starting_command": ["type": "string", "description": "Optional initial shell command to try first if you already know a likely starting point."],
                "command": ["type": "string", "description": "Backward-compatible alias for starting_command."],
                "timeout": ["type": "integer", "description": "Timeout in seconds (max 120)."]
            ] as [String: Any],
            required: ["objective"]
        )
    ]

    static let webSearch: [String: Any] = [
        "name": "web_search",
        "description": "Search the web for current documentation, API references, release notes, or other up-to-date technical information. Use this when correctness depends on current external information, such as Apple API changes, library behavior, or recent platform guidance. Form highly specific technical queries instead of vague browsing prompts, and prefer it when internal knowledge may be stale. Results should be treated as grounded context for the next step.",
        "strict": true,
        "input_examples": [
            ["query": "iOS 18 SwiftData ModelContext latest API"]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "query": ["type": "string", "description": "Search query."]
            ] as [String: Any],
            required: ["query"]
        )
    ]

    static let deployToTestFlight: [String: Any] = [
        "name": "deploy_to_testflight",
        "description": "Build and upload the current iOS app to TestFlight using a predefined Fastlane lane in the project directory. Use this only when the user clearly wants to ship or distribute the app and the project is already in a deployable state. This can take several minutes and requires a correctly configured signing and Fastlane environment. If no lane is provided, the default beta lane is used.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "lane": ["type": "string", "description": "Optional Fastlane lane name. Defaults to beta."]
            ] as [String: Any],
            required: []
        )
    ]
}
