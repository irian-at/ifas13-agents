---
description: File old plan documents into plans/archive/YYYY-MM month folders and commit the moves
argument-hint: "[days|all] [--dry-run]"
disable-model-invocation: true
allowed-tools: Bash(/home/sma/dev/projects/ifas13-agents/mathias/commands/archive-plans.sh:*)
---

# Archive Plans

Keep the plans directory down to what is still current by filing older plans away by month.

Run this once, exactly as written:

```bash
/home/sma/dev/projects/ifas13-agents/mathias/commands/archive-plans.sh $ARGUMENTS
```

The script resolves `plansDirectory` from the project settings on its own, moves every plan past
the cutoff into `<plans>/archive/YYYY-MM/`, sweeps loose files lying directly in `archive/` into
their month folder as well, and commits the moves in the repository holding the plans. The month
comes from the plan's `YYYY-MM-DD` filename prefix, or from its mtime when it has no prefix.

## Arguments

| Invocation | Effect |
|---|---|
| `/archive-plans` | plans older than 7 days |
| `/archive-plans 60` | plans older than 60 days |
| `/archive-plans all` | every plan |
| `/archive-plans --dry-run` | list the moves, change nothing, no commit |

## After the run

Report how many plans were archived and the commit subject. Do not push.

`skipped (target exists)` means a plan of that name already sits in the month folder — name those
files and leave them for the user to decide. Beyond that, do not move, rename, or edit plan files
yourself; the script is the only thing that touches them.
