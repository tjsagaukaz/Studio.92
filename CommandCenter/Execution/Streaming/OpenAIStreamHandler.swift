// OpenAIStreamHandler.swift
// Studio.92 — Command Center
// OpenAI Responses API streaming & helpers — extracted from AgenticBridge.swift

import Foundation

// MARK: - OpenAI Free Functions

let openAITransientStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
let openAIMaxRetryAttempts = 3
let openAIMaxRetryDelay: TimeInterval = 12
let openAIBroadFallbackModels = ["gpt-5.4-nano", "gpt-4.5", "gpt-4.1", "gpt-4o"]

/// Models that accept the `reasoning.effort` parameter (o-series, gpt-5.x).
/// gpt-4.x and earlier reject this parameter outright.
func openAIModelSupportsReasoning(_ model: String) -> Bool {
    model.hasPrefix("o") || model.hasPrefix("gpt-5")
}

struct ParsedOpenAIAPIError {
    let message: String?
    let requestID: String?
}

func parsedOpenAIAPIError(from body: String) -> ParsedOpenAIAPIError {
    guard let data = body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ParsedOpenAIAPIError(message: nil, requestID: nil)
    }

    let requestID = object["request_id"] as? String
    if let error = object["error"] as? [String: Any] {
        return ParsedOpenAIAPIError(
            message: error["message"] as? String,
            requestID: requestID
        )
    }

    return ParsedOpenAIAPIError(
        message: object["message"] as? String,
        requestID: requestID
    )
}

func openAIAPIErrorSummary(statusCode: Int, body: String) -> String {
    let parsed = parsedOpenAIAPIError(from: body)
    var summary = statusCode >= 500
        ? "OpenAI server error (\(statusCode))"
        : "API error (\(statusCode))"

    if let message = parsed.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
        summary += ": \(message)"
    } else if !body.isEmpty {
        summary += ": \(body.prefix(200))"
    }

    if let requestID = parsed.requestID, !requestID.isEmpty {
        summary += " [\(requestID)]"
    }

    return summary
}

func openAIUserFacingFailure(statusCode: Int, body: String) -> String {
    guard statusCode >= 500 else {
        return openAIAPIErrorSummary(statusCode: statusCode, body: body)
    }

    let parsed = parsedOpenAIAPIError(from: body)
    var message = "OpenAI had a temporary server error (\(statusCode))"

    if let detail = parsed.message?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
        message += ": \(detail)"
    }

    message += ". Please try again."

    if let requestID = parsed.requestID, !requestID.isEmpty {
        message += " Request ID: \(requestID)."
    }

    return message
}

func openAIShouldFallbackModel(statusCode: Int, body: String) -> Bool {
    guard statusCode == 400 else { return false }

    let parsed = parsedOpenAIAPIError(from: body)
    let detail = (parsed.message ?? body).lowercased()

    return detail.contains("does not have access to model")
        || detail.contains("model_not_found")
        || detail.contains("unknown model")
        || detail.contains("unsupported model")
}

func openAIShouldRetry(statusCode: Int, attempt: Int) -> Bool {
    openAITransientStatusCodes.contains(statusCode) && attempt < openAIMaxRetryAttempts
}

func openAIRetryDelay(attempt: Int, response: HTTPURLResponse) -> TimeInterval {
    // Jitter factor: random ±25% to prevent thundering herd
    let jitter = Double.random(in: 0.75...1.25)

    if let retryAfterMilliseconds = response.value(forHTTPHeaderField: "retry-after-ms"),
       let milliseconds = Double(retryAfterMilliseconds) {
        return min(max(milliseconds / 1000 * jitter, 0.5), openAIMaxRetryDelay)
    }

    if let retryAfter = response.value(forHTTPHeaderField: "Retry-After") {
        if let seconds = Double(retryAfter) {
            return min(max(seconds * jitter, 0.5), openAIMaxRetryDelay)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

        if let date = formatter.date(from: retryAfter) {
            return min(max(date.timeIntervalSinceNow * jitter, 0.5), openAIMaxRetryDelay)
        }
    }

    let fallback = pow(2, Double(max(0, attempt - 1))) * jitter
    return min(max(fallback, 0.5), openAIMaxRetryDelay)
}


// MARK: - AgenticClient OpenAI Extension

extension AgenticClient {

    // MARK: - Model Routing

    static func openAIModelCandidates(
        for model: StudioModelDescriptor,
        preferredIdentifier: String? = nil
    ) -> [String] {
        guard model.provider == .openAI else { return [model.identifier] }

        var candidates: [String] = []

        if let preferredIdentifier {
            let trimmed = preferredIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                candidates.append(trimmed)
            }
        }

        candidates.append(model.identifier)

        switch model.role {
        case .fullSend:
            candidates.append(contentsOf: ["gpt-5.4-mini", "gpt-4.5", "gpt-5.4-nano"] + openAIBroadFallbackModels)
        case .subagent:
            candidates.append(contentsOf: ["gpt-5.4-nano", "gpt-4.5", "gpt-5.4"] + openAIBroadFallbackModels)
        case .review, .escalation, .explorer:
            break
        }

        var seen = Set<String>()
        return candidates.filter { candidate in
            guard !candidate.isEmpty, !seen.contains(candidate) else { return false }
            seen.insert(candidate)
            return true
        }
    }

    static func nextOpenAIModelCandidate(
        for model: StudioModelDescriptor,
        after identifier: String
    ) -> String? {
        let candidates = openAIModelCandidates(for: model)
        guard let index = candidates.firstIndex(of: identifier), index < candidates.count - 1 else {
            return nil
        }
        return candidates[index + 1]
    }

    // MARK: - Fallback Wrappers

    func streamOpenAIResponseWithFallback(
        instructions: String,
        input: [Any],
        previousResponseID: String?,
        model: StudioModelDescriptor,
        preferredModelIdentifier: String?,
        maxOutputTokens: Int,
        reasoningEffort: String?,
        verbosity: String? = nil,
        tools: [[String: Any]],
        allowedToolNames: [String]? = nil,
        responseFormat: [String: Any]? = nil,
        latencyRunID: String? = nil,
        llmCallKey: String = ""
    ) async throws -> (AsyncThrowingStream<OpenAIStreamingEvent, Error>, String) {
        let candidates = Self.openAIModelCandidates(for: model, preferredIdentifier: preferredModelIdentifier)
        var lastError: Error?

        for (index, candidate) in candidates.enumerated() {
            do {
                let stream = try await streamOpenAIResponse(
                    instructions: instructions,
                    input: input,
                    previousResponseID: previousResponseID,
                    model: candidate,
                    maxOutputTokens: maxOutputTokens,
                    reasoningEffort: reasoningEffort,
                    verbosity: verbosity,
                    tools: tools,
                    allowedToolNames: allowedToolNames,
                    responseFormat: responseFormat,
                    latencyRunID: latencyRunID,
                    llmCallKey: llmCallKey
                )
                return (stream, candidate)
            } catch let error as AgenticBridgeError {
                guard case let .apiError(statusCode, body) = error,
                      openAIShouldFallbackModel(statusCode: statusCode, body: body),
                      index < candidates.count - 1 else {
                    throw error
                }

                lastError = error

                #if DEBUG
                print("[OpenAIModelFallback] unavailable=\(candidate) next=\(candidates[index + 1])")
                #endif
            }
        }

        throw lastError ?? AgenticBridgeError.apiError(statusCode: -1, body: "No OpenAI model candidates were available.")
    }

    func createOpenAIResponseWithFallback(
        instructions: String,
        input: [Any],
        previousResponseID: String?,
        model: StudioModelDescriptor,
        preferredModelIdentifier: String?,
        maxOutputTokens: Int,
        reasoningEffort: String?,
        verbosity: String? = nil,
        tools: [[String: Any]],
        allowedToolNames: [String]? = nil,
        latencyRunID: String? = nil,
        llmCallKey: String = ""
    ) async throws -> (OpenAIResponseEnvelope, String) {
        let candidates = Self.openAIModelCandidates(for: model, preferredIdentifier: preferredModelIdentifier)
        var lastError: Error?

        for (index, candidate) in candidates.enumerated() {
            do {
                let response = try await createOpenAIResponse(
                    instructions: instructions,
                    input: input,
                    previousResponseID: previousResponseID,
                    model: candidate,
                    maxOutputTokens: maxOutputTokens,
                    reasoningEffort: reasoningEffort,
                    verbosity: verbosity,
                    tools: tools,
                    allowedToolNames: allowedToolNames,
                    latencyRunID: latencyRunID,
                    llmCallKey: llmCallKey
                )
                return (response, candidate)
            } catch let error as AgenticBridgeError {
                guard case let .apiError(statusCode, body) = error,
                      openAIShouldFallbackModel(statusCode: statusCode, body: body),
                      index < candidates.count - 1 else {
                    throw error
                }

                lastError = error

                #if DEBUG
                print("[OpenAIModelFallback] unavailable=\(candidate) next=\(candidates[index + 1])")
                #endif
            }
        }

        throw lastError ?? AgenticBridgeError.apiError(statusCode: -1, body: "No OpenAI model candidates were available.")
    }


    // MARK: - OpenAI HTTP

    func createOpenAIResponse(
        instructions: String,
        input: [Any],
        previousResponseID: String?,
        model: String,
        maxOutputTokens: Int,
        reasoningEffort: String?,
        verbosity: String? = nil,
        tools: [[String: Any]],
        allowedToolNames: [String]? = nil,
        latencyRunID: String? = nil,
        llmCallKey: String = ""
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
        if let reasoningEffort, !reasoningEffort.isEmpty, openAIModelSupportsReasoning(model) {
            body["reasoning"] = ["effort": reasoningEffort, "summary": "auto"]
        }
        if let verbosity, !verbosity.isEmpty, openAIModelSupportsReasoning(model) {
            body["text"] = ["verbosity": verbosity]
        }
        if let allowedToolNames, !allowedToolNames.isEmpty {
            body["tool_choice"] = [
                "type": "allowed_tools",
                "mode": "auto",
                "tools": allowedToolNames.map { ["type": "function", "name": $0] }
            ] as [String: Any]
        }
        if tools.contains(where: { ($0["type"] as? String) == "web_search" || ($0["type"] as? String) == "web_search_preview" }) {
            body["max_tool_calls"] = 6
        }

        var request = URLRequest(url: Self.responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(openAIKey ?? "")", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performOpenAIDataRequest(
            request,
            latencyRunID: latencyRunID,
            llmCallKey: llmCallKey
        )
        return try OpenAIResponseEnvelope(data: data)
    }


    func streamOpenAIResponse(
        instructions: String,
        input: [Any],
        previousResponseID: String?,
        model: String,
        maxOutputTokens: Int,
        reasoningEffort: String?,
        verbosity: String? = nil,
        tools: [[String: Any]],
        allowedToolNames: [String]? = nil,
        responseFormat: [String: Any]? = nil,
        latencyRunID: String? = nil,
        llmCallKey: String = ""
    ) async throws -> AsyncThrowingStream<OpenAIStreamingEvent, Error> {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "max_output_tokens": maxOutputTokens,
            "parallel_tool_calls": false,
            "stream": true
        ]
        if let previousResponseID, !previousResponseID.isEmpty {
            body["previous_response_id"] = previousResponseID
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }
        if let reasoningEffort, !reasoningEffort.isEmpty, openAIModelSupportsReasoning(model) {
            body["reasoning"] = ["effort": reasoningEffort, "summary": "auto"]
        }
        if let verbosity, !verbosity.isEmpty, openAIModelSupportsReasoning(model) {
            body["text"] = ["verbosity": verbosity]
        }
        if let allowedToolNames, !allowedToolNames.isEmpty {
            body["tool_choice"] = [
                "type": "allowed_tools",
                "mode": "auto",
                "tools": allowedToolNames.map { ["type": "function", "name": $0] }
            ] as [String: Any]
        }
        if tools.contains(where: { ($0["type"] as? String) == "web_search" || ($0["type"] as? String) == "web_search_preview" }) {
            body["max_tool_calls"] = 6
        }
        if let responseFormat {
            var textDict = body["text"] as? [String: Any] ?? [:]
            textDict["format"] = responseFormat
            body["text"] = textDict
        }

        var request = URLRequest(url: Self.responsesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(openAIKey ?? "")", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0

        while true {
            attempt += 1

            let metricsDelegate = URLSessionTaskMetricsDelegate { metrics in
                Task {
                    await LatencyDiagnostics.shared.attachLLMNetworkMetrics(
                        runID: latencyRunID,
                        key: llmCallKey,
                        requestTTFBMs: Self.requestTTFBMilliseconds(from: metrics),
                        responseStartAt: Self.responseStartAbsoluteTime(from: metrics),
                        responseEndAt: Self.responseEndAbsoluteTime(from: metrics),
                        responseTransferMs: Self.responseTransferMilliseconds(from: metrics)
                    )
                }
            }

            let (bytes, response) = try await session.bytes(for: request, delegate: metricsDelegate)
            await LatencyDiagnostics.shared.markLLMHeaders(
                runID: latencyRunID,
                key: llmCallKey,
                at: CFAbsoluteTimeGetCurrent()
            )

            guard let http = response as? HTTPURLResponse else {
                throw AgenticBridgeError.noHTTPResponse
            }

            guard http.statusCode == 200 else {
                var errorData = Data()
                for try await byte in bytes { errorData.append(byte) }
                let errorBody = String(decoding: errorData, as: UTF8.self)

                if openAIShouldRetry(statusCode: http.statusCode, attempt: attempt) {
                    let retryDelay = openAIRetryDelay(attempt: attempt, response: http)

                    #if DEBUG
                    let parsed = parsedOpenAIAPIError(from: errorBody)
                    print(
                        "[OpenAIRetry] " +
                        "status=\(http.statusCode) " +
                        "attempt=\(attempt)/\(openAIMaxRetryAttempts) " +
                        "retry_in=\(String(format: "%.2f", retryDelay))s " +
                        "request_id=\(parsed.requestID ?? "-")"
                    )
                    #endif

                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    continue
                }

                throw AgenticBridgeError.apiError(statusCode: http.statusCode, body: errorBody)
            }

            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        var lineBuffer = ""
                        var eventType = ""
                        var eventData = ""
                        let decoder = UTF8StreamDecoder()

                        func emitParsedEventIfNeeded() {
                            guard !eventData.isEmpty else {
                                eventType = ""
                                return
                            }

                            if let event = Self.parseOpenAIStreamingEvent(type: eventType, data: eventData) {
                                let parsedAt = CFAbsoluteTimeGetCurrent()
                                Task {
                                    await LatencyDiagnostics.shared.markLLMFirstEvent(
                                        runID: latencyRunID,
                                        key: llmCallKey,
                                        eventType: Self.openAILatencyLabel(for: event),
                                        at: parsedAt
                                    )
                                    if case .textDelta = event {
                                        await LatencyDiagnostics.shared.markLLMFirstTextDelta(
                                            runID: latencyRunID,
                                            key: llmCallKey,
                                            at: parsedAt
                                        )
                                    }
                                }
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
                                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
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
                            if let decoded = decoder.append(byte) {
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
    }


    func performOpenAIDataRequest(
        _ request: URLRequest,
        latencyRunID: String? = nil,
        llmCallKey: String = ""
    ) async throws -> Data {
        var attempt = 0

        while true {
            attempt += 1

            let metricsDelegate = URLSessionTaskMetricsDelegate { metrics in
                Task {
                    await LatencyDiagnostics.shared.attachLLMNetworkMetrics(
                        runID: latencyRunID,
                        key: llmCallKey,
                        requestTTFBMs: Self.requestTTFBMilliseconds(from: metrics),
                        responseStartAt: Self.responseStartAbsoluteTime(from: metrics),
                        responseEndAt: Self.responseEndAbsoluteTime(from: metrics),
                        responseTransferMs: Self.responseTransferMilliseconds(from: metrics)
                    )
                }
            }

            let (data, response) = try await session.data(for: request, delegate: metricsDelegate)
            guard let http = response as? HTTPURLResponse else {
                throw AgenticBridgeError.noHTTPResponse
            }

            guard http.statusCode == 200 else {
                let errorBody = String(decoding: data, as: UTF8.self)

                if openAIShouldRetry(statusCode: http.statusCode, attempt: attempt) {
                    let retryDelay = openAIRetryDelay(attempt: attempt, response: http)

                    #if DEBUG
                    let parsed = parsedOpenAIAPIError(from: errorBody)
                    print(
                        "[OpenAIRetry] " +
                        "status=\(http.statusCode) " +
                        "attempt=\(attempt)/\(openAIMaxRetryAttempts) " +
                        "retry_in=\(String(format: "%.2f", retryDelay))s " +
                        "request_id=\(parsed.requestID ?? "-")"
                    )
                    #endif

                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    continue
                }

                throw AgenticBridgeError.apiError(statusCode: http.statusCode, body: errorBody)
            }

            return data
        }
    }


    static func userFacingOpenAIErrorMessage(for error: AgenticBridgeError) -> String {
        switch error {
        case .apiError(let statusCode, let body):
            return openAIUserFacingFailure(statusCode: statusCode, body: body)
        case .noHTTPResponse, .missingAPIKey:
            return error.localizedDescription
        }
    }

    // MARK: - OpenAI Streaming Event Model

    enum OpenAIStreamingEvent {
        case responseCreated(id: String)
        case textDelta(String)
        case reasoningDelta(String)
        case functionCallStarted(callID: String, name: String, arguments: String)
        case functionCallArgumentsDelta(callID: String, delta: String)
        case functionCallDone(OpenAIFunctionCall)
        case webSearchStarted(id: String)
        case webSearchDone(id: String, status: String)
        case completed(OpenAIResponseEnvelope?)
        case error(String)
    }

    // MARK: - OpenAI Event Parsing

    static func parseOpenAIStreamingEvent(type: String, data: String) -> OpenAIStreamingEvent? {
        guard data != "[DONE]" else { return nil }
        guard let json = parseJSON(data) else { return nil }

        switch type {
        case "response.created":
            let responseObject = openAIStreamingResponseObject(from: json)
            if let id = responseObject?["id"] as? String, !id.isEmpty {
                return .responseCreated(id: id)
            }
            return nil

        case "response.output_text.delta":
            let delta = json["delta"] as? String ?? ""
            return delta.isEmpty ? nil : .textDelta(delta)

        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            let delta = json["delta"] as? String ?? ""
            return delta.isEmpty ? nil : .reasoningDelta(delta)

        case "response.output_item.added":
            guard let item = json["item"] as? [String: Any] else { return nil }
            let itemType = item["type"] as? String ?? ""
            switch itemType {
            case "function_call":
                let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? ""
                let name = item["name"] as? String ?? ""
                let arguments = item["arguments"] as? String ?? ""
                guard !callID.isEmpty else { return nil }
                return .functionCallStarted(callID: callID, name: name, arguments: arguments)
            case "web_search_call":
                let id = (item["id"] as? String) ?? UUID().uuidString
                return .webSearchStarted(id: id)
            default:
                return nil
            }

        case "response.function_call_arguments.delta":
            let callID = (json["call_id"] as? String)
                ?? (json["item_id"] as? String)
                ?? ""
            let delta = json["delta"] as? String ?? ""
            guard !callID.isEmpty, !delta.isEmpty else { return nil }
            return .functionCallArgumentsDelta(callID: callID, delta: delta)

        case "response.function_call_arguments.done":
            let callID = (json["call_id"] as? String)
                ?? (json["item_id"] as? String)
                ?? ""
            let name = (json["name"] as? String)
                ?? ((json["item"] as? [String: Any])?["name"] as? String)
                ?? ""
            let arguments = (json["arguments"] as? String)
                ?? ((json["item"] as? [String: Any])?["arguments"] as? String)
                ?? ""
            guard !callID.isEmpty, !name.isEmpty else { return nil }
            return .functionCallDone(
                OpenAIFunctionCall(
                    callID: callID,
                    name: name,
                    arguments: arguments
                )
            )

        case "response.output_item.done":
            guard let item = json["item"] as? [String: Any] else { return nil }
            let doneType = item["type"] as? String ?? ""
            switch doneType {
            case "function_call":
                let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? ""
                let name = item["name"] as? String ?? ""
                let arguments = item["arguments"] as? String ?? ""
                guard !callID.isEmpty, !name.isEmpty else { return nil }
                return .functionCallDone(
                    OpenAIFunctionCall(
                        callID: callID,
                        name: name,
                        arguments: arguments
                    )
                )
            case "web_search_call":
                let id = (item["id"] as? String) ?? ""
                let status = (item["status"] as? String) ?? "completed"
                return .webSearchDone(id: id, status: status)
            default:
                return nil
            }

        case "response.completed", "response.done":
            return .completed(
                openAIStreamingResponseObject(from: json).flatMap(OpenAIResponseEnvelope.init(json:))
            )

        case "response.failed", "error":
            return .error(openAIStreamErrorMessage(from: json))

        default:
            return nil
        }
    }


    static func openAIStreamingResponseObject(from json: [String: Any]) -> [String: Any]? {
        if let response = json["response"] as? [String: Any] {
            return response
        }
        if json["id"] != nil {
            return json
        }
        return nil
    }

    static func openAIStreamErrorMessage(from json: [String: Any]) -> String {
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let code = error["code"] as? String,
               !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "OpenAI streaming error: \(code)"
            }
        }
        if let message = json["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        return "OpenAI streaming error."
    }

    static func openAILatencyLabel(for event: OpenAIStreamingEvent) -> String {
        switch event {
        case .responseCreated:
            return "response_created"
        case .textDelta:
            return "text_delta"
        case .reasoningDelta:
            return "thinking_delta"
        case .functionCallStarted:
            return "tool_call_start"
        case .functionCallArgumentsDelta:
            return "tool_call_input_delta"
        case .functionCallDone:
            return "tool_call_done"
        case .webSearchStarted:
            return "web_search_start"
        case .webSearchDone:
            return "web_search_done"
        case .completed:
            return "response_completed"
        case .error:
            return "error"
        }
    }


    // MARK: - OpenAI Tool Schemas

    static let toolSearchThreshold = 15

    static func openAIToolSchemas(from tools: [[String: Any]]?) -> [[String: Any]] {
        guard let tools, !tools.isEmpty else { return [] }

        var functionTools: [[String: Any]] = []
        var builtinTools: [[String: Any]] = []

        for tool in tools {
            guard let name = tool["name"] as? String,
                  let description = tool["description"] as? String,
                  let parameters = tool["input_schema"] as? [String: Any] else {
                continue
            }

            if name == "web_search" {
                builtinTools.append([
                    "type": "web_search",
                    "external_web_access": true
                ])
                continue
            }

            functionTools.append([
                "type": "function",
                "name": name,
                "description": description,
                "parameters": parameters,
                "strict": tool["strict"] as? Bool ?? true
            ])
        }

        // When tool count exceeds threshold, use hosted tool_search to defer
        // loading — the model searches registered tools and loads only what it needs.
        // Disable strict mode inside tool_search to avoid schema-compilation limits.
        if functionTools.count > toolSearchThreshold {
            let relaxedTools = functionTools.map { tool -> [String: Any] in
                var t = tool
                t["strict"] = false
                return t
            }
            let toolSearchEntry: [String: Any] = [
                "type": "tool_search",
                "tools": relaxedTools
            ]
            return builtinTools + [toolSearchEntry]
        }

        return builtinTools + functionTools
    }


    // MARK: - OpenAI Message Encoding

    static func openAIInputMessages(
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

    static func openAIInputMessage(from payload: [String: Any]) -> [String: Any] {
        let role = (payload["role"] as? String) ?? "user"

        if let content = payload["content"] as? String {
            return openAIInputMessage(role: role, text: content, anthropicContentBlocks: nil)
        }

        let anthropicBlocks = payload["content"] as? [[String: Any]]
        return openAIInputMessage(role: role, text: nil, anthropicContentBlocks: anthropicBlocks)
    }

    static func openAIInputMessage(
        role: String,
        text: String?,
        anthropicContentBlocks: [[String: Any]]?
    ) -> [String: Any] {
        let contentType = (role == "assistant") ? "output_text" : "input_text"
        var content: [[String: Any]] = []

        if let text, !text.isEmpty {
            content.append([
                "type": contentType,
                "text": text
            ])
        }

        if let anthropicContentBlocks {
            content.append(contentsOf: openAIContentBlocks(from: anthropicContentBlocks, contentType: contentType))
        }

        if content.isEmpty {
            content.append([
                "type": contentType,
                "text": ""
            ])
        }

        var message: [String: Any] = [
            "role": role,
            "content": content
        ]

        // GPT-5.4 phase parameter: tag replayed assistant messages as final_answer
        // to prevent the model from treating them as commentary/preambles.
        if role == "assistant" {
            message["phase"] = "final_answer"
        }

        return message
    }

    static func openAIContentBlocks(from anthropicBlocks: [[String: Any]], contentType: String = "input_text") -> [[String: Any]] {
        anthropicBlocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String else { return nil }
                return [
                    "type": contentType,
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

    static func openAIFunctionCallOutput(
        callID: String,
        outcome: ToolExecutionOutcome
    ) -> [String: Any] {
        [
            "type": "function_call_output",
            "call_id": callID,
            "output": serializedOpenAIFunctionOutput(from: outcome)
        ]
    }

    static func serializedOpenAIFunctionOutput(from outcome: ToolExecutionOutcome) -> String {
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

    // MARK: - OpenAI Response Types

    struct OpenAIUsage {
        let inputTokens: Int
        let outputTokens: Int
    }

    struct OpenAIFunctionCall: Sendable {
        let callID: String
        let name: String
        let arguments: String
    }

    struct OpenAIResponseEnvelope {
        let id: String
        let outputItems: [[String: Any]]
        let usage: OpenAIUsage?
        let stopReason: String?

        init(data: Data) throws {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String else {
                throw AgenticBridgeError.apiError(statusCode: -1, body: "Invalid OpenAI response envelope")
            }

            self.init(json: json, id: id)
        }

        init?(json: [String: Any]) {
            guard let id = json["id"] as? String else { return nil }
            self.init(json: json, id: id)
        }

        private init(json: [String: Any], id: String) {
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

        var webSearchCalls: [OpenAIWebSearchCall] {
            outputItems.compactMap(OpenAIWebSearchCall.init(item:))
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

    struct OpenAIWebSearchCall {
        let id: String
        let status: String?
        let action: [String: Any]?
        let queries: [String]

        init?(item: [String: Any]) {
            guard (item["type"] as? String) == "web_search_call",
                  let id = item["id"] as? String else {
                return nil
            }

            self.id = id
            self.status = item["status"] as? String
            self.action = item["action"] as? [String: Any]
            if let queryValues = (item["action"] as? [String: Any])?["queries"] as? [Any] {
                self.queries = queryValues.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } else {
                self.queries = []
            }
        }

        var isError: Bool {
            if let status {
                return status == "failed" || status == "cancelled" || status == "incomplete"
            }
            return false
        }

        var actionJSON: String? {
            guard let action,
                  JSONSerialization.isValidJSONObject(action),
                  let data = try? JSONSerialization.data(withJSONObject: action),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text
        }

        var summary: String {
            var parts: [String] = []

            if let actionType = action?["type"] as? String {
                switch actionType {
                case "search":
                    parts.append("OpenAI hosted web search completed.")
                case "open_page":
                    parts.append("OpenAI opened a web page during research.")
                case "find_in_page":
                    parts.append("OpenAI searched within a web page during research.")
                default:
                    parts.append("OpenAI hosted web search completed.")
                }
            } else {
                parts.append("OpenAI hosted web search completed.")
            }

            if !queries.isEmpty {
                parts.append("Queries: \(queries.joined(separator: " | "))")
            }

            if let status, !status.isEmpty, status != "completed" {
                parts.append("Status: \(status)")
            }

            return parts.joined(separator: "\n")
        }
    }
}
