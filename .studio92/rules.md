# Studio.92 Rules

Constraints and invariants that govern all code changes. Violations should be caught by
ArchitectureValidator at runtime and by review at PR time.

## Execution Rules

1. **All execution flows through ExecutionLoopEngine.** No direct LLM calls from views,
   coordinators, or tool handlers. The loop owns the stream→tools→iterate cycle.

2. **Streaming must be delimiter-driven.** SSE parsing splits on `\n\n` boundaries, not
   content-length or fixed buffers. Parsers must handle arbitrary chunk boundaries —
   a single event can arrive across multiple TCP segments. Tested by byte-at-a-time and
   split-boundary integration tests.

3. **No direct tool calls outside ToolDispatch.** All tool execution routes through
   the dispatch layer, which enforces guardrails, parallelism rules, and tracing.

4. **Tool parallelism respects read/write semantics.** Reads (file_read, list_files,
   web_search) run in parallel via TaskGroup. Writes (file_write, file_patch, terminal,
   deploy) run sequentially. A read targeting the same path as a pending write is demoted
   to sequential. Ceiling: `ship.toml [execution] max_parallel_tools`.

5. **Recovery strategy is resolved from error taxonomy, not per-tool config.**
   `ToolError` → `RecoveryStrategy` via pure function. No per-tool retry configuration.
   Circuit breaker (5 failures / 30s) gates retry attempts globally.

6. **Handoffs use typed delegation.** `HandoffContext` → `HandoffExecutor` →
   `HandoffResult`. No string-based role passing. Explorer and reviewer handoffs
   enforce read-only guardrails via `ToolPermissionPolicy(mode: .review)`.

## Routing Rules

7. **ModelRouting is the single entry point for model selection.** No hardcoded model
   identifiers in application code. All model IDs resolve from `ship.toml [models]` via
   `StudioModelStrategy`. Routing decisions flow through `routingDecision(context:)`.

8. **Routing priority cascade is fixed.** The 8-level priority order must not be reordered:
   explicit_escalation → review_escalation → failure_escalation → capability_match →
   review_intent → dag_verification → complexity_escalation → default.

9. **Plan adaptation has anti-oscillation guards.** Max 3 adaptations per plan. Reroute
   targets must differ from current role (prevents A→B→A loops). These caps exist to
   prevent pathological plan mutations.

10. **TaskPlanEngine is invisible to the user.** DAG planning and step execution happen
    behind PipelineRunner. The user sees a single goal → result flow. No plan UI unless
    explicitly building an inspector view.

## Guardrail Rules

11. **Sandbox checks happen BEFORE file operations.** `SandboxPolicy.check(path:)` must
    gate file_write and file_patch before any filesystem mutation. Symlinks are resolved
    via `resolvingSymlinksInPath()` before prefix comparison.

12. **Permission policy is per-autonomy-mode.** Plan mode blocks writes + terminal +
    deploy. Review mode blocks writes + deploy. FullSend blocks nothing. These sets are
    defined in `ToolPermissionPolicy` and must stay synchronized between SPM and CC.

13. **Subagent guardrails inherit the caller's sandbox.** `SubagentGuardrails` bundles
    the parent's `SandboxPolicy` + a review-mode `ToolPermissionPolicy`. Subagents
    cannot escalate their own permissions.

## Concurrency Rules

14. **Actors own mutable shared state.** `AgenticBridge`, `TraceCollector`,
    `LatencyDiagnostics`, `RecoveryExecutor` are actors. Do not add `nonisolated` to
    methods that touch mutable state.

15. **`@MainActor @Observable` for UI-bound state.** `ConversationStore`,
    `StreamPhaseController`, `ViewportStreamModel`, `RepositoryMonitor`, `JobMonitor`.
    Do not move these off MainActor — SwiftUI observation requires it.

16. **Blocking work goes to Task.detached.** Process execution, simulator commands,
    and any `waitUntilExit()` calls must not run on MainActor or inside actor-isolated
    methods.

17. **All external processes have timeouts.** Git: 30s. Simulator: 60s. Fastlane: 600s.
    Pattern: terminate → grace period → SIGKILL.

## Persistence Rules

18. **SwiftData for queryable storage.** Traces use `PersistedSpan` (@Model) +
    `TracePersister` (@ModelActor). Threads and messages use `@Model` types in
    `ThreadStorageModels.swift`. No ndjson files for structured data.

19. **Thread persistence is coordinator-mediated.** All thread CRUD goes through
    `ThreadPersistenceCoordinator`. No direct `modelContext` access from views.

## UI Rules

20. **Views are thin layout shells.** Business logic lives in coordinators
    (`WorkspaceCoordinator`, `ThreadCoordinator`) or observable models. Views do
    layout + binding + onChange delegation.

21. **Design tokens are non-negotiable.** Colors from `StudioColorTokens`, typography
    from `StudioTypography` (Geist font family), motion from `StudioMotion`, radii/shadows
    from `StudioPolish`. No inline hex colors, font sizes, or animation durations.

22. **No internal design-system abstraction layers.** Use SwiftUI primitives directly
    with Studio tokens applied. Do not create wrapper components that simply pass through
    to SwiftUI views.

## Structural Rules

23. **Domain folders, not type folders.** `Execution/`, `Routing/`, `Tools/` — not
    `Models/`, `Services/`, `Utils/`. Each folder owns a system domain. Max depth: 2.

24. **SPM types are canonical.** When a type exists in both `Sources/AgentCouncil/` and
    `CommandCenter/`, the SPM version is the source of truth. CC should import, not
    shadow-copy. (Current debt: CC does not yet import AgentCouncil as a dependency.)

25. **Protected paths are read-only by default.** `.git/`, `.codex/`, `.studio92/`,
    and agent/config state must not be mutated by tool execution unless the task
    explicitly requires it and the user confirms.

## Shipping Rules

26. **Ship blockers surface first.** Before any feature work on a shipping flow, check:
    signing, entitlements, privacy manifests, bundle identifiers, icons, screenshots,
    metadata, failing builds, and App Store policy compliance.

27. **Prefer Fastlane over Xcode GUI.** Archive, signing, TestFlight, and App Store
    Connect operations use deterministic CLI flows. GUI-driving Xcode is a last resort.

28. **Live research for shipping decisions.** Any decision that depends on current Apple
    SDK behavior, App Store Review Guidelines, privacy manifests, or entitlements must
    use live web research. Apple docs first, then broader search.

---

## Violation Examples

Concrete ❌/✅ pairs for each rule category to clarify intent.

### Execution
❌ A view calls `AgenticBridge.sendMessage()` directly to get a quick response.
✅ The view submits a goal through `WorkspaceCoordinator` → `PipelineRunner` → `ExecutionLoopEngine`.

❌ SSE parser splits events on `content-length` header or 4096-byte chunks.
✅ SSE parser splits on `\n\n` delimiter, buffering across arbitrary TCP segments.

### Routing
❌ `PipelineRunner` hardcodes `"claude-opus-4-6"` for escalation.
✅ `PipelineRunner` calls `routingDecision(context:)` which reads the model from `ship.toml`.

❌ A plan adaptation reroutes from Sonnet → Opus → Sonnet in the same plan.
✅ Adaptation is rejected because target equals a previous role (anti-oscillation guard).

### Guardrails
❌ `file_write` handler writes the file, then checks `SandboxPolicy`.
✅ `SandboxPolicy.check(path:)` gates the operation before any filesystem mutation.

❌ An explorer handoff creates its own `ToolPermissionPolicy(mode: .fullSend)`.
✅ Explorer handoff inherits the parent's sandbox + `ToolPermissionPolicy(mode: .review)`.

### Concurrency
❌ Adding `nonisolated` to a `TraceCollector` method that reads `spans`.
✅ All methods that touch mutable actor state remain actor-isolated.

❌ Running `Process.waitUntilExit()` inside an `@MainActor` method.
✅ Process execution runs in `Task.detached` with timeout.

### UI
❌ `Text("Error").foregroundColor(.red).font(.system(size: 14))`
✅ `Text("Error").foregroundStyle(StudioColorTokens.error).font(StudioTypography.caption)`

---

## When to Break a Rule

Rules are defaults, not absolutes. Break them when:

1. **Prototyping a new subsystem.** Skip guardrails and routing for throwaway spikes.
   Delete the spike before merging.

2. **Hot-path performance.** If `SandboxPolicy.check()` is profiled as a bottleneck in
   a tight loop, batch the check outside the loop. Document with a `// PERF:` comment.

3. **Apple SDK requires it.** If a new API demands main-thread access that violates
   rule 16, add `@MainActor` with a `// APPLE:` comment linking to the documentation.

4. **Test code.** Test helpers may call tools directly (bypassing ToolDispatch) or use
   inline model IDs. Production code must not.

5. **Ship-blocking emergency.** If a rule blocks a release, break it with a comment
   `// DEBT: rule N violated — tracking in issue #NNN` and file the issue immediately.

**Process:** When breaking a rule, add a comment at the call site citing the rule number
and the justification. ArchitectureValidator will still flag it — suppress with
`@ArchitectureValidator.suppress(ruleN)` if supported, otherwise note in the PR.

---

## Key Files

| Rule Category | Primary File | Path |
|---------------|-------------|------|
| Execution loops | ExecutionLoopEngine | `Execution/Loops/ExecutionLoopEngine.swift` |
| Streaming | AnthropicStreamHandler | `Execution/Streaming/AnthropicStreamHandler.swift` |
| Tool dispatch | ToolDispatch | `Tools/ToolDispatch.swift` |
| Tool parallelism | ToolParallelism | `Tools/ToolParallelism.swift` |
| Guardrails | ToolGuardrails | `Tools/ToolGuardrails.swift` |
| Recovery | ToolError | `Tools/ToolError.swift` |
| Routing | ModelRouting | `Routing/ModelRouting.swift` |
| Plan engine | TaskPlanEngine | `Routing/TaskPlanEngine.swift` |
| Handoffs | HandoffExecutor | `Execution/HandoffExecutor.swift` |
| Sandbox | ToolGuardrails | `Tools/ToolGuardrails.swift` |
| Persistence | ThreadStorageModels | `Persistence/ThreadStorageModels.swift` |
| Design tokens | StudioColorTokens | `Studio/StudioColorTokens.swift` |
| Architecture validator | ArchitectureValidator | `Diagnostics/ArchitectureValidator.swift` |
