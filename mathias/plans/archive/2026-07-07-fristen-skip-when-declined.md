# Skip FRISTENPRÜFUNGEN when the Meldung is already declined

## Context

**Reported deviation:** gf4 recalc, Zeile 18 — `LU0066902890` (CONFIRMED 649579).
The neusystem emits an extra `ERR_FRIST_NOSN` ("Die Meldung erfolgt nach der Meldefrist
und ist nicht als Selbstnachweis gekennzeichnet") that the legacy log does **not** contain.
See `error#diff.txt` line 65 (`[+] NUR IM NEUSYSTEM (FEHLER)`).

**Root cause (confirmed against legacy `c_st_meldung.cpp`):** The meldung's reported
Geschäftsjahr-Ende (31.12.2025) mismatches the previous meldung's (31.03.2026). In legacy,
`CheckVorhandeneMeldung` treats this as a hard error for CONFIRMED
(`if (daGj_ende != daMeldeGj_ende)`, c_st_meldung.cpp:8328 → `nIsErrorVorhandenMeldung=1`
→ consolidation at 8762-8789 → `CONFIRM_DECLINED`, `return -1`). `ProcessMeldung_CONFIRMED`
then returns **before** the `if (nConfirm_update == 0) → CheckLieferfristen()` branch
(c_st_meldung.cpp:3005-3011). `ERR_FRIST_NOSN` lives only inside `CheckLieferfristen`, so
legacy never evaluates it once the meldung is declined.

The neusystem's `SteuerMeldungStatusValidationService.validate()` instead accumulates all
messages with **no abort** and unconditionally runs the FRISTENPRÜFUNGEN block, so the
deadline check fires on top of the (correct, exact-match) decline errors.

**Rejected approach:** Removing `createArtificialGeschaeftsjahr` does *not* help — the
`ERR_FRIST_NOSN` deadline is `meldefristAsLastChance(steuerMeldung)`
(`SteuerMeldungFristenValidators.java:169`), derived from the meldung's own CSV `gjEnde`,
and never reads the `geschaeftsjahr` object. That object only feeds `snEnde`/`lastChance`,
consumed by the Selbstnachweis-only checks `errFristSn`/`errSnInmeldefrist` (irrelevant for
this Selbstnachweis=NEIN meldung). Removing it would only regress those Selbstnachweis checks.

**Intended outcome:** When a declining ERROR-severity message from the status/vorhanden
checks is already present, skip the entire deadline block — mirroring legacy's
"decline → skip CheckLieferfristen".

## Ordering verification (the user's key question)

No reordering is required. Every legacy decline-before-`CheckLieferfristen` point maps to a
neusystem validator that runs in **lines 119-231**, i.e. *before* the FRISTENPRÜFUNGEN block
at line 233:

| Legacy decline (CheckVorhandeneMeldung / CheckStatus) | Neusystem validator (line) |
|---|---|
| ERR_MELDEID_FEHLT / ERR_MELDID_FEHLT / ERR_MELDID_UNG | 121 / 129 / 125 |
| ERR_ISIN_MID | 134 |
| ERR_STATUS_UNGUE | 139 |
| **ERR_UNGL_VORH(F)** ← this case | **175** |
| ERR_UPD_SELBST | 181 |
| ERR_STATUS_NM | 194 |
| ERR_UPD_OLDM | 207 |
| ERR_VERGANGEN_UPD / ERR_AUSSCHT_AKT_CONF | 218 / 225 |

`ValidationMsg` has only ERROR/INFO. `errUnglVorh` severity is ERROR for CONFIRMED/DELETE/NEW
but **INFO for UPDATE** (`unglVorhSeverity`), exactly mirroring legacy's hard-for-CONFIRMED /
soft-`WriteStmInfo`-for-UPDATE asymmetry — so a UPDATE with a GJ mismatch (INFO) will *not*
gate, and its fristen check still runs (matches legacy's UPDATE-on-OPEN → `CheckLieferfristen`
path, gf4 Zeile 21). The declining `ERR_UNGL_VORHF` for the CONFIRMED case is present at
line 233, so an in-method gate is sufficient.

**Scope decision (chosen):** In-method gate only. Stammdaten-GJ (`ERR_GJE_UNGLEICH`, from the
later `SteuerMeldungDomainValidationService`) and ermittlungsvorgabe errors are produced
*after* `statusValidationService.validate()` returns (orchestrated at
`SteuerMeldungLieferungService.java:99-101`) and are intentionally **not** covered here. If a
future gf diff shows a stammdaten/vorgabe-only decline leaking a spurious fristen error, that
is a separate follow-up requiring a legacy check of whether those paths also skip
`CheckLieferfristen`.

## Change

**File:** `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidationService.java`

Wrap the entire FRISTENPRÜFUNGEN block (current lines 233-312 — the `geschaeftsjahr`
resolution, `vorherigeFinalSteuerMeldung` lookup, `snInmeldefrist`/`fristSn`/`fristNosn`, and
the `errUpdTolate`/`errConUpdTolate` inner block) in a guard:

```java
// ------------------ FRISTENPRÜFUNGEN -----------------
// Legacy: any hard error in CheckStatus/CheckVorhandeneMeldung declines the meldung and
// returns -1 before CheckLieferfristen is reached (c_st_meldung.cpp:2988-3011, consolidation
// at 8762-8789). All such decline reasons are emitted above (status/vorhanden checks) as
// ERROR-severity messages. Once one is present, skip every deadline check — otherwise the
// neusystem lists e.g. ERR_FRIST_NOSN on top of an already-declining ERR_UNGL_VORH
// (gf4 Zeile 18, LU0066902890). INFO-severity mismatches (UPDATE) do not gate, matching the
// legacy UPDATE-on-OPEN path that still runs CheckLieferfristen.
boolean alreadyDeclined = validationMsgs.stream().anyMatch(ValidationMsg::isError);
if (!alreadyDeclined) {
    // ... existing block unchanged ...
}
```

Notes:
- Reuse the existing `ValidationMsg.isError()` predicate — no new helper.
- This is a correctness fix in the domain logic; it applies unconditionally (production and
  recalc), **not** behind a `ValidationSetting` flag. It does not touch the uncommitted
  `ignorePreviousStmGueltBis` work.
- The whole block (all five fristen codes) is gated — faithful to legacy, where every fristen
  code sits after a decline point. Return-status behaviour is unaffected:
  `calculateDeclinedOrErrorStatus` already yields ERROR/`*_DECLINED` from the prior error, so
  suppressing the deadline messages only removes log noise.

## Verification

1. **Unit/integration tests (H2):**
   - `mvn test -Pno-proxy -Pskip-postgres15-tests -Pskip-sybase16-tests -pl ifas-testing/ifas-integration-tests -Dtest=SteuerMeldungStatusValidationServiceTest`
     — existing behaviour must stay green; add a case: CONFIRMED referencing an OPEN meldung
     with a GJ-Ende mismatch (→ ERR_UNGL_VORH ERROR) asserts **no** `ERR_FRIST_NOSN` is
     emitted, and a plain late CONFIRMED with no other error still yields `ERR_FRIST_NOSN`.
   - `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm -Dtest=SteuerMeldungFristenValidatorsTest,SteuerMeldungStatusValidatorsTest`
     — the validators themselves are unchanged; confirm nothing regresses.
2. **Recalc regression:** run the gf4 recalc that produced `error#diff.txt` (via
   `JiraIssueRecalculationTest` / the grossfile-recalc harness) and confirm Zeile 18 no longer
   shows `[+] NUR IM NEUSYSTEM (FEHLER) ERR_FRIST_NOSN`, and the four exact-match GJ errors
   remain. Confirm gf4 Zeile 21 (UPDATE 649585) and the gf5 Zeile 43 correction-frist cases
   are unchanged (they gate on INFO, not ERROR).
3. Update `docs/Rekalkulation/Fachabteilung-FRIST-NOSN-gf4.md` "Konsequenz fürs Neusystem" /
   "Hinweis für den Fix" sections to record that the fix landed as an in-method decline gate
   (not the artificial-GJ removal, and not a reorder).
