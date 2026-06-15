# Verify `compareDecimalArgument()` in `ValidationMsgMatcher`

## Context

The user asked for a verification of `ValidationMsgMatcher.compareDecimalArgument(String, BigDecimal)`
at `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/ValidationMsgMatcher.java:370-394`.
The method is part of the legacy↔new validation-message delta comparison and must classify decimal
arguments as `MATCH`, `MATCH_WITHIN_TOLERANCE`, or `NO_MATCH`.

## Findings

### 1. `MATCH_WITHIN_TOLERANCE` branch is dead code (bug)

`BigDecimals.roundWithPreScale(x, 4, 4, 16)` rounds the input to scale 4 (the `minDecimals=4`
parameter restores trailing zeros after `stripTrailingZeros`). Consequence:

- Both `legacyScaled` and `newScaled` have an effective resolution of `0.0001`.
- Their difference is therefore always a multiple of `0.0001`.
- If `legacyScaled.compareTo(newScaled) != 0`, the absolute difference is `>= 0.0001`.
- The tolerance check `…compareTo(new BigDecimal("0.0001")) < 0` is *strictly less than*, so it can
  never be true.

Result: every decimal comparison falls through to `NO_MATCH`; the `MATCH_WITHIN_TOLERANCE` quality
is unreachable.

**Fix (confirmed with user):** Allow exactly one ULP at scale 4 to count as within tolerance.
Change the comparator from `< 0` to `<= 0` so `|legacyScaled - newScaled| == 0.0001` (e.g.
`240240.0000` vs `240239.9999`) classifies as `MATCH_WITHIN_TOLERANCE`. Sub-step differences are
already covered by the equality check above (both values round to the same scale-4 number).

### 2. Naming convention violation (style, `.claude/rules/java-conventions.md`)

`default_tolerance` is snake_case. Java identifiers must be `camelCase` (or
`UPPER_SNAKE_CASE` for a `static final` constant).

### 3. Allocation per call

`new BigDecimal("0.0001")` is constructed on every comparison. Extract to a
`private static final BigDecimal DECIMAL_TOLERANCE = new BigDecimal("0.0001");` constant.

### 4. `abs(IFAS_MATH_CONTEXT)` is incorrect API usage

Passing a `MathContext` to `BigDecimal.abs()` causes rounding of the result to `DECIMAL128`
precision. The intermediate subtraction's scale is already small (≤ 4), so the rounding has no
effect — but it is misleading and not what the operation is for. Use plain `abs()`.

### 5. Catch block could be simplified

Both the in-`catch` `return NO_MATCH` and the trailing `return NO_MATCH` produce the same result,
making the explicit return inside the catch redundant. Either remove the in-`catch` return (let
control fall through) or move the trailing `return` into the `try`.

### 6. Note (not a bug): legacy decimal parsing

`legacyArg.replace(",", ".")` is sufficient for legacy IFAS log values (no thousand separators).
No change suggested.

## Reuse check

Searched `support-libs/core-support/src/main/java/at/oekb/ifas/core/numbers/BigDecimals.java`
for an existing tolerance helper:

- `BigDecimals.isEqual(a, b)` exists (uses `compareTo`), but no "within tolerance" helper.
- `roundWithPreScale` is the canonical scaling helper and is already used here — correct choice.

If fix option A is adopted and a tolerance comparison is needed in more than one place, consider
adding `BigDecimals.isWithinTolerance(BigDecimal a, BigDecimal b, BigDecimal tolerance)` rather
than inlining. For a single call site, inline is fine.

## Proposed fix

```java
private static final BigDecimal DECIMAL_TOLERANCE = new BigDecimal("0.0001");

private ArgumentMatchResult compareDecimalArgument(String legacyArg, BigDecimal newDecimal) {
    BigDecimal legacyDecimal;
    try {
        legacyDecimal = new BigDecimal(legacyArg.replace(",", "."));
    } catch (NumberFormatException e) {
        log.debug("Failed to parse legacy decimal argument '{}': {}", legacyArg, e.getMessage());
        return ArgumentMatchResult.NO_MATCH;
    }

    BigDecimal legacyScaled = BigDecimals.roundWithPreScale(legacyDecimal, 4, 4, IfasMathContexts.IFAS_BIG_DECIMAL_PRE_SCALE);
    BigDecimal newScaled = BigDecimals.roundWithPreScale(newDecimal, 4, 4, IfasMathContexts.IFAS_BIG_DECIMAL_PRE_SCALE);

    if (legacyScaled.compareTo(newScaled) == 0) {
        return ArgumentMatchResult.MATCH;
    }

    // Allow one ULP at scale 4 (e.g. 240240.0000 vs 240239.9999) — typical rounding
    // divergence between legacy IFAS and the new pipeline.
    if (legacyScaled.subtract(newScaled).abs().compareTo(DECIMAL_TOLERANCE) <= 0) {
        return ArgumentMatchResult.MATCH_WITHIN_TOLERANCE;
    }

    return ArgumentMatchResult.NO_MATCH;
}
```

## Verification

- Run the existing delta-calculator tests to confirm no regression:
  `mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm -Dtest=ValidationDeltaCalculatorTest`
  (and any `ValidationMsgMatcherTest` if present).
- Add or extend a unit test for the canonical tolerance case (`240240.0000` vs `240239.9999`
  → `MATCH_WITHIN_TOLERANCE`) and a negative case (`240240.0000` vs `240239.9998`
  → `NO_MATCH`).
- Run `QuickRecalculationTest` / `EstbReportTest` if they exercise delta reporting.