# Studio.92 Agents

Studio.92 is a Codex-compatible Apple app builder. The system should be able to research the live date, inspect the local machine, edit the workspace, verify code, and prepare apps for TestFlight and App Store Connect.

## Model Roles

- `Plan` and `Review`: `Claude Sonnet 4.6`
- `Full Send`: `GPT-5.4`
- `Subagents` and background worktrees: `GPT-5.4 mini`
- `Standards Research`: `GPT-5.4 mini`, escalate to `GPT-5.4` when sources conflict or the task is high-stakes
- `Release / Compliance`: `GPT-5.4`
- `Escalation only`: `Claude Opus 4.6`

## Operating Rules

- Treat Git as the source of truth. Use isolated worktrees for long-running, risky, or parallel tasks.
- Prefer SwiftUI and native Apple frameworks unless the task clearly requires something else.
- Do not recreate old internal design-system layers. Keep generated apps direct, native, and shippable.
- Always use live research when the request depends on current Apple SDK changes, App Store Review Guidelines, privacy manifests, entitlements, signing, TestFlight behavior, or App Store Connect rules.
- Search Apple docs first: `developer.apple.com`, Human Interface Guidelines, App Store Review Guidelines, platform release notes, and Swift evolution updates before broader web search.
- Build and verify real code. Do not stop at a plan when code changes are clearly requested.
- In background worktrees, edit only inside the assigned worktree path unless the user explicitly asks for broader machine access.
- Surface concrete ship blockers first: signing, entitlements, privacy manifests, bundle identifiers, icons, screenshots, metadata, failing builds, and policy issues.
- Keep outputs concise, grounded, and diff-oriented.

## Workspace Conventions

- Background sessions live in `.studio92/sessions/`
- Isolated worktrees live in `.studio92/worktrees/`
- Apple shipping defaults live in `.studio92/ship.toml`
- Shared Codex rules live in `.codex/rules/default.rules`
