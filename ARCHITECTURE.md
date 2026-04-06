# Studio.92 Architecture

Studio.92 is an AI-powered Apple app builder. It plans, executes, verifies, and ships
native SwiftUI apps through a multi-model agentic pipeline — from a single goal to a
TestFlight-ready binary.

## System Layers

```
┌─────────────────────────────────────────────────────────────────┐
│  User Layer                                                     │
│  CommandCenterView → WorkspaceShellView → Panes / Sidebar       │
├─────────────────────────────────────────────────────────────────┤
│  Conversation Layer                                             │
│  ConversationStore → ChatThread → Turns → Tool Results          │
│  ThreadCoordinator · ThreadPersistenceCoordinator · SwiftData   │
├─────────────────────────────────────────────────────────────────┤
│  Routing Layer                                                  │
│  ModelRouting (RoutingContext → RoutingDecision)                 │
│  TaskPlanEngine (DAG: discovery → analysis → impl → verify)     │
│  AGENTSParser · ToolSchemas · Capability Matching               │
├─────────────────────────────────────────────────────────────────┤
│  Execution Layer                                                │
│  PipelineRunner ─→ StreamPipeline ─→ Execution Loops            │
│  AnthropicExecutionLoop · OpenAIExecutionLoop                   │
│  LiveStateEngine · CompactionCoordinator · HandoffExecutor      │
├─────────────────────────────────────────────────────────────────┤
│  Streaming Layer                                                │
│  AnthropicStreamHandler (SSE → byte → UTF8 → events)            │
│  OpenAIStreamHandler                                            │
│  StreamingTextBuffer · StreamRendering                          │
├─────────────────────────────────────────────────────────────────┤
│  Tool Layer                                                     │
│  ToolDispatch → per-tool execution                              │
│  ToolGuardrails (SandboxPolicy · ToolPermissionPolicy)          │
│  ToolParallelism (read/write partitioning, TaskGroup ceiling)   │
│  StatefulTerminalEngine · TerminalCoordinator                    │
├─────────────────────────────────────────────────────────────────┤
│  Bridge Layer                                                   │
│  AgenticBridge (provider adapter — Anthropic + OpenAI)          │
│  AgenticBridgeTypes · MultimodalEngine                          │
├─────────────────────────────────────────────────────────────────┤
│  Diagnostics Layer                                              │
│  TraceStore (Span → PersistedSpan via SwiftData)                │
│  TelemetryIngestor · LatencyDiagnostics                         │
│  ArchitectureValidator · BuildDiagnostics · MemoryHardening     │
├─────────────────────────────────────────────────────────────────┤
│  Workspace Layer                                                │
│  GitFoundation · RepositoryMonitor · WorkspaceCoordinator       │
│  JobFoundation · DeploymentCoordinator · FactoryObserver        │
│  SessionTemplateEngine · SimulatorPreviewService                │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow

```
User Goal
  │
  ▼
WorkspaceCoordinator.submitGoal()
  │
  ▼
RoutingContext (failures, turns, attachments, contextPressure, DAG phase)
  │
  ▼
ModelRouting.routingDecision(context:)
  │  Priority cascade:
  │  1. explicit_escalation
  │  2. review_escalation
  │  3. failure_escalation (≥2 failures → Opus)
  │  4. capability_match (TaskCapability → ModelCostProfile)
  │  5. review_intent
  │  6. dag_verification (verification phase → review model)
  │  7. complexity_escalation
  │  8. default (fallback)
  │
  ▼
PipelineRunner.run()
  │
  ├─ Simple goal ──────────────────────────────────────┐
  │                                                     │
  ├─ Complex goal → TaskPlanEngine                      │
  │   │  generates DAG: [TaskStep]                      │
  │   │  phases: discovery → analysis → implementation  │
  │   │          → verification (→ repair if needed)    │
  │   │                                                 │
  │   ▼                                                 │
  │  TaskPlanExecutor                                   │
  │   │  per-step: capability routing, model selection  │
  │   │  adaptation: PlanAdaptationPolicy (3 rules)     │
  │   │  anti-oscillation guard (max 3 adaptations)     │
  │   │                                                 ▼
  │   └──────────────────────────────────────▶ Execution Loop
  │                                            │
  ▼                                            │
StreamPipeline                                 │
  │                                            │
  ▼                                            │
ExecutionLoopEngine ◄──────────────────────────┘
  │
  ├─ Anthropic path → AnthropicExecutionLoop
  │   └─ AnthropicStreamHandler (SSE, delimiter-driven)
  │
  └─ OpenAI path → OpenAIExecutionLoop
      └─ OpenAIStreamHandler
  │
  ▼
Tool Calls (if any)
  │
  ├─ ToolGuardrails.check()          — sandbox + permission gate
  ├─ ToolParallelism.partition()     — reads ∥, writes sequential
  └─ ToolDispatch.execute()           — per-tool handler
      │
      ├─ file_read, file_write, file_patch
      ├─ terminal → StatefulTerminalEngine
      ├─ web_search, web_fetch
      ├─ delegate_to_explorer / delegate_to_reviewer → HandoffExecutor
      └─ deploy_to_testflight → DeploymentCoordinator
  │
  ▼
Tool Results → back to Execution Loop (iterate until done)
  │
  ▼
ConversationStore ← streaming text + tool results
  │
  ▼
UI renders (ChatThreadComponents, ExecutionPaneView, etc.)
```

## Key Components

### Routing (`CommandCenter/Routing/`)
- **ModelRouting.swift** — Provider enums (`StudioModelProvider`, `StudioModelDescriptor`),
  `StudioModelStrategy` (reads `ship.toml`), `RoutingContext`, `RoutingDecision`,
  `TaskCapability` enum (7 cases), `ModelCostProfile` with capability matching.
- **TaskPlanEngine.swift** — Invisible hybrid DAG for complex multi-step tasks.
  `TaskPlan`, `TaskStep`, `TaskPhase`, `TaskPlanGenerator` (heuristic complexity detection),
  `TaskPlanExecutor` (sequential execution with adaptation).
- **AGENTSParser.swift** — Parses `AGENTS.md` for model role and operating rule extraction.
- **ToolSchemas.swift** — JSON schema definitions for all tool types.

### Execution (`CommandCenter/Execution/`)
- **PipelineRunner.swift** — Orchestrates the full execution cycle. Constructs
  `RoutingContext`, manages conversation history, coordinates streaming and tool execution.
- **ExecutionLoopEngine.swift** — Provider-agnostic loop: stream → collect tool calls →
  execute tools → feed results back → repeat.
- **AnthropicExecutionLoop / OpenAIExecutionLoop** — Provider-specific adapters.
- **CompactionCoordinator.swift** — Context window management. Summarizes older turns
  when token pressure exceeds threshold. Deadlock watchdog (Tier 1 fix).
- **HandoffExecutor.swift** — Typed delegation to subagents (explorer, reviewer).
  `HandoffContext` → `HandoffResult` with `FileTracker` for read-path collection.
- **LiveStateEngine.swift** — Real-time execution state broadcasting.

### Streaming (`CommandCenter/Execution/Streaming/`)
- **AnthropicStreamHandler.swift** — SSE parser. Byte → UTF8StreamDecoder →
  consumeDecoded → consumeLine → emitParsedEventIfNeeded on `\n\n` delimiter.
  All buffers persist across deliveries via closure capture. Delimiter-driven, not
  length-prefixed.
- **OpenAIStreamHandler.swift** — JSON-lines streaming for OpenAI responses.

### Tools (`CommandCenter/Tools/`)
- **ToolGuardrails.swift** — `SandboxPolicy` (symlink-resolved path checks),
  `ToolPermissionPolicy` (per-autonomy-mode blocking). Symlink escape vulnerability
  fixed via `resolvingSymlinksInPath()`.
- **ToolParallelism.swift** — Classifies tools as parallel-safe (reads) or sequential
  (writes, terminal, deploy). Write-conflict detection demotes reads targeting pending
  write paths. Bounded concurrency via `max_parallel_tools` from `ship.toml`.
- **StatefulTerminalEngine.swift** — Persistent terminal sessions with environment
  and working directory tracking across tool calls.

### Persistence (`CommandCenter/Persistence/`)
- **ConversationStore.swift** — `ConversationStore` (@Observable), turn models,
  message types. The in-memory conversation state.
- **ThreadStorageModels.swift** — SwiftData `@Model` types for threads and messages.
- **ThreadCoordinator.swift** — Thread lifecycle management (380 LOC, extracted from
  CommandCenterView).
- **ThreadPersistenceCoordinator.swift** — SwiftData read/write coordination.
- **ThreadTitleGenerator.swift** — LLM-powered thread title generation.

### Diagnostics (`CommandCenter/Diagnostics/`)
- **TraceStore.swift** — `PersistedSpan` (@Model) + `TracePersister` (@ModelActor).
  SwiftData-backed queryable trace storage.
- **TelemetryIngestor.swift** — Aggregates telemetry from execution runs.
- **ArchitectureValidator.swift** — Runtime invariant checking. Violations persisted
  to JSON in Application Support.
- **BuildDiagnostics.swift** — Xcode build output parsing and error extraction.
- **LatencyDiagnostics.swift** — Actor-isolated latency measurement and reporting.
- **MemoryHardening.swift** — Memory pressure detection and mitigation.

### Bridge (`CommandCenter/Bridge/`)
- **AgenticBridge.swift** — The provider adapter actor. Anthropic + OpenAI API clients,
  request construction, response handling. Currently ~495 LOC (down from 3500 after
  execution loop extraction).
- **AgenticBridgeTypes.swift** — Shared types for bridge communication.
- **MultimodalEngine.swift** — Image/vision payload construction, multimodal presets,
  bounding box normalization.

### Error Recovery (SPM: `Sources/AgentCouncil/Recovery/`)
- **ToolError.swift** — Error taxonomy (`ToolError` enum), `RecoveryStrategy` resolver,
  `CircuitBreaker` (5 failures / 30s → open → 60s cooldown → half-open),
  `RecoveryExecutor` actor with retry + backoff + jitter.
- Strategy matrix: sandboxViolation→failFast, timeout→retry(2), execution(OOM)→retry(1),
  permissionBlocked→escalateToUser.

## Concurrency Model

| Pattern | Used By | Notes |
|---------|---------|-------|
| `actor` | AgenticBridge, TraceCollector, LatencyDiagnostics, RecoveryExecutor | Thread-safe mutable state |
| `@MainActor @Observable` | ConversationStore, StreamPhaseController, ViewportStreamModel, RepositoryMonitor, JobMonitor | UI-bound reactive state |
| `@ModelActor` | TracePersister | Background SwiftData writes |
| `Task.detached` | SimulatorPreviewService, process execution | Off-main-thread blocking work |
| `withTaskGroup` | Tool parallel execution | Bounded concurrency with ceiling |
| `AsyncStream` / `AsyncBytes` | SSE streaming, event pipelines | Structured async data flow |

## SPM Package Structure (`Sources/`)

```
Sources/
├── AgentCouncil/          — Shared framework (public types)
│   ├── Tracing/           — Span, SpanKind, TraceCollector, TraceSummary
│   ├── Guardrails/        — ToolGuardrails (canonical), SandboxPolicy
│   ├── Handoffs/          — HandoffTypes, HandoffExecutor (SPM version)
│   ├── Recovery/          — ToolError, RecoveryStrategy, CircuitBreaker
│   └── Orchestrator/      — ToolExecutor, AgenticOrchestrator, SubAgentManager
├── AgentCouncilCLI/       — Standalone CLI for council operations
├── Executor/              — GPT-5.4 build repair execution engine
└── ExecutorCLI/           — Standalone CLI for executor operations
```

**SPM/CC relationship:** CommandCenter does NOT import AgentCouncil as a dependency.
Some types exist as shadow copies in both. This is the #1 structural debt — types will
drift. Planned fix: import AgentCouncil as a local package dependency.

## Test Infrastructure

- **CC Tests (37):** Xcode target `CommandCenterTests` in `CommandCenter/IntegrationTests/`
  - `PipelineIntegrationTests` (16) — SSE streaming, chunked delivery, tool calls, cancellation
  - `CapabilityRoutingTests` (12) — Capability matching, routing decisions, cost profiles
  - `RecoveryContractTests` (4) — Retry, circuit breaker, sandbox violations
  - `TraceLogContractTests` (5) — Span lifecycle, parent-child, structured fields
  - `MockSSEServer` — URLProtocol-based mock with chunked, byte-at-a-time, split-boundary modes
- **SPM Tests (150):** 4 targets in `Tests/`
  - `AgentCouncilTests` — Guardrails (15), Recovery (31), Tracing, Handoffs
  - `ExecutorTests` — Build repair execution
  - `BuildDiagnosticsTests` — Xcode output parsing
  - `MultimodalEngineTests` — Vision payloads, presets, bounding boxes

## Configuration

All runtime configuration flows through `.studio92/ship.toml`:
- `[models]` — Model role assignments (review, full_send, subagent, escalation, explorer)
- `[execution]` — `max_parallel_tools = 6`
- `[shipping]` — Bundle ID, TestFlight, privacy manifest, entitlements requirements
- `[signing]` — Team ID, automatic signing toggle
- `[research]` — Apple docs priority, live web requirements
- `[verification]` — Build + test commands

Read at runtime by `StudioModelStrategy` methods. No hardcoded model IDs in application code.

## Design System

Tokens defined in `CommandCenter/Studio/`:
- `StudioColorTokens` — accent color `#1CD1FF`, semantic palette
- `StudioTypography` — Geist font family (Light, Regular, Medium), size scale
- `StudioMotion` — Animation curves and durations
- `StudioPolish` — Corner radii, shadows, blur values
- `StudioFeedback` — Haptic and visual feedback patterns
