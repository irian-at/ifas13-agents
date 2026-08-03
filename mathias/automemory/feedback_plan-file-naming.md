---
name: plan-file-naming
description: "Immediately after plan approval, mv the plan file from ~/.claude/plans/<random-slug>.md to mathias/plans/ as YYYY-MM-DD-<descriptive-kebab-name>.md — renaming during plan mode is impossible."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3f16e04c-394e-423d-aa21-90f5c73de4df
---

The harness pre-creates the plan file at `~/.claude/plans/<random-slug>.md` (e.g. `have-a-look-at-elegant-stearns.md`) and ignores the configured `plansDirectory` (upstream bug anthropics/claude-code#19537). Plan mode is read-only — the slug file is the ONLY editable file, so renaming/moving **cannot happen before `ExitPlanMode`**.

**Instead: as the very first action after plan approval**, run

```
mv ~/.claude/plans/<slug>.md /home/sma/dev/projects/ifas13-agents/mathias/plans/YYYY-MM-DD-<descriptive-kebab-name>.md
```

The `YYYY-MM-DD-` prefix is today's date — Mathias uses it to tell new plans from old at a glance, so it is mandatory, not optional. The hook reminder includes the correct prefix.

A global PostToolUse hook on ExitPlanMode (`~/.claude/hooks/relocate-plan-file.sh`, managed via `~/nixos-config/modules/claude-code/`) injects a reminder with the exact source path and per-project target — follow it, don't skip it. It resolves the target from the project's `plansDirectory` setting; without one it renames in place. The old project-level copy at `mathias/hooks/relocate-plan-file.sh` is unregistered and superseded.

Good-name examples:
- `2026-06-16-fix-acceptance-check-and-preserve-input-meldungen.md`
- `2026-06-15-lei-from-steuer-meldung-instead-of-wkndesc.md`
- `2026-06-15-gf2-nur-im-altsystem-analysis.md`
- `2026-07-02-refactor-grouped-validation-msgs-at-csv-domain-boundary.md`

**Why:** Mathias can't find or revisit plans by random slug; the plans dir must be discoverable at a glance. He has flagged this multiple times.

**How to apply:**
- Pick the name from the plan's title/scope, not the session slug.
- Do the `mv` before touching any implementation work.
- Target dir for this project: `/home/sma/dev/projects/ifas13-agents/mathias/plans/`.

Related: [[plan-mode-tilde-path]]
