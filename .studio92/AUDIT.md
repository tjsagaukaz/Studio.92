# Studio.92 CommandCenter — Comprehensive Architectural Audit
**Date:** April 5, 2026 | **Grade: B−** | **Files analyzed:** ~54 Swift, ~24K+ LOC (CC) + ~5K LOC (SPM)

---

## 1. Executive Summary

**Codebase size:** ~54 Swift files, ~24,000+ lines in CommandCenter, plus a parallel ~5,000-line SPM framework (`AgentCouncil` + `Executor`) that CommandCenter **does not import** — maintaining shadow copies instead.

**Overall assessment: B−.** The architecture has strong bones — actors for concurrency isolation, `@Observable` for state, a real streaming pipeline, structured tracing, and a layered tool execution model. These are the right choices. But execution quality is inconsistent. The codebase has been built at feature velocity, and it shows: God Object views with 25+ state properties, unbounded memory growth in 7+ subsystems, missing timeouts on every external process call, and a critical source-of-truth split between the SPM framework and CommandCenter's local copies.

**Ship-blocking issues:** 4  
**High-risk issues:** 9  
**Medium-risk issues:** 14  
**The codebase is trending toward** maintainable-but-fragile. It needs targeted structural work now — not a rewrite, but specific extractions — before the next feature layer makes the God Objects permanent.

---

## 2. Architecture Map

```
┌─────────────────────────────────────────────────────────────────┐
│                    CommandCenterApp.swift                        │
│                    (entry point, Settings)                       │
└──────────────────────────┬──────────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────────┐
│                CommandCenterView.swift (~1200 LOC)               │
│  ⚠️ GOD OBJECT: 25+ @State, 20+ callbacks, 6 responsibilities  │
│  Owns: project selection, thread persistence, conversation      │
│        management, workspace switching, goal submission          │
└─────┬──────────┬──────────┬──────────┬──────────┬───────────────┘
      │          │          │          │          │
┌─────▼────┐ ┌──▼───────┐ ┌▼────────┐ ┌▼───────┐ ┌▼──────────────┐
│FleetSidebar│ │Workspace │ │Execution│ │Viewport│ │SessionInspector│
│  (~900)    │ │ShellView │ │PaneView │ │PaneView│ │    View        │
│  18 props  │ │  (~60)   │ │ (~1400) │ │ (~650) │ │   (~700)       │
└────────────┘ └──────────┘ └────┬────┘ └────────┘ └────────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │ ChatThreadComponents    │
                    │      (~2100 LOC)        │
                    │ ConversationTurnRow,     │
                    │ StreamingMarkdownReveal, │
                    │ InlineToolTraceGroup     │
                    └─────────────────────────┘

┌─── STREAMING ENGINE ──────────────────────────────┐
│ StreamPipeline.swift (~1270)                       │
│   StreamPhaseController (8-state FSM)              │
│   SemanticEventTransformer                         │
│   NarrativeChunker (actor)                         │
│ StreamRendering.swift (~700)                       │
│   StreamPhaseRenderer (phase-driven view switch)   │
└──────────────┬────────────────────────────────────┘
               │
┌──────────────▼────────────────────────────────────┐
│ AgenticBridge.swift (~3500 LOC) ⚠️ MEGA ACTOR     │
│   AgenticClient (actor) — full agentic loop       │
│   Anthropic + OpenAI streaming                    │
│   Tool dispatch (9 tools inline)                  │
│   CodexTerminalCoordinator, FastlaneDeployment    │
└──────────────┬────────────────────────────────────┘
               │
┌──────────────▼─────────┐  ┌────────────────────────┐
│ Tool Layer             │  │ Recovery Layer          │
│ ToolParallelism (~80)  │  │ ToolError.swift (~180)  │
│ ToolGuardrails (~130)  │  │ RecoveryExecutor (actor)│
│ ToolCallComponents(800)│  │ ⚠️ No tracer (CC copy)  │
└────────────────────────┘  └────────────────────────┘

┌─── INFRASTRUCTURE ─────────────────────────────────┐
│ Models.swift (~2574) — SwiftData models, stores    │
│ GitFoundation.swift (~1000) — git actor            │
│ JobFoundation.swift (~700) — background jobs       │
│ CompactionCoordinator (~400) — context compression │
│ TaskPlanEngine (~600) — execution planning         │
│ HandoffExecutor (~200) — subagent delegation       │
│ SimulatorPreviewService (~900) — device management │
└────────────────────────────────────────────────────┘

┌─── OBSERVABILITY ──────────────────────────────────┐
│ AgentTrace.swift (~300) — spans, TraceCollector     │
│ TraceStore.swift (~250) — SwiftData persistence     │
│ ArchitectureValidator (~250) — runtime invariants   │
│ LatencyDiagnostics (~450) — timing instrumentation  │
│ TelemetryIngestor — event ingestion                 │
└────────────────────────────────────────────────────┘

┌─── SPM FRAMEWORK (NOT IMPORTED BY CC) ─────────────┐
│ Sources/AgentCouncil/ (~4000 LOC)                   │
│   API/, Orchestrator/, Guardrails/, Handoffs/,      │
│   Recovery/, Tracing/, Personas/, Manifest/          │
│ Sources/Executor/ (~900 LOC) — GPT-5.4 build repair │
│ ⚠️ SHADOW COPIES in CC: ToolError, ToolGuardrails,  │
│    HandoffExecutor, AgentTrace                       │
└────────────────────────────────────────────────────┘
```

---

## 3. Critical Issues (Ship-Blocking)

### C1. CommandCenterView is a God Object
**File:** `CommandCenter/CommandCenterView.swift`  
**Impact:** Every feature added increases coupling. Refactoring becomes exponentially harder.

~1,200 lines, 25+ `@State` properties, 20+ closures passed to children. Owns 6 distinct responsibilities: project selection, thread persistence, conversation management, workspace switching, goal submission, and epoch/session lifecycle. A single `selectWorkspace()` modifies 8 properties with no rollback. `submitGoal()` is async but clears input state synchronously (race condition if user types during submission).

**Fix:** Extract `WorkspaceCoordinator` (observable class) for workspace + project state, `ThreadCoordinator` for thread persistence/rehydration, and `ConversationCoordinator` for message submission. CommandCenterView becomes a <200-line layout shell.

### C2. AgenticBridge.swift is a 3,500-line Mega Actor
**File:** `CommandCenter/AgenticBridge.swift`  
**Impact:** Untestable, un-navigable, and un-auditable. Every tool, every API provider, every retry path lives in one actor.

Contains: Anthropic streaming, OpenAI streaming with model fallback cascade, SSE parsing, UTF-8 stream decoding, all 9 tool implementations inline, terminal recovery, vision payload encoding, Fastlane deployment, and researcher subprocess orchestration. No cancellation hook for in-flight HTTP streams. Retry has no jitter (thundering herd risk). Tool classification uses fragile `string.contains()`.

**Fix:** Split into `AnthropicStreamHandler`, `OpenAIStreamHandler`, `ToolDispatcher` (with per-tool handler protocol), and `StreamDecoder`. Keep `AgenticClient` as a thin router.

### C3. SPM/CC Source-of-Truth Split
**Files:** `CommandCenter/ToolError.swift`, `CommandCenter/ToolGuardrails.swift`, `CommandCenter/HandoffExecutor.swift`, `CommandCenter/AgentTrace.swift` (CC copies) vs. `Sources/AgentCouncil/` originals  
**Impact:** CC's `RecoveryExecutor` has **no tracer integration** — retries and escalations are invisible. Guardrails are 100% duplicated. Handoff prompts will drift.

CommandCenter does not import AgentCouncil. It maintains local copies of 4 critical files, with the CC versions degraded (missing tracer calls, different access levels). A comment in HandoffExecutor explicitly warns "prompts must be kept in sync."

**Fix:** Make CommandCenter import AgentCouncil as a local package dependency. Remove CC shadow copies. Extend `SpanKind` in CC for `.compaction` and `.architectureViolation` via extension.

### C4. ~~Missing Timeouts on All External Processes~~ ✅ FIXED (Sprint 1)
**Files:** `CommandCenter/GitFoundation.swift`, `CommandCenter/SimulatorPreviewService.swift`, `CommandCenter/AgenticBridge.swift`  
**Status:** Fixed. 30s timeout on git (runGit), 60s timeout on simulator (runCommand), 600s timeout on Fastlane runner. All use terminate → grace period → SIGKILL pattern. Also fixed: invalid top-level `cache_control` on Anthropic request body removed (2 locations).

---

## 4. High-Risk Issues

| # | Issue | File | Fix |
|---|-------|------|-----|
| H1 | Infinite retry loop | JobFoundation ~L530 | Add 60s cumulative timeout |
| H2 | Unbounded memory growth (7 subsystems) | Multiple | Size caps, circular buffers, pruning |
| H3 | Main thread blocking | SimulatorPreviewService.runCommand() | Move to Task.detached with timeout |
| H4 | Debounce task leaks | ExecutionPaneView | Cancel pendingStageTask in onDisappear |
| H5 | ScrollView reader race | ChatThreadComponents | Debounce scroll-to-bottom |
| H6 | O(n²) streaming reveal | StreamingMarkdownRevealView | Batch 10 chars at a time |
| H7 | No cycle detection | TaskPlanEngine | Add cycle detection before execution |
| H8 | Phase deadlock | CompactionCoordinator | Auto-reset .optimizing after 120s |
| H9 | Unbounded retry backoff | ToolError RecoveryExecutor | Add jitter, enforce ceiling |

### Unbounded Memory Growth Details
| Source | What grows | Bound |
|--------|-----------|-------|
| `GitFoundation.readAll()` | Git command output | ~~None~~ ✅ Capped at 10 MB |
| `SessionInspectorModel` | Span array | None — rebuildSummary() per span |
| `LatencyDiagnostics` | Stages/points/llmCalls arrays | None |
| `TraceCollector` | Continuations array | ~~None~~ ✅ Fixed — onTermination cleanup |
| `AgentTrace` | Active spans (never timeout) | None |
| `JobFoundation` | Event log before trim | Spikes to N before trimming to 80 |
| `SimulatorPreviewService` | Screenshot files in /tmp | None |

---

## 5. Medium-Risk Issues

| # | Issue | File | Impact |
|---|-------|------|--------|
| M1 | Fragile tool classification via `string.contains()` | StreamPipeline | Wrong tool type → wrong streaming phase |
| M2 | Case-sensitive plan detection | StreamPipeline | LLM output variance breaks plan parsing |
| M3 | Filesystem walk (6 levels) on every CodeBlockCard render | MarkdownRendering | Perf drag on chat with many code blocks |
| M4 | `ativeRenderer` sentence splitting breaks on abbreviations | NarrativeRenderer | "Dr. Smith" split into two sentences |
| M5 | `ToolParallelism` whitelist excludes `web_fetch` | ToolParallelism | Legitimate parallel reads run sequentially |
| M6 | Sandbox check sometimes happens AFTER file operation | ToolGuardrails | Security gap: write-then-check ordering |
| M7 | `ArchitectureValidator` violations persist only in memory | ArchitectureValidator | App crash loses all violation history |
| M8 | Latency reports exported to hardcoded `/tmp` path | LatencyDiagnostics | Accumulates files forever |
| M9 | `CoreSceneController` array mutation during render | CoreSceneController | SceneKit threading crash risk |
| M10 | `ViewportStreamModel` silently ignores illegal transitions | ViewportStreamModel | Caller has no idea request was rejected |
| M11 | `AGENTSParser` silently degrades on parse failure | AGENTSParser | Config issues invisible to user |
| M12 | `ClaudeAPIClient` no Anthropic error classification | ClaudeAPIClient (SPM) | Can't distinguish rate-limit from auth failure |
| M13 | `ExecutorAgent` has no `Task.isCancelled` checks | ExecutorAgent (SPM) | UI can't interrupt build repair loops |
| M14 | Thread persistence optional everywhere; no rollback | CommandCenterView | Inconsistent state if persistence fails mid-op |

---

## 6. Spaghetti Risk Audit

### Prop Threading Depth
```
CommandCenterView (25+ @State)
  → WorkspaceShellView (pass-through, 15 props)
    → ExecutionPaneView (15 props, 7+ local @State)
      → ChatThreadView (12 props)
        → ConversationTurnRow (8 props)
          → InterleavedTurnContentView
            → InlineToolTraceGroup
```
**6 levels deep, 15+ props at the widest point.** This is the ceiling for manual prop threading.

### Coupling Hotspots
| File | Incoming refs | Outgoing refs | Score |
|------|--------------|--------------|-------|
| CommandCenterView | 0 (root) | 18 | Extreme out-coupling |
| Models.swift | ~30 | 3 | High in-coupling (fine for model layer) |
| AgenticBridge | 1 (runner) | 12 | High out-coupling |
| StreamPipeline | 2 | 5 | Moderate |
| GitFoundation | 3 | 0 | Clean |

### Verdict
**Not spaghetti yet, but one layer away.** The prop threading is at its limit. The God Object pattern in CommandCenterView is the primary risk — it's where spaghetti will emerge first because every new feature adds another `@State` + callback pair.

---

## 7. UI & Rendering Audit

### Chat Rendering Pipeline
```
ConversationStore (turns/blocks)
  → ChatThreadView (ScrollViewReader + ForEach)
    → ConversationTurnRow (role-based dispatch)
      → InterleavedTurnContentView (text + tool blocks interleaved)
        → MarkdownMessageContent (block parser → headings/lists/code/quotes)
        → StreamingMarkdownRevealView (character-by-character animation)
        → InlineToolTraceGroup (collapsible tool activity)
        → CodeBlockCard (syntax highlight + diff + apply-to-file)
```

**Strengths:**
- Structured block model (not just raw text) — handles mixed text/tool/thinking content
- Design token system fully wired (StudioTypography, StudioColorTokens, StudioPolish)
- Phase-driven streaming UI with 8-state FSM

**Weaknesses:**
- Markdown parser has no error recovery or nesting depth limit
- StreamingMarkdownRevealView does per-character async tasks (O(n²))
- CodeBlockCard walks filesystem 6 levels up on every render
- ConversationTurnListItem.Equatable compares 10 fields — any change rerenders entire turn

---

## 8. State Model Audit

| Layer | Owner | Pattern | Quality |
|-------|-------|---------|---------|
| App-wide projects/threads | CommandCenterView | 25+ @State | **GOD OBJECT** |
| Conversation turns | ConversationStore | @MainActor @Observable | Good |
| Streaming phase | StreamPhaseController | @MainActor @Observable FSM | Good |
| Viewport content | ViewportStreamModel | @MainActor @Observable FSM | Good |
| Repository state | RepositoryMonitor | @MainActor @Observable | Good |
| Background jobs | JobMonitor | @MainActor @Observable | Good |
| Tracing | TraceCollector | Actor | Good |
| Latency | LatencyDiagnostics | Actor | Good |
| Automation prefs | AutomationPreferenceStore | @MainActor .shared | Good |

**Right patterns in use.** Problem is CommandCenterView holding state that should be in coordinators.

---

## 9. Observability & Debugging Audit

### What's Instrumented
- Tracing: TraceCollector + TracePersister (8 span kinds, AsyncStream subscribers, summary stats)
- Latency: LatencyDiagnostics (stage times, LLM metrics, tool loop durations)
- Architecture: ArchitectureValidator (8 violation kinds, runtime)
- Telemetry: TelemetryIngestor for event ingestion

### What's NOT Instrumented
- CC RecoveryExecutor has NO tracer (SPM version does)
- ExecutorAgent (GPT-5.4 build repair) has NO tracer
- No span timeout detection (begun but never ended = memory forever)
- Architecture violations lost on app restart
- Latency exports to /tmp with no UI and no cleanup
- No error rate dashboards

---

## 10. Prioritized Fix Order

### Tier 0: Do Now (Before Next Feature)
1. ~~**Add timeouts to all Process calls**~~ ✅ — GitFoundation (30s), SimulatorPreviewService (60s), AgenticBridge Fastlane (600s)
2. **Fix infinite retry loop** — JobFoundation ~L530
3. **Move SimulatorPreviewService.runCommand()** to Task.detached

### Tier 1: Next Sprint
4. **Extract WorkspaceCoordinator from CommandCenterView** — reduces 1200 → <400 lines
5. **Resolve SPM/CC split** — import AgentCouncil, delete shadow copies
6. ~~**Add memory bounds**~~ ✅ (partial) — readAll capped at 10MB, TraceCollector continuations leak fixed. Remaining: cap spans at 5000, circular buffer LatencyDiagnostics
7. **Fix CompactionCoordinator deadlock** — auto-reset after 120s

### Tier 2: Following Sprint
8. **Split AgenticBridge** into handlers + dispatcher
9. **Fix ExecutionPaneView task leaks** — cancel pendingStageTask in onDisappear
10. **Add jitter to retry backoff** in ToolError
11. **Batch SessionInspectorModel.rebuildSummary()** — every 500ms not per-span
12. **Cache CodeBlockCard.resolvedPackageRoot** — compute once

### Tier 3: Ongoing
13. Replace string.contains() tool classification with enums
14. Add depth limits to parsers and span trees
15. Persist ArchitectureValidator violations
16. Add tracer to CC RecoveryExecutor and ExecutorAgent
17. Add cancellation to ExecutorAgent and TaskPlanExecutor

---

## 11. Refactor Recommendations

| # | What | Why | Risk | Scope |
|---|------|-----|------|-------|
| R1 | Extract Coordinators from CommandCenterView | God Object → testable coordinators | Medium | ~400 LOC/coordinator |
| R2 | Split AgenticBridge into Handler + Dispatcher | 3500 LOC actor untestable | Medium | ~2000 LOC restructured |
| R3 | Unify SPM/CC through package import | Eliminate 4-file duplication | Low | Types already compatible |
| R4 | Introduce ToolHandler protocol | Enable per-tool unit testing | Low | Mechanical extraction |
| R5 | StreamingMarkdownRevealView batch reveals | O(n²) → O(n) | Low | Imperceptible visual change |

---

## 12. What NOT to Change

1. **Actor-based concurrency model** — GitService, TraceCollector, BackgroundJobRunner, ArchitectureValidator correctly isolated
2. **@Observable for view models** — StreamPhaseController, ViewportStreamModel, RepositoryMonitor, JobMonitor are the pattern to replicate
3. **Streaming pipeline FSM** — 8-phase StreamPhaseController is well-designed. Fix edges, keep structure
4. **SwiftData for persistence** — AppProject, Epoch, PersistedThread, PersistedSpan are clean @Model types
5. **Design token system** — StudioColorTokens, StudioTypography, StudioSpacing, StudioPolish, StudioMotion, StudioRadius mature and fully migrated
6. **HandoffTypes.swift** — Zero red flags. Clean Sendable value types
7. **ArchitectureValidator concept** — runtime invariant checking is valuable, just needs persistence
8. **NarrativeRenderer voice pipeline** — 7-layer transform is opinionated but functional
9. **CoreSceneController visuals** — fix threading, don't redesign SceneKit setup
10. **Dual CLI targets** — AgentCouncilCLI + ExecutorCLI valuable for standalone testing

---

## Final Questions — Direct Answers

### 1. Is the codebase trending toward maintainable or spaghetti?
**Trending maintainable, but at the inflection point.** Infrastructure layer (actors, tracing, git, jobs) is clean. View layer is where spaghetti is forming — specifically CommandCenterView and ExecutionPaneView. If the God Object pattern isn't broken in the next 1–2 feature cycles, prop threading will cross the point where safe refactoring is possible.

### 2. Top 3 risks that could poison the foundation?
1. **CommandCenterView God Object** — every feature adds state here. At 30+ properties, no one will safely refactor it.
2. **Missing process timeouts** — one hung git or simulator command freezes the entire app with no recovery. Only risk that can make the app unshippable.
3. **SPM/CC source-of-truth split** — as both evolve independently, shadow copies will drift. CC's recovery executor already lacks observability.

### 3. Single most important architecture change needed?
**Extract coordinators from CommandCenterView.** This unblocks everything else. A 200-line layout shell with 3 observable coordinators is testable, navigable, and safe to extend. Do this before any new feature work.

### 4. Is the streaming/tool-call stack trustworthy?
**Conditionally yes.** The streaming FSM is well-designed. The tool execution model (parallelism partitioning, guardrails, sandbox) is sound. But: tool classification is string-based and fragile, there's no HTTP stream cancellation, retry has no jitter, and the entire stack lives in one 3,500-line actor. Split AgenticBridge and replace string heuristics with enums.

### 5. Is the chat/rendering layer good enough for a permanent control surface?
**Yes, with caveats.** The block model, markdown parser, code block cards with diff/apply, and phase-driven streaming renderer are architecturally solid. Fix: batch StreamingMarkdownRevealView, cache CodeBlockCard package root, finer-grained ConversationTurnListItem.Equatable. None are structural — performance polish on a sound foundation.
