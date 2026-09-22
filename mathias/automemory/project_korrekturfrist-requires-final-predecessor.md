---
name: korrekturfrist-requires-final-predecessor
description: "ERR_UPD_TOLATE (15.12. Korrekturfrist) only fires when a FINAL exists in the meldung's chain; an OPEN meldung that was never confirmed falls back to the plain Meldefrist (GJ-Ende + 7 months) instead, regardless of how far the calendar year has passed. Matches legacy exactly."
metadata: 
  node_type: memory
  type: project
  originSessionId: 1b89b7f7-7c02-49da-a202-ca702a59c468
  modified: 2026-09-21T13:50:47.377Z
---

`SteuerMeldungFristenValidators.errUpdTolate`/`checkKorrekturfrist` only ever gets a non-null
`zuflussDate` — and therefore can only fire — when `findZuflussDateForKorrekturfrist` finds a FINAL:
either the meldung being updated is itself `FINAL`, or it's `OPEN` with a FINAL somewhere back along
its `vorherigeStmId` chain (`findVorherigeFinalSteuerMeldung`).

**An OPEN meldung that was never confirmed to FINAL has no Korrekturfrist gate at all.**
`SteuerMeldungStatusValidationService.validate()` falls back to `meldefristAsLastChance` (GJ-Ende +
`GeschaeftsjahreCalculator.LAST_CHANCE_GRACE_PERIOD` = 7 months) in that case — a much longer window
than 15.12 of the report's own year.

This exactly mirrors legacy `c_st_meldung.cpp:9157-9268` (`CheckVorhandeneMeldung`'s `OPEN` branch):
when no prior FINAL is found in the chain, legacy also skips the Dec-15 test and falls through to
`CheckLieferfristen()` (the same Meldefrist check). Not a migration regression.

**How to apply:** before treating "an UPDATE past 15.12 of the report year was accepted" as a bug,
check whether the targeted meldung has ever been through CONFIRMED→FINAL. If it hasn't, the Meldefrist
(not the Korrekturfrist) legitimately governs — the report was never legally "final" so there is
nothing to "correct" yet. A stricter rule ("reject any update once the calendar year is over,
confirmed or not") is a new business requirement, not a fix — legacy has never enforced that either.

Related: [[gueltbis-active-meldung-discriminator]] (same "guelt_bis is null = active" chain-walk
family), [[checklieferfristen-status-reachability]], [[recalc-historical-fidelity]].
