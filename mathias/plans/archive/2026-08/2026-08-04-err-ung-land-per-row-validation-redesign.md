# Option A: restore row multiplicity, revert the mapper to a pure translator

## Context

D2 (position-significant dedup) and D3 (`CsvMessage.getPosition` descending into the per-country node)
are implemented, tested, and verified: the quick-recalc fixture goes from 3 to 26 `ERR_UNG_LAND` at
correct line numbers, `Nur im Neusystem (Fehler)` drops 31 → 22, `Nur im Altsystem` stays 0, and all
8 `GrossfileRecalculationTest` datasets pass with **baselines unchanged**.

D1 as built is being **replaced**. It made `ValidationMsgMapper.mapDuplicateValueError` read the
Ermittlungsvorgabe and emit `ERR_KENNUNG_DBA` / `ERR_UNG_LAND` — codes already owned by
`SteuerMeldungErmittlungsvorgabeValidators.errKennungDba:391` and
`validateCountryVectorInputField:161/:220`. Two authorities per code, and it forced a copy of
`errKennungDba`'s condition (numeric-refcode skip included) into the mapper.

**Root cause.** Legacy validates **per CSV row**: `cStFields_col::SetLandNumberValue`
(`c_stfields.cpp:3420-3460`) runs quelle → duplicate → country and emits the *first* failure, then
`return -1`. The new system validates **per unique (field, country) key**, because `putIfAbsent`
(`CsvMessage:141`) discards duplicate rows before any validator sees them. Two things are lost in the
CSV layer: **row multiplicity** and **cross-layer precedence**. Restore both, in their proper places.

**Division of labour this establishes.** `DUPLICATE_VALUE` is inherently a per-row fact and the mapper
is its rightful owner — one message per offending row, already correct. `ERR_UNG_LAND` and
`ERR_KENNUNG_DBA` are semantic facts owned by validators, which need positions in order to multiply.

## Changes

### 1. `CsvMessage` retains every position that delivered a record-key path

`support-libs/csv-schema/src/main/java/at/oekb/ifas/csv/schema/CsvMessage.java`

`addMapRecordValue` (`:130`) currently drops the duplicate row entirely. Keep a side-list so the
`data` map and `RecordValue` shapes stay untouched:

```java
private final Map<List<String>, List<CsvMessagePosition>> positionsByRecordKeys = new LinkedHashMap<>();
```

In `addMapRecordValue`, append `recordValue.getPosition()` to
`positionsByRecordKeys.computeIfAbsent(List.copyOf(recordKeys), ...)` **before** the `putIfAbsent`,
unconditionally. Then expose:

```java
/** Every row that delivered this field (and country), in file order. */
public List<CsvMessagePosition> getAllPositions(String fieldName, @Nullable String countryCode)
```

Collect from all recorded paths whose first element is `fieldName` and — when `countryCode != null` —
whose second element is `countryCode`; dedupe by `issueLineNumber` (a single row can map more than one
column into the same country node, e.g. `BETRAG` and `BETRAG_JE_ANTEIL`) and preserve insertion order.

### 2. `SteuerMeldung` gains a default `getFieldPositions`

`ifas-domain/ifas-domain-stm/.../stm/meldung/SteuerMeldung.java`

Exact precedent to follow: `getCountryCodesWithInvalidValue` (`:107`) — a `default` returning
`List.of()`, overridden only by `CsvSteuerMeldung`. So the four non-CSV implementations
(`LazyDbSteuerMeldung:292`, `EagerDbSteuerMeldung:283`, `ExcelSteuerMeldung:70`,
`WrappedSteuerMeldung:49`) need no change.

```java
/**
 * All rows that delivered the given field (and country), in file order. CSV submissions may repeat a
 * (field, country) key; legacy reports semantic errors once per row, not once per key. Non-CSV
 * sources have exactly one position per field.
 */
default List<Position> getFieldPositions(String fieldName, @Nullable String countryCode) {
    Position position = getFieldPosition(fieldName, countryCode);
    return position != null ? List.of(position) : List.of();
}
```

`WrappedSteuerMeldung` does need a delegating override so wrappers don't silently lose multiplicity —
it already delegates `getFieldPosition` at `:49`; add the sibling.

### 3. `CsvSteuerMeldung` override

`ifas-domain/ifas-domain-stm/.../stm/meldung/csv/CsvSteuerMeldung.java` (`implements SteuerMeldung`,
so `SteuerMeldung.super.getFieldPositions(...)` is available for the fallback)

```java
@Override
public List<Position> getFieldPositions(String fieldName, @Nullable String countryCode) {
    List<CsvMessagePosition> positions = csvMessage.getAllPositions(fieldName, countryCode);
    return positions.isEmpty()
            ? SteuerMeldung.super.getFieldPositions(fieldName, countryCode)
            : List.copyOf(positions);
}
```

### 4. The validator emits one `ERR_UNG_LAND` per row

`ifas-domain/ifas-domain-stm/.../stm/meldung/validation/SteuerMeldungErmittlungsvorgabeValidators.java`

Scope strictly to the **unknown-country** branches — legacy's `!IsLandOK` path:
- Site A, `:164-171` (`countrySpec == null` inside the `cv.getCountryCodes()` loop)
- Site B, `:221-229` (`validateCountryCodesWithInvalidValue`)

Both currently build one `ValidationMsg` from `getPosition(steuerMeldung, definedName, countryCode)`.
Replace with a shared private helper that loops `steuerMeldung.getFieldPositions(definedName,
countryCode)`, emitting one message per position and falling back to the existing single
`getPosition(...)` when the list is empty.

**Leave Site C (`validateAgainstCountrySpec:355-381`) alone** — that is the *valid* country forbidden
for the Satzart case (`CountrySpec.Befuellung.X`), a different legacy site (`c_stfields.cpp:1012`),
not the per-row `!IsLandOK` path.

**Leave `errKennungDba:391` alone** — making it loop would take `ERR_KENNUNG_DBA` from 1 to 39 for this
file, a much larger output change across every grossfile. Separate decision.

### 5. Revert `ValidationMsgMapper` to a pure translator

`ifas-domain/ifas-domain-stm/.../stm/validation/ValidationMsgMapper.java`

Delete `isUnknownCountry`, `isFieldNotDeliverable`, `resolveRecordType` and the three-way branch;
restore the original two-branch `mapDuplicateValueError` (`DUPLICATE_VALUE` → `ERR_DOPP_FELD_L` /
`ERR_DOPP_FELD`, unconditionally). Drop the now-unused imports (`RecordType`, `FieldCategories`,
`FieldSpec`, `EnumUtils`). Keep the user's `// todo - this seems off` comment on
`if (countryCode != null)`.

### 6. Precedence: one named rule, one place

`ifas-domain/ifas-domain-stm/.../stm/validation/ValidationMsgStore.java` — a new operation alongside
`deduplicate()`, applied in `SteuerMeldungLieferungService:109-116`. This encodes legacy's `return -1`
chain, which is what the split across layers destroyed.

Per entry bucket, keyed purely off `ValidationMsg.getArguments()` (verified arg shapes:
`ERR_UNG_LAND{country, satzart}`, `ERR_DOPP_FELD_L{field, country, satzart}`,
`ERR_DOPP_FELD{field, satzart}`, `ERR_KENNUNG_DBA{field, satzart}`,
`ERR_RECHENFELD_L{field, country, satzart}`, `ERR_RECHENFELD{field, satzart}`):

```
countriesWithUngLand      = { arg0 of each ERR_UNG_LAND }
fieldsWithFieldLevelError = { arg0 of each ERR_KENNUNG_DBA / ERR_RECHENFELD / ERR_RECHENFELD_L }

drop ERR_DOPP_FELD_L when its country ∈ countriesWithUngLand
                       or its field   ∈ fieldsWithFieldLevelError
drop ERR_DOPP_FELD   when its field   ∈ fieldsWithFieldLevelError
```

Keying the country suppression on the country alone (rather than field+country) is correct, not coarse:
an unknown country code is unknown throughout the Meldung. `ERR_UNG_LAND` carries no field, so this is
also the only option available — and it is sufficient, because the validator only iterates fields the
Ermittlungsvorgabe knows, so a non-deliverable field like `D_Dividenden_Subfonds_QuStKESt_e ` never
produces `ERR_UNG_LAND` in the first place (it has no `FieldSpec`; the run logs
`Field 'D_Dividenden_Subfonds_QuStKESt_e ' is not defined in Ermittlungsvorgaben`).

Order matters: run precedence **before** `deduplicate()`, so suppression sees every message.

### 7. `POSITION_SIGNIFICANT` (already in place)

`ERR_UNG_LAND` stays — 5 identical texts at 5 different lines must survive. `ERR_DOPP_FELD_L` stays for
now: after precedence, the surviving duplicates are genuine repeats of valid countries on deliverable
fields, which legacy reports per row. Confirm from the fixture output and report; it is one line to
narrow if the measured result says otherwise.

## Files touched

| File | Change |
|------|--------|
| `support-libs/csv-schema/.../CsvMessage.java` | retain positions per record-key path + `getRowPositions` |
| `ifas-domain-stm/.../meldung/SteuerMeldung.java` | `default getFieldPositions` |
| `ifas-domain-stm/.../meldung/util/WrappedSteuerMeldung.java` | delegate `getFieldPositions` |
| `ifas-domain-stm/.../meldung/csv/CsvSteuerMeldung.java` | override `getFieldPositions` |
| `ifas-domain-stm/.../meldung/validation/SteuerMeldungErmittlungsvorgabeValidators.java` | Sites A + B emit per position |
| `ifas-domain-stm/.../validation/ValidationMsgMapper.java` | revert to pure translator |
| `ifas-domain-stm/.../validation/ValidationMsgStore.java` | precedence operation |
| `ifas-domain-stm/.../meldung/SteuerMeldungLieferungService.java` | apply precedence before dedup |

## Tests

Adjust (not rewrite) the three cases added for the old D1 in
`CsvToValidationMsgCodeTest.ErrDoppFeldLTests`: `processAndMapMessageLevel` exercises only the mapper,
so the unknown-country and non-deliverable cases must now assert `ERR_DOPP_FELD_L` **is** produced —
suppression is no longer the mapper's job. Keep the enriched `MockErmittlungsvorgabe` (it made the
original test test what its name claims) and the `processAndMapMessageLevel(csv, vorgabe)` overload.

Add:
- `CsvMessageTest` (csv-schema): `getRowPositions` returns all rows for a repeated (field, country), one row for a unique one, deduped by line.
- `SteuerMeldungErmittlungsvorgabeValidatorsTest.ErrUngLandTests`: a repeated invalid-country key yields one `ERR_UNG_LAND` per row, at each row's line. Assert message text against a **literal** string, not `formatMessage(<same args>)`.
- `ValidationMsgStoreTest`: precedence drops `ERR_DOPP_FELD_L` for a country with `ERR_UNG_LAND`; drops it for a field with `ERR_KENNUNG_DBA`; leaves a genuine valid-country duplicate untouched.

Keep the already-passing `CsvMessageTest` position tests and the three `ValidationMsgStoreTest`
position-significance tests.

Per `.claude/rules/testing-conventions.md`: given-when-then, AssertJ, `@Inject`.

## Verification

1. `mvn -Pno-proxy -o install -DskipTests -pl ifas-testing/ifas-integration-tests -am`
   (a full `mvn install` fails in this environment on `oekb-auth-support` → `jespa:jespa-jakarta:2.0.5`,
   whose jar was never downloaded — pre-existing, unrelated to this work).
2. `mvn -Pno-proxy -o test -pl support-libs/csv-schema,ifas-domain/ifas-domain-stm` — expect the full
   suite green (1205 tests in domain-stm before this change).
3. Quick-recalc fixture: locally drop `@Disabled` at `QuickRecalculationTest:72` (**do not commit**),
   run, then inspect `ifas-testing/ifas-integration-tests/target/quick-recalc/`:
   - `error#recalc.log` — 26 `Laendercode` messages, on rows 193-197 / 232-236 / 397-401 / 436-440 /
     728 / 780 (never 159), and **zero** `nur einmal pro Meldung` on any `ISO Code` row.
   - `D_Dividenden_Subfonds_QuStKESt_e ` rows must show only
     `Die Lieferung des Feldes … nicht erlaubt.` — no `ERR_UNG_LAND`, no duplicate error.
   - `error#diff-deviations.txt` — `Nur im Neusystem (Fehler)` 22, `Nur im Altsystem` 0,
     `Exakte Treffer` 257.
   - Restore `@Disabled` and `git diff` the file to confirm only the pre-existing `STICHTAG` edit remains.
4. `mvn -Pno-proxy -o test -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest`
   over gf1–gf8. **Leave the baselines at `:199-246` untouched** and report the before/after counter
   table. Current state of this branch: all 8 pass unchanged — anything else is a regression to explain.
5. `mvn -Pno-proxy -o test -pl ifas-testing/ifas-integration-tests -Dtest=ValidationDeltaCalculatorIntegrationTest,StmRecalcJobServicesTest`

## Known deviation, out of scope

`ValidationMsgLogWriter.groupByPosition:181` collects into a `LinkedHashMap`, so positions within a
Meldung print in message-insertion order, not line order (the sort at `:62` is across Meldungen). With
10 `ERR_UNG_LAND` per Meldung this becomes visible: rows 193 and 232 print after 272. Legacy prints
strictly by line number. Pre-existing, affects no counter (the comparator matches by text within a
Meldung); fixing it would reorder every existing log.


---

# Close out Option A: re-verify after the final one-line edit

## Context

Option A is **fully implemented**. `ValidationMsgMapper` is a pure translator again, row multiplicity
lives in the CSV layer, `ERR_UNG_LAND` has a single owner, and legacy's check order is one named rule
(`ValidationMsgStore.applyLegacyCheckPrecedence`).

Verified results:

| | legacy | after redesign |
|---|---|---|
| `ERR_UNG_LAND` in quick-recalc fixture | 26 | 26, identical line numbers in file order |
| duplicate errors on `ISO Code` rows | 0 | 0 |
| `ERR_KENNUNG_DBA` line | 237 (first of 39) | 237 |
| `Nur im Neusystem (Fehler)` | — | 22 (was 31) |
| `Nur im Altsystem` / `Exakte Treffer` | — | 0 / 257 |
| gf1–gf8 baselines | — | unchanged, 8/8 pass |
| unit tests (`csv-schema` + `ifas-domain-stm`) | — | 1214 green |

The log-ordering deviation previously noted as out-of-scope resolved itself: the validator now emits all
five messages consecutively rather than splitting them between validator and mapper, so insertion order
coincides with line order.

**The one gap.** After launching the gf1–gf8 run I added a single guard to
`applyLegacyCheckPrecedence` — skip an entry bucket whose retained list is empty, matching
`filterBySeverity`'s precedent. Both the gf run and the last unit-test run predate it. The guard cannot
change behaviour (a suppression always retains the message that triggered it, so `retained` is never
empty), but that is reasoning rather than evidence.

## Step

Re-run the module suites so every green result covers the code as it now stands:

```bash
mvn -Pno-proxy -o install -DskipTests -pl support-libs/csv-schema,ifas-domain/ifas-domain-stm -am
mvn -Pno-proxy -o test -pl support-libs/csv-schema,ifas-domain/ifas-domain-stm
```

Expect 1214 tests, 0 failures. If the count or outcome differs, the guard was not inert and needs
investigating before this is called done.

`GrossfileRecalculationTest` does **not** need re-running for this: it exercises the same
`applyLegacyCheckPrecedence` path that the unit tests cover directly, and the guard is a no-op on any
input where a message was suppressed. Re-run it only if the unit suite shows a change.

## Note for the commit

`git status` shows two pre-existing local edits that are **not** part of this work and should not be
swept into a commit:
- `QuickRecalculationTest.java` — `STICHTAG` `2026-11-23` → `2026-07-27` (local scratch config)
- `docs/Rekalkulation/Fachabteilung-FRIST-NOSN-gf4.md` — +212/−25, and the staged
  `gf1-d20260724-export.yaml.txt`

`support-libs/csv-schema/.../CsvMessageTest.java` is new and was auto-staged by the IDE; it belongs
with this change.

## Deferred, deliberately

`ERR_KENNUNG_DBA` still reports once per field where legacy reports once per row (1 vs 39 for this
fixture). Making `errKennungDba:391` loop over `getFieldPositions` is now a two-line change — the
plumbing exists — but it is a ~39× output change on a message present in every grossfile, so it wants
its own measured run and its own decision.
