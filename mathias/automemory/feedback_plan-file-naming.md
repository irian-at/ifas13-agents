---
name: plan-file-naming
description: Plan files must be renamed from the random session slug to a descriptive name reflecting the plan content before exiting plan mode.
metadata:
  type: feedback
---

When entering plan mode, the harness pre-creates a plan file with a random session slug (e.g. `have-a-look-at-elegant-stearns.md`, `do-you-have-a-ticklish-seal.md`, `clever-leaping-bird.md`). Before calling `ExitPlanMode`, **rename the file to a descriptive kebab-case name reflecting what the plan actually does**.

Examples from this project's plans dir that follow the rule:
- `fix-acceptance-check-and-preserve-input-meldungen.md`
- `lei-from-steuer-meldung-instead-of-wkndesc.md`
- `gf2-nur-im-altsystem-analysis.md`
- `refactor-grouped-validation-msgs-at-csv-domain-boundary.md`

**Why:** The user can't find or revisit plans by their random slug — and we have a growing `plans/` directory where every file needs to be discoverable at a glance. Mathias has flagged this twice now.

**How to apply:**
- Pick the name from the plan's title/scope, not the session slug.
- Rename in the same step as writing the final content — before `ExitPlanMode`.
- The plans live at `/home/sma/dev/projects/ifas13-agents/mathias/plans/` for this project.

Related: [[plan-mode-tilde-path]]
