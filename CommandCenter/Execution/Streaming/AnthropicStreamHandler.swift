// AnthropicStreamHandler.swift
// Studio.92 — Command Center
// Anthropic SSE streaming — extracted from AgenticBridge.swift

import Foundation

extension AgenticClient {

    // MARK: - Anthropic SSE Event Model

    enum SSEEvent {
        case textDelta(index: Int, String)
        case thinkingDelta(index: Int, String)
        case thinkingSignature(index: Int, String)
        case toolCallStart(index: Int, id: String, name: String)
        case toolCallInputDelta(index: Int, json: String)
        case usage(input: Int, output: Int)
        case stopReason(String)
        case error(String)
    }

    // MARK: - Anthropic SSE Stream

    func streamRequest(
        system:      String,
        messages:    [[String: Any]],
        model:       String,
        maxTokens:   Int,
        temperature: Double?,
        outputEffort: String?,
        tools:       [[String: Any]]?,
        thinking:    [String: Any]?,
        cacheControl: [String: Any]?,
        latencyRunID: String?,
        llmCallKey: String
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
        // Note: cache_control belongs on individual content blocks (system/messages),
        // not at the request body level. Top-level placement is silently ignored.
        _ = cacheControl

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

        let requestStartedAt = CFAbsoluteTimeGetCurrent()
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
            let maxErrorBytes = 512_000 // 512KB cap on error body
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count >= maxErrorBytes { break }
            }
            let errorBody = String(decoding: errorData, as: UTF8.self)
            throw AgenticBridgeError.apiError(statusCode: http.statusCode, body: errorBody)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lineBuffer = ""
                    var eventType  = ""
                    var eventData  = ""
                    let decoder = UTF8StreamDecoder()
                    func emitParsedEventIfNeeded() {
                        guard !eventData.isEmpty else {
                            eventType = ""
                            return
                        }

                        if let event = Self.parseSSE(type: eventType, data: eventData) {
                            let parsedAt = CFAbsoluteTimeGetCurrent()
                            Task {
                                await LatencyDiagnostics.shared.markLLMFirstEvent(
                                    runID: latencyRunID,
                                    key: llmCallKey,
                                    eventType: Self.latencyLabel(for: event),
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
                            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .init(charactersIn: " "))
                            if eventData.isEmpty {
                                eventData = payload
                            } else if eventData.count + payload.count < maxBufferSize {
                                eventData += "\n" + payload
                            }
                            // If eventData exceeds maxBufferSize, silently drop further data
                            // lines for this event to prevent memory exhaustion.
                        }
                    }

                    let maxBufferSize = 2_000_000 // 2MB safety cap per buffer

                    func consumeDecoded(_ decoded: String) {
                        for character in decoded {
                            if character == "\n" {
                                consumeLine(lineBuffer)
                                lineBuffer.removeAll(keepingCapacity: true)
                            } else {
                                lineBuffer.append(character)
                                if lineBuffer.count > maxBufferSize {
                                    // Malformed stream: single line exceeding 2MB. Drain and reset.
                                    lineBuffer.removeAll(keepingCapacity: false)
                                }
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
                    await LatencyDiagnostics.shared.markPoint(
                        runID: latencyRunID,
                        name: "Anthropic SSE Stream Finished",
                        at: CFAbsoluteTimeGetCurrent(),
                        notes: "llm_call_key=\(llmCallKey) request_elapsed=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - requestStartedAt) * 1000))ms"
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Anthropic SSE Parsing

    static func parseSSE(type: String, data: String) -> SSEEvent? {
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


    static func anthropicBetaHeader(for model: String, thinking: [String: Any]?) -> String? {
        guard thinking != nil else { return nil }

        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedModel.hasPrefix("claude-") else { return nil }

        return StudioAPIConfig.anthropicBetaVersion
    }

    static func latencyLabel(for event: SSEEvent) -> String {
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

}
