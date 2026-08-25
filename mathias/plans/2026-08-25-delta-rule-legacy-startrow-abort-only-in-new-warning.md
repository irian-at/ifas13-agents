# Delta rule: only-in-new downgrade when legacy aborted at CheckStartRow

## Context

Legacy and the new system disagree in message *count* whenever a Meldung fails its START record.
Legacy stops; we don't.

| | legacy | new system |
|---|---|---|
| START-record checks | `CheckStartRow()` (`c_st_meldung.cpp:4197-5544`) — on error sets `nCheckStartRow = -1`, caller at `:1653` sets `nProcessingStatus = -1` | `SteuerMeldungDomainValidators`, run **third** |
| DB-existence checks | `CheckVorhandeneMeldung()` (`:7806-9369`) — reached only via `if ((nRet == 1) && (GetProcessingStatus() == 0))` at `:2803` | `SteuerMeldungStatusValidators`, run **first** |

`SteuerMeldungLieferungService:97-99` runs status → ermittlungsvorgabe → domain with no gate
between them, so we emit the DB-existence error before we have even computed the START-record
error that suppresses it in legacy. Both systems decline the Meldung; only the message count
differs.

This surfaced on gf1 (`IE0003921727`): legacy reported `ERR_GJ_FE_ZUKUNFT` alone, we reported that
plus `ERR_JAHRESM_VORH`. That instance was resolved by removing an out-of-order seeded Meldung from
the fixture, so no grossfile currently exercises it — but the divergence is structural and will
recur on other data, including production comparisons.

**Scope: delta report only.** The new system keeps emitting the message, and no result status
changes — both systems decline the Meldung either way.

## Why a delta rule rather than mirroring the abort

Mirroring legacy's gate would mean skipping the status validators when the START record already
failed. That inverts the collect-all-messages design and would reduce what Lieferanten see per
file. The codebase's established idiom is to downgrade in the delta report instead — see
`CODE_FIELD_PAIRS_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW` in `ValidationDeltaReports`, whose
`ERR_UNG_DATUM` entries carry exactly this reasoning ("legacy aborts at the FMVO version lookup …
an only-in-new hit means legacy bailed out early, not that the new system is wrong").

The rule is evidence-based, not assumed: a Meldung that tripped `CheckStartRow` carries the legacy
message for it on **both** sides, so the abort is detectable from the comparison. It also cannot
hide a genuine legacy message — it only ever reclassifies only-in-new entries.

## Change — all in `ifas-domain-stm/.../validation/delta/ValidationDeltaReports.java`

### 1. Two code sets

`LEGACY_START_ROW_ABORT_CODES` — raised by `CheckStartRow` **and** setting `nCheckStartRow = -1`.
Candidates from a scan of 4197-5544:

```
ERR_ISIN_GESPERRT, ERR_TECH_ISIN, ERR_PFLICHT_FEHL, ERR_PFLICHT_FEHL18, ERR_UNG_CODE,
ERR_GJ_BEG_ENDE, ERR_GJ_BEG_ENDE_GJ, ERR_GJB_UNGLEICH, ERR_GJE_UNGLEICH, ERR_GJE_BEENDET,
ERR_GJ_MELDE_ENDE, ERR_GJ_MELDE_ENDE2, ERR_GJ_MELDE_BEGINN, ERR_GJ_FE_ZUKUNFT, ERR_GJ_ZUKUNFT,
ERR_MELDE_ZUKUNFT, ERR_FELD_NA, ERR_ANZ_ANTEILE, ERR_KEINE_LIEFER
```

Deliberately excluded: `INFO_LEI_UNGLEICH`, `INFO_ART_UNGLEICH`, `INFO_KEST98_UNGLEICH` (log only,
no abort). Needing per-site confirmation: `ERR_GJB_UNGLEICH_O` and `ERR_GJE_UNGLEICH_O` — the `_O`
variants abort at some sites (`:4731`, `:4831`) but not others (`:4601`, `:4656`). **The scan that
produced this list paired each `GetMsg` with a nearby `-1` and is approximate — confirm each site
before trusting it.** Sub-checks called from `CheckStartRow` (`CheckIsin`, `CheckLEI`,
`CheckWaehrung`, `CheckLieferanten`) propagate failure too; their codes belong in the set as well
if they can abort.

`LEGACY_POST_GATE_CODES` — what legacy can only raise downstream of the gate, i.e. in
`CheckVorhandeneMeldung` (`:7806-9369`) and `CheckLieferfristen` (`:9579+`), both skipped by the
same `nProcessingStatus`:

```
ERR_JAHRESM_VORH, ERR_AUSSCHM_VORH, ERR_UNGL_VORH, ERR_UNGL_VORHF, ERR_UNGL_VORHF10,
ERR_UNGL_VORHF20, ERR_MELDEID_FEHLT, ERR_MELDID_FEHLT, ERR_MELDID_UNG, ERR_ISIN_MID,
ERR_UPD_SELBST, ERR_VERGANGEN_UPD, ERR_STATUS_NM, ERR_UPD_OLDM, ERR_UPD_TOLATE,
ERR_CON_UPD_TOLATE, ERR_AUSSCHT_AKT_CONF, ERR_SN_INMELDEFRIST, ERR_FRIST_SN
```

Plus the new-system-only helper `ERR_MELDID_NICHT_MEHR_GUELTIG`, which stands in for
`ERR_MELDID_FEHLT`. The `_LIEFERUNG` variants need no entry — they are already unconditional
warnings via `MSG_CODES_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW`.

### 2. Detect the abort per Meldung

`getValidationDeltas(ValidationMsgsComparison, ValidationSetting)` (`:148`) already holds the whole
comparison, so nothing needs plumbing from further up:

```java
private static boolean legacyAbortedAtStartRow(ValidationMsgsComparison comparison) {
    return Stream.concat(
                    comparison.getMatches().stream().map(ValidationMsgMatch::getLegacy),
                    comparison.getOnlyInLegacy().stream())
            .map(LegacyLogValidationMsg::matchedPattern)
            .flatMap(Optional::stream)
            .anyMatch(pattern -> pattern.equivalentCodeNames().stream()
                    .anyMatch(START_ROW_ABORT_CODE_NAMES::contains));
}
```

Use `equivalentCodeNames()`, not `name()`: several codes share a message template (e.g.
`ERR_UNGL_VORH` and `ERR_UNGL_VORHF`), so one matched pattern can stand for more than one code.
Keep the abort set as a `Set<String>` of names to compare against it.

### 3. Thread one flag into the helper

Add the boolean to `isShowAsWarningIfOnlyInNew` (`:186`) and downgrade when it is set and the code
is in `LEGACY_POST_GATE_CODES`. Compute it once per comparison in `getValidationDeltas` and pass it
down. Pass `false` for the **file-level** comparison at `:142` — the signal is per-Meldung and has
no meaning there.

`isShowAsWarningIfOnlyInNew` is package-private and called directly by the two existing rule tests,
so both need their call updated. Prefer changing the signature over an overload, so no caller can
silently keep the old semantics.

### 4. Test

New `ValidationDeltaReportsStartRowAbortTest`, modelled on `ValidationDeltaReportsUpdOldmTest`
(same `SimplePosition` record, same direct calls to `isShowAsWarningIfOnlyInNew`). Cover:

- only-in-new `ERR_JAHRESM_VORH` **with** a legacy `ERR_GJ_FE_ZUKUNFT` on the Meldung → warning
- the same **without** it → stays an error
- an only-in-new code outside `LEGACY_POST_GATE_CODES` → stays an error even when legacy aborted
- an `INFO_*` CheckStartRow code as the only legacy message → does **not** count as an abort
- file-level comparison → never downgraded

## Verification

```bash
mvn -o test -pl ifas-domain/ifas-domain-stm -Dtest='ValidationDeltaReports*Test'
mvn -o test -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest \
    -Pskip-postgres15-tests -Pskip-sybase16-tests
```

**All eight grossfile baselines must stay exactly as they are.** The rule is expected to be a no-op
on current data — gf1's instance was removed with the fixture fix, and nothing else is known to
trip it. If a baseline moves, the rule fired somewhere unexamined: inspect that Meldung in
`target/grossfile-recalc/<dataset>/error#diff.txt` and confirm legacy really did abort at
`CheckStartRow`, rather than accepting the new number.

Finish with the full module regression
(`-pl ifas-domain/ifas-domain-stm,ifas-testing/ifas-integration-tests -Pskip-sybase16-tests`),
last green at 1277 + 641.

## Risks

- **Set membership is the whole rule.** Too wide and it masks real divergences; too narrow and the
  noise stays. Every entry should be traceable to a confirmed legacy call site, and the
  approximate scan above is a starting point, not evidence.
- **Depends on the legacy line having matched a pattern.** An unmatched legacy log line yields no
  `matchedPattern`, so the abort goes undetected and the entry stays an error — a safe failure
  direction, but it means the rule is silently partial.
- **No production effect.** Result status and emitted messages are unchanged; only the delta
  report's severity classification moves.
