# Studio.92 Model Routing

How models are selected, why, and the philosophy behind the routing system.

## Philosophy

The routing system exists to answer one question: **which model should handle this
specific unit of work?** Not "which model is best" — which model is *appropriate* given
the context, cost, capabilities, and failure history of the current execution.

The system is deterministic by default. Given the same `RoutingContext`, it produces the
same `RoutingDecision`. Stochastic elements (confidence scoring, feedback-driven weight
adjustment) are deferred to Phase 4.

## Model Roles

Defined in `AGENTS.md` and resolved from `.studio92/ship.toml [models]`:

| Role | Default Model | When Used |
|------|--------------|-----------|
| `full_send` | `gpt-5.4` | Primary code generation, implementation |
| `review` | `claude-sonnet-4-6` | Read-only audit, verification phases |
| `escalation` | `claude-opus-4-6` | Architecture decisions, complex reasoning, failure recovery |
| `explorer` | `claude-haiku-4-5` | Codebase scouting, read-only exploration |
| `subagent` | `gpt-5.4-mini` | Background worktrees, focused delegation |

Explorer escalation chain: Haiku → Sonnet → Opus.

## Routing Priority Cascade

`routingDecision(context:)` evaluates 8 levels in fixed order. First match wins.

```
Priority 1: explicit_escalation
  → User or system explicitly requested a specific model/role

Priority 2: review_escalation
  → Explorer encountered complexity beyond its capability → Sonnet

Priority 3: failure_escalation
  → ≥2 consecutive failures on the same goal → Opus
  → Rationale: if a model failed twice, a cheaper model won't fix it

Priority 4: capability_match
  → TaskStep.requiredCapabilities → ModelCostProfile.satisfies()
  → Matches required capabilities to cheapest model that satisfies them
  → 7 capabilities: codeGeneration, reasoning, speed, multifileEdit,
    buildRepair, research, review

Priority 5: review_intent
  → Goal text signals review/audit intent → review model

Priority 6: dag_verification
  → DAG step is in verification phase → review model
  → Rationale: verification should use a different model than implementation

Priority 7: complexity_escalation
  → Heuristic complexity detection (token count, attachment count,
    context pressure) → escalation model

Priority 8: default (fallback)
  → ship.toml default for the current role
```

## Capability-Based Selection (Phase 3)

Each model role has a `ModelCostProfile`:
- `relativeCost: Double` — normalized cost (0.0–1.0, haiku=0.05, opus=1.0)
- `capabilities: Set<TaskCapability>` — what the model can do well

Each `TaskStep` has `requiredCapabilities` that default from its `TaskPhase`:
- discovery → `[research, speed]`
- analysis → `[reasoning, research]`
- implementation → `[codeGeneration, multifileEdit]`
- verification → `[review]`
- repair → `[buildRepair]`

Routing picks the cheapest `ModelCostProfile` that satisfies all required capabilities.
Ties break by profile order (which follows the cost profiles dictionary iteration).

## Plan Adaptation

When a DAG step completes, `PlanAdaptationPolicy` evaluates whether the plan should
change:

1. **Verification passed** → `skipRemaining` (no more steps needed)
2. **Discovery failed** → `rerouteStep` next analysis step to escalation model
3. **Implementation retries exhausted** → `rerouteStep` to escalation model

Guards:
- Max 3 adaptations per plan (`TaskPlan.adaptationCount` cap)
- Reroute target must differ from current role (prevents A→B→A oscillation)
- Anti-oscillation: adaptation is rejected if target equals current `recommendedRole`

Each adaptation emits a trace span with `role_before` and `role_after` attributes.

## GPT-5.4 Prompt Patterns

When the selected model starts with `gpt-5`, the system injects structured guidance:
- `tool_persistence` — complete the task even if early tools fail
- `dependency_checks` — verify file existence before edits
- `completeness_contract` — don't stop at partial implementations
- `verification_loop` — build and test after code changes

Mini sub-agent prompts (gpt-5.4-mini) follow tighter constraints:
- Critical rules first
- Numbered execution order
- Explicit output packaging format
- No follow-up questions

## Configuration

All model IDs live in `.studio92/ship.toml`:

```toml
[models]
review = "claude-sonnet-4-6"
full_send = "gpt-5.4"
subagent = "gpt-5.4-mini"
escalation = "claude-opus-4-6"
explorer = "claude-haiku-4-5"
```

To override for a specific scenario (e.g., using gpt-5.4-pro for escalation):
```toml
escalation = "gpt-5.4-pro-2026-03-05"
```

No code changes needed — `StudioModelStrategy` reads ship.toml at runtime.

## Telemetry

Every routing decision emits trace attributes:
- `routing.strategy` — which priority level matched
- `routing.capabilities_required` — capability set (if capability_match)
- `routing.candidates` — roles that satisfied capabilities

Per-DAG-step:
- `dag.step.{id}.routing_strategy`
- `dag.step.{id}.model`

## Open Work

- **Phase 4: Feedback-Driven Learning** — Use trace telemetry to build confidence
  scores per model×task-type pair. Weight routing decisions by historical success rates.
  `PlanAdaptationReason` enum is already structured for analytics extraction.

---

## Decision Provenance

Every routing decision produces trace attributes that form a provenance chain. These
attributes are contracts — changing their names or semantics is a breaking change for
any analytics or debugging tool that consumes them.

### Per-Decision Attributes
| Attribute | Type | Meaning |
|-----------|------|---------|
| `routing.strategy` | String | Which priority level matched (e.g., `capability_match`, `failure_escalation`) |
| `routing.model` | String | Selected model ID |
| `routing.role` | String | Selected role (e.g., `full_send`, `review`) |
| `routing.capabilities_required` | [String] | Capability set if `capability_match` was the strategy |
| `routing.candidates` | [String] | All roles that satisfied the required capabilities |
| `routing.cost` | Double | `relativeCost` of the selected model profile |

### Per-DAG-Step Attributes
| Attribute | Type | Meaning |
|-----------|------|---------|
| `dag.step.{id}.routing_strategy` | String | Strategy used for this step |
| `dag.step.{id}.model` | String | Model selected for this step |
| `dag.step.{id}.phase` | String | Task phase (discovery, analysis, implementation, verification, repair) |
| `dag.step.{id}.capabilities` | [String] | Required capabilities for this step |

### Adaptation Attributes
| Attribute | Type | Meaning |
|-----------|------|---------|
| `adaptation.reason` | String | Why the plan was adapted (verification_passed, discovery_failed, retries_exhausted) |
| `adaptation.role_before` | String | Role before adaptation |
| `adaptation.role_after` | String | Role after adaptation |
| `adaptation.count` | Int | Current adaptation count (max 3) |

### Contract Rules
1. Attribute names are stable — do not rename without a migration plan.
2. New attributes may be added freely.
3. `routing.strategy` values correspond 1:1 to priority cascade levels.
4. `adaptation.count` must never exceed `TaskPlan.maxAdaptations` (currently 3).

---

## Key Files

| Concern | File | Path |
|---------|------|------|
| Routing engine | ModelRouting | `Routing/ModelRouting.swift` |
| Plan generation + execution | TaskPlanEngine | `Routing/TaskPlanEngine.swift` |
| AGENTS.md parsing | AGENTSParser | `Routing/AGENTSParser.swift` |
| Tool schemas | ToolSchemas | `Routing/ToolSchemas.swift` |
| Pipeline orchestration | PipelineRunner | `Execution/Pipeline/PipelineRunner.swift` |
| Step routing | PipelineStepRouter | `Execution/Pipeline/PipelineStepRouter.swift` |
| Configuration | ship.toml | `.studio92/ship.toml` |
