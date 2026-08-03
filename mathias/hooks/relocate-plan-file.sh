#!/usr/bin/env bash
# PostToolUse hook on ExitPlanMode: remind Claude to move the freshly approved
# plan file out of the default ~/.claude/plans into mathias/plans with a
# descriptive name. Workaround for plansDirectory being ignored in project
# scope (anthropics/claude-code#19537).
# Pure bash + findutils — no jq (not on PATH on this NixOS setup).
set -euo pipefail

DEFAULT_PLANS_DIR="/home/sma/.claude/plans"
TARGET_PLANS_DIR="/home/sma/dev/projects/ifas13-agents/mathias/plans"

# Newest plan file written within the last 6 hours; if none, the plan already
# landed elsewhere (e.g. upstream bug fixed) and this hook is a no-op.
plan_file=$(find "$DEFAULT_PLANS_DIR" -maxdepth 1 -name '*.md' -mmin -360 -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | head -n1 | cut -d' ' -f2-)

[ -n "$plan_file" ] || exit 0

# JSON-escape the path (backslash and double quote are enough for filenames).
esc=${plan_file//\\/\\\\}
esc=${esc//\"/\\\"}

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Plan approved. Before starting implementation, relocate the plan file: mv %s %s/<descriptive-kebab-name>.md — derive the name from the plan title/scope (e.g. fristen-skip-when-declined.md), never keep the random session slug."}}\n' \
  "$esc" "$TARGET_PLANS_DIR"
