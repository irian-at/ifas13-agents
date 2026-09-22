---
paths:
  - "**/plans/*.md"
---

# Plan File Naming

Plan files live in `/home/sma/dev/projects/ifas13-agents/mathias/plans/` and are named
`YYYY-MM-DD-<descriptive-kebab-name>.md`. The date prefix is **mandatory**, not decoration —
Mathias uses it to tell new plans from old at a glance.

```
2026-06-16-fix-acceptance-check-and-preserve-input-meldungen.md
2026-06-15-lei-from-steuer-meldung-instead-of-wkndesc.md
2026-07-02-refactor-grouped-validation-msgs-at-csv-domain-boundary.md
```

## The rename cannot happen during plan mode

The harness pre-creates the plan at `~/.claude/plans/<random-slug>.md` (e.g.
`have-a-look-at-elegant-stearns.md`) and ignores the configured `plansDirectory` (upstream bug
anthropics/claude-code#19537). Plan mode is read-only and that slug file is the only writable file,
so the move **cannot** be done before `ExitPlanMode` — do not try to "override the suggested path
before writing".

**As the very first action after plan approval, before any implementation work:**

```bash
mv ~/.claude/plans/<slug>.md \
   /home/sma/dev/projects/ifas13-agents/mathias/plans/YYYY-MM-DD-<descriptive-kebab-name>.md
```

A global `PostToolUse` hook on `ExitPlanMode`
(`~/.claude/hooks/relocate-plan-file.sh`, managed via `~/nixos-config/modules/claude-code/`) injects
a reminder carrying the exact source path, today's date prefix and the resolved per-project target.
Follow it; don't skip it.

## How to apply

- Take the name from the plan's title and scope, never from the session slug.
- Do the `mv` before touching any implementation work.
- Never keep the harness's random adjective-noun slug (`-crispy-hippo`, `-distributed-peach`).

## Why

Mathias can't find or revisit plans by random slug, and an undated plans directory doesn't show at
a glance what is current. He has flagged this multiple times.
