# Keep the two Kontrollsummen tolerances separate + document why

## Context

`KontrollsummenComparisons` now has two tolerance constants:
- `DEFAULT_TOLERANCE = 0.0001` — equality / `>=` / `<=` / `<` comparisons (Kontrollsummen on totals; the 4-NK reporting floor that replaced legacy's `dToleranz = 10.0`).
- `LT_ZERO_TOLERANCE = -0.00001` — the `< 0` sign guard used by `isLessThanZeroByTolerance`.

Question raised: unify them (use `0.0001` everywhere). **Decision after investigating legacy: keep them separate — do not merge.**

### Why (legacy findings, `c_st_meldung.cpp::CheckKontrollsummen()`)

- Legacy's `< 0` tolerance is **not** `dToleranzKleiner0 = -0.00001` used as a threshold — every `if (dValue < dToleranzKleiner0)` is **commented out** (`:7017,7083,7139,7204,7261,7327`). What legacy actually does for the "must be ≥ 0" checks is round to **5 NK** and re-test the sign:
  ```cpp
  if (dValue < 0) { dValue = round(dValue*100000)/100000; if (dValue < 0) { error } }
  ```
  So the sign-check tolerance is at the **5-NK / 0.00001** scale — deliberately *tighter* than the 4-NK / 0.0001 equality band. The active `dToleranzGroesser0 = +0.00001` (`:7638-7717`, `INFO_AUSLQST_JA`) is its positive mirror.
- The two tolerances are different-purpose, different-scale on purpose: `0.0001` for Kontrollsummen equality on (large) totals; `0.00001` for tiny sign/rounding-noise guards.
- Widening the sign guard to `-0.0001` would loosen the **ERROR-level** `errKontrollNLt0` / `errKontrollLsnLt0` (`CalculatedSteuerMeldungValidators.java:334,399`) — which **decline meldungen** — by 10×, making the new system *accept* real 5-NK negatives that legacy rejects. The "new system is more precise → tighten" argument that justified `0.0001` for `INFO_KONTROLL_1` does **not** transfer: these checks catch genuinely-negative values, not amplified truncation.

## Change (doc-only, no behavior change)

In `KontrollsummenComparisons.java`, add a short javadoc to the two constants making the split explicit so nobody re-attempts the merge:
- `DEFAULT_TOLERANCE`: 4-NK equality/comparison band for Kontrollsummen on totals; replaced legacy's `dToleranz = 10.0` (which only existed to pad legacy's 10-NK-truncation-then-×count amplification — absent in the new system's DECIMAL128 arithmetic).
- `LT_ZERO_TOLERANCE`: 5-NK sign guard; a stand-in for legacy's round-to-5-NK-then-check-sign (`c_st_meldung.cpp:7015-7019`). Intentionally tighter than `DEFAULT_TOLERANCE` and must not be merged into it.

No logic changes.

## Known, separate inconsistency (not fixed here)

`infoAuslqstJa` (`:435`) uses strict `> 0`, not legacy's `+0.00001` (`dToleranzGroesser0`). That's the real divergence in this area (INFO-level). Leave as-is unless we decide to align the sign pair at `0.00001` in a separate change.

## Verification

`mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm test -Dtest=KontrollsummenComparisonsTest,CalculatedSteuerMeldungValidatorsTest -Dsurefire.failIfNoSpecifiedTests=false` — comment-only edit, all existing tests stay green (no behavior change).
