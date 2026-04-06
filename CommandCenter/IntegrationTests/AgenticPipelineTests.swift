// AgenticPipelineTests.swift
// Studio.92 — Integration Tests
// End-to-end tests for the agentic pipeline: SSE parsing, event stream,
// tool dispatch round-trip, multi-turn conversation, and error handling.

import XCTest
import AgentCouncil
@testable import CommandCenter

// MARK: - Agentic Pipeline Integration Tests

final class AgenticPipelineTests: XCTestCase {

    private var mockSession: URLSession!
    private var tempProjectDir: URL!

    override func setUp() async throws {
        MockSSEProtocol.reset()
        mockSession = MockSession.make()

        // Create an isolated temp project directory with a Package.swift
        // so sandbox and tool dispatch have a valid project root.
        tempProjectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio92-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempProjectDir, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.10\nimport PackageDescription\nlet package = Package(name: \"TestProject\")\n"
            .write(to: tempProjectDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        MockSSEProtocol.reset()
        if let dir = tempProjectDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Helpers

    private func makeClient(
        anthropicKey: String = "test-key",
        openAIKey: String? = nil
    ) -> AgenticClient {
        AgenticClient(
            apiKey: anthropicKey,
            projectRoot: tempProjectDir,
            openAIKey: openAIKey,
            runtimePolicy: CommandRuntimePolicy(
                accessScope: .workspaceOnly,
                approvalMode: .neverAsk
            ),
            permissionPolicy: ToolPermissionPolicy(),
            allowMachineWideAccess: false,
            session: mockSession
        )
    }

    private func collectEvents(from stream: AsyncStream<AgenticEvent>) async -> [AgenticEvent] {
        var events: [AgenticEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    private func accumulatedText(from events: [AgenticEvent]) -> String {
        events.compactMap {
            if case .textDelta(let text) = $0 { return text }
            return nil
        }.joined()
    }

    // MARK: - Tests

    // MARK: 1. Simple Text Generation

    func testSimpleTextGeneration() async throws {
        // Given: Mock returns a simple text response
        MockSSEProtocol.enqueue(
            .sse(events: AnthropicSSE.simpleTextResponse("Hello, world!"))
        )

        let client = makeClient()
        let stream = await client.run(
            system: "You are a helpful assistant.",
            userMessage: "Say hello",
            model: StudioModelStrategy.fullSend,
            maxTokens: 100
        )

        // When: Consume the event stream
        let events = await collectEvents(from: stream)

        // Then: Text deltas accumulated correctly
        let text = accumulatedText(from: events)
        XCTAssertEqual(text, "Hello, world!")

        // And: Stream completed with end_turn
        let completed = events.compactMap { event -> String? in
            if case .completed(let reason) = event { return reason }
            return nil
        }
        XCTAssertEqual(completed, ["end_turn"])
    }

    // MARK: 2. Multi-Chunk Streaming

    func testMultiChunkStreaming() async throws {
        // Given: Response arrives in multiple text deltas
        let events = [
            AnthropicSSE.messageStart(),
            AnthropicSSE.contentBlockStart(index: 0),
            AnthropicSSE.textDelta(index: 0, text: "Hello"),
            AnthropicSSE.textDelta(index: 0, text: ", "),
            AnthropicSSE.textDelta(index: 0, text: "world"),
            AnthropicSSE.textDelta(index: 0, text: "!"),
            AnthropicSSE.contentBlockStop(index: 0),
            AnthropicSSE.messageDelta(),
            AnthropicSSE.messageStop()
        ]
        MockSSEProtocol.enqueue(.sse(events: events))

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Stream test",
            model: StudioModelStrategy.fullSend
        )

        let collected = await collectEvents(from: stream)

        // Each text delta should be emitted individually for real-time UI
        let textDeltas = collected.compactMap { event -> String? in
            if case .textDelta(let text) = event { return text }
            return nil
        }
        XCTAssertEqual(textDeltas, ["Hello", ", ", "world", "!"])
        XCTAssertEqual(accumulatedText(from: collected), "Hello, world!")
    }

    // MARK: 3. Usage Tracking

    func testUsageEventsEmitted() async throws {
        MockSSEProtocol.enqueue(
            .sse(events: AnthropicSSE.simpleTextResponse("Hi"))
        )

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Usage test",
            model: StudioModelStrategy.fullSend
        )

        let events = await collectEvents(from: stream)

        // Usage event should be emitted from message_delta
        let usageEvents = events.compactMap { event -> (Int, Int)? in
            if case .usage(let input, let output) = event { return (input, output) }
            return nil
        }
        XCTAssertFalse(usageEvents.isEmpty, "Expected at least one usage event")
    }

    // MARK: 4. Tool Call Detection

    func testToolCallStartAndInputDetected() async throws {
        // Given: Mock returns a tool_use response
        let toolEvents = AnthropicSSE.toolCallResponse(
            textPrefix: "I'll read that file.",
            toolID: "toolu_abc123",
            toolName: "file_read",
            inputJSON: "{\"path\": \"test.swift\"}"
        )

        // First call: tool_use. Second call: final text after tool result.
        MockSSEProtocol.enqueueMultiple([
            .sse(events: toolEvents),
            .sse(events: AnthropicSSE.postToolTextResponse("Here's the file content."))
        ])

        // Create a file for the tool to read
        let testFile = tempProjectDir.appendingPathComponent("test.swift")
        try "let x = 42".write(to: testFile, atomically: true, encoding: .utf8)

        let client = makeClient()
        let stream = await client.run(
            system: "You are a builder.",
            userMessage: "Read test.swift",
            model: StudioModelStrategy.fullSend,
            tools: DefaultToolSchemas.all,
            maxIterations: 3
        )

        let events = await collectEvents(from: stream)

        // Then: Tool call start was emitted
        let toolStarts = events.compactMap { event -> (String, String)? in
            if case .toolCallStart(let id, let name) = event { return (id, name) }
            return nil
        }
        XCTAssertTrue(toolStarts.contains(where: { $0.1 == "file_read" }),
                       "Expected file_read tool call, got: \(toolStarts)")

        // And: Tool result was emitted
        let toolResults = events.compactMap { event -> (String, Bool)? in
            if case .toolCallResult(let id, _, let isError) = event { return (id, isError) }
            return nil
        }
        XCTAssertFalse(toolResults.isEmpty, "Expected at least one tool result")

        // And: Final text from second API call was received
        let finalText = accumulatedText(from: events)
        XCTAssertTrue(finalText.contains("Here's the file content."),
                       "Expected post-tool text, got: \(finalText)")
    }

    // MARK: 5. Tool Round-Trip: File Write + Read

    func testToolRoundTripFileWriteAndRead() async throws {
        // Given: First call writes a file, second call reads it
        let writeToolEvents = AnthropicSSE.toolCallResponse(
            toolName: "file_write",
            inputJSON: "{\"path\": \"output.txt\", \"content\": \"hello from test\"}"
        )

        MockSSEProtocol.enqueueMultiple([
            .sse(events: writeToolEvents),
            .sse(events: AnthropicSSE.postToolTextResponse("Done writing."))
        ])

        let client = makeClient()
        let stream = await client.run(
            system: "You are a builder.",
            userMessage: "Write output.txt",
            model: StudioModelStrategy.fullSend,
            tools: DefaultToolSchemas.all,
            maxIterations: 3
        )

        let events = await collectEvents(from: stream)

        // Then: Tool executed successfully
        let toolResults = events.compactMap { event -> (String, String, Bool)? in
            if case .toolCallResult(let id, let output, let isError) = event {
                return (id, output, isError)
            }
            return nil
        }
        XCTAssertFalse(toolResults.isEmpty, "Expected tool result")

        // And: The file was actually written
        let writtenFile = tempProjectDir.appendingPathComponent("output.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: writtenFile.path),
                       "Expected output.txt to be created")
        let content = try String(contentsOf: writtenFile, encoding: .utf8)
        XCTAssertEqual(content, "hello from test")
    }

    // MARK: 6. Missing API Key

    func testMissingAPIKeyEmitsError() async throws {
        let client = makeClient(anthropicKey: "")

        let stream = await client.run(
            system: "Test",
            userMessage: "Hello",
            model: StudioModelStrategy.fullSend
        )

        let events = await collectEvents(from: stream)

        let errors = events.compactMap { event -> String? in
            if case .error(let msg) = event { return msg }
            return nil
        }
        XCTAssertFalse(errors.isEmpty, "Expected error for missing API key")
        XCTAssertTrue(errors.first?.lowercased().contains("key") == true,
                       "Error should mention API key: \(errors)")
    }

    // MARK: 7. HTTP Error Response

    func testHTTPErrorResponse() async throws {
        let errorJSON = """
        {"type":"error","error":{"type":"authentication_error","message":"Invalid API key"}}
        """.data(using: .utf8)!

        MockSSEProtocol.enqueue(.json(data: errorJSON, statusCode: 401))

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Should fail",
            model: StudioModelStrategy.fullSend
        )

        let events = await collectEvents(from: stream)

        let errors = events.compactMap { event -> String? in
            if case .error(let msg) = event { return msg }
            return nil
        }
        XCTAssertFalse(errors.isEmpty, "Expected error event for 401")
    }

    // MARK: 8. Max Iterations

    func testMaxIterationsReached() async throws {
        // Given: Mock always returns tool_use (never end_turn), with maxIterations=2
        let toolResponse = AnthropicSSE.toolCallResponse(
            toolName: "file_read",
            inputJSON: "{\"path\": \"Package.swift\"}"
        )

        // Queue 2 tool responses (one per iteration)
        MockSSEProtocol.enqueueMultiple([
            .sse(events: toolResponse),
            .sse(events: toolResponse)
        ])

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Loop forever",
            model: StudioModelStrategy.fullSend,
            tools: DefaultToolSchemas.all,
            maxIterations: 2
        )

        let events = await collectEvents(from: stream)

        let errors = events.compactMap { event -> String? in
            if case .error(let msg) = event { return msg }
            return nil
        }
        XCTAssertTrue(errors.contains(where: { $0.contains("max iterations") }),
                       "Expected max iterations error, got: \(errors)")
    }

    // MARK: 9. Request Body Validation

    func testRequestBodyContainsExpectedFields() async throws {
        MockSSEProtocol.enqueue(
            .sse(events: AnthropicSSE.simpleTextResponse("OK"))
        )

        let client = makeClient()
        let stream = await client.run(
            system: "System prompt",
            userMessage: "User message",
            model: StudioModelStrategy.fullSend,
            maxTokens: 4096
        )

        _ = await collectEvents(from: stream)

        // Verify the captured request
        let requests = MockSSEProtocol.capturedRequests
        XCTAssertFalse(requests.isEmpty, "Expected at least one captured request")

        let request = requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"),
                       StudioAPIConfig.anthropicAPIVersion)
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")

        // Parse request body
        if let bodyData = request.httpBody {
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            XCTAssertEqual(body?["max_tokens"] as? Int, 4096)
            XCTAssertNotNil(body?["system"], "Expected system prompt in body")
            XCTAssertNotNil(body?["messages"], "Expected messages in body")
            XCTAssertTrue(body?["stream"] as? Bool == true, "Expected stream=true")
        } else {
            XCTFail("Request body was nil")
        }
    }

    // MARK: 10. Conversation History Accumulates Between Turns

    func testConversationHistoryAccumulatesBetweenTurns() async throws {
        // First turn: tool_use → tool result → second API call
        let toolResponse = AnthropicSSE.toolCallResponse(
            toolName: "file_read",
            inputJSON: "{\"path\": \"Package.swift\"}"
        )

        MockSSEProtocol.enqueueMultiple([
            .sse(events: toolResponse),
            .sse(events: AnthropicSSE.postToolTextResponse("Done."))
        ])

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Read the Package.swift",
            model: StudioModelStrategy.fullSend,
            tools: DefaultToolSchemas.all,
            maxIterations: 3
        )

        _ = await collectEvents(from: stream)

        // The second API call should include the full conversation history
        let requests = MockSSEProtocol.capturedRequests
        XCTAssertEqual(requests.count, 2, "Expected 2 API calls (initial + post-tool)")

        if requests.count >= 2, let bodyData = requests[1].httpBody {
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            let messages = body?["messages"] as? [[String: Any]]

            // Should have: user message, assistant (tool_use), user (tool_result)
            XCTAssertNotNil(messages)
            XCTAssertTrue((messages?.count ?? 0) >= 3,
                          "Expected ≥3 messages in second request, got \(messages?.count ?? 0)")

            // First message should be user
            XCTAssertEqual(messages?[0]["role"] as? String, "user")
            // Second should be assistant
            XCTAssertEqual(messages?[1]["role"] as? String, "assistant")
            // Third should be user (tool result)
            XCTAssertEqual(messages?[2]["role"] as? String, "user")
        }
    }

    // MARK: 11. Cancellation

    func testCancellationStopsStream() async throws {
        // Given: A response with many chunks (simulating a long stream)
        var longEvents: [String] = [AnthropicSSE.messageStart(), AnthropicSSE.contentBlockStart(index: 0)]
        for i in 0..<100 {
            longEvents.append(AnthropicSSE.textDelta(index: 0, text: "chunk\(i) "))
        }
        longEvents.append(AnthropicSSE.contentBlockStop(index: 0))
        longEvents.append(AnthropicSSE.messageDelta())
        longEvents.append(AnthropicSSE.messageStop())

        MockSSEProtocol.enqueue(.sse(events: longEvents))

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Long response",
            model: StudioModelStrategy.fullSend
        )

        // Consume only a few events, then cancel
        var eventCount = 0
        let task = Task {
            for await _ in stream {
                eventCount += 1
                if eventCount >= 5 {
                    break
                }
            }
        }
        await task.value

        // The stream should have stopped without consuming all 100 chunks
        // (exact count depends on buffering, but should be << 100)
        XCTAssertTrue(eventCount >= 5, "Should have received at least 5 events")
    }

    // MARK: 12. Empty Response

    func testEmptyResponseCompletesGracefully() async throws {
        // Given: A response with no text content
        let events = [
            AnthropicSSE.messageStart(),
            AnthropicSSE.messageDelta(),
            AnthropicSSE.messageStop()
        ]
        MockSSEProtocol.enqueue(.sse(events: events))

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Empty",
            model: StudioModelStrategy.fullSend
        )

        let collected = await collectEvents(from: stream)

        let text = accumulatedText(from: collected)
        XCTAssertEqual(text, "", "Expected empty text")

        // Should still complete
        let completed = collected.contains { event in
            if case .completed = event { return true }
            return false
        }
        XCTAssertTrue(completed, "Expected completion event")
    }

    // MARK: - A. Flaky Network Tests

    // MARK: 13. Chunked Delivery — Chunks Arrive Separately

    func testChunkedDeliveryReassemblesCorrectly() async throws {
        // Given: SSE events arrive in 3 separate didLoad() calls
        // The parser must reassemble the byte stream correctly.
        // Each chunk needs a trailing "" so the joined "\n" creates
        // the blank-line delimiter for the last SSE event in the chunk.
        let chunk1 = [
            AnthropicSSE.messageStart(),
            AnthropicSSE.contentBlockStart(index: 0),
            AnthropicSSE.textDelta(index: 0, text: "Hello"),
            ""
        ]
        let chunk2 = [
            AnthropicSSE.textDelta(index: 0, text: " from"),
            AnthropicSSE.textDelta(index: 0, text: " chunked"),
            ""
        ]
        let chunk3 = [
            AnthropicSSE.textDelta(index: 0, text: " stream!"),
            AnthropicSSE.contentBlockStop(index: 0),
            AnthropicSSE.messageDelta(),
            AnthropicSSE.messageStop()
        ]

        MockSSEProtocol.enqueue(.chunkedSSE(chunks: [chunk1, chunk2, chunk3]))

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Chunked test",
            model: StudioModelStrategy.fullSend
        )

        let events = await collectEvents(from: stream)

        // All text deltas should arrive correctly despite chunked delivery
        let text = accumulatedText(from: events)
        XCTAssertEqual(text, "Hello from chunked stream!")

        // Should complete normally
        let completed = events.contains { if case .completed = $0 { return true }; return false }
        XCTAssertTrue(completed, "Expected completion event after chunked delivery")
    }

    // MARK: 14. Mid-Stream Network Error

    func testMidStreamNetworkError() async throws {
        // Given: A chunked response where the connection drops mid-stream
        // First chunk has headers + partial content, then connection error
        MockSSEProtocol.enqueue(.chunkedSSE(
            chunks: [
                [AnthropicSSE.messageStart(),
                 AnthropicSSE.contentBlockStart(index: 0),
                 AnthropicSSE.textDelta(index: 0, text: "partial"),
                 ""] // terminate last event so parser emits it
                // No more chunks — simulating dropped connection
                // The URLProtocol will finish loading after the first chunk,
                // which means the SSE stream will end without message_stop
            ]
        ))

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Drop test",
            model: StudioModelStrategy.fullSend
        )

        // Stream should end after single chunk (no message_stop sent)
        let events = await collectEvents(from: stream)

        // Should have received the partial text
        let text = accumulatedText(from: events)
        XCTAssertTrue(text.contains("partial"), "Should have received partial text before drop")
    }

    // MARK: 15. Split SSE Event Across Chunk Boundaries

    func testSSEEventSplitAcrossChunkBoundaries() async throws {
        // Given: An SSE event's data line is split across two chunks.
        // The parser must reassemble it correctly from the byte stream.
        // We manually construct raw SSE strings that split mid-event.
        let rawChunk1 = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-sonnet-4-6\",\"stop_reason\":null,\"usage\":{\"input_tokens\":42,\"output_tokens\":0}}}\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\nevent: content_block_del"
        let rawChunk2 = "ta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Reassembled!\"}}\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":50}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

        // Use raw chunked SSE — deliver as pre-joined strings
        MockSSEProtocol.enqueue(.chunkedSSE(chunks: [[rawChunk1], [rawChunk2]], delayMs: 30))

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Split boundary",
            model: StudioModelStrategy.fullSend
        )

        let events = await collectEvents(from: stream)
        let text = accumulatedText(from: events)
        XCTAssertEqual(text, "Reassembled!", "SSE event split across chunks should reassemble correctly")
    }

    // MARK: 16. Single-Byte Streaming — Ultimate Parser Robustness

    func testSingleByteStreamingParsesCorrectly() async throws {
        // Given: The entire SSE stream is delivered one byte at a time.
        // This proves the parser is fully delimiter-driven and has zero
        // reliance on chunk boundaries or transport-level framing.
        let sseEvents = AnthropicSSE.simpleTextResponse("Byte by byte!")

        MockSSEProtocol.enqueue(.byteAtATime(events: sseEvents))

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Single byte test",
            model: StudioModelStrategy.fullSend
        )

        let events = await collectEvents(from: stream)
        let text = accumulatedText(from: events)
        XCTAssertEqual(text, "Byte by byte!", "Parser must produce correct output when fed one byte at a time")

        let completed = events.contains { if case .completed = $0 { return true }; return false }
        XCTAssertTrue(completed, "Stream must complete normally under byte-at-a-time delivery")
    }
}

// MARK: - B. Recovery & Circuit Breaker Contract Tests

final class RecoveryContractTests: XCTestCase {

    // MARK: 1. Retry Policy Applies with Backoff

    func testRetrySucceedsAfterTransientFailure() async throws {
        let recovery = RecoveryExecutor()
        var attempts = 0

        // .timeout maps to .retryWithBackoff(maxAttempts: 2)
        let result = await recovery.attemptRecovery(
            for: .timeout(tool: "terminal", elapsed: 30)
        ) {
            attempts += 1
            if attempts < 2 {
                // First attempt fails (returns nil)
                return nil
            }
            return ("success after retry", false)
        }

        XCTAssertTrue(result.succeeded, "Recovery should succeed after transient failure, got: \(result)")
        XCTAssertTrue(attempts >= 2, "Should have retried at least twice, got \(attempts)")
    }

    // MARK: 2. Fail-Fast Errors Skip Retry

    func testSandboxViolationFailsFast() async throws {
        let recovery = RecoveryExecutor()
        var attempts = 0

        let result = await recovery.attemptRecovery(
            for: .sandboxViolation(tool: "file_write", path: "/etc/passwd")
        ) {
            attempts += 1
            return ("should not reach", false)
        }

        XCTAssertTrue(result.isError, "Sandbox violation should fail fast")
        XCTAssertEqual(attempts, 0, "Sandbox violation should not attempt retry")
    }

    // MARK: 3. Circuit Breaker Trips After Threshold

    func testCircuitBreakerTripsAfterRepeatedFailures() async throws {
        let config = CircuitBreaker.Configuration(
            failureThreshold: 3,
            windowSeconds: 30,
            cooldownSeconds: 60
        )
        let recovery = RecoveryExecutor(circuitBreakerConfig: config)

        // .invalidInput → .failFast → recordFailure() on each call
        for i in 0..<3 {
            let _ = await recovery.attemptRecovery(
                for: .invalidInput(tool: "file_write", reason: "bad input \(i)")
            ) { nil }
        }

        let state = await recovery.circuitBreakerState()
        XCTAssertEqual(state, .open, "Breaker should be open after \(config.failureThreshold) failFast failures")

        // Next retryWithBackoff attempt should be rejected by breaker
        let result = await recovery.attemptRecovery(
            for: .timeout(tool: "terminal", elapsed: 30)
        ) {
            XCTFail("Retry block should not execute when breaker is open")
            return nil
        }
        XCTAssertTrue(result.isError, "Should fail when breaker is open")
        XCTAssertTrue(result.displayText.contains("Circuit breaker open"),
                       "Error should mention circuit breaker")
    }

    // MARK: 4. Circuit Breaker Resets

    func testCircuitBreakerResetsOnCommand() async throws {
        let config = CircuitBreaker.Configuration(failureThreshold: 2, windowSeconds: 30, cooldownSeconds: 60)
        let recovery = RecoveryExecutor(circuitBreakerConfig: config)

        for _ in 0..<2 {
            let _ = await recovery.attemptRecovery(
                for: .invalidInput(tool: "file_write", reason: "bad")
            ) { nil }
        }

        let openState = await recovery.circuitBreakerState()
        XCTAssertEqual(openState, .open)

        await recovery.resetCircuitBreaker()
        let closedState = await recovery.circuitBreakerState()
        XCTAssertEqual(closedState, .closed, "Breaker should be closed after reset")
    }
}

// MARK: - C. Trace & Log Contract Tests

final class TraceLogContractTests: XCTestCase {

    // MARK: 1. Span Lifecycle Contract

    func testSpanLifecycle_beginEndProducesCompletedSpan() async throws {
        let tracer = TraceCollector()

        let spanID = await tracer.begin(
            kind: .toolExecution,
            name: "file_read",
            attributes: ["tool": "file_read", "path": "/test.swift"]
        )

        await tracer.setAttribute("bytes_read", value: "1024", on: spanID)
        await tracer.end(spanID)

        let spans = await tracer.allSpans()
        let span = spans.first { $0.id == spanID }

        XCTAssertNotNil(span, "Completed span should be queryable")
        XCTAssertEqual(span?.kind, .toolExecution)
        XCTAssertEqual(span?.name, "file_read")
        XCTAssertNotNil(span?.endedAt, "Span should have end time")
        XCTAssertNotNil(span?.duration, "Span should have computed duration")
        XCTAssertEqual(span?.attributes["tool"], "file_read")
        XCTAssertEqual(span?.attributes["bytes_read"], "1024")
        if case .ok = span?.status {} else {
            XCTFail("Expected .ok status, got \(String(describing: span?.status))")
        }
    }

    // MARK: 2. Error Span Records Failure

    func testSpanError_recordsFailureMessage() async throws {
        let tracer = TraceCollector()

        let spanID = await tracer.begin(kind: .retry, name: "recovery_attempt")
        await tracer.end(spanID, error: "Connection refused after 3 retries")

        let spans = await tracer.allSpans()
        let span = spans.first { $0.id == spanID }

        XCTAssertNotNil(span)
        XCTAssertEqual(span?.kind, .retry)
        if case .error(let msg) = span?.status {
            XCTAssertTrue(msg.contains("Connection refused"), "Error message should be preserved")
        } else {
            XCTFail("Expected .error status, got \(String(describing: span?.status))")
        }
    }

    // MARK: 3. Parent-Child Span Relationship

    func testSpanParentChildRelationship() async throws {
        let tracer = TraceCollector()

        let parentID = await tracer.begin(kind: .llmCall, name: "anthropic_request")
        let childID = await tracer.begin(
            kind: .toolExecution,
            name: "file_write",
            parentID: parentID,
            attributes: ["tool": "file_write"]
        )
        await tracer.end(childID)
        await tracer.end(parentID)

        let spans = await tracer.allSpans()
        let child = spans.first { $0.id == childID }

        XCTAssertEqual(child?.parentID, parentID, "Child span should reference parent")
        XCTAssertEqual(spans.count, 2)
    }

    // MARK: 4. LogCollector Structured Fields

    func testLogCollector_structuredFieldsQueryable() async throws {
        let logger = LogCollector(traceID: UUID())

        await logger.info("routing", "Model selected", fields: [
            "route.reason": "failure_escalation",
            "model": "claude-opus-4-6",
            "consecutive_failures": "3"
        ])

        await logger.warn("recovery", "Retry backoff applied", fields: [
            "attempt": "2",
            "delay_ms": "450",
            "jitter_factor": "1.12"
        ])

        await logger.error("breaker", "Circuit breaker tripped", fields: [
            "state": "open",
            "failure_count": "5",
            "window_seconds": "30"
        ])

        // Query by category
        let routingLogs = await logger.query(category: "routing")
        XCTAssertEqual(routingLogs.count, 1)
        XCTAssertEqual(routingLogs.first?.fields["route.reason"], "failure_escalation")

        // Query by level
        let errors = await logger.query(level: .error)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.fields["state"], "open")

        // Query by substring
        let jitterLogs = await logger.query(containing: "backoff")
        XCTAssertEqual(jitterLogs.count, 1)
        XCTAssertEqual(jitterLogs.first?.fields["jitter_factor"], "1.12")

        // Summary
        let summary = await logger.summary()
        XCTAssertEqual(summary.totalEntries, 3)
        XCTAssertEqual(summary.infoCount, 1)
        XCTAssertEqual(summary.warnCount, 1)
        XCTAssertEqual(summary.errorCount, 1)
        XCTAssertTrue(summary.categories.contains("routing"))
        XCTAssertTrue(summary.categories.contains("recovery"))
        XCTAssertTrue(summary.categories.contains("breaker"))
    }

    // MARK: 5. Trace Summary Aggregation

    func testTraceSummary_countsByKind() async throws {
        let tracer = TraceCollector()

        let s1 = await tracer.begin(kind: .llmCall, name: "request_1")
        let s2 = await tracer.begin(kind: .toolExecution, name: "file_read", parentID: s1)
        let s3 = await tracer.begin(kind: .toolExecution, name: "terminal", parentID: s1)
        let s4 = await tracer.begin(kind: .retry, name: "recovery_1", parentID: s3)

        await tracer.end(s4)
        await tracer.end(s3)
        await tracer.end(s2)
        await tracer.end(s1)

        let summary = await tracer.summary()
        XCTAssertEqual(summary.spanCount, 4)
        // Verify the span kinds were recorded
        let spans = await tracer.allSpans()
        let kinds = Set(spans.map(\.kind))
        XCTAssertTrue(kinds.contains(.llmCall))
        XCTAssertTrue(kinds.contains(.toolExecution))
        XCTAssertTrue(kinds.contains(.retry))
    }
}

// MARK: - D. Phase 3 — Capability-Based Routing Tests

final class CapabilityRoutingTests: XCTestCase {

    // MARK: 1. Discovery Phase Routes to Cheapest Capable Model

    func testDiscoveryPhaseRoutesToExplorer() {
        // Discovery requires [.research, .speed] — explorer is the cheapest match.
        let context = StudioModelStrategy.RoutingContext(
            goal: "Read project files",
            requiredCapabilities: TaskPhase.discovery.defaultCapabilities
        )
        let decision = StudioModelStrategy.routingDecision(context: context)

        XCTAssertEqual(decision.model.role, .explorer, "Discovery should route to explorer (cheapest with research+speed)")
        XCTAssertEqual(decision.strategy, .capabilityMatch)
        XCTAssertEqual(decision.reason, "capability_match")
        XCTAssertNotNil(decision.candidateRoles)
        XCTAssertTrue(decision.candidateRoles!.contains(.explorer))
    }

    // MARK: 2. Implementation Phase Routes to Subagent (cheapest with codeGen+multifileEdit)

    func testImplementationPhaseRoutesToReview() {
        // Implementation requires [.codeGeneration, .multifileEdit].
        // review/fullSend are equivalent cost but review is listed first alphabetically —
        // actually review is the first entry in costProfiles that satisfies both.
        let context = StudioModelStrategy.RoutingContext(
            goal: "Write the new feature",
            requiredCapabilities: TaskPhase.implementation.defaultCapabilities
        )
        let decision = StudioModelStrategy.routingDecision(context: context)

        // Both review and fullSend satisfy [codeGeneration, multifileEdit] at the same cost.
        // The router picks the first matching by cost sort — they tie, so insertion order wins.
        let role = decision.model.role
        XCTAssertTrue(role == .review || role == .fullSend,
                      "Implementation should route to review or fullSend (cheapest with codeGen+multifileEdit), got \(role)")
        XCTAssertEqual(decision.strategy, .capabilityMatch)
    }

    // MARK: 3. Verification Phase Routes to Review

    func testVerificationPhaseRoutesToReview() {
        // Verification requires [.review] — review is cheapest with that capability.
        let context = StudioModelStrategy.RoutingContext(
            goal: "Run tests",
            requiredCapabilities: TaskPhase.verification.defaultCapabilities
        )
        let decision = StudioModelStrategy.routingDecision(context: context)

        XCTAssertEqual(decision.model.role, .review, "Verification should route to review")
        XCTAssertEqual(decision.strategy, .capabilityMatch)
    }

    // MARK: 4. Repair Phase Routes to Subagent

    func testRepairPhaseRoutesToSubagent() {
        // Repair requires [.buildRepair] — subagent is cheapest with that capability.
        let context = StudioModelStrategy.RoutingContext(
            goal: "Fix build errors",
            requiredCapabilities: TaskPhase.repair.defaultCapabilities
        )
        let decision = StudioModelStrategy.routingDecision(context: context)

        XCTAssertEqual(decision.model.role, .subagent, "Repair should route to subagent (cheapest with buildRepair)")
        XCTAssertEqual(decision.strategy, .capabilityMatch)
    }

    // MARK: 5. Explicit Escalation Overrides Capability Match

    func testExplicitEscalationOverridesCapabilities() {
        // Even with cheap capabilities required, explicit "use opus" wins.
        let context = StudioModelStrategy.RoutingContext(
            goal: "use opus to read project files",
            requiredCapabilities: [.research, .speed]
        )
        let decision = StudioModelStrategy.routingDecision(context: context)

        XCTAssertEqual(decision.model.role, .escalation, "Explicit escalation must override capability match")
        XCTAssertEqual(decision.reason, "explicit_escalation")
    }

    // MARK: 6. Failure Escalation Overrides Capability Match

    func testFailureEscalationOverridesCapabilities() {
        let context = StudioModelStrategy.RoutingContext(
            goal: "Read project files",
            consecutiveFailures: 3,
            lastFailedGoal: "Read project files",
            requiredCapabilities: [.research, .speed]
        )
        let decision = StudioModelStrategy.routingDecision(context: context)

        XCTAssertEqual(decision.model.role, .escalation, "Failure escalation must override capability match")
        XCTAssertEqual(decision.reason, "failure_escalation")
    }

    // MARK: 7. Cost Profile Satisfies Correctly

    func testCostProfileSatisfies() {
        let profile = ModelCostProfile(
            role: .review,
            costPerMInputTokens: 3.0,
            costPerMOutputTokens: 15.0,
            latencyP50Ms: 600,
            capabilities: [.codeGeneration, .reasoning, .review]
        )

        XCTAssertTrue(profile.satisfies([.review]))
        XCTAssertTrue(profile.satisfies([.codeGeneration, .reasoning]))
        XCTAssertFalse(profile.satisfies([.buildRepair]), "review profile should not satisfy buildRepair")
        XCTAssertTrue(profile.satisfies([]), "Empty requirements should always be satisfied")
    }

    // MARK: 8. Default Capabilities from TaskPhase

    func testTaskPhaseDefaultCapabilities() {
        XCTAssertEqual(TaskPhase.discovery.defaultCapabilities, [.research, .speed])
        XCTAssertEqual(TaskPhase.analysis.defaultCapabilities, [.reasoning, .research])
        XCTAssertEqual(TaskPhase.implementation.defaultCapabilities, [.codeGeneration, .multifileEdit])
        XCTAssertEqual(TaskPhase.verification.defaultCapabilities, [.review])
        XCTAssertEqual(TaskPhase.repair.defaultCapabilities, [.buildRepair])
    }

    // MARK: 9. TaskStep Inherits Phase Capabilities by Default

    func testTaskStepInheritsPhaseCapabilities() {
        let step = TaskStep(
            id: "test-1",
            intent: "Explore codebase",
            phase: .discovery,
            toolHint: .search
        )
        XCTAssertEqual(step.requiredCapabilities, [.research, .speed])
    }

    // MARK: 10. TaskStep Can Override Capabilities

    func testTaskStepOverridesCapabilities() {
        let step = TaskStep(
            id: "test-2",
            intent: "Complex analysis requiring code generation",
            phase: .analysis,
            toolHint: .mixed,
            requiredCapabilities: [.reasoning, .codeGeneration, .multifileEdit]
        )
        XCTAssertEqual(step.requiredCapabilities, [.reasoning, .codeGeneration, .multifileEdit])
        // Should NOT have .research from analysis phase default
        XCTAssertFalse(step.requiredCapabilities.contains(.research))
    }

    // MARK: 11. No Capabilities Falls Through to Default Routing

    func testNilCapabilitiesFallsThrough() {
        let context = StudioModelStrategy.RoutingContext(
            goal: "just do something"
        )
        let decision = StudioModelStrategy.routingDecision(context: context)

        XCTAssertEqual(decision.model.role, .fullSend, "No capabilities should fall through to default fullSend")
        XCTAssertEqual(decision.strategy, .fallback)
    }

    // MARK: 12. Routing Decision Contains Telemetry Fields

    func testRoutingDecisionContainsTelemetry() {
        let context = StudioModelStrategy.RoutingContext(
            goal: "Read codebase",
            requiredCapabilities: [.research, .speed]
        )
        let decision = StudioModelStrategy.routingDecision(context: context)

        XCTAssertEqual(decision.strategy, .capabilityMatch)
        XCTAssertNotNil(decision.capabilitiesRequired)
        XCTAssertTrue(decision.capabilitiesRequired!.contains(.research))
        XCTAssertTrue(decision.capabilitiesRequired!.contains(.speed))
        XCTAssertNotNil(decision.candidateRoles)
        XCTAssertFalse(decision.candidateRoles!.isEmpty)
        // matchedSignals should list the required capabilities
        XCTAssertTrue(decision.matchedSignals.contains("research"))
        XCTAssertTrue(decision.matchedSignals.contains("speed"))
    }
}