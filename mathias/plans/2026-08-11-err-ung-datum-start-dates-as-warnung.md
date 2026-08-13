# Downgrade only-in-new ERR_UNG_DATUM on post-gjBeginn START dates to WARNUNG

## Context

`QuickRecalculationTest` on bundle `189912_LU2561047924_JM_1620155.csv` (START row has
`GJ_Beginn = GJ_Ende = 18991230`) produces this deviation in
`target/quick-recalc/error#diff-deviations.txt`:

```
[+] NUR IM NEUSYSTEM (FEHLER)
    ERROR! Das Datumsfeld <Geschäftsjahr Ende> im Satz <START> hat den ungueltigen Wert <18991230>.
```

The new system is right and legacy is the one that is incomplete. In
`~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp` the START-row parser runs
in this order:

| line | what |
|------|------|
| ~1245 | `daGj_beginn.Set(...)`; year < 2000 → `ERR_UNG_DATUM` for `Geschaeftsjahr-Beginn` |
| ~1275 | `SetAkt_GjBeginn(...)` fails → `ERR_GET_VERSION`, then **`return -1`** |
| ~1340 | `GJ_Ende_e` date check — never reached |
| ~1360 | `Meldezeitraum_Beginn_e` date check — never reached |
| ~1380 | `Meldezeitraum_Ende_e` date check — never reached |

So legacy's silence on the last three fields is an early-return artifact, not a decision. The
new system's `CsvSteuerMeldungValidations.validate()` has no such short-circuit and reports every
pre-2000 START date. Keep those messages — just stop the delta report from scoring them as
regressions against legacy.

Note the downgrade can only ever fire when legacy stayed silent: when gjBeginn is valid and
gjEnde is pre-2000, legacy *does* emit its own `ERR_UNG_DATUM`, the two pair up as an
`EXAKTER TREFFER`, and the message never reaches `onlyInNew`.

## Change

### 1. `ifas-domain/ifas-domain-stm/.../validation/delta/ValidationDeltaReports.java`

Add three entries to `CODE_FIELD_PAIRS_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW` (the existing
unconditional (code, field) allowlist, currently holding only the `ERR_UNG_NUMMER` /
`STM_ID_REF` rule):

```java
private static final Set<CodeAndField> CODE_FIELD_PAIRS_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW = Set.of(
        // non-numeric in the numeric STM_ID_REF field (Melde-ID vorherige Meldung); legacy tolerated it.
        // SteuerMeldungLieferungService downgrades it to INFO, so it lands in the info diff, not the error diff.
        new CodeAndField(ERR_UNG_NUMMER, 0, SteuerMeldung.FieldName.STM_ID_REF),
        // pre-2000 START date. Legacy aborts at the FMVO version lookup right after its gjBeginn
        // check (c_st_meldung.cpp ~1275 return -1) and never reaches these three field checks,
        // so an only-in-new hit means legacy bailed out early, not that we are wrong.
        new CodeAndField(ERR_UNG_DATUM, 0, SteuerMeldung.FieldName.GJ_ENDE),
        new CodeAndField(ERR_UNG_DATUM, 0, SteuerMeldung.FieldName.MELDEZEITRAUM_BEGINN),
        new CodeAndField(ERR_UNG_DATUM, 0, SteuerMeldung.FieldName.MELDEZEITRAUM_ENDE)
);
```

`ERR_UNG_DATUM` is already static-imported. `ValidationMsgMapper` puts the `FieldName` at
argument index 0 on both emit paths (`INVALID_DATE_VALUE` at line 64, `VALUE_TYPE_VALIDATION`
`case "DATE"` at line 135), and `matchesCodeFieldWarningRule` compares `FieldName.definedName()`
— i.e. `"GJ_Ende_e"`, not the display name `"Geschäftsjahr Ende"`. No other code needed.

Deliberately **not** a `ValidationSetting` flag: per its javadoc every flag has two effects — delta-report
severity *and* an `ignore*Errors` twin in `SteuerlicheErmittlungRecalcOptions` that lets the meldung
reach a successful status. Here the meldung is legitimately declined (legacy declines it too), so only
the report half is wanted. The unconditional (code, field) set is the report-only hook.

### 2. `ifas-domain/ifas-domain-stm/.../validation/SteuerMeldungDomainValidationService.java`

Fix the javadoc on `validateGeschaeftsjahr` (lines 367-371) and the inline comment at 401-402.
Both currently claim *"the CPP parser emits ERR_UNG_DATUM for each such field and then aborts via
the FMVO version lookup"*. Per the table above it emits it for gjBeginn only. The short-circuit
itself stays correct and unchanged — only the stated reason is wrong.

## Effect

`isShowAsWarningIfOnlyInNew` feeds three consumers, so all of them shift together:

- `ValidationDeltaReportWriter:289` — the `[+] NUR IM NEUSYSTEM (…)` label → `WARNUNG`
- `ValidationDeltaCalculator.countOnlyInNewBySeverity` — the Zusammenfassung block moves the count
  from *Nur im Neusystem (Fehler)* to *(Warnung)*
- `ValidationDeltaReports.getValidationDeltas` → `BundleRecalculationResult.countValidationErrors()`,
  which drives the recalc protocol's ‼️/⚠️ icon and the `GrossfileRecalculationTest` baselines

## Verification

1. `mvn clean install -Pno-proxy -pl ifas-domain/ifas-domain-stm -am -DskipTests` to compile.
2. `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm -Dtest=ValidationDeltaReportWriterDeviationsOnlyTest`
   — existing coverage of the FEHLER/WARNUNG labels (lines 175, 199-200, 224-225). Add a case there
   for an only-in-new `ERR_UNG_DATUM` on `GJ_Ende_e` asserting the `WARNUNG` label, since the class
   already builds only-in-new fixtures.
3. Re-run `QuickRecalculationTest#givenSingleLieferungData_...` from the IDE (it is `@Disabled`) with
   the same bundle still in
   `ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/issues/quick-recalc/`.
   Expect in `target/quick-recalc/error#diff-deviations.txt`:
   - `[+] NUR IM NEUSYSTEM (WARNUNG)` on the Geschäftsjahr-Ende line
   - Zusammenfassung: `Nur im Neusystem (Fehler) : 0`, `Nur im Neusystem (Warnung) : 1`
4. `mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest`.
   The rule is unconditional, so it also applies there (that test uses `ValidationSetting.DEFAULT`).
   gf1 is the only dataset with regenerated output locally and its two `ERR_UNG_DATUM` deviations are
   on `Timestamp`/`END`, so no shift is expected — but gf2…gf8 have not been checked. If a baseline
   fails, move the delta from `onlyInNewError` to `onlyInNewWarning` in the matching
   `SummaryExpectation` after confirming in the regenerated
   `target/grossfile-recalc/<dataset>/error#diff-deviations.txt` that the moved line really is a
   pre-2000 START date.
