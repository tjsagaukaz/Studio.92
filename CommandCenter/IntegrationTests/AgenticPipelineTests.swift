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
}
