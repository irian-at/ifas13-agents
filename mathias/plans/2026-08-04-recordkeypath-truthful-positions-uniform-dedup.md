# `RecordKeyPath`, truthful field positions, then drop `POSITION_SIGNIFICANT`

## Context

`ValidationMsgStore`'s entry-level dedup key omits the position. That forced a per-code
`POSITION_SIGNIFICANT` flag on `ValidationMsgCode` so `ERR_UNG_LAND` — whose text names neither the field
nor the row — survives dedup once per offending row. The flag is a patch; the goal is to delete it by
making the key uniformly position-aware.

**Why the key is position-blind.** Introduced in `8e3df4cc0` as `deduplicateByStmAndText`, whose Javadoc
says: *"Owner-scoped messages ignore the line number to keep the CSV-layer / Ermittlungsvorgabe-layer
collapse working."* One STM, one problem, reported twice at different position granularity.

**Why the granularity differs — the actual root.** The validator is not at fault: `getPosition:605-608`
asks for the field position first and only falls back to `SteuerMeldungPositions.positionOf(stm)` on
`null`. But `CsvMessage.getPosition` **never returns null** — when the field is absent from `data` it
fabricates `CsvMessagePosition.of(this, null, firstLineNr, null)` (`CsvMessage:109`, carrying the existing
`// todo - should we return null instead?`). The fallback therefore never fires for CSV STMs, and the
validator gets a synthetic position indistinguishable from a real one.

Meanwhile `handleMissingRequiredField:777-802` **knows the exact line and column** and records it only in a
`CsvValidationMsg` — never anywhere the position lookup can reach.

⇒ Wherever the two layers overlap, a real line exists; it just isn't propagated. Where none exists (the
whole record type is absent) the CSV layer emits nothing, so there is no duplicate to collapse and the
START-line stand-in is harmless.

**Scope caveat — the overlap is narrow.** `resolveFieldNameForMissingField:813-822` deliberately emits
generic Altsystem labels (`"Code fuer Land"`, `"Wert des Feldes"`) for missing `LAENDERCODE`/`BETRAG` on
`MULTI_ROW_MAP` records, so for D/Z/ZA/AS/E the layers never render the same text and never interact with
dedup. For `START`, `firstLineNr` already *is* the right line. The genuinely divergent case is a missing
required column in `EA` / `STATUS` / `END`. Empirically **gf1 carries 77 messages in the
`ERR_PFLICHT_FEHL` / `ERR_UNG_NUMMER` family, gf2–gf8 none** — so this must be measured on gf1.
`ERR_UNG_NUMMER` is likely already fine: an invalid value *is* stored
(`CsvIfasMessageProcessor:489`, `SimpleRecordValue.invalid(position, …)`), so both layers already agree.

## Stage 0 — introduce `RecordKeyPath`

Addresses the existing `// todo - change recordKeys to Type RecordKeyPath` (`CsvMessage:172`). Done first
because stage 1 adds a third path-building site, and it should not add another bare `List<String>`.

New `support-libs/csv-schema/src/main/java/at/oekb/ifas/csv/schema/RecordKeyPath.java`. The path is the
record's key columns (`[fieldName]` for E, `[fieldName, countryCode]` for D/Z/ZA/AS) plus, for
`MULTI_VALUE`, the value column's `mapCode` (`BETRAG` / `CODE_NUM` / `BETRAG_JE_ANTEIL`).

```java
public record RecordKeyPath(List<String> keys) {
    public RecordKeyPath {
        keys = List.copyOf(keys);   // immutable — this is used as a Map key
    }
    public static RecordKeyPath of(String... keys) { ... }
    public static RecordKeyPath of(List<String> keys) { ... }
    public RecordKeyPath append(String key) { ... }
    public boolean startsWith(String... prefix) { ... }
    public String first() / last();  public boolean isEmpty();  public int size();
}
```

The defensive copy in the canonical constructor is what makes value-based `equals`/`hashCode` (inherited
from `List`) safe for map keying.

Replaces, with no behaviour change:

| Today | After |
|---|---|
| `addMapRecordValue(List<String>, SimpleRecordValue)` | `addMapRecordValue(RecordKeyPath, SimpleRecordValue)` |
| `Map<List<String>, List<CsvMessagePosition>> positionsByRecordKeys` | `Map<RecordKeyPath, …>` |
| `matchesRecordKeyPath(keys, field, country)` + `get(1)` / `size() > 1` index arithmetic | `path.startsWith(field)` / `path.startsWith(field, country)` |
| `addNestedRecordKeys` copying into a new `ArrayList` | `baseKeys.append(fieldCode)` |
| `collectRecordKeys` → `List<String>` | → `RecordKeyPath` |

Call sites: `CsvIfasMessageProcessor` (`:439`, `:449`, `:481`, `:489`, `:491`, `:507`, `:512`, `:618`,
`:637`) and four test sites (`CsvMessageTest`, `SteuerMeldungErmittlungsvorgabeValidatorsTest:634/1141/1186`).
`addSimpleRecordValue` and `addEmptyRecordValue` take single keys and are untouched. The Ausschüttung
processor does not use map records.

## Stage 1 — propagate the real position for a missing required column

`CsvMessage`, `CsvIfasMessageProcessor.handleMissingRequiredField`

`positionsByRecordKeys` already records every row that delivered a key. Extend it to record a row whose
**required column was missing**, so `getPosition`/`getRowPositions` return the true line instead of the
`firstLineNr` stand-in. Add a narrow entry point (e.g.
`CsvMessage.recordFieldPosition(RecordKeyPath, CsvMessagePosition)`) called from
`handleMissingRequiredField` alongside the existing `addValidationMsg`.

Detail to get right: the recorded path must be the one `getPosition` looks up. Derive it from
`columnSchema`/`baseRecordKeys` — **not** from `resolveFieldNameForMissingField`, which returns a display
label for multi-row records.

Behaviour change here: positions get more accurate. Dedup still ignores them, so no counts move.

## Stage 2 — verify stage 0+1 changed only positions

Module suites, then gf1–gf8 with baselines untouched. Counts must be identical; only `Zeile-Nr` values in
`error#recalc.log` may move, and only toward the correct line. Any count change means the stage-1 path
derivation is wrong.

## Stage 3 — uniformly position-aware key, delete `POSITION_SIGNIFICANT`

`ValidationMsgStore`, `ValidationMsgCode`

Always include `msg.getPosition().toUniqueKeyWithinSubmission()` in `EntryDedupKey`; delete
`POSITION_SIGNIFICANT`, `isPositionSignificant()` and `entryPositionKey`. The two-layer collapse then works
because both layers point at the *same real line*, not because position is ignored.

**Decision point.** Measure gf1 for double-reported `ERR_PFLICHT_FEHL` / `ERR_UNG_NUMMER`. Any remainder is
a real cross-layer overlap where the layers legitimately disagree on the line — resolve it by deciding
which layer owns the code, **not** by reintroducing a flag or special-casing the key. If that proves large,
stop after stage 2: `RecordKeyPath` and truthful positions stand on their own, and `POSITION_SIGNIFICANT`
can remain until the overlap is settled.

## Stage 4 — rewrite the dedup invariant test so it can fail

`ValidationMsgStoreTest:150-165`
(`givenCsvLayerAndErmittlungsvorgabeLayerForSameStm_whenDeduplicate_thenCollapsedToFirstOccurrence`)
currently cannot fail: it stubs `csvMessage.getPositionInSubmission()` to return the precise `csvPosition`,
and `CsvSteuerMeldung.getSourceEntry():296` returns that same mock — so `fallbackPosition` **is**
`csvPosition`. Both keys would be `"42"` even under a position-aware key, and `isSameAs(csvPosition)` is
tautological. (`8e3df4cc0`'s original used a distinct `SteuerMeldungPosition` type; the port lost it. Same
failure mode as `project_lieferung-tests-tautological`.)

Restate for the new invariant: same field at the **same real line** → one finding; **different** lines →
two. Construct both positions distinctly, never aliased through a mock. Replace the three
`POSITION_SIGNIFICANT` tests with position-aware equivalents (`ERR_UNG_LAND` at 193/194 → two, at 193/193 →
one). Add `RecordKeyPath` unit tests (`append`, `startsWith`, equality/hashing as a map key, immutability
of the copied list).

## Verification

```bash
mvn -Pno-proxy -o install -DskipTests -pl support-libs/csv-schema,ifas-domain/ifas-domain-stm -am
mvn -Pno-proxy -o test -pl support-libs/csv-schema,ifas-domain/ifas-domain-stm
mvn -Pno-proxy -o install -DskipTests -pl ifas-testing/ifas-integration-tests -am
mvn -Pno-proxy -o test -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest
```

Baselines at `GrossfileRecalculationTest:199-246` stay **untouched**; report the shift.

Quick-recalc fixture must hold its current result: 26 `Laendercode` messages at rows
193-197 / 232-236 / 396-401 / 435-440 / 727-728 / 779-780, zero duplicate errors on `ISO Code` rows,
`Nur im Neusystem (Fehler)` 22, `Nur im Altsystem` 0, `Exakte Treffer` 257. Enable
`QuickRecalculationTest:72` locally only; restore `@Disabled` afterwards and `git diff` the file (only the
pre-existing `STICHTAG` edit should remain).

For gf1, before/after counts of `ERR_PFLICHT_FEHL` / `ERR_UNG_NUMMER` in
`target/grossfile-recalc/gf1-d20260724/error#recalc.log` — that number decides stage 3.
