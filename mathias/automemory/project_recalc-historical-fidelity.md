---
name: recalc-historical-fidelity
description: When recalculating an old SteuerMeldung version V, IFAS13 must reproduce the validator output legacy would have produced at the time V was current — not legacy's current behavior. Version gates that look redundant may be intentional.
metadata:
  type: project
---

When IFAS13 recalculates a SteuerMeldung of schema version V (≤ current legacy version), the validators applied must match the legacy CPP behavior **at the time meldungen of version V were being processed live** — not legacy's current behavior. Replays of old recalcs are expected to produce the same result legacy produced back then.

**Why:** Stakeholders use recalc to compare historical outcomes. If legacy's behavior changes later (e.g. a validator is suppressed by an OeKBSD change), and IFAS13 mirrors only current legacy, old recalcs would diverge from their historical reference. Grossfile fixture logs inside the zips were captured at creation time and are the reference.

**How to apply:**
- Don't "clean up" a `if (steuerMeldung.getVersionsNr() < N)` gate around a validator just because it looks like dead code or a divergence. Check whether legacy CPP changed its behavior for versions < N at some point (look for `OeKBSD-…` dated comment-outs in `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp`).
- Concrete example: `infoLeiUngleich` at `SteuerMeldungDomainValidationService.java:309` is gated `< 6` because OeKBSD-733943 (2026-05-18) commented out the `INFO_LEI_UNGLEICH` writes in legacy. For v6+ both systems are silent; for ≤ v5 IFAS13 must still fire so historical recalcs match the pre-2026-05-18 fixture logs.
- When introducing a similar gate, cite the legacy `OeKBSD-…` ticket in the commit message so the rationale doesn't get lost.
- Grossfile baselines and `[+]/[-]` deviations may legitimately include legacy-only entries that current legacy wouldn't emit — those are stale-by-design (fixture logs predate legacy changes).

Related: [[only-change-what-was-asked]].