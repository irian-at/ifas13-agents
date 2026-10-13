---
paths:
  - "**/plans/*.md"
---

# Plan File Naming

Plan files live in `/home/sma/dev/projects/ifas13-agents/mathias/plans/` and are named
`YYYY-MM-DD-<descriptive-kebab-name>.md`. The date prefix is **mandatory** — Mathias uses it to tell
new plans from old at a glance.

```
2026-06-16-fix-acceptance-check-and-preserve-input-meldungen.md
2026-07-02-refactor-grouped-validation-msgs-at-csv-domain-boundary.md
```

## How to apply

The harness writes the plan under a random session slug (`have-a-look-at-elegant-stearns.md`) into
`plansDirectory` (older versions: `~/.claude/plans/`). Plan mode is read-only, so the rename is
**the very first action after plan approval**, before any implementation work:

```bash
mv <plans>/<slug>.md <plans>/YYYY-MM-DD-<descriptive-kebab-name>.md
```

A `PostToolUse` hook on `ExitPlanMode` (`~/.claude/hooks/relocate-plan-file.sh`, managed in
`~/nixos-config/modules/claude-code/`) injects a reminder with the exact source path, today's date
prefix and the target directory. Follow it.

- Take the name from the plan's title and scope, never from the session slug.
- Never keep the random adjective-noun slug (`-crispy-hippo`, `-distributed-peach`).
