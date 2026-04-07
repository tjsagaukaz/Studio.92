# Studio.92 CommandCenter — Architectural Audit

**Last updated:** April 7, 2026 | **Grade: A−** | **Audited:** 109 Swift files, ~58K LOC total

---

## 1. Executive Summary

**Codebase:** 76 Swift files in CommandCenter (~48K LOC), 24 in SPM framework (~7K LOC),
10 test files (~4K LOC across CC integration tests and SPM unit tests).

**Overall: A−** (up from B+ on April 7 AM, B− on April 5). Every critical and high-risk
issue has been resolved or confirmed already fixed. The remaining open items are medium
and low priority — UI performance, string-based classification, and parser ergonomics.
The hardening pass added data race protection (CoreSceneController `NSLock`), SSE buffer
caps (Anthropic + OpenAI 2MB), command timeout watchdog (120s), stream pipeline memory
bounds (512KB), FSEvents retain balance, Keychain-only credentials, isStreaming decoupling,
and 19 new audit-focused tests.

**Ship-blocking:** 0 (was 1)
**High-risk:** 2 (was 4, H1/H2 already fixed, remainder are UI-only)
**Medium-risk:** 5 (was 12, 7 resolved)
**Trending:** ship-ready

---

## 2. What Changed (April 5 → April 7)

### Critical Fixes
| Issue | Before | After |
|-------|--------|-------|
| C1. CommandCenterView God Object | 1,200 LOC, 25+ @State | 794 LOC, extracted WorkspaceCoordinator (166 LOC) + ThreadCoordinator (380 LOC) |
| C2. AgenticBridge Mega Actor | 3,500 LOC, untestable | 545 LOC — AnthropicExecutionLoop, OpenAIExecutionLoop, stream handlers extracted |
| C4. Missing process timeouts | None on any external call | Git 30s, Simulator 60s, Fastlane 600s — terminate→grace→SIGKILL |

### Security & Reliability Hardening (April 7 PM)
| Issue | Severity | Fix |
|-------|----------|-----|
| CoreSceneController data race | Critical | `RenderState` struct under `NSLock`, renderer snapshots → computes → writes back under lock |
| OpenAI SSE unbounded buffer | Critical | 2MB `maxBufferSize` cap on `eventData` + `lineBuffer` (matching Anthropic) |
| StatefulTerminalEngine no timeout | Critical | 120s watchdog: Ctrl-C → terminate → 2s → SIGKILL, exit 124 |
| StreamPipeline unbounded buffers | High | 512KB cap on `narrativeBuffer` + `thinkingBuffer` |
| Terminal stdout/stderr buffer OOM | High | 512KB `maxLineBufferSize`, drains partial-line on overflow |
| PathEventMonitor dangling pointer | High | `passRetained(self)` + balanced `release()` in `stop()` |
| Credentials.json plaintext | High | Keychain-only via `KeychainCredentialStore`, legacy migration + delete |
| JobFoundation infinite retry | High | Already fixed: `maxAttempts=3`, `cumulativeDeadlineSeconds=15` |
| isStreaming stuck after pipeline stops | High | `finalized()` cross-checks `isPipelineRunning`, auto-corrects to `.finalizing` |
| UTF-8 decoder unbounded buffer | Medium | 1MB drain cap in `AgenticBridge.UTF8StreamDecoder` |
| Anthropic parseSSE silent failures | Medium | Logs malformed JSON: type + first 200 chars |
| Unicode path normalization | Medium | `.precomposedStringWithCanonicalMapping` in `ToolGuardrails.resolvedURL` |
| CompactionCoordinator watchdog leak | Medium | `deinit { optimizingWatchdog?.cancel() }` |
| LatencyDiagnostics unbounded runs | Medium | Evicts oldest when `runOrder.count >= 10` |
| ViewportStreamModel silent rejections | Medium | Logs illegal phase transitions |
| ThreadPersistenceCoordinator no rollback | Medium | `try save()` + `rollback()` on failure |
| TraceStore observe() task leak | Low | Awaits old task before starting new stream |
| Empty SSE data payloads | Low | `guard !payload.isEmpty` before parse |
| content_block_delta empty strings | Low | Returns `nil` instead of `""` for missing keys |

### Structural Improvements
| What | Impact |
|------|--------|
| Folder reorganization | 76 flat files → 10 domain folders (App, Bridge, Diagnostics, Execution, Persistence, Routing, Studio, Tools, UI, Workspace) |
| File rename pass | 9 files renamed for clarity (ToolDispatch, PipelineStepRouter, ConversationStore, etc.) |
| Phase 1: RoutingContext | 7-level priority cascade for model selection |
| Phase 2: Adaptive Plan Execution | DAG-based task planning with anti-oscillation guards |
| Phase 3: Cost-Aware Routing | TaskCapability matching, ModelCostProfile, per-step model selection |
| Integration tests | MockSSEServer (URLProtocol), 56 CC tests (streaming, routing, recovery, tracing, audit fixes) |
| CI/CD | GitHub Actions: SPM build+test → Xcode build, SwiftLint, caching |
| AI context layer | ARCHITECTURE.md, .studio92/rules.md, routing.md, patterns.md |

---

## 3. Remaining Issues

### Ship-Blocking (0)

None. C3 (SPM/CC split) resolved — CommandCenter imports AgentCouncil as a local package.

### High-Risk (2)

| # | Issue | File | Status |
|---|-------|------|--------|
| H5 | ScrollView reader race | `UI/Chat/ChatThreadComponents.swift` | Open — multiple rapid onChange cascades |
| H6 | O(n²) streaming reveal | `UI/Chat/ChatThreadComponents.swift` | Open — per-character async tasks |

### Resolved Critical
- ~~C1. CommandCenterView God Object~~ ✅ Extracted WorkspaceCoordinator + ThreadCoordinator
- ~~C2. AgenticBridge Mega Actor~~ ✅ Decomposed to 545 LOC
- ~~C3. SPM/CC split~~ ✅ CC imports AgentCouncil as local package
- ~~C4. Missing process timeouts~~ ✅ Git 30s, Simulator 60s, Fastlane 600s
- ~~C5. CoreSceneController data race~~ ✅ `RenderState` + `NSLock`
- ~~C6. OpenAI SSE unbounded buffer~~ ✅ 2MB cap
- ~~C7. StatefulTerminalEngine no timeout~~ ✅ 120s watchdog

### Resolved High-Risk
- ~~H1. JobFoundation infinite retry~~ ✅ Already had maxAttempts=3 + 15s deadline
- ~~H2. Unbounded memory~~ ✅ All buffers capped (SSE 2MB, stream 512KB, terminal 512KB, latency 10 runs)
- ~~H3. Main thread blocking~~ ✅ SimulatorPreviewService uses Task.detached
- ~~H4. Debounce task leaks~~ ✅ ExecutionPaneView cancels tasks in onDisappear
- ~~H7. No plan cycle detection~~ ✅ Deadlock detection in executor loop, adaptation cap (3)
- ~~H8. CompactionCoordinator deadlock~~ ✅ Watchdog added, deinit cancels
- ~~H9. Unbounded retry backoff~~ ✅ ±25% jitter + 12s cap confirmed
- ~~H10. PathEventMonitor dangling pointer~~ ✅ passRetained + balanced release
- ~~H11. Credentials.json plaintext~~ ✅ Keychain-only
- ~~H12. isStreaming decoupling~~ ✅ finalized() cross-checks isPipelineRunning

### Medium-Risk (5)

| # | Issue | File | Impact |
|---|-------|------|--------|
| M1 | Fragile tool classification via string.contains() | `Execution/Pipeline/StreamPipeline.swift` | Wrong tool type → wrong streaming phase |
| M2 | Case-sensitive plan detection | `Execution/Pipeline/StreamPipeline.swift` | LLM output variance breaks parsing |
| M3 | Filesystem walk (6 levels) per CodeBlockCard | `UI/Components/MarkdownRendering.swift` | Perf drag on chat with many code blocks |
| M4 | Sentence splitting breaks on abbreviations | `UI/Components/NarrativeRenderer.swift` | "Dr. Smith" split into two sentences |
| M5 | ToolParallelism whitelist excludes web_fetch | `Tools/ToolParallelism.swift` | Legitimate parallel reads run sequentially |

### Resolved Medium-Risk
- ~~M6. Sandbox check ordering~~ ✅ (atomically:true + realpath covers TOCTOU)
- ~~M7. ArchitectureValidator violations memory-only~~ ✅ Persisted to JSON
- ~~M8. LatencyDiagnostics unbounded~~ ✅ Run eviction at 10
- ~~M9. CoreSceneController array mutation~~ ✅ NSLock-protected RenderState
- ~~M10. ViewportStreamModel silent rejections~~ ✅ Logs illegal transitions
- ~~M11. AGENTSParser silently degrades~~ ✅ (parser already logs warnings)
- ~~M13. ExecutorAgent no cancellation~~ ✅ Task.isCancelled + deadlock detection
- ~~M14. Thread persistence no rollback~~ ✅ try save() + rollback()

---

## 4. Current Architecture Map

```
CommandCenter/
├── App/                    Entry point + root view (794 LOC)
│   ├── CommandCenterApp        @main, Settings, SwiftData container
│   ├── CommandCenterView       Layout shell with coordinator delegates
│   └── CoreSceneController     SceneKit 3D visualization
│
├── Bridge/                 Provider adapters (545 LOC bridge)
│   ├── AgenticBridge           Actor — Anthropic + OpenAI API clients
│   ├── AgenticBridgeTypes      Shared bridge types
│   └── MultimodalEngine        Image/vision payload construction
│
├── Execution/              Agentic loop + streaming (13 files)
│   ├── CompactionCoordinator   Context window management (670 LOC)
│   ├── HandoffExecutor         Typed subagent delegation
│   ├── LiveStateEngine         Real-time execution state
│   ├── Loops/
│   │   ├── ExecutionLoopEngine     Provider-agnostic loop
│   │   ├── AnthropicExecutionLoop  Anthropic adapter
│   │   └── OpenAIExecutionLoop     OpenAI adapter
│   ├── Pipeline/
│   │   ├── PipelineRunner          Orchestrates full execution cycle
│   │   ├── PipelineStepRouter      DAG step routing + telemetry
│   │   ├── StreamPipeline          8-state FSM (1,606 LOC)
│   │   ├── StreamRendering         Phase-driven view switching
│   │   └── StreamingTextBuffer     Incremental text accumulation
│   └── Streaming/
│       ├── AnthropicStreamHandler  SSE → byte → UTF8 → events
│       └── OpenAIStreamHandler     JSON-lines streaming
│
├── Routing/                Model selection + planning (4 files)
│   ├── ModelRouting            RoutingContext, RoutingDecision, capabilities (880 LOC)
│   ├── TaskPlanEngine          DAG planner + executor (950 LOC)
│   ├── AGENTSParser            AGENTS.md model role extraction
│   └── ToolSchemas             JSON schema definitions
│
├── Tools/                  Tool execution layer (6 files)
│   ├── ToolDispatch            Per-tool routing
│   ├── ToolGuardrails          SandboxPolicy + ToolPermissionPolicy
│   ├── ToolParallelism         Read/write partitioning, TaskGroup
│   ├── ToolResultViews         UI for tool call results
│   ├── StatefulTerminalEngine  Persistent terminal sessions
│   └── TerminalCoordinator    Terminal lifecycle management
│
├── Persistence/            SwiftData + conversation state (5 files)
│   ├── ConversationStore       @Observable in-memory conversation
│   ├── ThreadStorageModels     SwiftData @Model types
│   ├── ThreadCoordinator       Thread lifecycle (380 LOC)
│   ├── ThreadPersistenceCoordinator  SwiftData read/write
│   └── ThreadTitleGenerator    LLM-powered title generation
│
├── Diagnostics/            Observability (6 files)
│   ├── TraceStore              PersistedSpan + TracePersister
│   ├── TelemetryIngestor       Event aggregation
│   ├── ArchitectureValidator   Runtime invariant checking
│   ├── BuildDiagnostics        Xcode output parsing
│   ├── LatencyDiagnostics      Timing instrumentation
│   └── MemoryHardening         Memory pressure detection
│
├── Studio/                 Design system (7 files)
│   ├── StudioColorTokens       Accent #1CD1FF, semantic palette
│   ├── StudioTypography        Geist font family
│   ├── StudioMotion            Animation curves
│   ├── StudioPolish            Radii, shadows, blur
│   ├── StudioFeedback          Haptic/visual feedback
│   ├── StudioInsightEngine     Insight aggregation
│   └── StudioAutomationEngine  Automation preferences
│
├── UI/                     Views (21 files)
│   ├── Chat/                   ConversationDetailViews, ChatThreadComponents, ComposerViews
│   ├── Components/             ArtifactViews, CodeDiffEngine, ChatContextHeader,
│   │                           LiveActivityViews, MarkdownRendering, NarrativeRenderer
│   ├── Inspector/              SessionInspectorModel, SessionInspectorView
│   └── Layout/                 Dashboard, ExecutionPane, ExecutionTree, FleetSidebar,
│                               ViewportPane, ViewportStreamModel, VolumetricCore,
│                               WorkspaceBackground, WorkspaceShell, WorktreeJobViews
│
├── Workspace/              Git, jobs, deployment (8 files)
│   ├── GitFoundation           Git actor (998 LOC)
│   ├── JobFoundation           Background jobs (839 LOC)
│   ├── WorkspaceCoordinator    Workspace state (166 LOC, extracted from view)
│   ├── RepositoryMonitor       @Observable git state
│   ├── DeploymentCoordinator   TestFlight/App Store flows
│   ├── FactoryObserver         Factory subprocess monitoring
│   ├── SessionTemplateEngine   Session template rendering
│   └── SimulatorPreviewService Device management
│
└── IntegrationTests/       56 tests
    ├── PipelineIntegrationTests  SSE, routing, recovery, tracing
    ├── AuditFixTests             UTF-8, buffers, credentials, streaming
    └── MockSSEServer             URLProtocol-based mock
```

---

## 5. State Model

| Layer | Owner | Pattern | Quality |
|-------|-------|---------|---------|
| App-wide workspace | WorkspaceCoordinator | @MainActor @Observable | ✅ Good (extracted) |
| Thread lifecycle | ThreadCoordinator | @MainActor @Observable | ✅ Good (extracted) |
| Conversation turns | ConversationStore | @MainActor @Observable | ✅ Good |
| Streaming phase | StreamPhaseController | @MainActor @Observable FSM | ✅ Good |
| Viewport content | ViewportStreamModel | @MainActor @Observable FSM | ✅ Good |
| Repository state | RepositoryMonitor | @MainActor @Observable | ✅ Good |
| Background jobs | JobMonitor | @MainActor @Observable | ✅ Good |
| Tracing | TraceCollector | Actor | ✅ Good |
| Latency | LatencyDiagnostics | Actor | ✅ Good |
| Recovery | RecoveryExecutor | Actor + CircuitBreaker | ✅ Good |
| Routing | ModelRouting | Pure functions + ship.toml | ✅ Good |

---

## 6. Test Coverage

| Target | Tests | Coverage Area |
|--------|-------|---------------|
| **CC: PipelineIntegrationTests** | 16 | SSE streaming (normal, chunked, split-boundary, byte-at-a-time, mid-stream drop), tool calls, cancellation, request validation, history |
| **CC: AuditFixTests** | 19 | UTF-8 pipe decoder (8), SSE buffer caps (3), stream pipeline caps (2), credential store (3), isStreaming decoupling (2), latency eviction (1) |
| **CC: CapabilityRoutingTests** | 12 | Capability matching, routing decisions, cost profiles, DAG step routing |
| **CC: RecoveryContractTests** | 4 | Retry success, circuit breaker, sandbox violations, transient failures |
| **CC: TraceLogContractTests** | 5 | Span lifecycle, parent-child, structured fields, error recording, summaries |
| **SPM: AgentCouncilTests** | ~60 | Guardrails (15), Recovery (31), Tracing, Handoffs |
| **SPM: ExecutorTests** | ~30 | Build repair execution |
| **SPM: BuildDiagnosticsTests** | ~30 | Xcode output parsing |
| **SPM: MultimodalEngineTests** | ~30 | Vision payloads, presets, bounding boxes |
| **Total** | **206** | |

---

## 7. Prioritized Remaining Work

### Tier 1: Next Sprint
1. **Fix O(n²) StreamingMarkdownRevealView** — batch 10 chars at a time
2. **Debounce ChatThread scroll** — prevent rapid onChange cascades

### Tier 2: Following Sprint
3. Replace string.contains() tool classification with enums (M1)
4. Case-insensitive plan detection (M2)
5. Reduce filesystem walks in CodeBlockCard (M3)

### Tier 3: Ongoing
6. Fix sentence splitting for abbreviations (M4)
7. Add web_fetch to ToolParallelism read whitelist (M5)
8. Add depth limits to parsers and span trees

---

## 8. What NOT to Change

1. Actor-based concurrency model (AgenticBridge, TraceCollector, LatencyDiagnostics, RecoveryExecutor)
2. @Observable for view models (ConversationStore, StreamPhaseController, ViewportStreamModel)
3. Streaming pipeline FSM — 8-phase StreamPhaseController is well-designed
4. SwiftData for persistence — @Model types are clean
5. Design token system (StudioColorTokens, StudioTypography, StudioMotion, StudioPolish)
6. HandoffTypes.swift — zero red flags, clean Sendable value types
7. ArchitectureValidator concept — runtime invariant checking
8. Domain-based folder structure (Execution/, Routing/, Tools/, UI/, etc.)
9. Dual CLI targets (AgentCouncilCLI, ExecutorCLI)
10. Integration test infrastructure (MockSSEServer, URLProtocol interception)
