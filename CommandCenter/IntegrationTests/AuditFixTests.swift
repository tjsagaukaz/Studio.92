// AuditFixTests.swift
// Studio.92 — Audit Fix Verification Tests
// Tests verifying the fixes from the April 2026 security/reliability audit.

import XCTest
import AgentCouncil
@testable import CommandCenter

// MARK: - UTF-8 Pipe Decoder Tests (C3 / StatefulTerminalEngine)

final class UTF8PipeDecoderTests: XCTestCase {

    // MARK: 1. Basic ASCII

    func testBasicASCII() {
        let decoder = UTF8PipeDecoder()
        let result = decoder.append(Data("Hello, world!".utf8))
        XCTAssertEqual(result, "Hello, world!")
    }

    // MARK: 2. Multi-Byte Character (Emoji) Split Across Deliveries

    func testMultiByteCharacterSplitAcrossDeliveries() {
        let decoder = UTF8PipeDecoder()
        // 🚀 = F0 9F 9A 80 (4 bytes). Split after byte 2.
        let emoji = "🚀"
        let bytes = Array(emoji.utf8)
        XCTAssertEqual(bytes.count, 4)

        let firstHalf = Data(bytes[0..<2])
        let secondHalf = Data(bytes[2..<4])

        // First delivery: incomplete sequence → no output yet.
        let result1 = decoder.append(firstHalf)
        XCTAssertNil(result1, "Incomplete UTF-8 should be buffered, not emitted")

        // Second delivery: completes the character.
        let result2 = decoder.append(secondHalf)
        XCTAssertEqual(result2, "🚀")
    }

    // MARK: 3. Text + Incomplete Tail

    func testTextFollowedByIncompleteSequence() {
        let decoder = UTF8PipeDecoder()
        // "OK" + first 2 bytes of a 3-byte character (é = C3 A9 as NFC, but let's use a
        // 3-byte CJK if we need a split. Actually é is 2 bytes. Use ñ = C3 B1, 2 bytes.)
        // Better: 中 = E4 B8 AD (3 bytes).
        let text = "OK"
        let cjk = Array("中".utf8) // [0xE4, 0xB8, 0xAD]
        XCTAssertEqual(cjk.count, 3)

        var data = Data(text.utf8)
        data.append(contentsOf: cjk[0..<2]) // incomplete 中

        let result1 = decoder.append(data)
        XCTAssertEqual(result1, "OK", "Should emit valid prefix, hold incomplete tail")

        // Complete the character.
        let result2 = decoder.append(Data([cjk[2]]))
        XCTAssertEqual(result2, "中")
    }

    // MARK: 4. Empty Data

    func testEmptyDataReturnsNil() {
        let decoder = UTF8PipeDecoder()
        XCTAssertNil(decoder.append(Data()))
    }

    // MARK: 5. Flush with Pending Bytes

    func testFlushEmitsPendingBytes() {
        let decoder = UTF8PipeDecoder()
        // Feed incomplete bytes.
        let bytes: [UInt8] = [0xE4, 0xB8] // first 2 of "中"
        _ = decoder.append(Data(bytes))

        // Flush should emit something (lossy) rather than holding forever.
        let result = decoder.flush()
        XCTAssertNotNil(result, "Flush should emit buffered bytes")
    }

    // MARK: 6. Flush with Nothing Pending

    func testFlushWithNothingPendingReturnsNil() {
        let decoder = UTF8PipeDecoder()
        XCTAssertNil(decoder.flush())
    }

    // MARK: 7. Multiple Consecutive Appends

    func testMultipleConsecutiveAppends() {
        let decoder = UTF8PipeDecoder()
        XCTAssertEqual(decoder.append(Data("Hello".utf8)), "Hello")
        XCTAssertEqual(decoder.append(Data(", ".utf8)), ", ")
        XCTAssertEqual(decoder.append(Data("world!".utf8)), "world!")
    }

    // MARK: 8. Large Payload

    func testLargePayload() {
        let decoder = UTF8PipeDecoder()
        let large = String(repeating: "A", count: 100_000)
        let result = decoder.append(Data(large.utf8))
        XCTAssertEqual(result?.count, 100_000)
    }
}

// MARK: - SSE Buffer Cap Tests (C2 — OpenAI + Anthropic)

final class SSEBufferCapTests: XCTestCase {

    private var mockSession: URLSession!
    private var tempProjectDir: URL!

    override func setUp() async throws {
        MockSSEProtocol.reset()
        mockSession = MockSession.make()

        tempProjectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio92-bufcap-\(UUID().uuidString)")
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

    // MARK: 1. Normal-Sized Response Passes Through

    func testNormalResponsePassesThrough() async throws {
        MockSSEProtocol.enqueue(
            .sse(events: AnthropicSSE.simpleTextResponse("Normal response"))
        )

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Hello",
            model: StudioModelStrategy.fullSend
        )

        let events = await collectEvents(from: stream)
        let text = accumulatedText(from: events)
        XCTAssertEqual(text, "Normal response")
    }

    // MARK: 2. Empty SSE Data Payload Skipped (L3)

    func testEmptySSEDataPayloadSkipped() async throws {
        // Construct SSE events where one data line is empty (data: \n\n).
        let events = [
            AnthropicSSE.messageStart(),
            AnthropicSSE.contentBlockStart(index: 0),
            "event: content_block_delta\ndata: \n",   // empty data payload
            AnthropicSSE.textDelta(index: 0, text: "Real text"),
            AnthropicSSE.contentBlockStop(index: 0),
            AnthropicSSE.messageDelta(),
            AnthropicSSE.messageStop()
        ]
        MockSSEProtocol.enqueue(.sse(events: events))

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Hello",
            model: StudioModelStrategy.fullSend
        )

        let collected = await collectEvents(from: stream)
        let text = accumulatedText(from: collected)
        XCTAssertTrue(text.contains("Real text"),
                       "Expected real text to pass through, got: \(text)")

        // Stream should complete without crash.
        let completed = collected.contains { event in
            if case .completed = event { return true }
            return false
        }
        XCTAssertTrue(completed, "Expected completion event")
    }

    // MARK: 3. Large Multi-Chunk Streaming Completes

    func testLargeMultiChunkStreamingCompletes() async throws {
        // Generate many text deltas to verify streaming handles volume gracefully.
        var sseEvents: [String] = [
            AnthropicSSE.messageStart(),
            AnthropicSSE.contentBlockStart(index: 0)
        ]

        let chunkCount = 500
        for i in 0..<chunkCount {
            sseEvents.append(AnthropicSSE.textDelta(index: 0, text: "chunk\(i) "))
        }

        sseEvents.append(AnthropicSSE.contentBlockStop(index: 0))
        sseEvents.append(AnthropicSSE.messageDelta())
        sseEvents.append(AnthropicSSE.messageStop())

        MockSSEProtocol.enqueue(.sse(events: sseEvents))

        let client = makeClient()
        let stream = await client.run(
            system: "Test",
            userMessage: "Long response",
            model: StudioModelStrategy.fullSend
        )

        let events = await collectEvents(from: stream)
        let text = accumulatedText(from: events)

        // All chunks should arrive.
        XCTAssertTrue(text.contains("chunk0"), "Expected first chunk")
        XCTAssertTrue(text.contains("chunk\(chunkCount - 1)"), "Expected last chunk")
    }
}

// MARK: - StreamPipeline Buffer Cap Tests (H1)

@MainActor
final class StreamPipelineBufferCapTests: XCTestCase {

    // MARK: 1. Narrative Buffer Accepts Normal Text

    func testNarrativeBufferAcceptsNormalText() {
        let controller = StreamPhaseController()
        controller.appendNarrative("Hello, this is a normal response.")
        XCTAssertEqual(controller.narrativeBuffer, "Hello, this is a normal response.")
    }

    // MARK: 2. Narrative Buffer Stops Growing Beyond Cap

    func testNarrativeBufferStopsGrowingBeyondCap() {
        let controller = StreamPhaseController()

        // Fill past the 512KB cap.
        let chunk = String(repeating: "A", count: 100_000)
        for _ in 0..<6 {
            controller.appendNarrative(chunk) // 600KB total, last append goes through because at 500K < 512K
        }
        let sizeAfterSix = controller.narrativeBuffer.utf8.count
        XCTAssertEqual(sizeAfterSix, 600_000, "Should accept append when buffer is under cap")

        // Now at 600KB (> 512KB cap), next append must be blocked.
        controller.appendNarrative(chunk)
        XCTAssertEqual(controller.narrativeBuffer.utf8.count, sizeAfterSix,
                        "Buffer should stop growing once at or above cap")
    }
}

// MARK: - Credential Store Tests (H4)

final class CredentialStoreTests: XCTestCase {

    // MARK: 1. Keychain Round-Trip

    func testKeychainRoundTrip() {
        let testKey = "studio92_audit_test_\(UUID().uuidString)"
        let testValue = "test-api-key-value"

        // Save via Keychain.
        KeychainCredentialStore.save(key: testKey, value: testValue)

        // Load.
        let loaded = KeychainCredentialStore.load(key: testKey)
        XCTAssertEqual(loaded, testValue, "Key should round-trip through Keychain")

        // Cleanup: delete the test key.
        KeychainCredentialStore.delete(key: testKey)
        XCTAssertNil(KeychainCredentialStore.load(key: testKey), "Key should be deleted")
    }

    // MARK: 2. StudioCredentialStore Delegates to Keychain

    func testStudioCredentialStoreDelegatesToKeychain() {
        let testKey = "studio92_audit_test2_\(UUID().uuidString)"
        let testValue = "delegated-value"

        // Save via StudioCredentialStore.
        StudioCredentialStore.save(key: testKey, value: testValue)

        // Verify it's in Keychain.
        let fromKeychain = KeychainCredentialStore.load(key: testKey)
        XCTAssertEqual(fromKeychain, testValue,
                        "StudioCredentialStore should delegate to KeychainCredentialStore")

        // Load via StudioCredentialStore.
        let fromStore = StudioCredentialStore.load(key: testKey)
        XCTAssertEqual(fromStore, testValue)

        // Cleanup.
        KeychainCredentialStore.delete(key: testKey)
    }

    // MARK: 3. Empty Value Deletes Key

    func testEmptyValueDeletesKey() {
        let testKey = "studio92_audit_test3_\(UUID().uuidString)"

        // Save a real value, then save empty.
        StudioCredentialStore.save(key: testKey, value: "real-value")
        XCTAssertNotNil(StudioCredentialStore.load(key: testKey))

        StudioCredentialStore.save(key: testKey, value: "")
        XCTAssertNil(StudioCredentialStore.load(key: testKey),
                      "Empty value should delete the key")
    }
}

// MARK: - ConversationStore isStreaming Decoupling (H6)

@MainActor
final class ConversationStoreStreamingTests: XCTestCase {

    // MARK: 1. RefreshPipelineState Clears Stale Streaming

    func testRefreshPipelineStateClearsStaleStreaming() {
        let store = ConversationStore()

        // Insert a streaming message.
        let msg = ChatMessage(
            kind: .streaming,
            goal: "Test",
            text: "",
            timestamp: Date(),
            streamingText: "partial response",
            isStreaming: true
        )
        store.applyLiveMessage(msg, isPipelineRunning: true)

        // Verify it's streaming.
        XCTAssertTrue(store.turns.last?.state == .streaming,
                       "Turn should be streaming initially")

        // Pipeline stops — refreshPipelineState should detect stale streaming.
        store.refreshPipelineState(isPipelineRunning: false)

        let lastTurn = store.turns.last
        XCTAssertEqual(lastTurn?.state, .finalizing,
                        "Stale streaming turn should transition to .finalizing")
        XCTAssertFalse(lastTurn?.response.isStreaming ?? true,
                        "isStreaming should be cleared")
    }

    // MARK: 2. Active Stream Preserved When Pipeline Running

    func testActiveStreamPreservedWhenPipelineRunning() {
        let store = ConversationStore()

        let msg = ChatMessage(
            kind: .streaming,
            goal: "Test",
            text: "",
            timestamp: Date(),
            streamingText: "partial",
            isStreaming: true
        )
        store.applyLiveMessage(msg, isPipelineRunning: true)

        // Pipeline still running — state should stay as streaming.
        store.refreshPipelineState(isPipelineRunning: true)

        let lastTurn = store.turns.last
        XCTAssertEqual(lastTurn?.state, .streaming,
                        "Turn should remain streaming when pipeline is running")
    }
}

// MARK: - LatencyDiagnostics Run Eviction (M6)

final class LatencyDiagnosticsEvictionTests: XCTestCase {

    // MARK: 1. Evicts Oldest Runs

    func testEvictsOldestRuns() async {
        let diag = LatencyDiagnostics.shared
        let now = CFAbsoluteTimeGetCurrent()

        // Create more runs than the retention limit (10).
        var runIDs: [String] = []
        for i in 0..<15 {
            let id = "eviction-test-run-\(i)-\(UUID().uuidString)"
            runIDs.append(id)
            await diag.beginRun(id: id, goalPreview: "test \(i)", triggeredAt: now + Double(i))
            await diag.finishRun(runID: id, endedAt: now + Double(i) + 0.1, outcome: "success")
        }

        // The first 5 runs should have been evicted.
        // percentiles() returns nil for evicted runs, non-nil for retained.
        for i in 0..<5 {
            let report = await diag.percentiles(for: runIDs[i])
            XCTAssertNil(report, "Run \(i) should have been evicted")
        }

        // The last 10 should still be present.
        for i in 5..<15 {
            let report = await diag.percentiles(for: runIDs[i])
            XCTAssertNotNil(report, "Run \(i) should still be retained")
        }
    }
}

// MARK: - Ambient Editor Context

final class AmbientEditorContextTests: XCTestCase {

    @MainActor
    func testStaleSelectionAndCursorAreDroppedFromSnapshot() throws {
        let workspaceURL = try makeWorkspace()
        let fileURL = workspaceURL.appendingPathComponent("Example.swift")
        try "struct Example {}\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let coordinator = AmbientEditorContextCoordinator(workspaceURL: workspaceURL)
        let observedAt = Date(timeIntervalSinceReferenceDate: 100)

        coordinator.noteSelection(
            path: fileURL.path,
            content: "struct Example {}\n",
            selection: NSRange(location: 7, length: 7),
            language: "swift",
            isDirty: false,
            observedAt: observedAt,
            openFiles: [OpenFileContext(path: fileURL.path, language: "swift", isDirty: false, lastFocusedAt: observedAt)]
        )

        let snapshot = coordinator.snapshot(
            for: .toolDispatch,
            influenceLevel: .minimal,
            now: observedAt.addingTimeInterval(31)
        )

        XCTAssertNil(snapshot.selectedRange)
        XCTAssertNil(snapshot.currentFile?.cursorLine)
        XCTAssertNil(snapshot.currentFile?.cursorColumn)
        XCTAssertEqual(snapshot.currentFile?.path, fileURL.path)
        XCTAssertEqual(snapshot.selectionFreshnessMs, 31_000)
        XCTAssertFalse(snapshot.contextID.uuidString.isEmpty)
    }

    @MainActor
    func testSelectionWinsConflictOverDiagnostics() throws {
        let workspaceURL = try makeWorkspace()
        let fileA = workspaceURL.appendingPathComponent("A.swift")
        let fileB = workspaceURL.appendingPathComponent("B.swift")
        try "func alpha() {}\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "func beta() {}\n".write(to: fileB, atomically: true, encoding: .utf8)

        let coordinator = AmbientEditorContextCoordinator(workspaceURL: workspaceURL)
        let observedAt = Date(timeIntervalSinceReferenceDate: 200)
        coordinator.noteSelection(
            path: fileA.path,
            content: "func alpha() {}\n",
            selection: NSRange(location: 5, length: 5),
            language: "swift",
            isDirty: false,
            observedAt: observedAt,
            openFiles: [OpenFileContext(path: fileA.path, language: "swift", isDirty: false, lastFocusedAt: observedAt)]
        )
        coordinator.replaceDiagnostics([
            EditorDiagnosticContext(
                path: fileB.path,
                line: 1,
                column: 1,
                severity: .error,
                message: "Cannot find 'beta' in scope",
                source: "xcode_build",
                observedAt: observedAt
            )
        ], observedAt: observedAt)

        let snapshot = coordinator.snapshot(for: .modelRouting, influenceLevel: .standard, now: observedAt)

        XCTAssertEqual(snapshot.conflict?.reason, .selectionOverridesOtherSignals)
        XCTAssertEqual(snapshot.routingFocus()?.path, fileA.path)
    }

    func testRoutingUsesAmbientDiagnosticsAndRecentEditsDeterministically() {
        let observedAt = Date(timeIntervalSinceReferenceDate: 300)
        let contextID = UUID()
        let diagnosticsContext = DiagnosticsContext(items: [
            EditorDiagnosticContext(
                path: "/tmp/Example.swift",
                line: 12,
                column: 4,
                severity: .error,
                message: "Value of type 'Int' has no member 'foo'",
                source: "xcode_build",
                observedAt: observedAt
            )
        ], observedAt: observedAt)
        let ambient = AmbientEditorContext(
            contextID: contextID,
            capturedAt: observedAt,
            lastUpdatedAt: observedAt,
            influenceLevel: .standard,
            selectionFreshnessMs: nil,
            currentFile: nil,
            selectedRange: nil,
            openFiles: .empty,
            recentEdits: [RecentEditContext(path: "/tmp/Example.swift", changedLineRange: nil, timestamp: observedAt, source: "workspace")],
            diagnostics: diagnosticsContext,
            gitContext: nil,
            conflict: nil
        )

        let diagnosticDecision = StudioModelStrategy.routingDecision(context: .init(
            goal: "fix this error",
            ambientContext: ambient
        ))
        XCTAssertEqual(diagnosticDecision.reason, "ambient_diagnostics_focus")

        let recentEditDecision = StudioModelStrategy.routingDecision(context: .init(
            goal: "review my changes",
            ambientContext: ambient
        ))
        XCTAssertEqual(recentEditDecision.reason, "ambient_recent_edits_review")
        XCTAssertEqual(recentEditDecision.model.role, .review)
        XCTAssertEqual(ambient.contextID, contextID)
    }

    func testTaskPlanningUsesCurrentFileFocus() {
        let observedAt = Date(timeIntervalSinceReferenceDate: 400)
        let contextID = UUID()
        let ambient = AmbientEditorContext(
            contextID: contextID,
            capturedAt: observedAt,
            lastUpdatedAt: observedAt,
            influenceLevel: .standard,
            selectionFreshnessMs: nil,
            currentFile: CurrentFileContext(
                path: "/tmp/Focus.swift",
                language: "swift",
                cursorLine: 14,
                cursorColumn: 9,
                nearbyLineRange: 11...17,
                nearbySnippet: "let focused = true",
                isDirty: false,
                observedAt: observedAt
            ),
            selectedRange: nil,
            openFiles: OpenFilesContext(
                files: [OpenFileContext(path: "/tmp/Focus.swift", language: "swift", isDirty: false, lastFocusedAt: observedAt)],
                observedAt: observedAt
            ),
            recentEdits: [],
            diagnostics: .empty,
            gitContext: nil,
            conflict: nil
        )

        let assessment = TaskComplexityAnalyzer.ComplexityAssessment(
            shouldUseDAG: true,
            reason: "multi_step_signal",
            matchedSignals: ["refactor"],
            suggestedPhases: [.discovery, .analysis, .implementation]
        )

        let plan = TaskPlanGenerator.generate(goal: "Refactor this", assessment: assessment, ambientContext: ambient)
        XCTAssertTrue(plan.steps[0].intent.contains("Focus.swift"))

        let supplement = TaskPlanPromptInjection.promptSupplement(
            for: plan,
            currentStep: plan.steps[0],
            ambientContext: ambient
        )
        XCTAssertTrue(supplement?.contains("Active editor file: /tmp/Focus.swift") == true)
        XCTAssertEqual(ambient.contextID, contextID)
    }

    func testToolDispatchReadsAmbientFileButRejectsAmbientMutationTarget() async throws {
        let workspaceURL = try makeWorkspace()
        let fileURL = workspaceURL.appendingPathComponent("Readme.swift")
        try "let value = 42\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let observedAt = Date(timeIntervalSinceReferenceDate: 500)
        let ambient = AmbientEditorContext(
            contextID: UUID(),
            capturedAt: observedAt,
            lastUpdatedAt: observedAt,
            influenceLevel: .minimal,
            selectionFreshnessMs: 0,
            currentFile: CurrentFileContext(
                path: fileURL.path,
                language: "swift",
                cursorLine: 1,
                cursorColumn: 5,
                nearbyLineRange: 1...1,
                nearbySnippet: "let value = 42",
                isDirty: false,
                observedAt: observedAt
            ),
            selectedRange: SelectedRangeContext(
                path: fileURL.path,
                startLine: 1,
                startColumn: 1,
                endLine: 1,
                endColumn: 4,
                selectedText: "let",
                isTruncated: false,
                observedAt: observedAt
            ),
            openFiles: OpenFilesContext(
                files: [OpenFileContext(path: fileURL.path, language: "swift", isDirty: false, lastFocusedAt: observedAt)],
                observedAt: observedAt
            ),
            recentEdits: [],
            diagnostics: .empty,
            gitContext: nil,
            conflict: nil
        )

        let client = AgenticClient(
            apiKey: nil,
            projectRoot: workspaceURL,
            openAIKey: nil,
            runtimePolicy: CommandRuntimePolicy(accessScope: .workspaceOnly, approvalMode: .neverAsk),
            allowMachineWideAccess: false,
            ambientContextSnapshot: ambient
        )

        let readOutcome = await client.executeTool(name: "file_read", input: [:])
        XCTAssertFalse(readOutcome.isError)
        XCTAssertTrue((readOutcome.toolResultPayload as? String)?.contains("let value = 42") == true)

        let patchOutcome = await client.executeTool(name: "file_patch", input: [
            "old_string": "42",
            "new_string": "43"
        ])
        XCTAssertTrue(patchOutcome.isError)
        XCTAssertTrue(patchOutcome.displayText.contains("cannot infer a mutation target"))
    }

    func testPromptInjectionIncludesContextIDAndSelectionFreshness() {
        let observedAt = Date(timeIntervalSinceReferenceDate: 600)
        let contextID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let ambient = AmbientEditorContext(
            contextID: contextID,
            capturedAt: observedAt,
            lastUpdatedAt: observedAt,
            influenceLevel: .minimal,
            selectionFreshnessMs: 1_200,
            currentFile: CurrentFileContext(
                path: "/tmp/Focus.swift",
                language: "swift",
                cursorLine: 7,
                cursorColumn: 3,
                nearbyLineRange: nil,
                nearbySnippet: nil,
                isDirty: false,
                observedAt: observedAt
            ),
            selectedRange: nil,
            openFiles: .empty,
            recentEdits: [],
            diagnostics: .empty,
            gitContext: nil,
            conflict: nil
        )

        let block = ambient.promptInjectionBlock(workspaceRoot: "/tmp")
        XCTAssertTrue(block?.contains("context_id: 12345678-1234-1234-1234-1234567890AB") == true)
        XCTAssertTrue(block?.contains("selection_freshness_ms: 1200") == true)
    }

    func testHistoricalSummaryIncludesAmbientContextMetadata() throws {
        let traceID = UUID()
        let startedAt = Date(timeIntervalSinceReferenceDate: 700)
        let contextID = "12345678-1234-1234-1234-1234567890AB"
        let attributes = try JSONEncoder().encode([
            "ambient.context_id": contextID,
            "ambient.selection_freshness_ms": "1200",
            "ambient.current_file": "/tmp/Focus.swift"
        ])

        let sessionSpan = PersistedSpan(
            id: UUID(),
            traceID: traceID,
            kind: "session",
            name: "agentic_loop",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(2),
            statusText: "ok",
            isError: false,
            attributesJSON: attributes
        )
        let toolSpan = PersistedSpan(
            id: UUID(),
            parentID: sessionSpan.id,
            traceID: traceID,
            kind: "toolExecution",
            name: "file_read",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(0.25),
            statusText: "ok",
            isError: false
        )

        let model = SessionInspectorModel()
        model.loadHistorical(traceID: traceID, persistedSpans: [toolSpan, sessionSpan])

        XCTAssertEqual(model.summary?.ambientContextID, contextID)
        XCTAssertEqual(model.summary?.ambientSelectionFreshnessMs, 1200)
        XCTAssertEqual(model.summary?.ambientCurrentFile, "/tmp/Focus.swift")
        XCTAssertEqual(model.summary?.spanCount, 1)
        XCTAssertEqual(model.summary?.toolExecutionCount, 1)
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
