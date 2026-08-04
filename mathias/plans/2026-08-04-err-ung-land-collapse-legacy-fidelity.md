# ERR_UNG_LAND collapse in QuickRecalculationTest: 26 legacy → 3 new

## Context

In `QuickRecalculationTest` (`BestFonds31122025-mh.csv`), the legacy `error.log` contains **26**
`ERROR! Laendercode <ISO Code> nicht erlaubt mit Satzart <D>.` messages — one per offending CSV row.
The new system's `error#recalc.log` contains **3**, and each is attached to the *wrong* line
(e.g. `Zeile-Nr: 159 | D;D_Dividenden_Subfonds_e;170083.6232;AT` — an `AT` row, not an `ISO Code` row).

The input CSV has 39 rows whose country column is the literal string `ISO Code`, 13 per field:

```
193-197, 232-236, 271-275   → Meldung LU0173001644 (START line 132)   legacy: 10 ERR_UNG_LAND
396-401, 435-440, 474-479   → Meldung LU0173002378 (START line 336)   legacy: 12
727-728, 779-780, 831-832   → Meldung LU0173001560 (START line 650)   legacy:  4
```

Legacy emits `ERR_UNG_LAND` for 26 of the 39 — the `D_Dividenden_Subfonds_QuStKESt_e` block
(13 rows) is short-circuited by the earlier `Die Lieferung des Feldes … ist bei der Satzart <D>
nicht erlaubt.` check. The new system emits 1 per Meldung.

`QuickRecalculationTest` asserts nothing (both methods `@Disabled`; it is a manual dev tool). The
assertion-carrying sibling is `GrossfileRecalculationTest`, which locks all six delta counters per
dataset against hard-coded baselines. The delta report for this file currently reads
`Gesamt Altsystem: 257 / Exakte Treffer: 257 / Nur im Altsystem: 0` — `ValidationDeltaCalculator`
matches each *legacy* message to at most one new message but never consumes new messages, so 26
legacy messages all match the same 3 and the collapse is invisible to the comparator. What *is*
visible: 9 spurious `ERR_DOPP_FELD_L` messages inside `Nur im Neusystem (Fehler): 31`.

## Root cause — three stacked defects

For Meldung LU0173001644 the arithmetic is `10 → (5→1 per field) → 2 → (dedup) → 1`.

### D1 — duplicate collapse at parse time (this *is* the duplicate remover)

`support-libs/csv-schema/.../csv/schema/CsvMessage.java:141` (`addMapRecordValue`)

```java
RecordValue existing = currentMap.putIfAbsent(finalKey, recordValue);
```

Rows 194–197 never enter the field map — only 193's entry exists. Each suppressed row instead goes
`CsvIfasMessageProcessor.handleDuplicateValue` (`:726`) → `CsvErrorCode.DUPLICATE_VALUE` →
`ValidationMsgMapper.mapDuplicateValueError` (`:105`) → `ERR_DOPP_FELD_L`. So **5 rows → 1 country
key per field**, and 4 rows produce a duplicate error instead of a country error.

**Legacy emits no duplicate error here.** `cStFields_col::SetLandNumberValue`
(`~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_stfields.cpp:3437`) guards with:

```cpp
if (!(cStF[i].IsNull(strPLand)))   // → ERR_DOPP_FELD_L
```

`cStFields::IsNull(land)` (`c_stfields.cpp:1243`) first calls `IsLandOK`, which returns `0` for
`ISO Code` (no DBA record *and* no ISO country entry) → `IsNull` returns **`-1`** → `!(-1)` is
**false** → the duplicate branch is skipped, control falls through to `SetValue` → `IsLandOK` fails
→ `ERR_UNG_LAND`, **every row**.

This is *not* about the `0.0000` amount: `cABasisParameter::dNull` is `-999.999`
(`Ifas/cprogs2/lib/c_basisparam.cpp:50`), so `SetValue`'s `if (dPBetrag != dNull)` guard
(`c_stfields.cpp:704`) *does* store `0.0000`. For a **valid** country legacy would flag a repeated
`0.0000` row as a duplicate.

⇒ Legacy's duplicate detection has exactly one precondition the new system ignores:
**the country code must be a valid country.** When it isn't, legacy reports the country error per
row and never a duplicate error. Note also the ordering: legacy checks *field deliverability*
(`strQuelle == "O"`, `c_stfields.cpp:3430`) **before** the duplicate check — which is why the
`QuStKESt` block gets the field error and never a country error.

### D2 — over-dedup across fields

`ifas-domain/ifas-domain-stm/.../stm/validation/ValidationMsgStore.java:147-153`

```java
EntryDedupKey key = new EntryDedupKey(msg.getSeverity(), msg.getFormattedMessage());
unique.putIfAbsent(key, msg);
```

Entry-level dedup keys on `(severity, formattedMessage)` — position deliberately excluded (only the
submission-level bucket keys on position). `ERR_UNG_LAND`'s text (`ValidationMsgCode.java:75`) is
`"Laendercode <{0}> nicht erlaubt mit Satzart <{1}>."` — **no field name**. So the message from
`D_Dividenden_Subfonds_e` and the one from `D_Ertragsausgleich_Aufwand_Verlust_Dividenden_Subfonds_e`
render identically and collapse. **2 fields → 1.** The same happens to the four `ERR_DOPP_FELD_L`
from rows 194–197, which collapse to the single one visible at line 194.

Single production caller: `SteuerMeldungLieferungService.java:109-116`.

### D3 — wrong line number on the surviving message

`support-libs/csv-schema/.../csv/schema/CsvMessage.java:82-92`

```java
if (countryCode != null) {
    RecordValue countryRecordValue = mapRecordValue.getValueMap().get(countryCode);
    if (countryRecordValue instanceof SimpleRecordValue sv) {   // never true for country vectors
        return sv.getPosition();
    }
}
// No country code or country code not found — find first SimpleRecordValue in tree
CsvMessagePosition found = findFirstPosition(mapRecordValue);
```

For a country-vector field the per-country node is a **`MapRecordValue`** (children `BETRAG`,
`CODE_NUM`, `BETRAG_JE_ANTEIL`), not a `SimpleRecordValue`. The `countryCode` branch therefore never
matches and it falls through to `findFirstPosition` over the whole field subtree → the field's
**first** country row (line 159, `;AT`). Affects every country-scoped message routed through
`SteuerMeldungErmittlungsvorgabeValidators.getPosition` (`:585`), not just `ERR_UNG_LAND`.

### Emission sites (reference)

All in `ifas-domain/ifas-domain-stm/.../stm/meldung/validation/SteuerMeldungErmittlungsvorgabeValidators.java`,
none with its own dedup/`distinct`/`limit`. Driving loop:
`SteuerMeldungErmittlungsvorgabeValidationService.java:30-40`, once per `FieldSpec` per Meldung.

| Site | Line | Loop | Meaning |
|------|------|------|---------|
| A | 161-171 | `cv.getCountryCodes()` | country code not in Ermittlungsvorgabe |
| B | 220-229 | `getCountryCodesWithInvalidValue()` | country dropped from CV because BETRAG invalid |
| C | 355-381 | inside A's `else` via `validateField` | valid country, `Befuellung.X` for this Satzart |

## Fix

### D3 — `CsvMessage.getPosition` descends into the per-country node

`support-libs/csv-schema/src/main/java/at/oekb/ifas/csv/schema/CsvMessage.java:82-87`

Add a `MapRecordValue` branch for the resolved country node, reusing the existing
`findFirstPosition` helper (`:98`). Keep the `SimpleRecordValue` branch and keep the existing
whole-subtree fallback for "country key genuinely absent":

```java
if (countryCode != null) {
    RecordValue countryRecordValue = mapRecordValue.getValueMap().get(countryCode);
    if (countryRecordValue instanceof SimpleRecordValue sv) {
        return sv.getPosition();
    } else if (countryRecordValue instanceof MapRecordValue countryMap) {
        // country vectors nest BETRAG / CODE_NUM / BETRAG_JE_ANTEIL under the country key
        CsvMessagePosition countryPosition = findFirstPosition(countryMap);
        if (countryPosition != null) {
            return countryPosition;
        }
    }
}
```

No new helper — `findFirstPosition` already recurses.

### D1 — invalid country ⇒ country error, not duplicate error

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgMapper.java:105-118`

**Layering — why "the domain check happens after the dopp_feld check" is the mechanism, not the
problem.** The substitution deliberately does **not** go in the CSV layer. `CsvIfasMessageProcessor`
only records a neutral, uninterpreted fact — *"field X, country Y, line N appeared twice"*
(`CsvErrorCode.DUPLICATE_VALUE`). Nothing decides which German message that becomes until
`SteuerMeldungLieferungService.mapToValidationMsgStore` (`:166-186`), which is a **second pass over
the already-collected `csvValidationMsgs` after the whole file is parsed**, resolving the
`Ermittlungsvorgabe` per message (`:175-177`). So `support-libs/csv-schema` never learns about
countries, and the country lookup happens exactly where the domain knowledge lives.

**The country lookup is already the right seam.** `Ermittlungsvorgabe.getCountrySpec(String)`
(`vorgabe/Ermittlungsvorgabe.java:40`) is an interface method, and it is the **same** one
`SteuerMeldungErmittlungsvorgabeValidators:163,221` already uses for `ERR_UNG_LAND`. Both
`ERR_UNG_LAND` paths therefore agree by construction, and if country codes later move to a database
table the change is behind that method — the mapper is untouched. Only `ExcelErmittlungsvorgabe` is
used for validation today, so no capability probing is warranted.

In `mapDuplicateValueError`, emit `ERR_UNG_LAND(countryCode, recordType)` instead of
`ERR_DOPP_FELD_L` when:

```java
countryCode != null
        && ermittlungsvorgabe != null                              // field is @Nullable (see :177)
        && ermittlungsvorgabe.getCountrySpec(countryCode) == null
```

The `ermittlungsvorgabe != null` check is required, not defensive: `mapToValidationMsgStore:175-177`
passes `null` for non-`CsvMessage` positions, and `resolveFieldName` (`:91`) already guards the same
way. The `CsvMessagePosition` on the `CsvValidationMsg` is already the real per-row line
(`CsvIfasMessageProcessor.addDuplicateValueValidationMsg:756`), so rows 194–197 get correct line
numbers for free.

**Load-bearing guard — legacy's ordering.** Legacy checks field deliverability (`strQuelle == "O"`,
`c_stfields.cpp:3430`) *before* the duplicate check. Verified in the fixture: legacy emits
`Die Lieferung des Feldes <D_Dividenden_Subfonds_QuStKESt_e > ist bei der Satzart <D> nicht erlaubt.`
for **all five** `ISO Code` rows 271–275 (`error.log:156-165`) and never `ERR_UNG_LAND`, never
`ERR_DOPP_FELD_L`. So do not substitute for a field that is not deliverable for that Satzart, or rows
272-275 / 475-479 / 832 gain `ERR_UNG_LAND` messages legacy never emits. Reuse the existing predicate
(`SteuerMeldungErmittlungsvorgabeValidators.isFieldForbiddenForCountry` / the `FieldSpec.befuellung`
lookup at `:176-177`) rather than writing a new one; lift it to package-visible if it is not reachable
from the mapper.

Combined with D3 this yields per field: 1 (Site A, row 193) + 4 (mapper, rows 194–197) = **5** —
matching legacy exactly.

**Rejected alternative** (worth knowing, since it needs no country lookup in the mapper at all): a
post-pass that drops any `ERR_DOPP_FELD_L` for a `(field, country)` which already has an
`ERR_UNG_LAND`. It removes the 9 spurious duplicates without the mapper touching country data, but it
only *deletes* — it cannot recover rows 194–197 as `ERR_UNG_LAND`, so you land on 1 per field instead
of legacy's 5. Rejected because full legacy fidelity was the chosen scope; it is the fallback if the
coupling ever proves unworkable.

### D2 — position-significant codes are deduped by position

`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgCode.java`

Do **not** add a third constructor arg — `declined` already occupies the 2-arg form and
`ERR_UNG_LAND("...", false, true)` would be noise across ~200 constants. Instead add an `EnumSet`
constant plus an accessor, keeping the knowledge on the enum:

```java
private static final Set<ValidationMsgCode> POSITION_SIGNIFICANT =
        EnumSet.of(ERR_UNG_LAND, ERR_DOPP_FELD_L);

/** Legacy reports these once per offending row, so identical text at different rows must survive dedup. */
public boolean isPositionSignificant() {
    return POSITION_SIGNIFICANT.contains(this);
}
```

`ValidationMsgStore.java:147-153` + the `EntryDedupKey` record (`:191-194`): add a nullable
`positionKey` component, populated from `msg.getPosition().toUniqueKeyWithinSubmission()` only when
`msg.getValidationMsgCode().isPositionSignificant()`, otherwise `null`. This preserves the
documented purpose of the position-blind key (collapsing the CSV layer and the Ermittlungsvorgabe
layer emitting the same error for one STM at different `Position` granularity — pinned by
`ValidationMsgStoreTest.givenCsvLayerAndErmittlungsvorgabeLayerForSameStm_whenDeduplicate_thenCollapsedToFirstOccurrence`,
`ValidationMsgStoreTest.java:150-165`). Update the `deduplicate()` Javadoc (`:124-132`) accordingly.

`ERR_DOPP_FELD_L` is in the set because legacy emits one duplicate error per duplicate row; without
it, valid-country duplicates would still collapse 4→1 after D1. It is one line to remove if the
measured shift argues against it.

**Deliberately left out — `ERR_KENNUNG_DBA`** (`ValidationMsgCode.java:150`,
`"Die Lieferung des Feldes <{0}> ist bei der Satzart <{1}> nicht erlaubt."`). Its text carries the
field name but no country, so it collapses the same way: legacy emits it for all 39 `QuStKESt` rows of
Meldung 132 (`error.log:154-165` and up), the new system emits **1** (line 237). Same defect class as
D2, but a ~39× multiplier on a message that appears across every grossfile — a much wider blast radius
than the country errors. Out of scope here; revisit once the D1–D3 baseline shift is measured.
`ERR_NA_LAND` is a similar, smaller candidate.

## Files touched

| File | Change |
|------|--------|
| `support-libs/csv-schema/.../CsvMessage.java` | D3 — `getPosition` country-node branch |
| `ifas-domain/ifas-domain-stm/.../validation/ValidationMsgMapper.java` | D1 — `mapDuplicateValueError` substitution |
| `ifas-domain/ifas-domain-stm/.../meldung/validation/SteuerMeldungErmittlungsvorgabeValidators.java` | D1 — only if the deliverability predicate must be lifted to package-visible |
| `ifas-domain/ifas-domain-stm/.../validation/ValidationMsgCode.java` | D2 — `POSITION_SIGNIFICANT` + accessor |
| `ifas-domain/ifas-domain-stm/.../validation/ValidationMsgStore.java` | D2 — `EntryDedupKey` + Javadoc |

Tests to extend (do not rewrite): `ValidationMsgStoreTest`,
`SteuerMeldungErmittlungsvorgabeValidatorsTest` (`@Nested ErrUngLandTests`, `:417-590` — its cases
all assert `hasSize(1)` for a single field/country, so add multiplicity cases rather than editing
those), and a `CsvMessage.getPosition(field, countryCode)` unit test for the country-vector shape.

Per `.claude/rules/testing-conventions.md`: given-when-then naming, AssertJ, `@Inject`.

## Verification

1. `mvn clean install -Pno-proxy -DskipTests -pl support-libs/csv-schema,ifas-domain/ifas-domain-stm -am`
   (`ValidationMsgMapper` sits next to MapStruct mappers — rebuild the module so annotation
   processing reruns).
2. Unit tests:
   `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm -Dtest=ValidationMsgStoreTest,SteuerMeldungErmittlungsvorgabeValidatorsTest,CsvIfasValidationTest,CsvToValidationMsgCodeTest`
   and `mvn test -Pno-proxy -pl support-libs/csv-schema`.
   `CsvToValidationMsgCodeTest` already exercises `mapDuplicateValueError` with
   `new ValidationMsgMapper(null)` (`:362`) and with a real vorgabe (`:805`) — extend it with a
   valid-country case (still `ERR_DOPP_FELD_L`) and an invalid-country case (`ERR_UNG_LAND`).
3. Enable `QuickRecalculationTest.givenSingleLieferungData_whenRecalculate_thenWriteResultsToFilesystem`
   (drop the `@Disabled` at `:72` locally, do not commit that) and run it. Then inspect
   `ifas-testing/ifas-integration-tests/target/quick-recalc/`:
   - `error#recalc.log` — expect `ERR_UNG_LAND` at lines **193-197 and 232-236** for Meldung 132
     (10, not 1), none at 159, and **no** `ERR_DOPP_FELD_L` for any `ISO Code` row.
   - the `QuStKESt` rows (271-275) must still show only
     `Die Lieferung des Feldes … nicht erlaubt.` — no new `ERR_UNG_LAND` there.
   - `error#diff-deviations.txt` — `Nur im Neusystem (Fehler)` should fall from 31 to 22.
   - `error#diff.txt` — `Nur im Altsystem` must stay 0.
4. `mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest`
   over gf1–gf8. **Leave the baselines at `:199-246` untouched** and report a before/after table of
   the six counters per dataset, calling out which moves are improvements (fewer `onlyInNew`, fewer
   `onlyInLegacy`) and which are regressions.
5. `mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest=ValidationDeltaCalculatorIntegrationTest,StmRecalcJobServicesTest`
   — the delta plumbing and the `error.log` / `error#recalc.log` / `error#diff.txt` zip entries.
6. Full build: `mvn clean install -Pno-proxy` (forbiddenapis runs in `package`).
