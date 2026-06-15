# Plan: ERR_KONTROLL_N_LT_0 — Field List Origin & Source-Filter Question

## Context

While inspecting `target/quick-recalc/error#recalc.log` we noticed that
`ERR_KONTROLL_N_LT_0` errors ("Das Ergebnis im Feld `<X>` `<value>` darf nicht
kleiner 0 sein") render at the meldung's START line (no per-row anchor) and
visually attach themselves under whatever CSV-line subheader was printed
immediately before them, in `ValidationMsgLogWriter`.

The domain expert's claim: this check should only apply to fields whose
`FieldSpec.quelle = STEUERLICHER_VERTRETER`. The current Java implementation
applies it to a hardcoded list of 7 `_inklEA` (calculated) fields — which,
under that rule, would mean the validator should run on **zero** of them.

The Java author left a TODO documenting the same suspicion:

```java
// TODO - angeblich nicht für errechnete felder.. aber wo kommt diese Liste dann her??
```

This document captures the research so the discussion can continue with the
expert without re-deriving everything.

## Where the Java list lives

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/calculated/CalculatedSteuerMeldungValidators.java:321-344`

```java
public static void errKontrollNLt0(List<ValidationMsg> validationMsgs, SteuerMeldung steuerMeldung) {
    String[] fieldNames = {
            "Gewinnvortrag_Ertraegeordentlich_versteuert_inklEA",
            "Gewinnvortrag_Ertraegeausserordentlich_60vH_versteuert_inklEA",
            "Gewinnvortrag_Ertraegeausserordentlich_nichtversteuert_40vH_KV_inklEA",
            "Gewinnvortrag_Ertraegeausserordentlich_Privatanleger_InvFG1993_versteuert_inklEA",
            "ImmoInvF_Gewinnvortrag_inklEA",
            "AIF_Gewinnvortrag_Einkuenfte_AIF_inklEA",
            "Substanzverluste_inklEA"
    };
    // TODO - angeblich nicht für errechnete felder.. aber wo kommt diese Liste dann her??
    for (String fieldName : fieldNames) {
        BigDecimal value = steuerMeldung.getFieldValue(fieldName, BigDecimal.class);
        if (value != null && KontrollsummenComparisons.isLessThanZeroByTolerance(value)) {
            validationMsgs.add(ValidationMsg.of(
                    SteuerMeldungPosition.of(steuerMeldung),
                    ValidationMsgCode.ERR_KONTROLL_N_LT_0,
                    ValidationMsg.Severity.ERROR,
                    fieldName,
                    value
            ));
        }
    }
}
```

Test mirrors the same 7 fields verbatim at
`CalculatedSteuerMeldungValidatorsTest.java:948-1030`.

## What the legacy C++ does (source of the list)

`~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp:7137-7398`
inside `cSt_Meldung::CheckKontrollsummen()`. Same 7 `_inklEA` fields, same
order, same per-version conditional for the `ImmoInvF_Gewinnvortrag_*`
variant. Each block follows this pattern (first example, line 7137 onward):

```cpp
// Pr fung: Gewinnvortrag_Ertraegeordentlich_versteuert_inklEA < 0
dValue = pcStF->GetValue0("Gewinnvortrag_Ertraegeordentlich_versteuert_inklEA", nAnzNK);
...
if (dValue < 0)
{
    dValue = round(dValue * 100000)/100000;        // 5-NK Toleranz
    if (dValue < 0)
    {
        sprintf(...szBuf, cStm_Logger::cBugMsgs.GetMsg("ERR_KONTROLL_N<0"),
                "Gewinnvortrag_Ertraegeordentlich_versteuert_inklEA", dValue);
        cStm_Logger::WriteStmBug(...szBuf, "STM_ERROR", 0);
        nKontrollsummen = -1;
        cProStatus.nCheckKontrollsummen = 1;       // ERROR
    }
}
```

Message template registered at
`~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_stm_logger.cpp:369-370`:

```
cBugMsgs.AddMsg(j++, "ERR_KONTROLL_N<0",
    "Das Ergebnis im Feld %s <%.4lf> darf nicht kleiner 0 sein");
```

Key facts about the legacy:

- **No `quelle` filter.** Fields are hardcoded by name.
- **All 7 fields are calculated.** Confirmed in
  `~/dev/projects/oekb/ifas/Kurs/tabledefs/kest_2024/update_5_fields_calc_order.cr`:
  every one has `calc_order >= 1` and `anz_vorgaenger >= 2`
  (e.g. `AIF_Gewinnvortrag_Einkuenfte_AIF_inklEA` calc_order=1;
  `Substanzverluste_inklEA` calc_order=2, anz_vorgaenger=5).
- **No per-line anchor.** `WriteStmBug(szBuf, "STM_ERROR", 0)` — the third
  parameter `nPrintAktRow=0`, and `c_stm_logger.cpp` `Write()` does not emit a
  per-row anchor in that mode. `WriteStmBug` is a thin wrapper that routes via
  `cStm_Logger::nIndexError` to `error.log` (`c_stm_logger.cpp:554-556`). The
  error lands at the meldung level, under the START header. Mirror of the
  Java `SteuerMeldungPosition.of(...)`.
- **Fatal**: `nKontrollsummen = -1`, `cProStatus.nCheckKontrollsummen = 1`,
  callers (`c_st_meldung.cpp:2772`, `:3107`) reject the meldung.
- **Run once per Meldung**, after all field calculations. Not per CSV line.
- **Guarded by an upstream short-circuit** (NEW finding — see next section).

## Why no `ERR_KONTROLL_N<0` ever lands in `error.log` on realistic data

`CheckKontrollsummen()` is gated by `c_st_meldung.cpp:2735-2772`:

```cpp
nRet = CheckMeldung();                            // input-field validation
if ((nRet == 1) && (GetProcessingStatus() == 0))  // "keine Fehler bisher"
{
    ...
    if (GetProcessingStatus() < 0)                // line 2759
    {
        // "Es ist bei der vorherigen Prüfungen ein Fehler aufgetreten"
        return -1;                                // EARLY EXIT
    }
    nRet = CalcMeldung();                         // line 2767
    if (nRet == 0)
        nRet = CheckKontrollsummen();             // line 2772
}
```

The same pattern guards the second call site near `:3107`.

`CheckMeldung()` runs the input-field range validation. When any `_e` input
field violates `>= 0`, it emits "Feld <X> im Satz <E> - Wert <-1> muss
groesser oder gleich 0.0 sein" and flips `GetProcessingStatus() < 0`. The
guard at line 2759 then returns `-1` immediately — `CalcMeldung()` and
`CheckKontrollsummen()` are never reached.

**Empirical confirmation** from this dataset: fund `LU0086913125`
(`target/quick-recalc/error.log` lines 277-385) emits ~50 `muss groesser
oder gleich 0.0` errors and zero `ERR_KONTROLL_N<0` errors. The 7 `_inklEA`
counterparts of those negative `_e` inputs would all be negative on a v5
Ermittlungsvorgabe, yet none are flagged — confirming the early exit fired.

The Java port has no equivalent gate. `SteuerlicheErmittlungDomainService`
filters post-calculation validators only on `StmStatus`
(`shallPostProcessValidate()` at `:131-134` — OPEN/FINAL/CONFIRMED/DELETED).
Input-validation errors do not flip status, so the meldung sails through to
`errKontrollNLt0`, the `_inklEA` values were still computed from the bad
inputs, come out negative, and 7 errors are emitted — visible in
`target/quick-recalc/error#recalc.log` lines 393-399 under the same START.

**Implication for the validator's effective scope**: on realistic data the
only way an `_inklEA` calculated field is < 0 is when at least one of its
`_e` inputs is < 0 (the formula is roughly `sum(_e components) + EA
adjustment`). So the legacy validator was effectively unreachable — every
case it would have caught is pre-empted by `CheckMeldung()`. The 7-field
list is a vestigial defensive layer in the C++ code that almost never
fires.

There is also an earlier `ImmoInvF_Gewinnvortrag_ImmoInvF_Bewirtschaftungsgewinne_inklEA`
check at `c_st_meldung.cpp:6876-6901` inside the v3/v4 fund-art branch, which
the Java port skips (Java keeps only the v5 name `ImmoInvF_Gewinnvortrag_inklEA`).

## `FieldSpec.quelle` infrastructure in IFAS13

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/FieldSpec.java`:

- `Quelle` enum (`:166-198`): `STEUERLICHER_VERTRETER`, `OEKB_KAG`,
  `OEKB_ERRECHNET`, `BMF`, `FORMEL`, `KAG_OEKB`, `KAG`, `OEKB`.
- `Type` enum (`:154-164`): `INPUT_STEUERLICHER_VERTRETER`, `INPUT_BMF`,
  `INPUT_OEKB`, `CALCULATED`, `FIXED_VALUE`, with `isInput()` helper.
- `FieldSpec.isReportedBySteuerlicherVertreter()` (`:286`):
  `type() == INPUT_STEUERLICHER_VERTRETER || reportBySteuerlicherVertreterAllowed`.
- Already used as a filter at `Ermittlungsvorgabe.java:43`:
  `getAllFields().filter(FieldSpec::isReportedBySteuerlicherVertreter)`.

If we accept the expert's framing, the implementation is mechanically trivial:

```java
ermittlungsvorgabe.getAllFields()
    .filter(FieldSpec::isReportedBySteuerlicherVertreter)
    .forEach(spec -> {
        BigDecimal value = steuerMeldung.getFieldValue(spec.definedName(), BigDecimal.class);
        if (value != null && KontrollsummenComparisons.isLessThanZeroByTolerance(value)) {
            validationMsgs.add(ValidationMsg.of(
                    steuerMeldung.getFieldPosition(spec.definedName(), null), // per-row anchor
                    ValidationMsgCode.ERR_KONTROLL_N_LT_0,
                    ValidationMsg.Severity.ERROR,
                    spec.definedName(), value
            ));
        }
    });
```

## The "actual contradiction" — now resolved

Two stories were on the table:

| Story | Evidence |
|-------|----------|
| Check 7 hardcoded calculated `_inklEA` fields, no source filter, meldung-level anchor | Legacy C++ (`c_st_meldung.cpp:7137-7398`), Java port, Java test (`CalculatedSteuerMeldungValidatorsTest.java:948-1030`) |
| Apply only to `quelle = STEUERLICHER_VERTRETER` (i.e. input) fields | Domain expert |

Resolution: **the expert was almost certainly describing a different
check** — the per-input-field `>= 0` rule visible in `error.log` ("Feld
<X> im Satz <E> - Wert <-1> muss groesser oder gleich 0.0 sein") which
*does* iterate `STEUERLICHER_VERTRETER` input fields with per-row anchors.
In Java that's `ERR_UNTERGRENZE` / `ERR_UNTERGRENZE_L` at
`SteuerMeldungErmittlungsvorgabeValidators.java:275-298`.

The 7-field `ERR_KONTROLL_N<0` validator is a separate, vestigial
meldung-level safety net that the legacy short-circuit makes effectively
unreachable. There's no real contradiction — the two stories describe two
different validators.

Other candidate codes still worth noting if more clarity is needed:
- `ERR_KONTROLL_SN_LT_0` ("Die Summe der Inhalte der Meldefelder …")
- `ERR_KONTROLL_LSN_LT_0` ("… fuer Land … darf nicht kleiner 0 sein")
- `ERR_REAL_VERLUSTE` ("Realisierte Verluste aus Substanz … darf nicht
  kleiner 0 sein.")

## Recommended fix (Java side)

Mirror the legacy short-circuit. `errKontrollNLt0` (and likely all
`CalculatedSteuerMeldungValidators`) should not run on a meldung that
already has `ERR_UNTERGRENZE` / `ERR_UNTERGRENZE_L` errors. Two
implementation options:

1. **Gate in the orchestrator** (`SteuerlicheErmittlungDomainService.java`
   around `:107`): only invoke `calculatedSteuerMeldungValidationService.validate(...)`
   on meldungen whose prior validation messages contain no ERROR-severity
   entries. Cleanest mapping of the C++ `GetProcessingStatus() < 0` guard.
2. **Gate per validator**: have `errKontrollNLt0` (and peers) early-return
   if `validationMsgs` already contains any ERROR for this meldung. Local
   change but easy to overlook for new validators.

Option 1 is closer to the legacy flow and self-documenting. The 7-field
list can stay as-is — it never fires under realistic data either way.

## Open questions for the expert

1. **Confirm the diagnosis**: was the expert describing
   `ERR_UNTERGRENZE` / `ERR_UNTERGRENZE_L` (input-field `>= 0`,
   per-row, `STEUERLICHER_VERTRETER`-scoped), not `ERR_KONTROLL_N<0`?
2. **Approve mirroring the legacy short-circuit**: skip
   `CalculatedSteuerMeldungValidators` for meldungen with ERROR-severity
   input-validation messages?
3. Leave the 7-field list in `errKontrollNLt0` untouched (vestigial but
   harmless under the new gate) — or remove it entirely?

## Related issues fixed / proposed in the same session

- **Fixed**: `ValidationMsgGroups` sort/grouping bug that caused calculated
  validation errors to land at the tail of the log in arbitrary order
  (because the wrapper `ProcessedSteuerMeldung` was used as a separate map
  key with `Integer.MAX_VALUE` sort line). Now unwraps via
  `SteuerMeldung.getSourceEntry()` so wrapper and bare `CsvSteuerMeldung`
  collapse to one group. Regression test at
  `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgGroupsTest.java`.
- **Proposed, not implemented**: `ValidationMsgLogWriter` header-suppression
  bug. When the START-line group is iterated after another group, its
  subheader is skipped to avoid repeating the START line — but the result
  is that meldung-level errors visually attach to whatever subheader was
  printed last. Safest fix: only suppress when the START-line group is the
  *first* group emitted; otherwise print a neutral marker (e.g.
  `- (Meldung-Ebene):`) or repeat the START line. Independent of the
  validator-side fix above.

## Key file:line references

- Java validator: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/calculated/CalculatedSteuerMeldungValidators.java:321-344`
- Java message code: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgCode.java:188`
- Java message pattern: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgCodePattern.java:172`
- Java test: `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/validation/calculated/CalculatedSteuerMeldungValidatorsTest.java:948-1030`
- Java `FieldSpec`/`Quelle`: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/FieldSpec.java:52, 154-198, 286`
- Java existing STV filter usage: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/Ermittlungsvorgabe.java:43`
- C++ validator: `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp:7137-7398` (plus v3/v4 extra check at `:6876-6901`)
- C++ message template: `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_stm_logger.cpp:369-370`
- C++ logger anchoring behavior: `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_stm_logger.cpp:629-661`
- C++ field calc-order proof (all 7 are calculated): `~/dev/projects/oekb/ifas/Kurs/tabledefs/kest_2024/update_5_fields_calc_order.cr` (calc_order entries for each field)

## Uncertainties

- The PDF specs under `docs/Validierung/*.pdf` and the spreadsheets
  `Plausi-Steuermeldung.ods` / `Validierung STM.xlsx` could not be text-
  extracted from the shell (no `pdftotext` / spreadsheet dumper). A
  contradicting spec there is possible but unverified.
- The altsystem `error.log` contains zero `ERR_KONTROLL_N<0` matches —
  initially read as "no rendering reference available", but actually
  evidence that the upstream short-circuit at `c_st_meldung.cpp:2759`
  pre-empts the validator on this dataset (see "Why no ERR_KONTROLL_N<0
  ever lands in error.log" section above). A dataset that triggers
  `ERR_KONTROLL_N<0` without any input-field `>= 0` violations would be
  needed to see the legacy rendering, and is unlikely to exist in practice.
