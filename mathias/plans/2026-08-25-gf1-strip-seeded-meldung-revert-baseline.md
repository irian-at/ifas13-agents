# Clean gf1's pre-state, revert its baseline

## Context

The `findAllStmIdsByIsin` Stichtag-predicate fix (already implemented and green) unhid the ISIN
lookup for funds whose `WKN_HIST` row ends in the future. One side effect: gf1 gained an
only-in-new `ERR_JAHRESM_VORH` on `IE0003921727`, and the baseline was bumped 10 → 11.

Investigation showed that bump is the wrong fix.

- `INV.fondsEnde = 2026-08-03` (set by the open `INV_H` row `gueltAb 2026-02-17`), with a
  SYSTEM-generated Rumpf-`GESCHAEFTSJAHR` `2026-01-01 … 2026-08-03`, `gjTyp E`.
- gf1's Stichtag is 2026-07-24, so the fund is **not** ended yet. Legacy's rule
  (`c_st_meldung.cpp:4994-5008`) is a delivery window: `gjEnde - 7d = 2026-07-27`; later than the
  Stichtag ⇒ `ERR_GJ_FE_ZUKUNFT`. The Jahresmeldung was delivered 3 days too early.
- The duplicate it collides with, STM 649492, was created by `gf2a-d20260731.csv`
  (`STEUER_MELDUNG_FILE` fileId 348755, 14:17 on 2026-02-25) — a delivery whose Stichtag
  (31.07) is *inside* the window. gf1 ran at 17:07 the same day.

So in the intended timeline gf1 (24.07) precedes gf2a (31.07) and its pre-state holds no meldung
for that ISIN. The fixture was seeded in the wrong order.

Removing 649492 does **not** invalidate the captured legacy logs: `ERR_GJ_FE_ZUKUNFT` is raised in
`CheckStartRow` (`c_st_meldung.cpp:5001`), which sets `nProcessingStatus = -1` and gates the
`CheckVorhandeneMeldung` call at `:2803`. Legacy never reaches its vorhanden-check, so its
`error.log`, `info.log` and return record are identical with or without 649492. It is also the
only meldung in that snapshot, so no other ISIN is touched.

## Change

### 1. Strip STM 649492 from gf1's pre-state

`ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/gf1-d20260724.zip`
→ entry `gf1-d20260724/gf1-d20260724-export.yaml.txt`.

Remove these entity blocks (1126 of the file's 9101 entities):

| Entity | Count | Key |
|---|---|---|
| `STEUER_MELDUNG` | 1 | `id: 649492` |
| `STEUER_FIELDS_DATA` | 974 | `stmId: 649492` |
| `STEUER_BEH_DATA` | 151 | `stmId: 649492` |
| `STEUER_MELDUNG_FILE` | 1 | `fileId: 348755` (only referenced by 649492) |

Nothing else references 649492 — no `vorherigeStmId`, and the `GESCHAEFTSJAHR` rows for
`wfsWkn 34993` carry other stmIds (the 2026 Rumpf-GJ row has none).

Rewrite the zip with a script that copies every other entry byte-for-byte, preserving each
entry's name, `compress_type` and `date_time`, so the diff is confined to the one yaml.

### 2. Revert the gf1 baseline

`ifas-testing/.../recalc/GrossfileRecalculationTest.java:215` — error `SummaryExpectation` back to
`(315, 2, 8, 3, 10, 0)` and drop the `ERR_JAHRESM_VORH` comment added for the bump.

## Verification

```bash
mvn -o test -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest \
    -Pskip-postgres15-tests -Pskip-sybase16-tests
```

Expect all 8 datasets green with gf1 at `onlyInNewError = 10`. Then confirm the meldung's block in
`target/grossfile-recalc/gf1-d20260724/error#diff.txt` shows only the `[=] EXAKTER TREFFER` for
`ERR_GJ_FE_ZUKUNFT` and no `[+] NUR IM NEUSYSTEM`. Finish with the full module regression
(`-pl ifas-domain/ifas-domain-stm,ifas-testing/ifas-integration-tests -Pskip-sybase16-tests`),
which last ran green at 1277 + 641 tests.

Still outstanding from the underlying fix: `SteuerMeldungRepositoryTest` has not run against
Sybase (`datagrip/sybase:16.0` would not start locally), and the changed predicate is the one
cross-DB-sensitive part.

---

## Follow-up, not part of this change: the general early-abort rule

Cleaning gf1 fixes this instance. The underlying ordering difference remains and will resurface on
other data: `SteuerMeldungLieferungService:97-99` runs status → ermittlungsvorgabe → domain with no
gate, so we emit DB-existence errors before computing the START-record error that suppresses them
in legacy. The codebase's idiom for legacy early-aborts is a delta-report rule, not mirroring the
abort — see `CODE_FIELD_PAIRS_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW` for `ERR_UNG_DATUM`.

Sketch, all inside `ValidationDeltaReports`:

1. **Two code sets.** `LEGACY_START_ROW_ABORT_CODES` — the `ERR_*` codes `CheckStartRow`
   (`c_st_meldung.cpp:4197-5009`) raises *and* which set `nCheckStartRow = -1`; candidates are
   `ERR_GJ_FE_ZUKUNFT`, `ERR_GJE_BEENDET`, `ERR_GJE_UNGLEICH(_O)`, `ERR_GJB_UNGLEICH(_O)`,
   `ERR_GJ_BEG_ENDE(_GJ)`, `ERR_GJE_FE_UNGL`, `ERR_GJ_MELDE_ENDE`, `ERR_PFLICHT_FEHL(18)`,
   `ERR_UNG_CODE`, `ERR_ISIN_GESPERRT`, `ERR_TECH_ISIN` (the `INFO_*` ones do not abort — each
   needs checking individually). And `LEGACY_VORHANDEN_CHECK_CODES` — what
   `CheckVorhandeneMeldung` can raise: `ERR_JAHRESM_VORH`, `ERR_AUSSCHM_VORH`, `ERR_UNGL_VORH*`,
   `ERR_STATUS_NM`, `ERR_UPD_OLDM`, `ERR_MELDID_*`, `ERR_ISIN_MID`, `ERR_UPD_SELBST`.

2. **Detect the abort per meldung.** `getValidationDeltas(ValidationMsgsComparison, ...)` already
   holds the whole comparison. `LegacyLogValidationMsg.matchedPattern()` yields a
   `ValidationMsgCodePattern` whose constants share names with `ValidationMsgCode`, so scan
   `getMatches().map(ValidationMsgMatch::getLegacy)` plus `getOnlyInLegacy()` for any pattern whose
   name is in the abort set (`equivalentCodeNames()` covers shared templates).

3. **Thread one boolean.** Compute it once per comparison and pass it to
   `isShowAsWarningIfOnlyInNew`, which currently takes only `(ValidationMsg, ValidationSetting)`;
   downgrade when the flag is set and the code is in the vorhanden set.

4. **Test** alongside `ValidationDeltaReportsStatusNmTest` / `ValidationDeltaReportsUpdOldmTest`.

Trade-offs worth weighing before committing to it: the rule is only as good as those two sets —
too wide and it masks real divergences, too narrow and noise remains; it depends on the legacy log
line having been pattern-matched at all; and it changes the delta report only, since both systems
decline the meldung either way.
