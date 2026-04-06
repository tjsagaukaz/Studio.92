// MockSSEServer.swift
// Studio.92 — Integration Tests
// URLProtocol-based mock for Anthropic / OpenAI SSE streaming.

import Foundation
import XCTest

// MARK: - Mock URL Protocol

/// Intercepts HTTP requests to Anthropic/OpenAI endpoints and returns
/// pre-configured SSE event streams. Supports sequenced responses for
/// multi-turn conversations (tool call → result → next API call).
final class MockSSEProtocol: URLProtocol {

    /// Thread-safe response queue — each call to the API pops the next response.
    private static let lock = NSLock()
    private static var _responseQueue: [MockSSEResponse] = []
    private static var _capturedRequests: [URLRequest] = []

    static func enqueue(_ response: MockSSEResponse) {
        lock.lock()
        defer { lock.unlock() }
        _responseQueue.append(response)
    }

    static func enqueueMultiple(_ responses: [MockSSEResponse]) {
        lock.lock()
        defer { lock.unlock() }
        _responseQueue.append(contentsOf: responses)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _responseQueue.removeAll()
        _capturedRequests.removeAll()
    }

    static var capturedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _capturedRequests
    }

    private static func dequeue() -> MockSSEResponse? {
        lock.lock()
        defer { lock.unlock() }
        return _responseQueue.isEmpty ? nil : _responseQueue.removeFirst()
    }

    private static func captureRequest(_ request: URLRequest) {
        // URLProtocol receives body via httpBodyStream; copy it into httpBody for assertions.
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n > 0 { data.append(buf, count: n) } else { break }
            }
            captured.httpBody = data
        }
        lock.lock()
        defer { lock.unlock() }
        _capturedRequests.append(captured)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.contains("anthropic.com") || host.contains("openai.com")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.captureRequest(request)

        guard let mock = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch mock {
        case .sse(let events, let statusCode):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

            let sseData = events.joined(separator: "\n").data(using: .utf8)!
            client?.urlProtocol(self, didLoad: sseData)
            client?.urlProtocolDidFinishLoading(self)

        case .json(let data, let statusCode):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)

        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)

        case .chunkedSSE(let chunks, let delayMs, let statusCode):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

            // Deliver ALL chunks synchronously via separate didLoad() calls.
            // This tests that the SSE parser correctly handles data arriving in
            // multiple fragments. Callers are responsible for ensuring each chunk
            // contains properly terminated SSE events (trailing blank line).
            for chunk in chunks {
                let data = chunk.joined(separator: "\n").data(using: .utf8)!
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)

        case .byteAtATime(let events, let statusCode):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

            // Deliver the entire SSE stream one byte at a time.
            // This is the ultimate parser robustness test: proves the parser
            // is delimiter-driven and has zero reliance on chunk boundaries.
            let fullData = events.joined(separator: "\n").data(using: .utf8)!
            for i in 0..<fullData.count {
                client?.urlProtocol(self, didLoad: fullData[i...i])
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - Mock Response Types

enum MockSSEResponse {
    case sse(events: [String], statusCode: Int = 200)
    /// Delivers SSE events in separate chunks with delays between them.
    /// Each chunk is delivered via a separate `didLoad()` call, simulating network jitter.
    case chunkedSSE(chunks: [[String]], delayMs: UInt64 = 50, statusCode: Int = 200)
    /// Delivers the entire SSE stream one byte at a time via separate `didLoad()` calls.
    /// Proves the parser is fully delimiter-driven with zero chunk-boundary assumptions.
    case byteAtATime(events: [String], statusCode: Int = 200)
    case json(data: Data, statusCode: Int)
    case error(Error)
}

// MARK: - SSE Event Builders

/// Fluent builder for constructing realistic Anthropic SSE event streams.
enum AnthropicSSE {

    static func messageStart(model: String = "claude-sonnet-4-6", inputTokens: Int = 42) -> String {
        """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","content":[],"model":"\(model)","stop_reason":null,"usage":{"input_tokens":\(inputTokens),"output_tokens":0}}}

        """
    }

    static func contentBlockStart(index: Int, type: String = "text") -> String {
        """
        event: content_block_start
        data: {"type":"content_block_start","index":\(index),"content_block":{"type":"\(type)","text":""}}

        """
    }

    static func toolUseStart(index: Int, id: String, name: String) -> String {
        let escapedID = id.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedName = name.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        event: content_block_start
        data: {"type":"content_block_start","index":\(index),"content_block":{"type":"tool_use","id":"\(escapedID)","name":"\(escapedName)","input":{}}}

        """
    }

    static func textDelta(index: Int, text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        event: content_block_delta
        data: {"type":"content_block_delta","index":\(index),"delta":{"type":"text_delta","text":"\(escaped)"}}

        """
    }

    static func inputJSONDelta(index: Int, json: String) -> String {
        let escaped = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        event: content_block_delta
        data: {"type":"content_block_delta","index":\(index),"delta":{"type":"input_json_delta","partial_json":"\(escaped)"}}

        """
    }

    static func contentBlockStop(index: Int) -> String {
        """
        event: content_block_stop
        data: {"type":"content_block_stop","index":\(index)}

        """
    }

    static func messageDelta(stopReason: String = "end_turn", outputTokens: Int = 50) -> String {
        """
        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"\(stopReason)","stop_sequence":null},"usage":{"output_tokens":\(outputTokens)}}

        """
    }

    static func messageStop() -> String {
        """
        event: message_stop
        data: {"type":"message_stop"}

        """
    }

    // MARK: - Convenience Builders

    /// A complete simple text response.
    static func simpleTextResponse(_ text: String, model: String = "claude-sonnet-4-6") -> [String] {
        [
            messageStart(model: model),
            contentBlockStart(index: 0),
            textDelta(index: 0, text: text),
            contentBlockStop(index: 0),
            messageDelta(),
            messageStop()
        ]
    }

    /// A response with a tool_use block.
    static func toolCallResponse(
        textPrefix: String = "",
        toolID: String = "toolu_test_1",
        toolName: String,
        inputJSON: String
    ) -> [String] {
        var events: [String] = [messageStart()]

        if !textPrefix.isEmpty {
            events.append(contentBlockStart(index: 0))
            events.append(textDelta(index: 0, text: textPrefix))
            events.append(contentBlockStop(index: 0))
        }

        let toolIndex = textPrefix.isEmpty ? 0 : 1
        events.append(toolUseStart(index: toolIndex, id: toolID, name: toolName))
        events.append(inputJSONDelta(index: toolIndex, json: inputJSON))
        events.append(contentBlockStop(index: toolIndex))
        events.append(messageDelta(stopReason: "tool_use"))
        events.append(messageStop())

        return events
    }

    /// A follow-up response after tool results (the second API call).
    static func postToolTextResponse(_ text: String) -> [String] {
        simpleTextResponse(text)
    }
}

// MARK: - Session Factory

enum MockSession {
    /// Creates a URLSession configured to intercept API calls via MockSSEProtocol.
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSSEProtocol.self]
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }
}
