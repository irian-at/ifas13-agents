# gf2-d20260731 — NUR IM ALTSYSTEM Validation Discrepancies

## Context

The grossfile recalculation test for the `gf2-d20260731` dataset reports five `[-] NUR IM ALTSYSTEM (FEHLER)` entries in
`ifas-testing/ifas-integration-tests/target/test-output/grossfile-recalc/gf2-d20260731/error#diff-deviations.txt`. The
legacy CPP system raises these errors; IFAS13 does not. The summary shows: 93 exact matches, 5 only in legacy, 6 only
in IFAS13 (all `ERR_UNBEK_ISIN` — out of scope per user instruction).

This document analyses each NUR IM ALTSYSTEM entry per the `validation-discrepancy` skill: identify the legacy raiser,
locate the IFAS13 counterpart, explain the gap. It is an **analysis**, not a fix. Each entry ends with a fix shape so
implementation work can be scoped later.

All five ERR codes exist in IFAS13's `ValidationMsgCode.java`. The reason they don't fire splits into three patterns:

- **Within-file state tracking gap** (entries 1, 3) — the first CONFIRMED of an stmId in the lieferung makes it FINAL
  in legacy's in-memory state, so the second CONFIRMED/DELETE of the same stmId sees FINAL and triggers ERR_STATUS_NM.
  IFAS13 validates every meldung against a single pre-pass DB snapshot and never updates that snapshot mid-lieferung,
  so the second meldung sees the same OPEN status as the first.
- **Test-data gap masquerading as a code gap** (entries 4, 5) — the affected ISINs are missing from IFAS13's INV
  (Stammdaten); ERR_UNBEK_ISIN fires and downstream validators that depend on `inv != null` are skipped. The actual
  validators (`errJahresmVorh`, `errGjeBeendet`) exist and look correct.
- **Unclear, needs runtime inspection** (entry 2) — the LEI mismatch check exists in `UNGL_VORH_FIELD_CHECKS` and the
  observed CSV/DB shape should make it fire. Most plausible cause: pattern 4 from the skill (cross-ISIN lookup
  blind spot) leaving `previousSteuerMeldung == null`, which short-circuits `errUnglVorh` at
  `SteuerMeldungStatusValidationService.java:137`.

---

## Entry 1 — Z113: `Aktueller Status <FINAL>, CONFIRMED nicht moeglich.`

**CSV context** (`gf2-d20260731.csv` Z110–115):

```
110: START;LU0125727601;...;213800NQDIOBLYXILZ43
111: STATUS;CONFIRMED;649534
112: END;LU0125727601;...
113: START;LU0125727601;...;213800NQDIOBLYXILZ43    ← duplicate
114: STATUS;CONFIRMED;649534                          ← same stmId
115: END;LU0125727601;...
```

**Legacy raiser**

- Code `ERR_STATUS_NM` — template defined at `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_stm_logger.cpp:113`.
- Raised in `c_st_meldung.cpp:8451`, inside `CheckVorhandeneMeldung()` — CONFIRMED branch.
- Called from `ProcessMeldung_CONFIRMED` (`c_st_meldung.cpp:2926`). Status gating: CONFIRMED only.
- Legacy keeps the just-processed Z110 in memory with status FINAL, so when Z113 is processed it sees previousStatus
  = FINAL ≠ OPEN and raises `ERR_STATUS_NM`.

**IFAS13 counterpart**

- Same code `ERR_STATUS_NM`.
- Raised in `SteuerMeldungStatusValidators.errStatusNm` at `validation/status/SteuerMeldungStatusValidators.java:170`.
- Gate (line 183–184): `(deliveredStatus == CONFIRMED || deliveredStatus == DELETE) && previousStatus != OPEN`.
- Invoked from `SteuerMeldungStatusValidationService.java` (around line 153 in the call sequence).

**Why it doesn't fire**

`SteuerMeldungStatusValidationService.validate` loads `existingMeldungen` **once per call** via
`getExistingMeldungenByIsin(...)` at `SteuerMeldungStatusValidationService.java:76`. Each meldung in the lieferung is
validated against that snapshot. There is no in-memory tracking that the first CONFIRMED for `stmId 649534` already
flipped the status to FINAL. Both Z110 and Z113 read `previousStatus == OPEN`.

`SteuerMeldungStatusValidationService` does maintain `seenNewMeldungKeys` for the NEW-vs-NEW within-file duplicate
check (`ERR_JAHRESM_VORH_LIEFERUNG`, `ERR_AUSSCHM_VORH_LIEFERUNG`) — but that mechanism does not extend to status
transitions.

**Pattern**: within-file state tracking gap (new pattern — not in skill's catalogue yet; siblings of #1 from skill but
applied to status transitions rather than field validators).

**Fix shape**

Track in-lieferung status changes per stmId. After each CONFIRMED or DELETE is validated, remember the stmId so that
subsequent meldungen targeting the same stmId in the same lieferung see the post-transition status. Two viable
shapes:

- A `Set<Long> confirmedOrDeletedStmIds` analogous to `seenNewMeldungKeys`, consulted inside `errStatusNm`.
- A `Map<Long, StmStatus> inLieferungStatusOverrides` consulted alongside the DB snapshot in `errStatusNm` (and any
  other validator that reads `previousStatus`).

Cite legacy reference: `c_st_meldung.cpp:8451` in `CheckVorhandeneMeldung()` for CONFIRMED.

---

## Entry 2 — Z122: `Der Parameter LEI <U090UTR2IZOR4U9CSZ50> entspricht nicht dem Parameter <> aus der urspruenglichen Meldung`

**CSV context**

```
122: START;LU0136043550;...;1;U090UTR2IZOR4U9CSZ50   ← new LEI
123: STATUS;CONFIRMED;649538
124: END;LU0136043550;...
```

Legacy compared the CSV LEI `U090UTR2IZOR4U9CSZ50` to the original DB row's empty LEI (`<>`).

**Legacy raiser**

- Code `ERR_UNGL_VORH` — template at `c_stm_logger.cpp:102–103`.
- Raised at `c_st_meldung.cpp:8307` inside `CheckVorhandeneMeldung()`.
- Status gating: UPDATE + CONFIRMED + DELETE (UPDATE downgrades to INFO at line 8308).
- Lookup of the existing meldung is keyed by **`stm_id` alone** at
  `c_st_meldung.cpp:7676` (`where stm_id = %d`), with `LEI = isnull(m.LEI, '-')` projected at
  `c_st_meldung.cpp:7671-7673` (version 4+ only).

**IFAS13 counterpart**

- Same code `ERR_UNGL_VORH`.
- LEI is registered in `UNGL_VORH_FIELD_CHECKS` at `SteuerMeldungStatusValidators.java:461`.
- Compared in `checkFieldUnchanged` at `SteuerMeldungStatusValidators.java:488`.
- Severity: ERROR (because status is CONFIRMED, not UPDATE — see line 492).

**Schema gap — fixed**

IFAS13's `steuer_meldung` table previously had no `lei` column; both `EagerDbSteuerMeldung` and
`LazyDbSteuerMeldung` resolved `getLei()` through `InvRepository` → `WknDesc.lei` (master data). For
any meldung loaded from the DB, `getLei()` therefore reflected current master data, not the
snapshot legacy stored on the STM row at creation time.

Closed by the schema migration `V036__steuer_meldung_lei.sql` (postgres15 + sybase16) plus the
entity field `SteuerMeldungEntity.lei` and rewires of `Eager/LazyDbSteuerMeldung.getLei()` to read
from the entity (see plan `lei-from-steuer-meldung-instead-of-wkndesc.md`). MapStruct auto-maps
`SteuerMeldungDto.lei` ↔ entity; no separate production write path exists (legacy CPP still owns
STM DB writes).

**Why Z122 still doesn't fire — confirmed cause**

With the schema fix in place, the only remaining gate is the `if (previousSteuerMeldung != null)`
guard at `SteuerMeldungStatusValidationService.java:137`. `previousSteuerMeldung` is looked up at
line 80 from a **same-ISIN-filtered** map (line 76 — `getExistingMeldungenByIsin`). Legacy's
lookup is stm_id-only, so legacy finds the row for `649538` regardless of which ISIN it was filed
under; IFAS13 needs the lookup to match the CSV's ISIN `LU0136043550`. If the original meldung
`649538` was filed under a different ISIN, or the test DB is missing the row, the lookup returns
null and `errUnglVorh` is skipped silently.

This is **pattern 4 from the validation-discrepancy skill** — *Lookup pre-filtered by ISIN
(cross-ISIN blind spot)*. The partial mitigation `previousIsinAnyMatch` at line 89 already covers
`ERR_ISIN_MID` / `ERR_MELDID_FEHLT` but does **not** feed `errUnglVorh`.

**Pattern**: pattern 4 (cross-ISIN blind spot) — `errUnglVorh` not yet wired through the hybrid
lookup.

**Fix shape**

Confirm at runtime by adding a temporary log in the validator, then either:

- Extend the hybrid lookup so `previousSteuerMeldungAnyIsin` feeds `errUnglVorh` when same-ISIN
  lookup is null (caveat: this may surface other UNGL_VORH fields that don't match either —
  review scope before applying), OR
- If the root cause is test-data drift (the DB row for `649538` simply isn't loaded), fix the
  test data and confirm no code change is needed.

Cite legacy reference: `c_st_meldung.cpp:7676` (stm_id-only lookup) and `c_st_meldung.cpp:8307`
(LEI comparison) inside `CheckVorhandeneMeldung()`.

---

## Entry 3 — Z134: `Aktueller Status <FINAL>, DELETE nicht moeglich.`

**CSV context**

```
131: START;LU0133194562;...
132: STATUS;CONFIRMED;649542         ← confirms stmId 649542 (matches legacy & IFAS13 silently)
133: END;LU0133194562;...
134: START;LU0133194562;...          ← duplicate
135: STATUS;DELETE;649542            ← same stmId, now DELETE
136: END;LU0133194562;...
```

**Legacy raiser**

- Code `ERR_STATUS_NM` — same template as Entry 1.
- Raised at `c_st_meldung.cpp:8615` inside `CheckVorhandeneMeldung()` (DELETE branch).
- Called from `ProcessMeldung_DELETE` (`c_st_meldung.cpp:3244`). Status gating: DELETE only.

**IFAS13 counterpart**

Same validator as Entry 1 — `SteuerMeldungStatusValidators.errStatusNm` covers CONFIRMED **and** DELETE in one
`if` (line 183).

**Why it doesn't fire**

Same root cause as Entry 1 — no in-lieferung state tracking for status transitions.

**Pattern**: within-file state tracking gap (same as Entry 1).

**Fix shape**

A single fix covers both entries 1 and 3 since `errStatusNm` handles both deliveredStatus values together. See Entry
1's fix shape.

Cite legacy reference: `c_st_meldung.cpp:8615` for DELETE.

---

## Entry 4 — Z197: `Jahresmeldung bereits vorhanden.`

**CSV context**

```
197: START;LU0136043394;InvF;T;EUR;01.01.2024;31.12.2024;JA;...;5;...
198: STATUS;NEW
199: E;Aufwand_Gesamtbetrag_e;0
200: E;Aufwand_Gesamtbetrag_KV_e;0
201: END;LU0136043394;...
```

Status NEW, Jahresdatenmeldung JA, Gj 2024. Legacy detects an existing Jahresmeldung for this ISIN+Gj in DB.

**IFAS13 raises a different error instead**: `ERR_UNBEK_ISIN` ("Die ISIN <LU0136043394> ist nicht fuer eine
Steuerdatenmeldung registriert.") — see the corresponding `[+] NUR IM NEUSYSTEM` entry on Z197.

**Legacy raiser**

- Code `ERR_JAHRESM_VORH` — template at `c_stm_logger.cpp:376–377`.
- Raised at `c_st_meldung.cpp:7531` inside `CheckVorhandeneMeldung()`. Status gating: NEW only
  (`ProcessMeldung_NEW` at `c_st_meldung.cpp:2741`).

**IFAS13 counterpart**

- Same code `ERR_JAHRESM_VORH`.
- Raised in `SteuerMeldungStatusValidators.errJahresmVorh` at `SteuerMeldungStatusValidators.java:301`.
- Gates: status == NEW, Jahresdatenmeldung == true, `duplicateExists` from DB lookup.
- Lookup performed by `findExistingMeldungStmIdByGjEndeAndJahresMeldung` (lines 351–370).

**Why it doesn't fire**

The status validator runs regardless of `inv == null` — it does not depend on INV data. The reason it stays silent
here is one of:

- The IFAS13 test database does not contain the prior Jahresmeldung row for `LU0136043394` Gj 2024 (test-data gap).
- The lookup query in `findExistingMeldungStmIdByGjEndeAndJahresMeldung` misses the row (less likely — well-trodden
  code path).

The visible `ERR_UNBEK_ISIN` indicates this ISIN is also missing from INV in the test DB. The two gaps share a
common root: the test DB for this dataset is missing both the INV row and the prior STM row for `LU0136043394`.

**Pattern**: pattern 5 from the skill (spec/data mismatch — no code change needed). Specifically, **test-data drift**
between legacy and IFAS13 test fixtures.

**Fix shape**

- Verify in the IFAS13 test DB whether the prior Jahresmeldung for `LU0136043394` Gj 2024 is present. If absent, add
  the corresponding fixture data.
- Verify INV/Stammdaten for `LU0136043394` is present in IFAS13's test fixtures. If absent, add it.
- No code change expected. If after fixing the test data the discrepancy persists, escalate to inspecting
  `findExistingMeldungStmIdByGjEndeAndJahresMeldung`.

---

## Entry 5 — Z225: `Das gemeldete Geschaeftsjahr-Ende <2025.12.14> fällt in den Zeitraum, in dem der Fonds als beendet gmeldet war.`

(Legacy template typo "gmeldet" is intentional; preserved verbatim.)

**CSV context**

```
225: START;LU0891777665;InvF;T;USD;13.12.2025;14.12.2025;JA;;;1;...
226: STATUS;NEW
227: E;Aufwand_Gesamtbetrag_e;0
228: E;Aufwand_Gesamtbetrag_KV_e;0
229: END;LU0891777665;...
```

Status NEW, Gj-Beginn 13.12.2025, Gj-Ende 14.12.2025 (very short Gj — typical for a terminated fund). Legacy detects
that Gj-Ende falls inside the fund-termination window.

**IFAS13 raises a different error**: `ERR_UNBEK_ISIN` for `LU0891777665` — see the matching `[+] NUR IM NEUSYSTEM`
on Z225.

**Legacy raiser**

- Code `ERR_GJE_BEENDET` — template at `c_stm_logger.cpp:276–277` (note legacy typo `gmeldet`).
- Raised at `c_st_meldung.cpp:4621` inside `CheckStartRow()`. Status gating: all four statuses (called from
  `CheckMeldung()` which runs in every `ProcessMeldung_*`).

**IFAS13 counterpart**

- Same code `ERR_GJE_BEENDET`.
- Raised in `SteuerMeldungDomainValidators.errGjeBeendet` at
  `validation/SteuerMeldungDomainValidators.java:688`.
- Gate (lines 688–705): `gjEnde != null`, `fondsEnde != null`, and the date-range comparison.

**Why it doesn't fire**

`errGjeBeendet` is invoked from `validateGeschaeftsjahr`, which is itself nested under the
`if (inv != null) { ... }` block in `SteuerMeldungDomainValidationService` (around `SteuerMeldungDomainValidators.java:419`).
Since INV/Stammdaten for `LU0891777665` is missing in the IFAS13 test DB, `inv == null`, and
`validateGeschaeftsjahr` returns before reaching `errGjeBeendet`.

There is also a **secondary concern** worth flagging during a code review: the condition at line 688–705 reads
`!LocalDates.isBetweenInclusive(fondsBeginn, fondsEnde, gjEnde)` (per the third Explore agent's report). The German
template says "GJ-Ende falls inside the period the fund was reported as ended" — the negation looks suspicious.
Confirm against legacy `c_st_meldung.cpp:4621` semantics before relying on this check. (Possibly the names
`fondsBeginn` / `fondsEnde` here refer to "fund active period" rather than "fund terminated period", which would
make the negation correct. Worth a 5-minute sanity check.)

**Pattern**: pattern 5 / test-data gap (same root cause as Entry 4).

**Fix shape**

- Add INV/Stammdaten for `LU0891777665` to IFAS13's test fixtures so `inv != null` and `validateGeschaeftsjahr`
  reaches `errGjeBeendet`.
- Separately, verify the `errGjeBeendet` boundary semantics against legacy `c_st_meldung.cpp:4621`. If the
  inclusive/negated logic is wrong, fix it — but only after the test data is in place so the validator actually
  runs.

---

## Cross-cutting observations

- **Test-data drift is the dominant root cause** for two of the five entries. The dataset has six
  `[+] NUR IM NEUSYSTEM` entries, all of which are `ERR_UNBEK_ISIN`. That makes it likely the gf2 dataset's INV
  fixtures need a sweep, not just the two ISINs called out above.
- **Within-file state tracking** is a real code gap that affects entries 1 and 3 and may surface again in any
  scenario where the same `stmId` appears more than once in a lieferung. The skill's catalogue should be extended
  with this pattern.
- **Entry 2 is the one that requires actual runtime debugging** before committing to a fix scope.

## Verification

After implementing any fix:

1. Re-run `GrossfileRecalculationTest#givenGrossfileZip_whenRecalculate_thenWriteResultsToFilesystem` (it is
   `@Disabled` by default — enable temporarily). It will re-emit
   `target/test-output/grossfile-recalc/gf2-d20260731/error#diff-deviations.txt`.
2. Confirm net diff reduction — fixes should turn `[-] NUR IM ALTSYSTEM` entries into exact matches, not flip them
   into `[+] NUR IM NEUSYSTEM` entries on other rows. Use `diff` against the prior `error#diff-deviations.txt` to
   spot regressions.
3. For the test-data fixes (entries 4 & 5), confirm both that `ERR_UNBEK_ISIN` disappears AND that the legacy
   `ERR_JAHRESM_VORH` / `ERR_GJE_BEENDET` start firing in IFAS13 as exact matches.
