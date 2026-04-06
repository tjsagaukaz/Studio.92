# Studio.92 CommandCenter — Architectural Audit

**Last updated:** April 7, 2026 | **Grade: B+** | **Audited:** 109 Swift files, ~58K LOC total

---

## 1. Executive Summary

**Codebase:** 76 Swift files in CommandCenter (~48K LOC), 24 in SPM framework (~7K LOC),
9 test files (~3.3K LOC across CC integration tests and SPM unit tests).

**Overall: B+** (up from B− on April 5). The architecture was always sound — actors for
concurrency, `@Observable` for state, structured streaming, layered tool execution. What's
changed is execution quality. The God Object view was split into coordinators.
AgenticBridge was decomposed from 3,500 to 545 LOC. Process timeouts were added everywhere.
A context-aware model routing system with capability matching replaced keyword classification.
Integration test infrastructure was built from scratch (37 CC tests, 150 SPM tests). The
codebase was reorganized from 76 flat files into 10 domain-based folders. An AI context
layer (ARCHITECTURE.md, rules.md, routing.md, patterns.md) now makes the system
self-describing.

**Ship-blocking:** 1 (was 4, 3 fixed)
**High-risk:** 4 (was 9, 5 fixed or mitigated)
**Medium-risk:** 12 (was 14, 2 fixed)
**Trending:** solidly maintainable

---

## 2. What Changed (April 5 → April 7)

### Critical Fixes
| Issue | Before | After |
|-------|--------|-------|
| C1. CommandCenterView God Object | 1,200 LOC, 25+ @State | 794 LOC, extracted WorkspaceCoordinator (166 LOC) + ThreadCoordinator (380 LOC) |
| C2. AgenticBridge Mega Actor | 3,500 LOC, untestable | 545 LOC — AnthropicExecutionLoop, OpenAIExecutionLoop, stream handlers extracted |
| C4. Missing process timeouts | None on any external call | Git 30s, Simulator 60s, Fastlane 600s — terminate→grace→SIGKILL |

### Structural Improvements
| What | Impact |
|------|--------|
| Folder reorganization | 76 flat files → 10 domain folders (App, Bridge, Diagnostics, Execution, Persistence, Routing, Studio, Tools, UI, Workspace) |
| File rename pass | 9 files renamed for clarity (ToolDispatch, PipelineStepRouter, ConversationStore, etc.) |
| Phase 1: RoutingContext | 7-level priority cascade for model selection |
| Phase 2: Adaptive Plan Execution | DAG-based task planning with anti-oscillation guards |
| Phase 3: Cost-Aware Routing | TaskCapability matching, ModelCostProfile, per-step model selection |
| Integration tests | MockSSEServer (URLProtocol), 37 CC tests (streaming, routing, recovery, tracing) |
| CI/CD | GitHub Actions: SPM build+test → Xcode build, SwiftLint, caching |
| AI context layer | ARCHITECTURE.md, .studio92/rules.md, routing.md, patterns.md |

---

## 3. Remaining Issues

### Ship-Blocking (1)

**C3. SPM/CC Source-of-Truth Split** — CommandCenter does not import AgentCouncil. Shadow
copies of ToolError (missing tracer), ToolGuardrails (100% duplication), HandoffExecutor
(different arch), AgentTrace (CC extends SpanKind). RecoveryExecutor in CC has no tracer.
Fix: import AgentCouncil as local package dependency.

### High-Risk (4)

| # | Issue | File | Status |
|---|-------|------|--------|
| H1 | Infinite retry in JobFoundation.persist() | `Workspace/JobFoundation.swift` ~L530 | Open — add 60s cumulative timeout |
| H2 | Unbounded memory (5 remaining) | Multiple | Partial — GitFoundation ✅ capped, TraceCollector ✅ fixed. Remaining: SessionInspectorModel spans, LatencyDiagnostics arrays, AgentTrace active spans |
| H5 | ScrollView reader race | `UI/Chat/ChatThreadComponents.swift` | Open — multiple rapid onChange cascades |
| H6 | O(n²) streaming reveal | `UI/Chat/ChatThreadComponents.swift` | Open — per-character async tasks |

### Resolved High-Risk
- ~~H3. Main thread blocking~~ ✅ SimulatorPreviewService uses Task.detached
- ~~H4. Debounce task leaks~~ ✅ ExecutionPaneView cancels tasks in onDisappear
- ~~H7. No plan cycle detection~~ ✅ Deadlock detection in executor loop, adaptation cap (3)
- ~~H8. CompactionCoordinator deadlock~~ ✅ Watchdog added
- ~~H9. Unbounded retry backoff~~ ✅ ±25% jitter + 12s cap confirmed

### Medium-Risk (12)

| # | Issue | File | Impact |
|---|-------|------|--------|
| M1 | Fragile tool classification via string.contains() | `Execution/Pipeline/StreamPipeline.swift` | Wrong tool type → wrong streaming phase |
| M2 | Case-sensitive plan detection | `Execution/Pipeline/StreamPipeline.swift` | LLM output variance breaks parsing |
| M3 | Filesystem walk (6 levels) per CodeBlockCard | `UI/Components/MarkdownRendering.swift` | Perf drag on chat with many code blocks |
| M4 | Sentence splitting breaks on abbreviations | `UI/Components/NarrativeRenderer.swift` | "Dr. Smith" split into two sentences |
| M5 | ToolParallelism whitelist excludes web_fetch | `Tools/ToolParallelism.swift` | Legitimate parallel reads run sequentially |
| M6 | Sandbox check sometimes AFTER file op | `Tools/ToolGuardrails.swift` | Security gap: write-then-check |
| M8 | Latency reports to hardcoded /tmp | `Diagnostics/LatencyDiagnostics.swift` | Accumulates files forever |
| M9 | CoreSceneController array mutation during render | `App/CoreSceneController.swift` | SceneKit threading crash risk |
| M10 | ViewportStreamModel ignores illegal transitions | `UI/Layout/ViewportStreamModel.swift` | Caller unaware request rejected |
| M11 | AGENTSParser silently degrades | `Routing/AGENTSParser.swift` | Config issues invisible |
| M12 | ClaudeAPIClient no error classification | `Sources/AgentCouncil/API/` | Can't distinguish rate-limit vs auth |
| M14 | Thread persistence optional, no rollback | `Persistence/ThreadCoordinator.swift` | Inconsistent state on failure |

### Resolved Medium-Risk
- ~~M7. ArchitectureValidator violations memory-only~~ ✅ Persisted to JSON in Application Support
- ~~M13. ExecutorAgent no cancellation~~ ✅ TaskPlanExecutor has Task.isCancelled + deadlock detection

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
└── IntegrationTests/       37 tests
    ├── PipelineIntegrationTests  SSE, routing, recovery, tracing
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
| **CC: CapabilityRoutingTests** | 12 | Capability matching, routing decisions, cost profiles, DAG step routing |
| **CC: RecoveryContractTests** | 4 | Retry success, circuit breaker, sandbox violations, transient failures |
| **CC: TraceLogContractTests** | 5 | Span lifecycle, parent-child, structured fields, error recording, summaries |
| **SPM: AgentCouncilTests** | ~60 | Guardrails (15), Recovery (31), Tracing, Handoffs |
| **SPM: ExecutorTests** | ~30 | Build repair execution |
| **SPM: BuildDiagnosticsTests** | ~30 | Xcode output parsing |
| **SPM: MultimodalEngineTests** | ~30 | Vision payloads, presets, bounding boxes |
| **Total** | **187** | |

---

## 7. Prioritized Remaining Work

### Tier 1: Next Sprint
1. **Resolve SPM/CC split** — import AgentCouncil as local package dependency, delete shadow copies
2. **Fix JobFoundation infinite retry** — add 60s cumulative timeout
3. **Bound remaining memory** — cap SessionInspectorModel spans at 5K, circular buffer LatencyDiagnostics

### Tier 2: Following Sprint
4. **Fix O(n²) StreamingMarkdownRevealView** — batch 10 chars at a time
5. **Debounce ChatThread scroll** — prevent rapid onChange cascades
6. **Add tracers** to CC RecoveryExecutor and ExecutorAgent

### Tier 3: Ongoing
7. Replace string.contains() tool classification with enums
8. Add depth limits to parsers and span trees
9. Fix sandbox check ordering (M6 — check before write, not after)
10. Handle ViewportStreamModel illegal transitions (M10 — log or throw)

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
