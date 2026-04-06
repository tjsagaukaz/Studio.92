# Studio.92 Agents

Studio.92 is a Codex-compatible Apple app builder. The system should be able to research the live date, inspect the local machine, edit the workspace, verify code, and prepare apps for TestFlight and App Store Connect.

## Model Roles

- `Full Send` (primary builder): `Claude Sonnet 4.6`
- `Review` (read-only audit): `Claude Sonnet 4.6`
- `Plan` (execution planning and decomposition): `Claude Sonnet 4.6`
- `Escalation` (complex / architecture / deep reasoning): `Claude Opus 4.6`
- `Explorer` (codebase scouting, read-only exploration): `Claude Haiku 4.5`, escalates Haiku → Sonnet → Opus
- `Executor` (build repair, deterministic JSON fixes): `gpt-5.4`
- `Release Manager` (archive, signing, Fastlane, TestFlight, App Store Connect): `gpt-5.4`
- `Computer Use` (full-machine actions, Xcode, Safari, local file operations outside the workspace): `gpt-5.4`
- `Subagents` and background worktrees: `gpt-5.4-mini`
- `Standards Research`: `gpt-5.4-mini`, escalate to `gpt-5.4` when sources conflict or the task is high-stakes
- `Fallback`: `gpt-5.4-nano`, `gpt-4.5` (retry chain)

## Operating Rules

- Treat Git as the source of truth. Use isolated worktrees for long-running, risky, or parallel tasks.
- Prefer SwiftUI and native Apple frameworks unless the task clearly requires something else.
- Do not recreate old internal design-system layers. Keep generated apps direct, native, and shippable.
- Always use live research when the request depends on current Apple SDK changes, App Store Review Guidelines, privacy manifests, entitlements, signing, TestFlight behavior, or App Store Connect rules.
- Search Apple docs first: `developer.apple.com`, Human Interface Guidelines, App Store Review Guidelines, platform release notes, and Swift evolution updates before broader web search.
- Build and verify real code. Do not stop at a plan when code changes are clearly requested.
- Keep `Review` read-only. `Review` finds issues; `Executor`, `Release Manager`, or `Full Send` performs changes.
- Prefer `Fastlane` and deterministic CLI flows for archive, signing, TestFlight, and App Store Connect work over GUI-driving Xcode whenever possible.
- Model computer use with separate controls for access scope and approval policy. Do not treat machine autonomy as a single toggle.
- Access scopes: `Read Only`, `Workspace Only`, `Full Mac Access`.
- Approval modes: `Always Ask`, `Ask on Risky Actions`, `Never Ask`.
- Default to `Workspace Only` + `Ask on Risky Actions`. Escalate to `Full Mac Access` only when explicitly enabled for the current task.
- Prefer granting explicit extra roots over broad machine-wide access when the task needs files outside the main workspace.
- Even in `Full Mac Access`, treat destructive machine actions and shipping actions as high risk: deleting outside the workspace, changing signing or keychain state, modifying credentials, and submitting builds should require an explicit arm or confirmation step.
- Keep protected paths read-only by default even in writable workflows: `.git/`, `.codex/`, `.studio92/`, and other agent/config state unless the task explicitly requires changing them.
- In background worktrees, edit only inside the assigned worktree path unless the user explicitly asks for broader machine access.
- Surface concrete ship blockers first: signing, entitlements, privacy manifests, bundle identifiers, icons, screenshots, metadata, failing builds, and policy issues.
- Keep outputs concise, grounded, and diff-oriented.
- Use `delegate_to_explorer` and `delegate_to_reviewer` for focused sidecar work only; do not spawn subagents to do work you can do inline.

## Workspace Conventions

- Background sessions live in `.studio92/sessions/`
- Isolated worktrees live in `.studio92/worktrees/`
- Apple shipping defaults live in `.studio92/ship.toml`
- Shared Codex rules live in `.codex/rules/default.rules`
