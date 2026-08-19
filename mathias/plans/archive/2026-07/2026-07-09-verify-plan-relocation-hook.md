# Plan: End-to-end test of the ExitPlanMode relocate hook

## Context

Verification run for the plan-file relocation hook built in the previous session. Static checks passed (permission entry present, hook registered, script executable, no-op path correct). This plan exists solely to trigger the live path.

## Steps

1. Approve this plan → the PostToolUse hook on ExitPlanMode should fire and inject an `additionalContext` reminder naming this file (`~/.claude/plans/why-does-my-claude-twinkling-emerson.md`).
2. I follow the reminder: `mv` this file to `/home/sma/dev/projects/ifas13-agents/mathias/plans/verify-plan-relocation-hook.md`.
3. The `mv` must run without a permission prompt (new allowlist entry).

## Verification

- Hook reminder visible in my context after approval → hook fires in a real session.
- `mv` succeeds promptlessly → permission entry works.
- File lands in `mathias/plans/` with a descriptive name → whole chain works.
