# Plan: Tolerance for `isLessThan*` in `KontrollsummenComparisons`

## Context

The `infoKontroll9` validator emits

> Der Inhalt des Meldefeldes Ausschuettung_e <273468.0766> ist kleiner als die gemeldeten Ertraege … Ertraege_Ausschuettung_keineJahresmeldung_KontrollsummeOeKB <273468.0767>

The two values differ by exactly **0.0001** — a sub-cent rounding artefact. The message is misleading because the values are effectively equal.

Root cause: `KontrollsummenComparisons.isLessThanBigDecimals` (and its sibling `isLessThanOrEqualBigDecimals`) perform a **strict** `compareTo(...) < 0` with no tolerance. The class already declares `SCALE_10_TOLERANCE = 10.0` (FMVO 2017 / C++ `dToleranz`) and `DEFAULT_TOLERANCE = 0.00000001`, but neither is wired into the less-than methods.

Intended outcome: comparisons treat values that are equal within a small tolerance as **not less-than**, so rounding noise no longer fires `INFO_KONTROLL_9` (and analogously `ERR_KONTROLL_5`). The user requested the **strictest** tolerance that prevents this specific case — i.e. `0.0001` under the existing `diff <= tolerance` semantics.

## Approach

Reuse the existing `isEqualBigDecimals(bd1, bd2, tolerance)` helper. It already handles the `IfasMathContexts.IFAS_MATH_CONTEXT` subtraction and uses the `diff.compareTo(tolerance) <= 0` semantics consistently with the rest of the file.

Introduce one new constant and short-circuit both less-than methods on equality-within-tolerance:

- `LESS_THAN_TOLERANCE = new BigDecimal("0.0001")` — strictest value that suppresses the reported 273468.0766 vs 273468.0767 case (diff = 0.0001) under `diff <= tolerance` semantics. This value already has precedent in the codebase (`StmDiffConfig.DEFAULT_TOLERANCE`, `ValidationMsgMatcher.DECIMAL_TOLERANCE`).

The existing zero-arg `isEqualBigDecimals(bd1, bd2)` keeps its `DEFAULT_TOLERANCE = 0.00000001` — its semantic role (strict equality) is different and should not change.

## Files to modify

### `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/KontrollsummenComparisons.java`

1. Add the constant:
   ```java
   /**
    * Tolerance for less-than / less-than-or-equal comparisons.
    * Values that are equal within this tolerance are not treated as less-than.
    */
   private static final BigDecimal LESS_THAN_TOLERANCE = new BigDecimal("0.0001");
   ```

2. Change `isLessThanBigDecimals` (line 36) to short-circuit on equality-within-tolerance:
   ```java
   public boolean isLessThanBigDecimals(BigDecimal bd1, BigDecimal bd2) {
       if (isEqualBigDecimals(bd1, bd2, LESS_THAN_TOLERANCE)) {
           return false;
       }
       return bd1.compareTo(bd2) < 0;
   }
   ```

3. Update `isLessThanOrEqualBigDecimals` (line 29) to use the same tolerance constant instead of the zero-arg `isEqualBigDecimals` (which uses the much tighter `DEFAULT_TOLERANCE`):
   ```java
   public boolean isLessThanOrEqualBigDecimals(BigDecimal bd1, BigDecimal bd2) {
       if (isEqualBigDecimals(bd1, bd2, LESS_THAN_TOLERANCE)) {
           return true;
       }
       return bd1.compareTo(bd2) < 0;
   }
   ```

No call-site changes required.

## Blast radius

Only two callers exist, both in
`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/calculated/CalculatedSteuerMeldungValidators.java`:

| Method | Line | Validator | Fields compared |
|---|---|---|---|
| `isLessThanBigDecimals` | 268 | `infoKontroll9` (INFO_KONTROLL_9) | `Ausschuettung_e` vs `Ertraege_Ausschuettung_keineJahresmeldung_KontrollsummeOeKB` |
| `isLessThanOrEqualBigDecimals` | 193 | `errKontroll5` (ERR_KONTROLL_5) | `immoInvF_SteuernauslAnrechenbarImmobilien_e` vs `immoInvF_SteuernauslAnrechenbarImmobilien_Kontrollsumme` |

Effect:
- `INFO_KONTROLL_9` no longer fires when the values differ by ≤ 0.0001.
- `ERR_KONTROLL_5` "equal" short-circuit widens from 0.00000001 to 0.0001 — same rounding-noise reasoning applies; this is intentional alignment, not a regression.

No existing tests exercise `KontrollsummenComparisons` directly.

## Verification

1. **Unit test (new):** create `KontrollsummenComparisonsTest` in
   `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/validation/`
   covering at minimum:
   - `isLessThanBigDecimals(273468.0766, 273468.0767)` → `false` (regression case from the user report)
   - `isLessThanBigDecimals(273468.0766, 273468.0768)` → `true` (diff = 0.0002 > tolerance)
   - `isLessThanBigDecimals(0, 0.0001)` → `false` (boundary, `<=` semantics)
   - `isLessThanBigDecimals(0, BigDecimal.valueOf(0.00011))` → `true`
   - Same shape for `isLessThanOrEqualBigDecimals`.

2. **Domain regression:** rerun the Steuermeldung that produced the reported message — confirm `INFO_KONTROLL_9` is gone, no new validation messages appear.

3. **Module test suite:**
   ```bash
   mvn test -pl ifas-domain/ifas-domain-stm -Pno-proxy
   ```
   Confirm no existing test breaks (especially anything exercising `errKontroll5` / `infoKontroll9`).
