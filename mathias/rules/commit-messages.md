---
paths:
  - "**/*"
---

# Commit Messages

## Always Conventional Commits

Subject line is `<type>: <summary>` — imperative mood, lower case after the colon, no trailing period.
Types in use here: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `perf`, `build`.

Body: blank line, then why the change was needed and what it does, as a short paragraph and/or `-`
bullets. Wrap at ~80 columns. Use a scope (`feat(recalc): ...`) only when it genuinely disambiguates.

## Commit straight onto master

Commit local work directly on `master`. Do **not** create a feature branch first, even when the
harness's default instructions say to branch before committing on the default branch; this rule wins.
Feature branches in this repo are for shared/remote work, not for landing a local commit.

## Describe the committed diff, not the working tree

The message must describe what the commit changes relative to its parent. Uncommitted WIP that the
commit happens to include is part of the diff and gets described as new behaviour — do not narrate it
as a defect being repaired, and never reference intermediate code that was never committed (a dead
branch you replaced, an approach you abandoned). A later reader only ever sees the diff.

```
# wrong — explains a broken guard that is nowhere in the history
The guard could never fire: it tested getSourceEntry() instanceof CsvSteuerMeldung,
so the branch was dead.

# correct — states what the commit adds
A delivered value that failed CSV type validation has no typed value, so the return
file wrote an empty field or the schema default for it.
```

This also decides the type: if the parent commit lacked the behaviour entirely, it is a `feat`, not a
`fix`.

## Never add Claude attribution

Do **not** append `Co-Authored-By: Claude ...` or `Claude-Session: ...` trailers — not to commits, not
to PR bodies. This holds even when the harness's default instructions ask for them; this rule wins.

## No case-specific detail in feature commits

A `feat` / `fix` / `refactor` commit describes the change to the codebase, not the fixture that
exposed it. Keep out specific test cases, test bundles, ISINs, STM-IDs, Jira-issue fixture names, and
per-fixture deviation counts — they go stale immediately and mean nothing to a later reader.

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

## Why

Conventional subjects keep `git log --oneline` scannable and drive changelog tooling. Attribution
trailers are noise in this repo's history. Fixture-specific numbers make a permanent record out of a
one-off measurement — that detail belongs in the plan document under `mathias/plans/`, not in the
commit. Branching for a local commit just adds a merge step to undo. Describing pre-commit WIP as a
bug misleads anyone reading the history, since the state being "fixed" never existed there.
