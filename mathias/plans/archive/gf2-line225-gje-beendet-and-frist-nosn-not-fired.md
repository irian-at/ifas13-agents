# gf2 Zeile-Nr 225 (LU0891777665) — ERR_GJE_BEENDET and ERR_FRIST_NOSN not fired

Analysis of the two only-in-legacy errors at
`ifas-testing/ifas-integration-tests/target/grossfile-recalc/gf2-d20260731/error#diff-deviations.txt:51-59`.

## The deviation

CSV row 225 of `gf2-d20260731.csv`:

```
START;LU0891777665;InvF;T;USD;13.12.2025;14.12.2025;JA;;;1;;LU;NEIN;JA;NEIN;;NEIN;JA;1;
STATUS;NEW
END;LU0891777665;31.01.2024 09:43:44
```

Jahresdatenmeldung=JA, GJ 13.12.2025–14.12.2025 (a 2-day fiscal year following an `Ende`), Versionsnr=1, Selbstnachweis=NEIN.

Legacy fires both, IFAS13 fires neither:

- `[-] NUR IM ALTSYSTEM (FEHLER)`: `ERROR! Das gemeldete Geschaeftsjahr-Ende <2025.12.14> faellt in den Zeitraum, in dem der Fonds als beendet gemeldet war.`
- `[-] NUR IM ALTSYSTEM (FEHLER)`: `ERROR! Die Meldung erfolgt nach der Meldefrist und ist nicht als Selbstnachweis gekennzeichnet.`

Codes: `ERR_GJE_BEENDET` and `ERR_FRIST_NOSN`.

## Fund history (from the merged YAML)

`LU0891777665` → `wfsWkn=150881` / `numWfsKu=150799`.

The fund was reported as terminated on `2025-12-12`, then **un-terminated** on `2026-01-08`. INV_H tells the story:

| gueltAb | gueltBis | fondsBeginn | fondsEnde | gjEnde |
|---|---|---|---|---|
| 2014-06-13 | 2017-11-28 | 2014-06-13 | — | 31.12. |
| 2017-11-29 | 2023-05-31 | 2014-06-13 | — | 31.12. |
| 2023-06-01 | 2025-12-08 | 2014-06-13 | — | 31.12. |
| 2025-12-09 | 2025-12-11 | 2014-06-13 | **2025-12-12** | 31.12. |
| 2025-12-12 | 2026-01-07 | 2014-06-13 | **2025-12-12** | 31.12. |
| 2026-01-08 | (current) | 2014-06-13 | **null** | 30.09. |

GESCHAEFTSJAHR rows (only those near the relevant window):

| gjBeginn | gjEnde | gjTyp | stmId | lastChance |
|---|---|---|---|---|
| 2025-01-01 | 2025-12-12 | `E` (Ende) | 636577 | 2026-07-10 |
| 2025-12-13 | 2025-12-14 | `B` | — | — |
| 2025-12-15 | 2026-09-30 | `W` | — | 2027-04-30 |

Stichtag (from the grossfile filename `gf2-d20260731.zip`) is `2026-07-31`.

## Why each validator skips

### ERR_GJE_BEENDET

Raiser: `SteuerMeldungDomainValidators.java:688-705`.

```java
if (gjEnde.value() == null || fondsEnde == null) {
    return;   // early return
}
if (!LocalDates.isBetweenInclusive(fondsBeginn, fondsEnde, gjEnde.value())) {
    validationMsgs.add( … ERR_GJE_BEENDET … );
}
```

Caller `SteuerMeldungDomainValidationService.java:440`:

```java
errGjeBeendet(validationMsgs, stmGjEnde, inv.getFondsBeginn(), inv.getFondsEnde());
```

The `inv` here is the *current* INV at stichtag `2026-07-31`. That INV (gueltAb=2026-01-08) has `fondsEnde=null` because the fund was un-terminated. The early return fires and the error is silently dropped.

Legacy doesn't consult INV/INV_H at all. At `c_st_meldung.cpp:4679-4685` it looks up the **Geschaeftsjahr** row in the GJ table that matches the meldung's `daGj_ende` and tests `cGJs[idx].IsBeendet()`. `IsBeendet()` at `c_geschaeftsjahr.cpp:1468-1473` is literally `strGj_typ == "B"`. The 'B' rows are the gap-fillers inserted between a `gj_typ=E` (Fonds-Ende) and a `gj_typ=W` (Wiederauflage) — exactly the "period when the fund was reported as terminated" the German message names.

For Zeile 225 the meldung's `gjEnde=2025-12-14` matches the `gjTyp=B` row (`2025-12-13 → 2025-12-14`), so legacy fires.

Pattern: IFAS13 reads a derived field on the current INV (`fondsEnde`) where legacy reads a domain property on the matched GJ row (`gj_typ`). The stammdaten (the GJ Zeitreihe) is the canonical source — by the time `errGjeBeendet` runs, the meldung's gjEnde has been validated against the GJ table by `errGjeUngleich`/`errGjeUngleichO` (`SteuerMeldungDomainValidationService.java:436-442`), so consulting the matched row's `gjTyp` is both correct and consistent with the surrounding checks.

### ERR_FRIST_NOSN

Raiser: `SteuerMeldungFristenValidators.java:101-122`.

```java
if (TRUE.equals(steuerMeldung.getSelbstnachweis())) return;
if (lastChance == null) return;          // early return
if (stichtag.isAfter(lastChance)) {
    validationMsgs.add( … ERR_FRIST_NOSN … );
}
```

`lastChance` is derived at `SteuerMeldungStatusValidationService.java:227-232`:

```java
Geschaeftsjahr geschaeftsjahr = findGeschaeftsjahrForMeldung(steuerMeldung, stichtag);
…
LocalDate lastChance = geschaeftsjahr != null ? geschaeftsjahr.getLastChance() : null;
```

`findGeschaeftsjahrForMeldung` matches by the meldung's `(gjBeginn, gjEnde)` and picks the `2025-12-13 → 2025-12-14, gjTyp: B` row. That row has no `lastChance` — `Geschaeftsjahre.calcRawLastChance` at line 216-222 explicitly returns null for `GjTypen.isBeendet(gjTyp)` ("Ein beendetes GJ hat keine Lastchance"). Early return, error dropped.

Legacy does not use a per-GJ `lastChance` lookup at all. At `c_st_meldung.cpp:9700-9707`:

```cpp
if (cSt_Meldung::strSelbstnachweis == "NEIN") {
    if (cSt_Meldung::daFristDatum > daGj_ende) {   // daFristDatum = stichtag − 7 months
        sprintf( … "ERR_FRIST_NOSN" …);
    }
}
```

`daFristDatum` is set once at startup from `daDatum − nSTM_Frist_Monate` (`c_st_meldung.cpp:513`, with `nSTM_Frist_Monate = 7`). Algebraically `stichtag − 7M > gjEnde` ≡ `stichtag > gjEnde + 7M`, i.e. legacy derives the deadline from the meldung's `gjEnde` directly, regardless of the GJ row's `gj_typ`. For Zeile 225: `2026-07-31 − 7M = 2025-12-31 > 2025-12-14` → fires.

Pattern: IFAS13 reads a precomputed deadline column on the matched GJ row (which is null-by-design for B) where legacy derives it on the fly from the meldung's own `gjEnde`. Follow legacy verbatim: for ERR_FRIST_NOSN specifically, derive `lastChance = meldung.gjEnde + 7M` at the call site, independent of any GJ row. Legacy doesn't no-op when no GJ matches either — it fires both `ERR_FRIST_NOSN` and `ERR_GJE_UNGLEICH_O` when the meldung's `gjEnde` is both late-by-its-own-claim and unrecognised; both are true and both should be emitted.

Note this is divergent from how IFAS13 derives the GJ-entity's `lastChance` (which trading-day-adjusts earlier via `ensureAustrianStockExchangeTradingDayOrElseEarlier`). Legacy uses the raw `gjEnde + 7M` without adjustment; mirroring that keeps us from firing FRIST_NOSN on 1–2-day windows where legacy stays silent. The GJ-entity's `lastChance` stays correct for its own consumers (`snEnde`, `mahnungAb`, korrekturfrist) — we just don't route the FRIST_NOSN comparison through it.

## Fix shape

Both issues are validator-side; the merged YAML data is fine (it contains the INV_H history and the GJ rows needed). No fixture change required.

Both fixes consult the **matched Geschaeftsjahr row** from the stammdaten (the `gjZeitreihe` already in scope at `SteuerMeldungDomainValidationService.java:425`) rather than INV/INV_H or precomputed deadline columns. The meldung's `gjEnde` is already validated against this same Zeitreihe by `errGjeUngleich`/`errGjeUngleichO`, so using the matched row keeps the canonical-source discipline consistent across the validators in this block.

1. **ERR_GJE_BEENDET** — change `errGjeBeendet` to take the matched GJ (or its `GjTyp`) instead of `fondsBeginn`/`fondsEnde` and fire when `GjTypen.isBeendet(matchedGj.getGjTyp())`. Update the call at `SteuerMeldungDomainValidationService.java:440` accordingly. Cite legacy: `c_st_meldung.cpp:4679-4685` (`cGJs[nIndGj_Ende].IsBeendet()`) and `c_geschaeftsjahr.cpp:1468-1473` (`IsBeendet()` ≡ `gj_typ == "B"`).
2. **ERR_FRIST_NOSN** — at the call site (`SteuerMeldungStatusValidationService.java:232` or directly where `errFristNosn` is invoked), derive `lastChance = steuerMeldung.getGjEnde() + LAST_CHANCE_GRACE_PERIOD` for this specific check, without trading-day adjustment. Pass that to `errFristNosn` instead of `geschaeftsjahr.getLastChance()`. Don't change the GJ-entity's stored `lastChance` (other consumers depend on it) and don't gate on whether a GJ row matched — legacy fires `ERR_FRIST_NOSN` even when no GJ matches, alongside `ERR_GJE_UNGLEICH_O`. Cite legacy: `c_st_meldung.cpp:513,9703` (`daFristDatum = stichtag − 7M`; fires when `daFristDatum > daGj_ende`).

## Verification

After the fix, regenerate the gf2 diff:
- `target/grossfile-recalc/gf2-d20260731/error#diff-deviations.txt` should no longer list Zeile-Nr 225 LU0891777665 under `NUR IM ALTSYSTEM`.
- `GrossfileRecalculationTest`'s gf2 baseline (`GrossfileRecalculationTest.java:152-155`, currently `SummaryExpectation(94, 0, 2, 2, 5, 0)` for error) will need recompution — the `onlyInLegacy` count should drop by 2.

## Critical files

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/SteuerMeldungDomainValidators.java:688-705` — `errGjeBeendet` raiser
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/SteuerMeldungDomainValidationService.java:440` — caller passing current INV's `fondsEnde` (replace with matched-GJ `gjTyp`)
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/fristen/SteuerMeldungFristenValidators.java:101-122` — `errFristNosn` raiser
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidationService.java:227-232` — `lastChance` derivation; for ERR_FRIST_NOSN compute a local `meldung.gjEnde + LAST_CHANCE_GRACE_PERIOD` (no trading-day adjustment, mirroring legacy) instead of using `geschaeftsjahr.getLastChance()`. Leave `snEnde` and other consumers untouched.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/geschaeftsjahr/Geschaeftsjahre.java:216-222` — `calcRawLastChance` returns null for `GjTypen.isBeendet(gjTyp)` by design; the fix must not change this (other callers depend on it) — it has to live in the fristen-check call site instead
- `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/gf2-d20260731/gf2-d20260731.csv:225` — the offending row

## Notes

- Stichtag for gf2 is `2026-07-31` (parsed from `gfN-d<yyyyMMdd>.zip` per `GrossfileRecalculationTest.java:50,71`).
- The `gjTyp` codes: `E` = Ende of FY at fund termination, `B` = likely Beendung/Bereinigung (interregnum window between termination and reopening), `W` = Wiedereröffnung (new FY after un-termination). Confirm semantics in `GjTyp` enum or the `gj_typ` table if a fix touches the typing.
- This deviation is independent of the YAML merge work — it would surface against a clean DB export too.
