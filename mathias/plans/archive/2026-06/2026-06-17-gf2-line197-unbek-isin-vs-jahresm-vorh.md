# gf2 Zeile-Nr 197 (LU0136043394) — ERR_UNBEK_ISIN vs ERR_JAHRESM_VORH

Analysis of the only-in-legacy/only-in-new pair at
`ifas-testing/ifas-integration-tests/target/grossfile-recalc/gf2-d20260731/error#diff-deviations.txt:67-74`.

## The deviation

CSV row 197 of `gf2-d20260731.csv`:

```
START;LU0136043394;InvF;T;EUR;01.01.2024;31.12.2024;JA;;;5;;LU;JA;JA;NEIN;;NEIN;NEIN;5;U090UTR2IZOR4U9CSZ50
STATUS;NEW
E;Aufwand_Gesamtbetrag_e;0
E;Aufwand_Gesamtbetrag_KV_e;0
END;LU0136043394;31.01.2024 09:43:44
```

Jahresdatenmeldung=JA, GJ 2024, Status=NEW, Selbstnachweis=NEIN, Versionsnr=5.

- `[-] NUR IM ALTSYSTEM (FEHLER)`: `ERROR! Jahresmeldung bereits vorhanden.`
- `[+] NUR IM NEUSYSTEM (FEHLER)`: `ERROR! Die ISIN <LU0136043394> ist nicht fuer eine Steuerdatenmeldung registriert.`

## What each system does

**Legacy (CPP)**
1. Finds the INV record for `LU0136043394` (registration check passes).
2. Goes to the "Jahresmeldung already exists" check, hits existing Meldung 649490
   for `(ISIN=LU0136043394, GJ=2024)`.
3. Emits `ERR_JAHRESM_VORH` and writes
   `STATUS;NEW_DECLINED;;649490;Meldung ist bereits vorhanden`
   to `gf2-d20260731_return.csv:1772`.

**IFAS13**
1. `SteuerMeldungDomainValidationService.java:73` calls
   `invRepository.getInvByIsin("LU0136043394", stichtag=2026-07-31)`.
2. The JPQL at `InvRepository.java:21-32` joins
   `Inv → WknDesc → WknHist` with `WknHist.numWkn = :isin` and validity covering `stichtag`.
3. Returns empty → `errUnbekIsin` fires at `SteuerMeldungDomainValidationService.java:281`
   (helper: `SteuerMeldungDomainValidators.java:868-883`).
4. The `if (inv != null) { … }` guard at `SteuerMeldungDomainValidationService.java:288`
   short-circuits, so the Jahresmeldung-duplicate check (`ERR_JAHRESM_VORH` at
   `SteuerMeldungStatusValidators.java:356-...`) never runs.

## Root cause: fixture data gap

The pre-state YAML inside `gf2-d20260731.zip`
(`gf-d20260724-export-AFTER.yaml.txt`, dated 2026-02-25) **does not contain
`LU0136043394`** — neither in its ISIN header list nor in any `WKN_HIST` / `WKN_DESC` / `INV` entry.

By contrast, the post-state YAML inside `gf3-d20260805.zip`
(`gf2-d20260731-export-AFTER.yaml.txt`, the snapshot AFTER gf2) **does**
contain it:

```
WKN_DESC numWfs=36515  txtBezXl="Schroder ISF EURO Liquidity A"  lei=U090UTR2IZOR4U9CSZ50
WKN_HIST numWfsHist=77273  quelle="ISIN"  numWkn="LU0136043394"
         datGueltigAb=2001-09-21  wknDesc=36515
```

Legacy's real DB at gf2-run time clearly had the ISIN registered since 2001 — it's just
absent from the gf2 fixture's import YAML. Same gap explains gf2 line 225
(`LU0891777665`, `[-] GJ-Ende fällt in den Zeitraum…beendet` vs `[+] ERR_UNBEK_ISIN`).

## Classification

**Fixture data gap, not a validator/code bug.** The new system's reaction
(`ERR_UNBEK_ISIN`) is correct given the imported state.

Already counted in the gf2 baseline at
`GrossfileRecalculationTest.java:154`:
`SummaryExpectation(94, 0, 2, 2, 5, 1)` — `onlyInLegacy=2` and `onlyInNewError=5`
absorb this row.

## Options for closing the gap

### Option A — patch the gf2 fixture YAML (recommended if we want exact match)

Add to `gf-d20260724-export-AFTER.yaml.txt` inside `gf2-d20260731.zip`:

1. The missing entries for `LU0136043394` — copy from gf3's post-state YAML:
   - `WKN_DESC numWfs=36515` (incl. `lei=U090UTR2IZOR4U9CSZ50`, fund metadata).
   - `WKN_HIST numWfsHist=77273` (and the secondary `WKN_HIST` numWfsHist=181710 / numWkn=791930).
   - The corresponding `INV` row (lookup via `numWfsKu=36485`).
   - `KEST98` / `LIEFER_STATUS_GESAMT` if needed for downstream checks.
2. The pre-existing `STEUER_MELDUNG` row with `meldeId=649490`, ISIN=LU0136043394,
   GJ=2024, Jahresdatenmeldung=true, status=ACCEPTED (or whatever legacy state
   triggered `Meldung ist bereits vorhanden`) — so the duplicate check actually fires.
3. Same treatment for `LU0891777665` (gf2 line 225).

Expected outcome: both rows flip from `[-]/[+]` deviation pair to an exact-match
`ERR_JAHRESM_VORH` and exact-match `Geschaeftsjahr-Ende fällt in den Zeitraum…`
respectively. After that, the gf2 baseline counters need to drop by ~1 on each
of `onlyInLegacy` / `onlyInNewError` per row.

### Option B — leave as-is

The baseline already accounts for the deviation. Cost: the diff-deviations
report carries two stale-by-design entries. This is consistent with
`[[recalc-historical-fidelity]]` — fixture logs predate certain state and
deviations may be legitimately stale.

## TODOs for tomorrow

- [ ] Decide between A and B with Manfred / fixture owner. Lean A if we want the
      gf2 baseline to mean "everything matches except real bugs".
- [ ] If A: write a one-off script (or extend the existing yaml-export tool) to
      diff gf3-AFTER vs gf2-AFTER and surface the candidate rows; pull just the
      LU0136043394 and LU0891777665 closure (WKN_DESC + WKN_HIST + INV +
      STEUER_MELDUNG 649490 and the equivalent for LU0891777665) into the gf2
      YAML.
- [ ] Verify the same ISIN-gap pattern doesn't hide a real bug elsewhere — grep
      all `error#diff-deviations.txt` files for `ist nicht fuer eine
      Steuerdatenmeldung registriert` in `[+] NUR IM NEUSYSTEM` blocks. If a
      legacy-only counterpart is also `ERR_UNBEK_ISIN` (or any "ISIN unknown"
      variant), it's the same data gap; otherwise it might be a real divergence.
- [ ] After fix, rerun `GrossfileRecalculationTest` and update the gf2
      `SummaryExpectation` in `GrossfileRecalculationTest.java:154`.

## Key files

- `ifas-testing/ifas-integration-tests/target/grossfile-recalc/gf2-d20260731/error#diff-deviations.txt:67-74` (the deviation)
- `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/gf2-d20260731.zip` (fixture to patch — contains the pre-state YAML)
- `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/gf3-d20260805.zip` (source of truth for the missing entries — its `gf2-d20260731-export-AFTER.yaml.txt` is the post-state snapshot)
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/SteuerMeldungDomainValidationService.java:271-341` (`validateInv`, where `errUnbekIsin` short-circuits)
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/SteuerMeldungDomainValidators.java:868-883` (`errUnbekIsin` helper)
- `ifas-database/ifas-persistence-inv/src/main/java/at/oekb/ifas/persistence/inv/InvRepository.java:21-32` (`getInvByIsin` query)
- `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/recalc/GrossfileRecalculationTest.java:147-181` (baselines, gf2 at line 154)
