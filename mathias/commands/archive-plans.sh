#!/usr/bin/env bash
# Move plan files out of the plans directory into archive/YYYY-MM/ month folders.
#
# The month comes from the plan's own date: the YYYY-MM-DD filename prefix if it
# has one, otherwise the file's mtime. Loose files sitting directly in archive/
# are swept into their month folder too, so a run always leaves the archive
# uniform and repeated runs are no-ops.
#
# usage: archive-plans.sh [<days>|all] [--dry-run] [--plans-dir <dir>]
#          <days>  archive plans older than that many days (default 7)
#          all     archive every plan
set -euo pipefail

# --- arguments ---------------------------------------------------------------
CUTOFF_DAYS=7
DRY_RUN=0
PLANS_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    all)                CUTOFF_DAYS=-1 ;;
    -n|--dry-run)       DRY_RUN=1 ;;
    --plans-dir)        PLANS_DIR="${2:-}"; shift ;;
    -h|--help)          sed -n '2,10p' "$0"; exit 0 ;;
    ''|*[!0-9]*)        echo "usage: $(basename "$0") [<days>|all] [--dry-run]" >&2; exit 2 ;;
    *)                  CUTOFF_DAYS="$1" ;;
  esac
  shift
done

# --- resolve the plans directory (same lookup as relocate-plan-file.sh) -------
if [ -z "$PLANS_DIR" ]; then
  project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  for f in "$project_dir/.claude/settings.local.json" \
           "$project_dir/.claude/settings.json" \
           "$HOME/.claude/settings.json"; do
    [ -f "$f" ] || continue
    t=$(grep -o '"plansDirectory"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
      | head -n1 | sed 's/.*"\([^"]*\)"$/\1/') || true
    [ -n "${t:-}" ] || continue
    case "$t" in
      "~/"*) PLANS_DIR="$HOME/${t#\~/}" ;;
      /*)    PLANS_DIR="$t" ;;
      *)     PLANS_DIR="$project_dir/$t" ;;
    esac
    break
  done
fi
[ -n "$PLANS_DIR" ] || PLANS_DIR="$HOME/.claude/plans"
[ -d "$PLANS_DIR" ] || { echo "no plans directory at $PLANS_DIR" >&2; exit 1; }
PLANS_DIR=$(cd "$PLANS_DIR" && pwd)
ARCHIVE_DIR="$PLANS_DIR/archive"

# --- move plans into archive/YYYY-MM/ ----------------------------------------
today_s=$(date +%s)
moved=()
skipped=0

plan_date() {
  local base
  base=$(basename "$1")
  if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    date -r "$1" +%Y-%m-%d
  fi
}

archive_file() {
  local src="$1" month dst
  month=$(plan_date "$src"); month="${month:0:7}"
  dst="$ARCHIVE_DIR/$month/$(basename "$src")"
  if [ -e "$dst" ]; then
    echo "  skipped (target exists): ${src#"$PLANS_DIR"/}" >&2
    skipped=$((skipped + 1))
    return
  fi
  echo "  ${src#"$PLANS_DIR"/} -> ${dst#"$PLANS_DIR"/}"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$ARCHIVE_DIR/$month"
    mv "$src" "$dst"
  fi
  moved+=("$src" "$dst")
}

echo "plans directory: $PLANS_DIR"
if [ "$CUTOFF_DAYS" -lt 0 ]; then
  echo "archiving: every plan"
else
  echo "archiving: plans older than $CUTOFF_DAYS days"
fi
[ "$DRY_RUN" -eq 0 ] || echo "(dry run — nothing is moved)"

shopt -s nullglob
for f in "$PLANS_DIR"/*.md; do
  d=$(plan_date "$f")
  age=$(( (today_s - $(date -d "$d" +%s)) / 86400 ))
  if [ "$CUTOFF_DAYS" -lt 0 ] || [ "$age" -gt "$CUTOFF_DAYS" ]; then
    archive_file "$f"
  fi
done

# loose files already in archive/ belong in a month folder too
for f in "$ARCHIVE_DIR"/*.md; do
  archive_file "$f"
done

count=$(( ${#moved[@]} / 2 ))
if [ "$count" -eq 0 ]; then
  if [ "$skipped" -gt 0 ]; then
    echo "nothing to archive ($skipped skipped)"
  else
    echo "nothing to archive"
  fi
  exit 0
fi
echo "$count plan(s) archived"

# --- commit ------------------------------------------------------------------
[ "$DRY_RUN" -eq 0 ] || exit 0
if ! git -C "$PLANS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not a git work tree — no commit"
  exit 0
fi

if [ "$CUTOFF_DAYS" -lt 0 ]; then
  msg="chore: archive all plans by month"
else
  msg="chore: archive plans older than $CUTOFF_DAYS days"
fi
# A moved source path that git never tracked matches no pathspec and would abort
# the whole add; keep only paths git can resolve.
paths=()
for p in "${moved[@]}"; do
  if [ -e "$p" ] || git -C "$PLANS_DIR" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    paths+=("$p")
  fi
done
git -C "$PLANS_DIR" add -A -- "${paths[@]}"
git -C "$PLANS_DIR" commit -q -m "$msg" -- "${paths[@]}"
git -C "$PLANS_DIR" --no-pager log --oneline -1
