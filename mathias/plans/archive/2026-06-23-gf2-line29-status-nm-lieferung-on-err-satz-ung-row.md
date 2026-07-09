# gf2 line 29: `ERR_STATUS_NM_LIEFERUNG` on a row already rejected by `ERR_SATZ_UNG`

## Context

In `gf2-d20260731.csv` the Melde-ID **649560** appears twice (LU0134335420):

- Lines 18-28: `STATUS;CONFIRMED;649560` followed by EA/E/D/Z/ZA/AS payload records
- Lines 29-39: `STATUS;DELETE;649560` followed by the same payload records

The diff at `target/grossfile-recalc/gf2-d20260731/error#diff.txt:108-137` shows both systems agree on 12× `[=] EXAKTER TREFFER` for `ERR_SATZ_UNG` (`"Die {CONFIRMED|DELETE} Meldung darf die Satzart <X> nicht enthalten."`). The deviation is one trailing line on the DELETE row, only emitted by IFAS13:

```
[+] NUR IM NEUSYSTEM (WARNUNG)
    ERROR! Aktueller Status <FINAL>, DELETE nicht moeglich. Status-Aenderung fuer Melde-ID <649560> bereits in dieser Lieferung durchgefuehrt.
```

Two things to explain:
1. The legacy *does* have a `Aktueller Status <FINAL>, DELETE nicht moeglich` check — it fires for the structurally-clean **649542** at lines 132-136 and gets paired with IFAS13's `_LIEFERUNG` variant as `[=] ABGEDECKTER TREFFER`. So legacy is not silently permissive in general.
2. The legacy stays silent for 649560 specifically — that's the contrast to understand.

## Mechanism

| Row | Legacy | IFAS13 |
|-----|--------|--------|
| 1 — `CONFIRMED;649560` + payload | 6× `ERR_SATZ_UNG`, short-circuit before DB write — DB state unchanged | 6× `ERR_SATZ_UNG` from upstream CSV validation, **but** the `producedError` gate at `SteuerMeldungLieferungService.java:110-113` only inspects `perMeldungMsgs` from the three local validators — record-type errors from `CsvSteuerMeldungen.loadAndValidateInputFromCsv` aren't in that list. So `acceptedState.accept(steuerMeldung)` runs and `InLieferungAcceptedState` marks `649560 → FINAL`. |
| 2 — `DELETE;649560` + payload | 6× `ERR_SATZ_UNG`; status check evaluates against the still-original DB state → emits nothing | 6× `ERR_SATZ_UNG`; **plus** `acceptedState.hasAcceptedTransitionFor(649560) == true` → `ERR_STATUS_NM_LIEFERUNG` fires |

For comparison, **649542** (lines 132-136) is status-only on both rows: row 1 passes the record-type check on both sides, both systems record FINAL (legacy in DB, IFAS13 in `InLieferungAcceptedState`), and both reject row 2 with `Aktueller Status <FINAL>, DELETE nicht moeglich.` — paired by `StatusNmCoveredByStatusNmLieferung` as `[=] ABGEDECKTER TREFFER`.

### Why the message reads `<FINAL>` even though the CSV says `CONFIRMED`

`InLieferungAcceptedState.accept()` stores the *post-transition* Meldestelle status, not the Lieferant-input action:

- `CONFIRMED` (Lieferant) ⇒ stored as `FINAL` (Meldestelle)
- `DELETE` (Lieferant) ⇒ stored as `DELETED`

`SteuerMeldungStatusValidators.errStatusNmLieferung` (lines 206-228) reports that effective state. The error template is `ValidationMsgCode.ERR_STATUS_NM_LIEFERUNG` at `ValidationMsgCode.java:38`.

## Design intent

The current behavior is explicitly documented in `ValidationDeltaReports.java:30-42`:

> "Within-file duplicate `_LIEFERUNG` variants. The covered-by rules already pair these with their legacy DB-existence counterparts as exact matches; a `_LIEFERUNG` entry can only land here when legacy emitted nothing — which happens when legacy declined the first row of the ISIN upstream (e.g. via `ERR_SATZ_UNG`) and therefore never updated its in-memory state. **That is new-system-stricter-by-design, not a regression.**"

`ERR_STATUS_NM_LIEFERUNG` (along with `ERR_JAHRESM_VORH_LIEFERUNG`, `ERR_AUSSCHM_VORH_LIEFERUNG`, `ERR_UPD_OLDM_LIEFERUNG`) is listed in `MSG_CODES_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW` (`ValidationDeltaReports.java:44`), which is why the diff classifier renders it as `(WARNUNG)` rather than `(FEHLER)`.

## Decision

Three options:

1. **Keep as-is.** Accept the `+1` new-warning per affected pair; rely on the existing classifier downgrade. Rationale: surfacing the suspect "confirm-then-delete-same-stmId-in-one-file" pattern is genuinely useful even when the first row was malformed.
2. **Tighten the accept-gate to converge with legacy.** Change `SteuerMeldungLieferungService.java:110-113` to consider *all* `ValidationMsg.Severity.ERROR` messages on the meldung — including upstream CSV/record-type errors from `steuerMeldungenWithValidations.validationMsgs()` — not just the three local validators. Effect: 649560-style cases no longer trip `_LIEFERUNG` follow-ups; legacy behavior is matched; the `+1` goes to `0`.
3. **Hybrid.** Keep the accept-gate as-is but skip `_LIEFERUNG` follow-ups specifically when the prior accepted row had ERROR-severity upstream messages — i.e. accept for downstream business-key uniqueness purposes but not for status-transition purposes. More surgical; more state to thread through.

Option 2 is the simplest change. The conceptual question for product: should the system flag `CONFIRMED;X` + `DELETE;X` in one file when the CONFIRMED row was itself rejected? Legacy says no (because legacy never *saw* the CONFIRMED); IFAS13 today says yes.

## Key files

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungService.java` — `producedError` gate at lines 110-113
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/InLieferungAcceptedState.java` — the in-memory accept tracker
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidationService.java` — dispatch to `errStatusNmLieferung` vs `errStatusNm` at lines 179-191
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidators.java` — `errStatusNmLieferung` at lines 206-228
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgCode.java:38` — `ERR_STATUS_NM_LIEFERUNG` template; line 145 — `ERR_SATZ_UNG` template
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgMapper.java:74` — where `RECORD_TYPE_NOT_ALLOWED` maps to `ERR_SATZ_UNG` (upstream of the local validators)
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/StatusNmCoveredByStatusNmLieferung.java` — covered-by rule for the structurally-clean 649542 case
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/ValidationDeltaReports.java:30-44` — the `_LIEFERUNG`-downgrade-to-warning policy and its rationale
- `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/recalc/GrossfileRecalculationTest.java:152-155` — gf2 baseline expectations (the trailing `1` corresponds to this case)

## Verification

If implementing option 2:

1. Adjust the `producedError` predicate at `SteuerMeldungLieferungService.java:110-113` to OR in any ERROR-severity entry of `steuerMeldungenWithValidations.validationMsgs()` for the current meldung's CSV-position scope.
2. Run `GrossfileRecalculationTest` and confirm the gf2 error baseline drops the trailing `1` (`SummaryExpectation(94, 0, 2, 2, 5, 0)`); regenerate baselines for other grossfiles affected.
3. Spot-check `target/grossfile-recalc/gf2-d20260731/error#diff.txt:136` — the `[+] NUR IM NEUSYSTEM (WARNUNG)` line for 649560 should disappear; the `[=] EXAKTER TREFFER` block for 649542 (lines 132-136 in the CSV) must remain unchanged.
4. Add a focused unit test in `SteuerMeldungLieferungServiceTest` (or equivalent) covering: meldung with upstream `ERR_SATZ_UNG` must not register in `InLieferungAcceptedState`.
