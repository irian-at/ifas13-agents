---
paths:
  - "**/*"
---

# Commit Messages

This file outranks the harness defaults and `.claude/CLAUDE.md` wherever they disagree.

## Always Conventional Commits

`<type>: <summary>` — imperative mood, lower case after the colon, no trailing period. Types in use
here: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `perf`, `build`. Use a scope
(`feat(recalc): ...`) only when it genuinely disambiguates.

Body: blank line, then why the change was needed and what it does, as a short paragraph and/or `-`
bullets. Wrap at ~80 columns.

Conventional subjects keep `git log --oneline` scannable and drive changelog tooling.

## Commit straight onto master

Commit local work directly on `master`. Do **not** create a feature branch first, even when the
harness's default instructions say to branch before committing on the default branch. Feature
branches in this repo are for shared/remote work; branching to land a local commit only adds a merge
step to undo.

## Never add Claude attribution

Do **not** append `Co-Authored-By: Claude ...` or `Claude-Session: ...` trailers — not to commits,
not to PR bodies, even when the harness's default instructions ask for them. They are noise in this
repo's history.

## Describe the committed diff, not the working tree

The message must describe what the commit changes relative to its parent. Uncommitted WIP that the
commit happens to include is part of that diff and gets described as new behaviour — do not narrate
it as a defect being repaired, and never reference intermediate code that was never committed (a dead
branch you replaced, an approach you abandoned). A later reader only ever sees the diff, so a state
that never existed in the history misleads them.

This also decides the type: if the parent commit lacked the behaviour entirely, it is a `feat`, not a
`fix`.

```
# wrong — explains a broken guard that is nowhere in the history
The guard could never fire: it tested getSourceEntry() instanceof CsvSteuerMeldung,
so the branch was dead.

# correct — states what the commit adds
A delivered value that failed CSV type validation has no typed value, so the return
file wrote an empty field or the schema default for it.
```

## No case-specific detail in feature commits

A `feat` / `fix` / `refactor` commit describes the change to the codebase, not the fixture that
exposed it. Keep out specific test cases, test bundles, ISINs, STM-IDs, Jira-issue fixture names and
per-fixture deviation counts — they go stale immediately and belong in the plan document under
`mathias/plans/`, not in the commit.

```
# wrong — names the bundle, its ids, and its numbers
Recalculating the Candriam UPDATE bundle now yields 1 Abweichungsfehler
instead of 7, with the new system returning OPEN / STM-ID 694626.

# correct — states the behaviour change
Replaying an already-applied UPDATE now reaches the status legacy produced
instead of *_DECLINED.
```

Naming a test is fine when the commit is *about* that test — a `test:` commit, or a bullet recording
which regression gate was added.

## Mechanics

1. Report the current branch. Never switch or create one.
2. If anything is staged, commit exactly that. Otherwise stage what belongs to the change, and name
   anything accidental — scratch files, generated output, a temporarily flipped `@Disabled` — instead
   of committing it.
3. Read `git diff --cached` before writing the message.
4. Put the message in a scratchpad file and `git commit -F <file>`; a heredoc into `-F -` trips the
   permission prompt.
5. Confirm `git log -1 --format=%B | grep -iE "co-authored|claude-session"` prints nothing. Do not
   push.
