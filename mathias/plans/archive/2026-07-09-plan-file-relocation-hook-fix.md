# Plan: ExitPlanMode hook to relocate + rename plan files, and fix the plan-naming memory

## Context

Plan files keep landing in `~/.claude/plans/<random-slug>.md` instead of `/home/sma/dev/projects/ifas13-agents/mathias/plans/` with descriptive names. Diagnosis (confirmed this session + upstream issues):

1. The `plansDirectory` setting in the project-local settings (`.claude/settings.local.json` → symlink → `ifas13-agents/mathias/claude-settings.local.json`) is **ignored by Claude Code** — known bug [#19537](https://github.com/anthropics/claude-code/issues/19537) (project-scope `plansDirectory` ignored in favor of the `~/.claude/plans` default), compounded by symlinked-settings issues ([#40857](https://github.com/anthropics/claude-code/issues/40857), [#41259](https://github.com/anthropics/claude-code/issues/41259)). Not fixed as of v2.1.191.
2. The memory `feedback_plan-file-naming.md` says to rename **before** exiting plan mode — which is impossible: plan mode forbids every mutating action except editing the harness-assigned plan file. So the instruction fires at a moment Claude can't act, and after approval it's often forgotten.

Chosen fix (per Mathias): a **PostToolUse hook on ExitPlanMode** that injects a reminder with the concrete file path right when the plan is approved, plus **rewriting the memory** with actionable timing. (Deliberately NOT setting user-scope `plansDirectory` in `~/.claude/settings.json` — it would redirect plans from all other projects too.)

## Changes

All personal config lives in `~/dev/projects/ifas13-agents/mathias/` — nothing goes into the shared ifas13 repo (`.claude/hooks/` there is tracked with a `.gitkeep` and stays untouched).

### 1. Hook script: `~/dev/projects/ifas13-agents/mathias/hooks/relocate-plan-file.sh`

New executable bash script (create the `hooks/` dir). Behavior:

- Find the most recently modified `*.md` in `/home/sma/.claude/plans/` with mtime within the last 6 hours (the plan file is always written moments before `ExitPlanMode`). Use `find -mmin -360` + sort by mtime.
- If none found (e.g. the upstream bug gets fixed and the file already lands in the right dir): exit 0 with no output.
- Otherwise emit PostToolUse JSON on stdout (via `jq -n` for safe escaping):

```json
{"hookSpecificOutput": {"hookEventName": "PostToolUse",
 "additionalContext": "Plan approved. Before starting implementation, relocate the plan file: mv '<found-path>' /home/sma/dev/projects/ifas13-agents/mathias/plans/<descriptive-kebab-name>.md — derive the name from the plan's title/scope (e.g. fristen-skip-when-declined.md), never keep the random session slug."}}
```

### 2. Register the hook: `~/dev/projects/ifas13-agents/mathias/claude-settings.local.json`

Edit the **symlink target directly** (not through the project symlink — avoids the symlink-replacement bug #40857). Two edits:

- Add to the existing `hooks` object:
  ```json
  "PostToolUse": [
    { "matcher": "ExitPlanMode",
      "hooks": [{ "type": "command",
                  "command": "/home/sma/dev/projects/ifas13-agents/mathias/hooks/relocate-plan-file.sh" }] }
  ]
  ```
- Add to `permissions.allow` so the `mv` never prompts:
  `"Bash(mv /home/sma/.claude/plans/* /home/sma/dev/projects/ifas13-agents/mathias/plans/*)"`
- Keep `plansDirectory` in place — harmless, and starts working if upstream fixes #19537 (then the hook's find-nothing path makes it a no-op).

### 3. Rewrite memory: `automemory/feedback_plan-file-naming.md`

Keep name/type and the Why; fix the broken timing and document the hook:

- Renaming is **impossible during plan mode** (read-only; only the harness-assigned file is editable). Do it **immediately after plan approval, as the very first action**: `mv ~/.claude/plans/<slug>.md /home/sma/dev/projects/ifas13-agents/mathias/plans/<descriptive-kebab-name>.md`.
- An ExitPlanMode PostToolUse hook (`mathias/hooks/relocate-plan-file.sh`) injects a reminder with the exact path — follow it, don't skip it.
- Keep the good-name examples and the "pick the name from the plan's title/scope" rule.
- Update the one-line hook for this entry in `MEMORY.md` accordingly (rename happens *after* approval, enforced by hook).

### 4. Dogfood

After approval, move this session's own plan file: `mv ~/.claude/plans/why-does-my-claude-twinkling-emerson.md ~/dev/projects/ifas13-agents/mathias/plans/plan-file-relocation-hook-fix.md`.

## Verification

1. **Script unit test**: run `echo '{"tool_name":"ExitPlanMode"}' | ./relocate-plan-file.sh` with a fresh dummy `.md` in `~/.claude/plans/` — expect valid JSON naming that file; then with no fresh file — expect empty output, exit 0. Validate JSON with `jq`.
2. **Settings sanity**: `jq . claude-settings.local.json` parses; symlink in the ifas13 repo still points at the file (`ls -la`).
3. **End-to-end**: hooks are loaded at session start, so the real test is the next plan-mode session — after approving any plan, the reminder should appear and the mv should run without a permission prompt. (Cannot be tested from within this session.)
