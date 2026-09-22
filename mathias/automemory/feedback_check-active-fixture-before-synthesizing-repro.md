---
name: check-active-fixture-before-synthesizing-repro
description: "When the user is mid-investigation of a specific production/test-environment ticket, check their already-staged scratch fixture (quick-recalc.zip etc.) for the exact scenario before building a synthetic minimal reproduction from scratch."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 1b89b7f7-7c02-49da-a202-ca702a59c468
  modified: 2026-09-21T13:51:11.839Z
---

Spent two expensive forks (~350k tokens each) building and running a guessed synthetic
Jahresmeldung reproduction for an `ERR_UPD_TOLATE` ticket, before the user pointed out the real
scenario was already sitting in `quick-recalc.zip` — the exact CSV/yaml they'd been asking about
since the start of the same conversation. The guess ("Jahresmeldung" in their phrasing was read
as "a CSV row with `Jahresdatenmeldung=JA`") was wrong; the actual record was a plain
Ausschüttungsmeldung.

**Why:** the user routinely stages the real (or server-exported) data for whatever they're
currently debugging in their disposable `quick-recalc` scratch slot before asking about it — per
[[quick-recalc-stale-test-classes]], that fixture is gitignored and swapped between
investigations. Building a parallel synthetic scenario duplicates work they'd already done and
risks testing the wrong shape of data entirely.

**How to apply:** when the user references a specific ticket/work-queue item during an active
investigation, ask what's already staged in their scratch fixtures (or just check
`quick-recalc.zip`'s current contents) before spending effort on a hand-built minimal repro. Only
fall back to synthesizing data once it's confirmed nothing usable already exists.
