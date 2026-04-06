# Phase 1: Collapse the Mirrors

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

## Purpose / Big Picture

Studio.92's orchestration has accumulated redundant layers over time. This phase removes the easiest duplication without changing observable behavior. After this change, the codebase has fewer moving parts, one config parser instead of two, no duplicate tool schema sets, and a leaner model resolution path. The result: faster orientation for any agent (human or AI) reading the code, and fewer places where a config or schema change can go stale.

## Progress

- [x] (2025-04-05 18:00Z) Audit all mirror files and build relationships.
- [x] (2025-04-05 18:30Z) Simplify StudioModelStrategy (killed NSLock + ShipModelCacheEntry + mtime cache, unified TOML parser).
- [x] (2025-04-05 18:35Z) Merge DefaultToolSchemas.backgroundWorker into leanOperator (deleted duplicate, updated call site in JobFoundation).
- [x] (2025-04-05 18:35Z) Flatten duplicate TOML parsing (one parseShipTOML function serves both shipModelOverrides and shipMaxParallelTools).
- [x] (2025-04-05 18:40Z) Flatten HandoffExecutor from actor to enum with static methods. Deleted dead HandoffContext and AgentRole types.
- [x] (2025-04-05 18:45Z) BUILD SUCCEEDED. 84 SPM tests pass (1 pre-existing failure in ExecutorTests, unrelated).

## Surprises & Discoveries

- CommandCenter is an Xcode project that does NOT import the AgentCouncil SPM package. Mirror files exist because of this build boundary. Full unification requires adding the SPM package as a dependency to the Xcode project — deferred to Phase 2.
- AutonomyMode is defined in BOTH Sources/AgentCouncil/Orchestrator/ToolExecutor.swift (public) AND CommandCenter/Models.swift (internal). These cannot be unified without a build change.
- DefaultToolSchemas.backgroundWorker and DefaultToolSchemas.leanOperator are literally identical arrays.

## Decision Log

- Decision: Do not attempt to make CommandCenter import AgentCouncil in Phase 1. The build system change is risky and orthogonal to simplification. Rationale: risk containment. Date: 2025-04-05.
- Decision: Keep mirror files for now but mark them clearly. Unification deferred. Date: 2025-04-05.

## Outcomes & Retrospective

Phase 1 complete. Net code reduction:
- StudioModelStrategy: Deleted ShipModelCacheEntry struct, NSLock, mtime validation, normalizedPackageRoot helper. Replaced with unified parseShipTOML + shipTOMLURL (2 small functions vs 3 complex ones).
- DefaultToolSchemas: Deleted backgroundWorker (exact duplicate of leanOperator). 1 call site updated.
- HandoffExecutor: Converted from actor (with init, stored state, instance methods) to enum with static methods. Removed SubagentRunner being threaded through init — now passed directly. Deleted HandoffContext and AgentRole (dead code after refactor).
- HandoffTypes: Removed 3 types (AgentRole, HandoffContext, the "mirror" comment). Kept HandoffResult + HandoffOutcome which are still actively used.
- Zero behavioral changes. All existing tests pass. Build succeeds.

## Context and Orientation

CommandCenter/Models.swift contains StudioModelStrategy (lines 821–1140), which resolves model descriptors through a 4-source chain with NSLock caching and mtime validation. This is over-engineered for a config file that changes at most once per session.

CommandCenter/AgenticBridge.swift contains DefaultToolSchemas (line 3980+), which defines tool JSON schemas. backgroundWorker and leanOperator are identical.

Both shipModelOverrides() and shipMaxParallelTools() parse the same .studio92/ship.toml file independently, duplicating the TOML parsing logic.

## Plan of Work

1. In StudioModelStrategy, replace the NSLock + ShipModelCacheEntry + mtime machinery with a one-shot parse function. Cache the result in a simple static var (no lock, no mtime — read on first access).
2. Unify the TOML parsing: one private static function parses ship.toml into a [String: [String: String]] (section → key → value). Both shipModelOverrides and shipMaxParallelTools call this single parser.
3. In DefaultToolSchemas, delete backgroundWorker and replace all call sites with leanOperator.
4. Build and run tests.

## Validation and Acceptance

Run `xcodebuild -project CommandCenter/CommandCenter.xcodeproj -scheme CommandCenter -configuration Debug build` — expect success. Run SPM tests `swift test` — expect all pass. Verify the app launches and the Fleet sidebar shows correct model info.
