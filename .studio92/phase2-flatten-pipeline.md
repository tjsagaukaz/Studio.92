# Phase 2 — Flatten the Pipeline

## Diagnosis

SemanticStreamEvent is a 13-case enum used exclusively as message-passing
between StreamPipelineCoordinator and StreamPhaseController.  Both types
live in the same file.  The coordinator creates an event and immediately
calls `phaseController.ingest(event)`, which unpacks it via a switch.

This is indirection without decoupling.  No other type produces or
consumes SemanticStreamEvent.  Zero grep hits outside StreamPipeline.swift.

### What We Tried to Collapse But Can't

The original Phase 2 plan targeted "5 conversation models → 3".
Detailed audit showed all 5 are load-bearing and serve distinct layers:

- ChatMessage: wire/streaming (15+ view bindings)
- ConversationTurn: view-model grouping (interleavedBlocks, state machine)
- ConversationHistoryTurn: API message format + compaction input
- PersistedMessage: SwiftData persistence contract
- PacketSummary: sole telemetry → epoch metrics bridge

Attempting to collapse any of these would cause cascading breakage
with no architectural benefit.

## Tasks

- [x] 1. Replace `SemanticStreamEvent` with named methods on StreamPhaseController
- [x] 2. Update StreamPipelineCoordinator to call named methods (kill .ingest())
- [x] 3. Delete SemanticStreamEvent enum and supporting comment blocks
- [x] 4. Build & verify

## Scope

- **Files touched:** CommandCenter/StreamPipeline.swift (only)
- **Lines deleted:** ~65 (enum definition + ingest() switch)
- **Lines added:** ~10 (method signatures on StreamPhaseController)
- **Net:** ~-55 lines
- **Risk:** Low — purely internal to one file, no API/view changes

## Outcomes & Retrospective

**File touched:** StreamPipeline.swift (only)

| Metric | Before | After |
|--------|--------|-------|
| SemanticStreamEvent enum | 13 cases, ~50 lines | Deleted |
| StreamPhaseController.ingest() | 1 switch with 13 arms | 10 named methods |
| Coordinator call sites | 14× `.ingest(.caseName(...))` | 14× direct method calls |
| Intermediary message types | 1 (SemanticStreamEvent) | 0 |
| Build | SUCCEEDED | SUCCEEDED |
| Tests | 83/84 pass (same pre-existing failure) | Same |

**What changed architecturally:**
- StreamPipelineCoordinator no longer packages data into an enum just to unpack it
- StreamPhaseController exposes intent through method names, not case matching
- Zero semantic change — every behavior is identical, the indirection is gone

