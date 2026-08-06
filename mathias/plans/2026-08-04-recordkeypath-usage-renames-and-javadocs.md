# Rename `RecordKeyPath` usages and correct two stale Javadocs

## Context

`RecordKeyPath` replaced bare `List<String>` paths, but the surrounding identifiers still describe the old
shape: a field named `…ByRecordKeys` for a map keyed by a single path, a `collectRecordKeys` that returns one
path rather than a collection, and a `getRowPositions` that does not say all *of what*. Two Javadocs also now
assert things the code does not do.

Pure rename plus documentation: no behaviour change, so all 1216 tests must stay green and no fixture needs
re-running. `addNestedRecordKeys` was already inlined at its single call site in a prior step, which is what
made the record-path vs value-path distinction visible and motivated `toRecordKeyPath` over a bare `toPath`.

## Renames

Use `mcp__idea__rename_refactoring` so `{@link}` references and cross-module call sites update together.
Reference counts below are from a full grep, so nothing is missed.

### `support-libs/csv-schema/.../CsvMessage.java`

| current | new | why | sites |
|---|---|---|---|
| `positionsByRecordKeys` | `rowPositionsByPath` | keyed by one `RecordKeyPath`, not several keys; the values are the *rows* that addressed it | 4 + 1 comment |
| `getRowPositions` | `getRowPositions` | says all *of what*; pairs with `getPosition` as the many vs the one | 4 in-file (2 are `{@link}`), 7 test, 1 in `CsvSteuerMeldung:65` |
| `recordRowPosition` | `recordRowPosition` | records the position of a *row* that addressed a path, not a field's own position | 2 in-file, 1 test, 1 in `CsvIfasMessageProcessor:820` |
| param `recordKeyPath` | `path` | stutters against the type in `addMapRecordValue` and `recordRowPosition` | 2 signatures |

### `ifas-domain-stm/.../meldung/csv/CsvIfasMessageProcessor.java`

| current | new | why | sites |
|---|---|---|---|
| `collectRecordKeys` | `toRecordKeyPath` | returns one path, not a collection. `to*` marks a pure conversion — unlike this file's `resolve*`, which means "derive or look up" (`resolveFieldName` consults the schema). Follows the `CsvMessage.toFirstLinePosition` precedent, including its habit of naming the target: with `valuePath` now two lines below, a bare `toPath` would not say *which* path | 2 |
| `baseRecordKeys` (local + `collidesWithSimpleField` param) | `recordKeyPath` | it is the record's own key path, before a value key is appended; contrasts with the adjacent `valuePath` | 7 |

## Javadocs to correct — both currently state the opposite of the code

### `toRecordKeyPath` (was `collectRecordKeys`, `:612-616`)

```java
/**
 * Collects key values from a CSV record to form map keys.
 * Ensures consistent key structure by using placeholders for missing optional keys.
 *
 * @return List of key values, or empty list if required keys are missing
 */
```

Two false claims. There are **no placeholders**: `getKeyValue` returns `null` for a missing or empty column
and the stream does `.filter(Objects::nonNull)`, so a `D` row without its `LAENDERCODE` yields a
**one-element** path, not a padded two-element one. And it returns a `RecordKeyPath`, not a `List`. Replace
with the actual contract: the record's key-column values in schema order, missing or empty columns dropped
rather than padded, and an empty path when no key column could be read — which the caller at `:442` treats as
"skip this record".

### `RecordKeyPathTest:68`

```java
 * {@code CsvMessage.positionsByRecordKeys} keys a map by this type, so two independently built equal
```

Inside `{@code}`, so the IDE rename will **not** update it. Fix by hand to `rowPositionsByPath`.

## Comments to add where they carry insight

- **`rowPositionsByPath`** — extend the existing doc with why it cannot be derived from `data`: the
  `putIfAbsent` collapse discards the losing rows, and those rows are exactly what per-row validation needs.
- **`RecordKeyPath.startsWith`** — note this is the prefix match `getRowPositions` depends on: one key selects
  a whole field, two keys narrow to one country within it.
- **`toRecordKeyPath`** — a line naming the two concrete shapes the reader will meet:
  `[Ertrag_sonstiger_e]` for an `E` record, `[D_Dividenden_Subfonds_e, AT]` for a country record.

## Verification

```bash
mvn -Pno-proxy -o install -DskipTests -pl support-libs/csv-schema,ifas-domain/ifas-domain-stm -am
mvn -Pno-proxy -o test -pl support-libs/csv-schema,ifas-domain/ifas-domain-stm
```

Expect **1216** tests, 0 failures — identical to now, since nothing but names and comments change.

Then confirm no stale identifier survives anywhere, comments included:

```bash
grep -rn "positionsByRecordKeys\|getAllPositions\|recordFieldPosition\|collectRecordKeys\|baseRecordKeys" \
    --include=*.java --exclude-dir=target .
```

Must return nothing. A non-empty result means the IDE rename missed a `{@code}`/plain-text mention, which is
precisely what happened at `RecordKeyPathTest:68`.

No grossfile or quick-recalc run needed. If either is run anyway, output must be byte-identical apart from the
`Verarbeitungsbeginn` timestamp.
