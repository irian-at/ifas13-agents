# Fix `CsvMessage.hasRecordType` for `MULTI_ROW_MAP` records

## Context

`QuickRecalculationTest` on `20260710_134629_eb_143_0754a03_eu_at0000a3ftp1_20260710_133500_2#recalc.zip`
reports 4 Altsystem-only errors on the single `STATUS;UPDATE;674321` Meldung:

```
Zeile 4 | E;165;-2256,5700   ERR_UNTERGRENZE  Aufwand_Gesamtbetrag_e
Zeile 9 | E;166;-2256,5700   ERR_UNTERGRENZE  Aufwand_Gesamtbetrag_KV_e
Zeile 9                      ERR_PFLICHT_FEHL Aufwand_Gesamtbetrag_e
Zeile 9                      ERR_PFLICHT_FEHL Aufwand_Gesamtbetrag_KV_e
```

Debugging showed the cause: the partial-update gate in
`SteuerMeldungErmittlungsvorgabeValidators.java:70-72`

```java
if (status == StmStatus.UPDATE && !inputHasRecordType(steuerMeldung, recordType)) {
    return List.of();
}
```

bails out for `RecordType.E` even though the CSV contains E rows, because
`CsvMessage.hasRecordType` (`support-libs/csv-schema/.../CsvMessage.java:254`) inspects only
**top-level** `data.values()` and `return false`s for `MapRecordValue`:

```java
return data.values().stream().anyMatch(rv -> {
    if (rv instanceof SimpleRecordValue srv) { return recordType.equals(srv.getPosition().recordType()); }
    if (rv instanceof EmptyRecordValue erv)  { return recordType.equals(erv.getPosition().recordType()); }
    return false;                                  // ← every MULTI_ROW_MAP record lands here
});
```

`MULTI_ROW_MAP` + `MULTI_VALUE` records (E, D, Z, ZA, AS) are stored as a top-level
`MapRecordValue` keyed by field name — `data["Aufwand_Gesamtbetrag_e"] = MapRecordValue{BETRAG → SimpleRecordValue}`
after `replaceNumericRecordKeyWithFieldName`. `MapRecordValue` carries no position at all
(`MapRecordValue.java` holds only `valueMap`); the `recordType` lives on the leaf
`SimpleRecordValue`s.

Not a regression in storage — the helper never supported these record types:

| Commit | Date | What |
|---|---|---|
| `bfb1261db` | 2025-12-02 | numeric E code → field name hoisting to top level |
| `7fa631ac2` | 2026-02-11 | `hasRecordType` introduced for `ERR_SATZ_FEHLT`/`ERR_RECHENFELD`, top-level `SimpleRecordValue` only, used for `"EA"` (positional) |
| `1b8a15ab2` | 2026-03-12 | extended to `EmptyRecordValue`; `addEmptyRecordValue` is only called from `addSingleRowRecordValues` (`CsvIfasMessageProcessor.java:369`) |
| `287575751` | 2026-06-12 | partial-update gate reuses it for E/D/Z/ZA/AS — where it is structurally wrong |

**Impact beyond this Lieferung:** the gate currently skips level-3 field validation for *every*
E/D/Z/ZA/AS field of *every* `UPDATE` Meldung — `ERR_PFLICHT_FEHL`, `ERR_UNTERGRENZE(_L)`,
`ERR_NA_LAND`, `ERR_UNG_LAND`, `ERR_FELD_MELDEST`. STAMMDATEN/EA/START fields are unaffected
(their columns land as top-level `SimpleRecordValue`s), STB fields are skipped anyway
(`SteuerMeldungErmittlungsvorgabeValidators.java:82-84`).

## Change

### `support-libs/csv-schema/src/main/java/at/oekb/ifas/csv/schema/CsvMessage.java`

Make `hasRecordType` descend recursively into `MapRecordValue`, keeping the existing
`SimpleRecordValue` / `EmptyRecordValue` handling. Recursion, not a single unwrap: per
`RecordKeyPath`'s javadoc a plain E field is `[<field>, BETRAG]` (one nesting) while a
country-vector row is `[<field>, AT, BETRAG]` (two), so D/Z/ZA/AS need arbitrary depth.

Extract a private static helper that takes a `RecordValue` and the wanted record type, and have
the public method stream `data.values()` through it. Update the javadoc: it currently says
*"Derives this from the record type stored in the positions of parsed field values"* — keep that
wording but note it covers nested map records too.

Deliberately **not** reimplemented on top of `rowPositionsByPath`: that map is also fed for values
that never reached `data` (repeated keys, missing required columns) and is not fed for
`EmptyRecordValue`, so switching sources would both widen and narrow the semantics at once.

### No change to `inputHasRecordType`

`SteuerMeldungErmittlungsvorgabeValidators.inputHasRecordType` (`:118-123`) is already correct —
it asks the right question, the answer was wrong.

## Tests

**`support-libs/csv-schema/src/test/java/at/oekb/ifas/csv/schema/CsvMessageTest.java`** — the method
has no direct coverage today (the `hasRecordType` calls in `CsvIfasValidationTest` are the unrelated
`CsvValidationMsgAssertions` helper). Add:

- `givenMultiRowMapRecord_whenHasRecordType_thenTrue` — one nesting level (`E` field → `BETRAG`)
- `givenNestedCountryMapRecord_whenHasRecordType_thenTrue` — two levels (`D` field → country → `BETRAG`)
- `givenOnlyOtherRecordTypes_whenHasRecordType_thenFalse` — guards against the recursion matching everything
- keep/extend the positional and `EmptyRecordValue` cases so `1b8a15ab2`'s behaviour stays covered

**`ifas-domain/ifas-domain-stm/src/test/java/.../meldung/validation/`** — add a case asserting that
an `UPDATE` Meldung carrying an E row with a negative value below its Untergrenze yields
`ERR_UNTERGRENZE`. `SteuerMeldungErmittlungsvorgabeValidatorsTest` only uses synthetic
`FieldSpecTestdata` specs, so drive this one through a real `CsvSteuerMeldung`
(`CsvTests.getCsvSteuerMeldungWithValidations`) to cover the gate itself.

**`ifas-domain/ifas-domain-stm/src/test/java/.../vorgabe/ErmittlungsvorgabenTest.java`** — add an
assertion that V6 `Aufwand_Gesamtbetrag_e` parses to `untergrenze == 0` and
`befuellung == MANDATORY`. The file asserts parsed `untergrenze` for other fields but not these,
and it pins the metadata this fix depends on.

## Verification

```bash
mvn test -Pno-proxy -pl support-libs/csv-schema -Dtest=CsvMessageTest
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm
```

Then re-run `QuickRecalculationTest#givenSingleLieferungData_whenRecalculate_thenWriteResultsToFilesystem`
(remove `@Disabled`) and check `target/quick-recalc/error#diff-deviations.txt`.

Expected after the fix:

- the two `ERR_UNTERGRENZE` deviations disappear (now emitted on lines 4 and 9)
- the two `ERR_PFLICHT_FEHL` deviations disappear via
  `validation/delta/FieldNotFilledCoveredBySpecificFieldError` — legacy discards the rejected value
  (`c_stfields.cpp:607` returns before `nIsNull = 0` at `:651`) so the field stays NULL and its
  mandatory pass fires too; that delta rule covers a legacy `ERR_PFLICHT_FEHL` as soon as IFAS13
  reports *any* message on the same field
- the Neusystem-only `Melde-ID <674321> ist nicht vorhanden` **warning** and the three info-log
  `aus der urspruenglichen Meldung` lines **remain**. Legacy's `ProcessMeldung_UPDATE`
  (`c_st_meldung.cpp:3129-3138`) only reaches `CheckVorhandeneMeldung()` when `CheckMeldung()`
  returned 1, so a field error means legacy ran neither check; IFAS13 has the inverse phase order
  (`SteuerMeldungLieferungService.java:97` before `:98`) and no short-circuit. Out of scope here.

So the delta should go from 7 errors + 1 warning to 3 errors + 1 warning.

Also re-run the broader recalc suites (`GrossfileRecalculationTest`, `StmDiffsTest`) — this
re-enables level-3 field validation for all UPDATE Meldungen, so previously-suppressed
`ERR_PFLICHT_FEHL`/`ERR_UNTERGRENZE`/`ERR_UNG_LAND` messages will start appearing there and may
shift expected deltas in both directions.

## Note on the fixture (no action)

`STEUER_MELDUNG 674321` in the testdata YAML has `gueltBis: 2026-07-10T14:26:28.83` and is
superseded by `682575` (`vorherigeStmId: 674321`, `anzahlAnteile: 82771.833`,
`meldungszeitraumEnde: 2026-07-10`) — the FIN result of this Lieferung's successor. The snapshot is
post-state; at the real processing time (13:46) 674321 was still active. That is why the new system
raises `ERR_MELDID_NICHT_MEHR_GUELTIG` (not `ERR_MELDID_FEHLT`), downgraded to WARNUNG by
`ValidationDeltaReports.java:195` under `RECALC_ARTIFACT_DIFFS_AS_WARNING`.
