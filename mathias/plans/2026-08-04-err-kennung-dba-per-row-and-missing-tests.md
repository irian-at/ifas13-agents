# Close the todo, add the missing tests, report `ERR_KENNUNG_DBA` per row

## Context

Stages 0–3 are done and verified: `RecordKeyPath` replaced the bare `List<String>` paths, field positions
consult the rows that addressed them, and the entry dedup key is uniformly `(severity, text, position)` —
`POSITION_SIGNIFICANT` and `isPositionSignificant()` are gone, and `ValidationMsgCode`'s diff is empty.
gf1–gf8 pass with baselines untouched; quick-recalc is byte-identical (26/26 `Laendercode`, 0 duplicate
errors on `ISO Code` rows). Along the way the probe surfaced a real duplicate (`validateIsin` reporting the
same invalid value for `ISIN` and `END_ISIN`, fixed at source) and a real gap (a third `EA` parameter-count
error legacy reports that we were swallowing, now emitted).

Three things remain.

## 1. Resolve the `should we return null instead?` question

The todo comment is already gone, but the question deserves a stated answer rather than an implicit one.

**Answer: no.** `CsvMessage.getPosition` has 12 callers
(`CsvSteuerMeldungValidations` ×6, `CsvAusschuettungenValidations` ×4, `CsvSteuerMeldung` ×2) and every one
feeds the result straight into message construction, where `ValidationMsg`'s constructor does
`Objects.requireNonNull(position)`. Returning null would push the same fallback decision into 12 places.
The method's job is "give this message somewhere to point", and it now has a three-tier answer:

1. the real position from `data`
2. the position of a row that addressed the path (a repeated key, or a required column that was missing)
3. the message's own position — nothing in the file addressed the field at all

Action: replace the inline comments with a proper Javadoc on `getPosition` stating that contract and that it
never returns null. That closes the question in a form the next reader can act on.

**Deliberately not doing** (worth knowing it was considered): adding a `@Nullable findPosition(...)` and
rewiring `CsvSteuerMeldung.getFieldPosition` to it, so the validators' `SteuerMeldungPositions.positionOf`
fallback at `SteuerMeldungErmittlungsvorgabeValidators:606-607` stops being dead code. It is a real
improvement in honesty, but the two fallback positions are not interchangeable: today's synthetic position
has `recordType == null`, `colIdx == -1` and no `CSVRecord`, so it prints `Zeile-Nr: N`, whereas
`firstLinePosition` prints `Zeile-Nr: N | START;…`. Swapping them changes log output and would need its own
measured run. Also, adding `findPosition` with no caller is speculative API. Separate decision.

## 2. The missing unit tests

New `support-libs/csv-schema/src/test/.../RecordKeyPathTest.java`
- `of(String...)` / `of(List)`, `append` returns a new path and leaves the original untouched
- `startsWith` — matching prefix, non-matching prefix, prefix longer than the path, empty prefix
- `first` / `last` / `size` / `isEmpty`
- **map-key behaviour**: two independently built equal paths hash and compare equal, so they collide in a
  `HashMap` — this is what `positionsByRecordKeys` depends on
- **immutability**: mutating the list passed to the constructor does not change the path, and `keys()`
  rejects modification

`CsvMessageTest` — the stage-1 case that no fixture exercises. Using the public
`recordFieldPosition(RecordKeyPath, CsvMessagePosition)`: record a row for a field whose value never landed
in `data`, then assert `getPosition` returns **that row's line**, not `firstLineNr`. Plus the negative:
a field nothing addressed still falls back to `firstLineNr`.

`SteuerMeldungErmittlungsvorgabeValidatorsTest` — `ERR_KENNUNG_DBA` emitted once per delivered row, at each
row's line (see item 3). Assert message text against a **literal** string, not
`formatMessage(<same args>)`.

**Prove the rewritten dedup test can fail.** The whole point was that the old one could not. Temporarily
drop the position from `EntryDedupKey`, run `ValidationMsgStoreTest`, and confirm
`givenCsvLayerAndErmittlungsvorgabeLayerAtDifferentRows_whenDeduplicate_thenBothRetained` and
`givenSameTextAtDifferentLinesOfSameEntry_whenDeduplicate_thenBothRetained` **fail**; then revert the probe.
Without this the test suite is unverified against the exact regression it exists to catch.

## 3. `ERR_KENNUNG_DBA` once per row

`ifas-domain-stm/.../meldung/validation/SteuerMeldungErmittlungsvorgabeValidators.java`,
`.../SteuerMeldungErmittlungsvorgabeValidationService.java`

Legacy reports the field-not-allowed error for **every** row of the offending field. Measured on the
quick-recalc fixture: legacy **231**, current new system **6** (one per Meldung). Per-Meldung legacy counts
are 27 / 39 / 39 / 35 / 52 / 39 for START lines 1 / 132 / 336 / 497 / 650 / 854.

`errKennungDba:411` builds one message from `getPosition(steuerMeldung, fieldNameStr, null)`. The plumbing to
do this per row already exists — `SteuerMeldung.getFieldPositions`, added in stage 0/1 and already used by
`addErrUngLandPerRow`.

Extract the shared shape rather than duplicating it (two per-row emitters now):

```java
/** One message per row that delivered the field (and country) — legacy validates per row, not per key. */
private static List<ValidationMsg> perDeliveredRow(
        SteuerMeldung steuerMeldung, String definedName, @Nullable String countryCode,
        Function<Position, ValidationMsg> msgFactory
) {
    List<Position> positions = steuerMeldung.getFieldPositions(definedName, countryCode);
    if (positions.isEmpty()) {
        positions = List.of(getPosition(steuerMeldung, definedName, countryCode));
    }
    return positions.stream().map(msgFactory).toList();
}
```

- rewrite `addErrUngLandPerRow` in terms of it (behaviour unchanged — the fixture must stay at 26)
- change `errKennungDba` to return `List<ValidationMsg>`, keeping its existing guards intact: the numeric
  refcode skip (`:420`), the `DATA_RECORD_TYPES` check, and the
  `fieldSpec == null || !isAllowedForRecordType` condition. Derive `recordType` from the primary position as
  today; all rows of one field share it.
- in the service, replace the `collectIfPresent(… ::errKennungDba)` call (`:44-47`) with
  `validationMsgs.addAll(errKennungDba(…))`, matching how `errRechenfeldL` is already called at `:56-59`.

The uniform position-aware dedup key is what lets all 231 survive; under the old per-code flag they would
have collapsed to one.

**Out of scope, flagged not assumed:** `errRechenfeld` (`:446`) has the same single-message shape and legacy
may well report it per row too. Its sibling `errRechenfeldL` already returns a list. Not touching it without
measuring separately — say so rather than bundling it in.

## Verification

```bash
mvn -Pno-proxy -o install -DskipTests -pl support-libs/csv-schema,ifas-domain/ifas-domain-stm -am
mvn -Pno-proxy -o test -pl support-libs/csv-schema,ifas-domain/ifas-domain-stm
mvn -Pno-proxy -o install -DskipTests -pl ifas-testing/ifas-integration-tests -am
mvn -Pno-proxy -o test -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest
```

Quick-recalc (enable `QuickRecalculationTest:72` locally, restore `@Disabled` after, then `git diff` the file
— only the pre-existing `STICHTAG` edit should remain):

- `Die Lieferung des Feldes` — expect **231**, matching legacy, with per-Meldung counts 27/39/39/35/52/39
- `Laendercode` must stay **26**, and duplicate errors on `ISO Code` rows must stay **0**
- `Exakte Treffer` 257 and `Nur im Altsystem` 0 must hold; `Nur im Neusystem (Fehler)` is the number to watch
  — report it either way rather than assuming +225 messages are absorbed

gf1–gf8: baselines at `GrossfileRecalculationTest:199-246` stay **untouched**; report the counter shift. This
is a far larger output change than anything so far (`ERR_KENNUNG_DBA` appears in every grossfile), so a
baseline move here is expected rather than a red flag — but each moved counter needs naming and a judgement
on whether it moved toward legacy.
