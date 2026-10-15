---
name: test-stage-nightly-deploy
description: "TEST deploys master nightly, so a migration pushed today has reached no DB yet; it may still be edited until the nightly run"
metadata:
  node_type: memory
  type: project
  originSessionId: 30601363-4040-41b1-9298-d52b746f6eab
  modified: 2026-10-15T11:04:59.362Z
---

The TEST stage deploys `master` every night (user, 2026-10-15). A Flyway script pushed to `master`
today has not run on any stage database yet.

**Why:** `database-conventions.md` freezes every script on `master`, because once a stage has applied
it, an edit breaks startup with a checksum mismatch. Before the nightly deploy, nothing has applied it.

**How to apply:** Editing a same-day migration on `master` is acceptable only when:
- the edit is pushed before that night's deploy (otherwise TEST applies the old version and the edited
  one fails validation the next night)
- nobody ran it on a persistent local Postgres in the meantime (if someone did, they need
  `flyway repair` or a fresh volume; H2 and Testcontainers are unaffected)

The user chose this for V084 (`rueckmeldung_level` → `rueckmeldung_status`) instead of adding V085,
because he wants one Flyway file per rename feature. See [[naming]].
