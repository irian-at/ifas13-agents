# Code Review: Stichtag-keyed CSV schema lookup

## Context

The uncommitted diff replaces **version-keyed** STM CSV schema lookup with **Stichtag-keyed**
lookup, and extracts the schema cache out of `CsvSteuerMeldungen` into a new
`CsvIfasSchemas` utility class. A `LocalDate stichtag` is threaded through the writer, the
`SteuerMeldungen` facade, `CalculationOutputs`/`RecalculationOutputs`, and the
Ermittlungsvorgabe validation path.

Verified as **behaviour-neutral today**: only one dated schema resource exists per type
(`STM_LIEFERFORMAT_2022-04-03`, `STM_AUSLIEFERFORMAT_2022-04-03`), and `CsvIfasSchemas`
ignores the `stichtag` argument (documented `// todo`). Repo-wide greps confirm no stale
callers of the deleted version-based API, and IDE diagnostics report **no compile errors**
in any of the 18 changed files. `SteuerMeldungLieferungOrigination#getStichtag()` is
`@NullMarked` and non-null, so the six new `origination().getStichtag()` call sites are safe.

The findings below are the leftovers of the migration.

## Fixes to apply

### 1. Broken test — `CsvSteuerMeldungenWriterTest:409`

`givenMixedVersionMeldungen_whenWriteReturnToCsv_thenThrows` asserts an
`IllegalArgumentException` containing `"same schema version"`, but the diff deleted the only
call to `validateSameSchemaVersion` from `internalWriteSteuerMeldungenToCsv`. No test
excludes apply in the root POM, so this test runs and fails.

**Recommended: drop the guard.** Git history shows the version-based dispatch was never
load-bearing — `cbf075fa6` (2025-09-15) introduced `STM_MESSAGE_CSV_SCHEMA_V3..V6` as four
constants all pointing at the *same* resource, with `getSchema(5), // todo - get version` at
the only call site; `a09238d05` (2026-03-18) collapsed them into the two constants this diff
moves. No commit or comment ever asserts the key must be the version. And because Stichtag is
per-delivery while version was per-message, keying on Stichtag removes the very class of bug
`validateSameSchemaVersion` guarded.

So: delete the test, and delete the now-dead `validateSameSchemaVersion` at
`CsvSteuerMeldungenWriter.java:438` (IDE: "never used"). If you'd rather keep a
mixed-version consistency check, restore the call in `internalWriteSteuerMeldungenToCsv` as a
check independent of schema selection — but that is a new decision, not a restoration.

### 2. Dead parameter — `SteuerMeldungErmittlungsvorgabeValidators.java:125`

`determineRecordType(FieldSpec, SteuerMeldung, LocalDate)` no longer uses `steuerMeldung`
(IDE: "Parameter 'steuerMeldung' is never used") — it previously supplied `getVersionsNr()`.
Remove the parameter and update the single call site at line 59.

### 3. Unused imports / dead code (IDE-confirmed)

- `RecalculationOutputs.java:5` — `import at.oekb.ifas.core.temporal.LocalDates;` added by this
  diff, never used.
- `CsvSteuerMeldungen.java:26` — `import static ...CsvIfasSchemas.getSchema;` unused (line 240
  calls it fully qualified). Also remove the double blank line left at the end of the class.
- `CsvSteuerMeldungenWriter.java:438` — `validateSameSchemaVersion` (see #1).

### 4. `CsvIfasSchemas.java` — convention gaps

- **Line 15**: missing `@NullMarked`. `.claude/rules/java-conventions.md` → "Mark every
  class/interface with `@NullMarked`". All three siblings in the package have it. Also make
  the class `final` to match `CsvSteuerMeldungen`.
- **Line 13**: `@Slf4j` with no `log.` call — remove.
- **Line 17**: the moved comment "V3-V6 currently share the same schema; add version-specific
  entries when formats diverge" describes a version mechanism this class no longer has.
  Rewrite for the stichtag-keyed API or drop it.
- **Lines 47-48**: chopped-down call with the closing `)` not on its own line —
  `.claude/rules/java-conventions.md` "Formatting".
- **Lines 38-49**: prefer an exhaustive `switch` expression (as the deleted
  `getSchemaPath` used) over a `switch` statement plus trailing `throw`. `CsvSchemaType` has
  exactly two constants, so the throw is unreachable today; an expression makes adding a
  constant a compile error instead of a runtime one.

### 5. Stichtag consistency in tests

- `SteuerMeldungErmittlungsvorgabeValidationServiceTest:52` loads the CSV with
  `LocalDates.nowInVienna()` but line 63 validates with `STICHTAG = 2022-04-03`. Use one
  value for both.
- `CsvTests.loadCsvFileFromResource(Resource)` (line 48) defaults to
  `LocalDates.nowInVienna()`, making ~25 call sites' schema selection wall-clock dependent,
  while every other changed test pins `LocalDate.of(2022, 4, 3)`. Pin a constant here too.

### 6. Comment hygiene — the six duplicated TODOs

`CalculationOutputs.java:103,117,137` and `RecalculationOutputs.java:370,389,414` each carry
`// todo - can we use stichtag of origination here?`. `.claude/rules/code-comments.md` → "One
fact, stated once" and "No narration, hedging". Answer the question and delete the comments,
or state it once (e.g. on the `SteuerMeldungen` facade) if it must stay.

### 7. Stale test name — `CsvSteuerMeldungenWriterTest:426`

`givenMixedVersionMeldungen_whenWriteEstbReportToCsv_thenDoesNotThrowAndWritesAll` now calls
`writeReturnSteuerMeldungenToCsv`, and its comment still talks about ESTB reports spanning
versions. The test is `@Disabled`, so this is cosmetic — rename to match what it does, or
delete it now that the ESTB path takes a single `SteuerMeldung`.

### 8. Stale package docs — `ifas-domain-stm/.../meldung/package-info.java`

Not in the diff, but this change invalidates three spots:
- `:138` — `"├─ Validate schema version consistency"` documents the step just deleted.
- `:190` — `writeSteuerMeldungenToCsv(outputStream, steuerMeldungen)` — missing `stichtag`.
- `:248` — the usage example `SteuerMeldungen.writeSteuerMeldungenToCsv(out, meldungen);`
  no longer compiles as written.

### 9. Observability regression — `CsvSteuerMeldungenWriter.java:97,112`

Deleting `TypeOfCsv` cost the log lines their only discriminator:
`log.warn("No SteuerMeldungen to write for {}-CSV", typeOfCsv)` became
`log.warn("No SteuerMeldungen to write!")`, and the `"Writing {} {}-CSV SteuerMeldungen …"`
info line is gone. A return-CSV, a delete-CSV and a confirm-CSV now emit byte-identical lines,
and there is no MDC anywhere in `CalculationOutputs` (verified) nor other context to tell them
apart — `SteuerMeldungen.write*ToCsv` builds a fresh writer per call.

Cheapest fix: pass the CSV kind (or just a label) into the writer, or have the three
`SteuerMeldungen` facade methods log which kind they are about to write.

## Design note — Stichtag alone may not be enough

The repo's established "resolve a versioned artifact from a date" contract is
`ErmittlungsvorgabeProvider.getVorgabe(LocalDate gjBeginn, LocalDate stichTag)` /
`DefaultErmittlungsvorgabeProvider.getApplicableBmfVersion(gjBeginn, stichTag)` (line 150),
whose `isApplicable` filters `SteuerMeldungVersion` on **four** bounds — `gjBeginnAb/Bis` *and*
`stichtagAb/Bis`. That is, a Stichtag alone does not determine a version in this codebase; the
pair does.

`CsvIfasSchemas.getSchema(CsvSchemaType, LocalDate stichtag)` takes only the Stichtag.
Harmless today (both branches return the same constant), but when a schema does diverge the
signature will have to change rather than just gaining a map entry. Worth deciding now whether
the API should take `(gjBeginn, stichtag)` or delegate to `ErmittlungsvorgabeProvider`.

Also confirmed: no existing stichtag-keyed schema utility exists to reuse — `csv-schema`
offers only `CsvSchemas.loadCsvSchema(Resource)`, and fondspreise holds a single eager
constant (`CsvPreismeldungen.java:34`). `CsvIfasSchemas` is not reinventing anything. And only
one dated resource exists per STM type, so nothing is being silently ignored.

## Not changing

- `IsinAnforderungDiffTest:87` — `skipUnsupportedVersions` flipped `true` → `false`. The only
  test method in the file is `@Disabled`, so there is no CI impact; flagging it in case it was
  a local-debug leftover rather than intentional. Note the rethrown
  `IllegalArgumentException` there originates in Ermittlungsvorgabe resolution
  (`ExcelErmittlungsvorgabeResources:25`), which this diff does not touch — so `false` will
  still abort on an unsupported version.

## Verification

```bash
mvn clean install -Pno-proxy -pl ifas-domain/ifas-domain-stm -am
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm \
    -Dtest='CsvSteuerMeldungenWriterTest+CsvSteuerMeldungenRoundTripTest+SteuerMeldungErmittlungsvorgabeValidatorsTest+CsvIfasValidationTest+CsvToValidationMsgCodeTest'
mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests \
    -Dtest=SteuerMeldungErmittlungsvorgabeValidationServiceTest
```

Then re-run `mcp__idea__get_file_problems` on `CsvIfasSchemas.java`,
`CsvSteuerMeldungenWriter.java`, `CsvSteuerMeldungen.java`, `RecalculationOutputs.java`, and
`SteuerMeldungErmittlungsvorgabeValidators.java` — all five should come back with no
unused-import / never-used warnings.
