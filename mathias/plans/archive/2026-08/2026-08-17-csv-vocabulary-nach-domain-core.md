# Move the write-side CSV vocabulary to core: enum + formatters

## Context

`ifas-domain-fondspreise` now exists as a sibling module with zero dependency on `ifas-domain-stm`,
and the shared read-side CSV classes already live in `at.oekb.ifas.domain.core.csv`
(`CsvIfasDateFormat`, `CsvTypeConversions`, `CsvIfasValueTypeValidator`, `CsvIfasFilenameValidator`).
Three write-side classes stayed behind. Investigation showed only **one** of them is genuinely
coupled to STM — my earlier claim that all three were blocked by persistence enums was wrong.

| Class | Blocker |
|---|---|
| `CsvIfasValueType` (18 lines) | **none** — zero imports, a bare enum |
| `CsvValueFormatters` (125 lines) | one misplaced 9-line constants class, `IfasMathContexts` |
| `CsvTypeCoercions` (110 lines) | **real** — 5 enums from `ifas-persistence-stm`; core must not depend on persistence |

Decision: move the enum and the formatters (with `IfasMathContexts` as the prerequisite), leave
`CsvTypeCoercions` in `ifas-domain-stm`. The validator-keys-off-the-enum cleanup is a **separate
follow-up**, not part of this change.

The immediate payoff is modest — `CsvSteuerMeldungenWriter` is still the only consumer, since
Preismeldung has no write path yet. The reason to do it now is that it puts the whole CSV *vocabulary*
in one module, which is the precondition for closing the string/enum drift described at the end.

## Step 1 — `IfasMathContexts` → `core-support`

`at.oekb.ifas.domain.stm.ermittlung.calc.IfasMathContexts` has no domain coupling at all — three
numeric constants:

```java
public static final MathContext IFAS_MATH_CONTEXT = new MathContext(MathContext.DECIMAL128.getPrecision(), RoundingMode.HALF_UP);
public static final int IFAS_BIG_DECIMAL_EQUALITY_ROUNDING_SCALE = 15;
public static final int IFAS_BIG_DECIMAL_PRE_SCALE = 16;
```

Target: `support-libs/core-support/src/main/java/at/oekb/ifas/core/numbers/IfasMathContexts.java`,
package `at.oekb.ifas.core.numbers` — beside `BigDecimals`, which already takes
`IFAS_BIG_DECIMAL_PRE_SCALE` as a parameter (`roundWithPreScale(v, max, min, preScale)`). Keep the
class name and the `public class` shape; this is a relocation, not a redesign.

All 11 referencing files are inside `ifas-domain-stm`, which already depends on `core-support`:

- `domain/stm/ermittlung/calc/JavaSteuerMeldungCalculator.java` — same package today, so it needs a
  **new** import
- repath the existing (some are `import static`) in: `domain/stm/recalc/diff/KnownLegacySystemIssues.java`,
  `domain/stm/recalc/diff/StmDiffs.java`, `domain/stm/validation/KontrollsummenComparisons.java`,
  `domain/stm/validation/ValidationMsgCode.java`, `domain/stm/validation/delta/ValidationMsgMatcher.java`,
  `domain/stm/ermittlung/ErweitertValuesCalculations.java`, `domain/stm/meldung/csv/CsvValueFormatters.java`,
  plus tests `domain/stm/recalc/diff/StmDiffEqualHandlerTest.java`,
  `domain/stm/ermittlung/calc/op/IfasStmOpHandlersTest.java`

## Step 2 — `CsvIfasValueType` → `ifas-domain-core`

`git mv` into `ifas-domain/ifas-domain-core/src/main/java/at/oekb/ifas/domain/core/csv/`, package
`at.oekb.ifas.domain.core.csv`. Four referencing files:

| File | Action |
|---|---|
| `CsvValueFormatters` | moves too (step 3) → ends up in the same package, no import |
| `CsvTypeCoercions` (stays in stm) | add import |
| `CsvSteuerMeldungenWriter` (stays) | add import |
| `CsvValueFormattersTest` (stays, see step 3) | add import |

## Step 3 — `CsvValueFormatters` → `ifas-domain-core`

`git mv` into the same `at.oekb.ifas.domain.core.csv` package. Inside the class:

- `IfasMathContexts` → new `at.oekb.ifas.core.numbers` path (step 1)
- **drop** the now-redundant imports of `CsvIfasDateFormat` and `CsvIfasValueType` — both are in the
  same package after this change (including the `import static … CsvIfasDateFormat.DEFAULT_CSV_DATE_OUTPUT_FORMAT`,
  which becomes a plain same-package reference)

**The test stays in `ifas-domain-stm`.** `CsvValueFormattersTest` imports
`at.oekb.ifas.persistence.stm.steuermeldung.Art` and `StmStatus` to exercise the `formatEnum` path
with real STM enums, so it cannot follow the class into core. It needs its `CsvValueFormatters` and
`CsvIfasValueType` imports added. This mirrors `CsvIfasFilenameValidatorTest` and
`CsvIfasValueTypeValidatorTest`, which likewise test core classes from the stm suite — a deliberate
consequence of the extraction, not an oversight. Rewriting the test against a throwaway local enum
would let it move, but it would stop proving that the real STM enums format correctly; keep the
fidelity.

Also update `CsvSteuerMeldungenWriter` (stays in stm) with an import for `CsvValueFormatters`.

## What stays in `ifas-domain-stm`, and why

`CsvTypeCoercions` — its job is partly to map CSV value types onto `WRabattArt`,
`Kapitalrueckzahlung`, `Ertragstyp`, `StmStatus` and `Art`. Roughly 9 of its value types are generic
(`String`, `LocalDate`, `LocalDateTime`, `BigDecimal`, `Long`, `Boolean`) and 5 are STM enums, so a
generic/STM split is possible — but its `switch` over `CsvIfasValueType` is exhaustive, so the core
half would need a throwing default plus a composition seam. That is design work, and there is no
consumer asking for it yet.

## Follow-up (approved, deliberately separate)

Make `CsvIfasValueTypeValidator` resolve its pattern keys through `CsvIfasValueType` instead of raw
strings, so schema `valueType`s cannot drift from the enum. Today they already have: the validator
carries the three `PREIS_*` patterns, the enum does not, and
`AUSSCHUETTUNG_OUTPUT-LIEFERFORMAT_2018-03-19.csv-schema.yml` declares a phantom `valueType: TIME`
present in neither. That change also has to add `PREIS_MELDEKATEGORIE`/`PREIS_AKTION`/
`PREIS_PERIODIZITAET` to the enum and decide the `TIME` question.

**Consequence to resolve then, not now:** adding `PREIS_*` to the shared enum forces new arms in the
exhaustive switches of both `CsvValueFormatters` (fine — treat as text, and it will be in core) and
`CsvTypeCoercions` (**not** fine — that is in `ifas-domain-stm`, and Preismeldung constants there
reintroduce exactly the STM/Preismeldung mixing we just removed). So the follow-up will likely force
the `CsvTypeCoercions` split, either by giving its switch a default or by moving the generic half to
core. Worth knowing before starting it.

Note the `String` stays at the API boundary regardless: `CsvValueTypeValidator.validate(String valueType, …)`
is defined in `csv-schema`.

## Verification

```bash
# nothing should reference the old locations afterwards
grep -rn "domain\.stm\.ermittlung\.calc\.IfasMathContexts\|domain\.stm\.meldung\.csv\.CsvIfasValueType\|domain\.stm\.meldung\.csv\.CsvValueFormatters" --include=*.java . | grep -v /target/

mvn -Pno-proxy -o -pl support-libs/core-support,ifas-domain/ifas-domain-core,ifas-domain/ifas-domain-stm,ifas-domain/ifas-domain-fondspreise -am test
mvn -Pno-proxy -Pdev-build -o clean install -DskipTests     # full reactor, all 34 modules
```

Baseline to preserve: `ifas-domain-core` 291 tests, `ifas-domain-stm` 1265,
`ifas-domain-fondspreise` 46 — all passing, full reactor green. `core-support` currently 113.
Expect core's count to rise and stm's to fall by whatever moves; `CsvValueFormattersTest` (47 tests)
stays in stm.

Always pass `-am`: the `xls-support` jar in `~/.m2` is stale and lacks `Workbooks.isBlank(Cell)`, so a
`-pl` build without it fails to compile `SteuerlicheBehandlungFieldSpecs`.

Use `git mv` for every relocation so the renames stay tracked (the previous round produced clean
R077–R099 rename detection for all 7 moves).
