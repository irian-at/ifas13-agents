# Tighten EXACT match quality gate by line-number scope

## Context

In `ValidationMsgMatcher.createExactMatch` (ValidationMsgMatcher.java:60–109) a block was added (lines 70–95) that:

- Records a "Zeilennummern unterscheiden sich … (innerhalb Toleranz)" diff when legacy and new line numbers differ but the legacy line still falls within the new validation's `CsvMessage` span `[getFirstLineNr(), getLastLineNr()]`.
- Downgrades the match to `MatchQuality.DIVERGENT_ARGS` when the legacy line is outside that span.

This runs *after* `findBestExactMatch` has already picked a candidate. The current `findBestExactMatch` (ValidationDeltaCalculator.java:388–411) only keys on `(refcode, normalized args)` via `isExactMatch` (line numbers are only a tiebreaker, not a gate), so two validations on genuinely different CSV rows can be paired and then either accepted as `EXACT` with a tolerance note or downgraded to `DIVERGENT_ARGS` after the fact.

**Goal:** turn line-number scope into a real quality gate during candidate selection, with a dedicated match tier for "same record, line drifted within the multi-line span" so the drift is visible in the delta report without conflating it with a true `EXACT` match.

**The new tier:** `MatchQuality.DIVERGENT_ROWS_IN_TOLERANCE`, sitting between `EXACT` and `DIVERGENT_ARGS`.

**Resulting classification (when both line numbers are present):**

| Position on the new side | Lines equal | Lines differ but legacy ∈ `[firstLineNr, lastLineNr]` | Other |
|---|---|---|---|
| `CsvMessagePosition` | `EXACT` | `DIVERGENT_ROWS_IN_TOLERANCE` | not matched as exact → falls through to divergent-args / covered / unmatched |
| `CsvFilePosition`    | `EXACT` | n/a (no span) | not matched as exact (strict equality required) |
| `SteuerMeldungPosition` / other | n/a — `extractLineNumber` returns `null`, gate is skipped, treated as `EXACT` |

If either line number is `null`, no gate is applied (today's behaviour).

## Approach

### 1. Add the new enum value

In `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/MatchQuality.java`, insert `DIVERGENT_ROWS_IN_TOLERANCE` between `EXACT` and `DIVERGENT_ARGS` with a Javadoc explaining the semantics ("same code and arguments, legacy line within the new validation's `CsvMessage` span but not equal"). Ordering matters if any code compares `MatchQuality` by ordinal — check and adjust on the fly.

Find every reference to `MatchQuality` after adding the value (`grep -r MatchQuality. ifas-domain ifas-services ifas-web`) and handle the new case explicitly in any `switch` / equality-based logic. Expected touch points: delta report rendering and any test that pins down per-quality counts.

### 2. Revert the block in `createExactMatch`

Restore ValidationMsgMatcher.java:70–95 to the pre-change state: `MatchQuality quality = MatchQuality.EXACT;` with no line-number diff / downgrade logic. The method then only reports argument-level differences for codes in `DivergentArgsCodes` (existing behaviour below the reverted block stays intact).

### 3. Add matcher predicates and a factory on `ValidationMsgMatcher`

Reuses existing helpers (`isExactMatch`, `extractLineNumber`, `LegacyLogValidationMsg.lineNumber`, `CsvMessage.getFirstLineNr/getLastLineNr`, `CsvMessagePosition.getCorrespondingEntry`) — no duplicated logic, per `mathias/rules/reuse-before-reimplementing.md`. Explicit types, JSpecify, no `var` — per `.claude/rules/java-conventions.md`.

- `boolean isExactLineMatch(LegacyLogValidationMsg legacy, ValidationMsg newValidation)`
  - Returns `true` iff `isExactMatch(legacy, newValidation)` AND lines are exactly compatible:
    `legacyLine == null || newLine == null || legacyLine.equals(newLine)`.
- `boolean isInToleranceMatch(LegacyLogValidationMsg legacy, ValidationMsg newValidation)`
  - Returns `true` iff `isExactMatch(legacy, newValidation)` AND both lines are present and unequal AND the new validation's position is a `CsvMessagePosition` whose `getCorrespondingEntry()` span contains `legacyLine`. Returns `false` for `CsvFilePosition` (no span — strict equality already covered by `isExactLineMatch`).
- `ValidationMsgMatch createInToleranceMatch(LegacyLogValidationMsg legacy, ValidationMsg newValidation)`
  - Mirrors `createDivergentArgsMatch` (ValidationMsgMatcher.java:160–188): collects argument-level differences and prepends a line-drift entry `"Zeilennummern unterscheiden sich: Altsystem=%d, Neusystem=%d"`. Quality = `DIVERGENT_ROWS_IN_TOLERANCE`.

`isExactMatch` itself stays "code + args" — its unit tests in `ValidationMsgMatcherTest.java` and its test-only `SimplePosition` use cases are unaffected.

### 4. Two-pass lookup in `ValidationDeltaCalculator`

Mirrors the existing tiered pattern (`exact → divergent-args → covered`). In `compareValidationMsgs` (ValidationDeltaCalculator.java around line 320), add an in-tolerance pass right after the exact-line pass and before divergent-args.

- Rename `findBestExactMatch` to use `matcher.isExactLineMatch` (drop the now-redundant "prefer same line" tiebreaker — the predicate already enforces same-line).
- Add `findBestInToleranceMatch` using `matcher.isInToleranceMatch`. If multiple candidates qualify, pick the one whose new line is closest to `legacyLine` (smaller `|newLine − legacyLine|`) to minimise reported drift.
- Dispatch in `compareValidationMsgs`:
  1. exact-line → `createExactMatch`
  2. in-tolerance → `createInToleranceMatch`
  3. divergent-args → `createDivergentArgsMatch` (unchanged)
  4. covered → `createCoveredMatch` (unchanged)

## Files to modify

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/MatchQuality.java` — add enum value.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/ValidationMsgMatcher.java` — revert lines 70–95; add `isExactLineMatch`, `isInToleranceMatch`, `createInToleranceMatch`.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/ValidationDeltaCalculator.java` — tighten `findBestExactMatch`; add `findBestInToleranceMatch`; insert dispatch tier in `compareValidationMsgs`.
- Delta-report rendering / any other `switch (MatchQuality)` consumers — add a case for the new value (grep first to enumerate).

No changes to `DivergentArgsCodes`, `isAllowedDivergentArgsMatch`, `hasMatchingLineNumbers`, or covered-match logic.

## Behavioural impact

- **Tightening, not loosening.** Pairs that today are matched as `EXACT` with equal line numbers stay `EXACT`. Pairs that today are matched across rows are reclassified:
  - in-span (same `CsvMessage`) → `DIVERGENT_ROWS_IN_TOLERANCE` with a line-drift diff entry.
  - out-of-span / `CsvFilePosition` with differing lines → not matched as exact; falls through to divergent-args (strict line equality there will reject them too) → split delta in the report.
- **No silent quality downgrades.** Out-of-span candidates aren't paired at all; their split-delta surface is the intended signal.
- **`isExactMatch` semantics unchanged** — direct callers and `ValidationMsgMatcherTest` unaffected.
- **`SteuerMeldungPosition` flows unaffected** — `extractLineNumber` returns `null`, gate short-circuits.
- **Performance**: at most one extra pass over the candidate list per legacy message; the predicates are cheap (range check + instanceof). Negligible.

## Verification

1. Build the affected module:
   ```bash
   mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm -am clean compile
   ```
2. Confirm every `MatchQuality` consumer compiles (any switch without a default will surface the new value as a compile error — fix at the call site):
   ```bash
   grep -rn "MatchQuality\." ifas-domain ifas-services ifas-web ifas-testing
   ```
3. Run the matcher unit tests (should pass unchanged):
   ```bash
   mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm test -Dtest=ValidationMsgMatcherTest
   ```
4. Run the delta integration tests and inspect generated delta reports for T05/T06/T07:
   ```bash
   mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests test -Dtest=ValidationDeltaCalculatorIntegrationTest
   ```
   Expect some entries that previously rendered as `EXACT` (with the old "(innerhalb Toleranz)" diff) to now render as `DIVERGENT_ROWS_IN_TOLERANCE`, and any cross-record pairs to become split deltas. Update committed expected outputs only where the new behaviour is intentional.
5. Add focused unit tests in `ValidationMsgMatcherTest` covering:
   - `isExactLineMatch` true when lines equal, true when one line null.
   - `isInToleranceMatch` true within span, false outside span, false for `CsvFilePosition` with differing lines.
   - `createInToleranceMatch` produces quality `DIVERGENT_ROWS_IN_TOLERANCE` and includes the line-drift diff entry.
