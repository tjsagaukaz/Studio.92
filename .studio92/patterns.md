# Studio.92 Patterns

Recurring implementation patterns used throughout the codebase. When adding new code,
follow these patterns for consistency.

## Actor for Shared Mutable State

When multiple concurrent contexts need to read/write the same state, use a Swift actor.

```swift
actor TraceCollector {
    private var spans: [Span] = []
    private var activeSpans: [String: UUID] = [:]

    func beginSpan(_ kind: SpanKind, ...) -> UUID { ... }
    func endSpan(_ id: UUID, status: SpanStatus) { ... }
}
```

Used by: `AgenticBridge`, `TraceCollector`, `LatencyDiagnostics`, `RecoveryExecutor`,
`CircuitBreaker`.

Do not use `@MainActor` for non-UI state. Do not add `nonisolated` to methods that
touch mutable properties.

## @Observable for UI State

View models that drive SwiftUI use `@MainActor @Observable`:

```swift
@MainActor @Observable
final class ConversationStore {
    var turns: [ConversationTurn] = []
    var isStreaming = false
    // ...
}
```

Used by: `ConversationStore`, `StreamPhaseController`, `ViewportStreamModel`,
`RepositoryMonitor`, `JobMonitor`.

SwiftUI observation requires MainActor. These classes must stay `@MainActor`.

## Coordinator Extraction

When a view accumulates business logic (>400 LOC of non-layout code), extract a
coordinator:

```swift
@MainActor @Observable
final class WorkspaceCoordinator {
    func submitGoal(_ goal: String) async { ... }
    func selectProject(_ project: Project) { ... }
}
```

The view becomes a thin layout shell that delegates via `onChange` and method calls.
The coordinator owns the logic, the view owns the layout.

Extracted so far: `WorkspaceCoordinator` (166 LOC), `ThreadCoordinator` (380 LOC).

## Pipeline FSM

Execution pipelines use finite state machines with explicit phase transitions:

```swift
enum StreamPhase: Sendable {
    case idle
    case connecting
    case streaming
    case toolExecution(toolName: String)
    case compacting
    case complete
    case error(String)
}
```

Transitions are validated — `ViewportStreamModel` should reject illegal transitions
(M10 finding: currently silently ignores them).

## Error Taxonomy → Recovery Strategy

Errors are classified into a typed enum, then a pure function resolves the recovery
strategy:

```swift
enum ToolError: Error, Sendable {
    case sandboxViolation(path: String)
    case permissionBlocked(tool: String, mode: String)
    case timeout(tool: String, seconds: Int)
    case executionFailed(tool: String, exitCode: Int, stderr: String)
    // ...
}

func recoveryStrategy(for error: ToolError) -> RecoveryStrategy {
    switch error {
    case .sandboxViolation: return .failFast
    case .timeout:          return .retryWithBackoff(maxAttempts: 2)
    // ...
    }
}
```

No per-tool retry configuration. No magic numbers scattered across call sites.
The taxonomy is the configuration.

## Read/Write Partitioning for Parallel Execution

When executing a batch of operations, partition into parallel-safe and sequential:

```swift
let (parallel, sequential) = ToolParallelism.partition(
    toolCalls,
    name: { $0.name },
    inputJSON: { $0.input }
)

// Parallel reads with bounded concurrency
await withTaskGroup(of: Result.self) { group in
    for (index, call) in parallel {
        group.addTask { await execute(call) }
    }
}

// Sequential writes
for (index, call) in sequential {
    await execute(call)
}
```

Write-conflict detection: if a read targets the same path as a pending write in the
sequential batch, it's demoted to sequential.

## Typed Handoffs

Delegation to subagents uses typed context and results, not string passing:

```swift
let context = HandoffContext(
    role: .explorer,
    goal: "Find all usages of ToolError",
    packageRoot: packageRoot,
    guardrails: SubagentGuardrails(sandbox: sandbox, permissions: reviewPolicy)
)

let result = try await handoffExecutor.execute(context)

switch result.outcome {
case .completed(let summary): // ...
case .escalated(let reason):  // ...
case .failed(let error):      // ...
}
```

Guardrails are inherited from the parent. Subagents cannot escalate their own
permissions.

## SSE Streaming (Delimiter-Driven)

The SSE parser processes bytes incrementally without assuming chunk alignment:

```
Bytes → UTF8StreamDecoder → consumeDecoded() → consumeLine()
    → emitParsedEventIfNeeded() on empty line (\n\n)
```

Key properties:
- All buffers persist across `urlSession(_:dataTask:didReceive:)` calls via closure capture
- Parser state is never reset between chunks
- The `\n\n` delimiter is the only event boundary — not content-length, not chunk size
- Tested with: normal delivery, chunked SSE, split-boundary, byte-at-a-time, mid-stream drop

## Process Execution with Timeout

All external process calls follow the same pattern:

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
process.arguments = [...]

try process.run()

// Timeout with graceful degradation
let deadline = DispatchTime.now() + .seconds(30)
DispatchQueue.global().asyncAfter(deadline: deadline) {
    if process.isRunning {
        process.terminate()
        // Grace period, then SIGKILL
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5)) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

process.waitUntilExit()
```

Timeouts: Git 30s, Simulator 60s, Fastlane 600s.

## Configuration from ship.toml

Runtime configuration reads from `.studio92/ship.toml`, not hardcoded values:

```swift
static func shipMaxParallelTools(packageRoot: String?) -> Int {
    // Read [execution] max_parallel_tools from ship.toml
    // Fall back to default (6) if not found
}
```

Used for: model IDs, parallel tool ceiling, signing config, shipping requirements,
verification commands.

## SwiftData for Queryable Storage

Structured data that needs querying or pagination uses SwiftData:

```swift
@Model
final class PersistedSpan {
    var spanID: UUID
    var kind: String
    var status: String
    var startTime: Date
    var endTime: Date?
    var attributes: [String: String]
}

@ModelActor
actor TracePersister {
    func persist(_ span: Span) throws { ... }
}
```

`@ModelActor` for background writes. `@Model` types in `PersistenceModels.swift`.
No ndjson files for structured data — SwiftData provides queryability and migration.

## Design Token Application

UI styling uses Studio tokens, never inline values:

```swift
Text("Build succeeded")
    .font(StudioTypography.body)
    .foregroundStyle(StudioColorTokens.primary)

RoundedRectangle(cornerRadius: StudioPolish.cornerRadius.medium)
    .fill(StudioColorTokens.surface)

withAnimation(StudioMotion.standard) {
    // state change
}
```

No inline hex colors. No magic font sizes. No hardcoded animation durations.

## Integration Testing with MockSSEServer

Integration tests use `URLProtocol` interception, not real network calls:

```swift
final class MockSSEProtocol: URLProtocol {
    static var responseQueue: [MockResponse] = []

    override func startLoading() {
        let response = Self.responseQueue.removeFirst()
        // Deliver headers, then body data
        client?.urlProtocol(self, didReceive: httpResponse, ...)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
```

Response types: `.sseEvents`, `.chunkedSSE`, `.byteAtATime`, `.error`.
Request body is captured for assertion via `MockSSEProtocol.lastRequestBody`.
