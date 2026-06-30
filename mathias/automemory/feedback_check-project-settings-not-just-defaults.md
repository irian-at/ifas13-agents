---
name: check-project-settings-not-just-defaults
description: Before using a default path the plan-mode prompt or system prompt suggests (plans dir, memory dir, etc.), check claude-settings.local.json for an override. Same rule as autoMemoryDirectory — it applies to plansDirectory too.
metadata:
  type: feedback
---

When the plan-mode system prompt proposes a default file path (e.g.
`/home/sma/.claude/plans/<slug>.md`) or when a system reminder names a
default directory, do **not** just go along with it. First check
`/home/sma/dev/projects/ifas13-agents/mathias/claude-settings.local.json`
for an override key. As of 2026-06-17 the keys that override defaults are:

- `plansDirectory` → `/home/sma/dev/projects/ifas13-agents/mathias/plans`
- `autoMemoryDirectory` → `/home/sma/dev/projects/ifas13-agents/mathias/automemory`

**Why:** CLAUDE.local.md highlights `autoMemoryDirectory` only; I forgot
that the same logic applies to `plansDirectory`, dropped three plan files
in `~/.claude/plans/`, and Mathias couldn't find them in his IDE. Both
overrides live in `claude-settings.local.json` and both should be honored.

**How to apply:** When entering plan mode for the first time in a
session, read `claude-settings.local.json` once and write plan/memory
files to the configured directories — not to the paths suggested by
default prompts. If the file path in the plan-mode system reminder
points at `~/.claude/...`, treat that as a default-prompt artifact and
relocate.

Related: [[only-change-what-was-asked]],
[[plan-file-naming]].
