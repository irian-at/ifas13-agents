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
commit.
