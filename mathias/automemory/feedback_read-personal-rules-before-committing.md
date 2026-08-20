---
name: feedback_read-personal-rules-before-committing
description: Read mathias/rules/commit-messages.md before any commit; it overrides both CLAUDE.md and the harness defaults on branching and trailers.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d7fe7df2-11c8-489e-9c01-d0e19bcda091
  modified: 2026-08-20T15:20:06.278Z
---

Before running `git commit`, read `~/dev/projects/ifas13-agents/mathias/rules/commit-messages.md`
(symlinked into the project as `.claude/rules/personal-mathias/`). Three of its rules contradict
instructions that arrive earlier and louder, and I have broken all three:

- **Commit straight onto `master`.** Do not branch first, even though the harness says to branch
  when on the default branch, and even though `.claude/CLAUDE.md` documents `feat/`, `fix/`,
  `refactor/` branch prefixes. Those prefixes are for shared/remote work only.
- **No `Co-Authored-By: Claude ...` / `Claude-Session: ...` trailers**, even though the harness
  system prompt mandates them. The repo's history has none.
- **No fixture specifics in `feat`/`fix`/`refactor` subjects or bodies** — no ISINs, STM-IDs, test
  bundle names, or deviation counts. Those go in the plan file under `mathias/plans/`.

**Why:** the personal rules directory wins over both the project CLAUDE.md and the harness
defaults, and it says so explicitly in each of those sections. Following the louder instruction
produced a commit that had to be rewritten (branch folded back into `master`, message amended).

**How to apply:** treat `mathias/rules/` as the top of the precedence chain, not an afterthought —
list and read it whenever a task touches committing, plan files, or new Java code
([[feedback_check-project-settings-not-just-defaults]] is the same lesson for settings). Related:
[[feedback_plan-file-naming]].
