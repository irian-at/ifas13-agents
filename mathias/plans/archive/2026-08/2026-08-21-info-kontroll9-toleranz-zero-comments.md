# Update the INFO_KONTROLL_9 tolerance comments after setting it to 0

## Context

`ifas.stm.validation.info-kontroll9-toleranz` was `0.0001` as a stopgap: it suppressed one
reported case where the KAG-delivered `Ausschuettung_e` and the OeKB-computed Kontrollsumme
differed by one ULP at 4 NK. Both the Javadoc and the properties comment carried an explicit
**OPEN** question — whether the Altsystem reports that case, and an instruction to set the value
to 0 once settled.

That question is now settled: the Altsystem allows no tolerance for INFO_KONTROLL_9, and the
value has been changed to `0` (already in the working tree). The surrounding comments still
describe `0.0001` and the open question, so they are now wrong. Two test constants documented as
"Default of `ifas.stm.validation.info-kontroll9-toleranz`" still hold `0.0001` and are likewise
stale.

## Changes

### 1. `ifas-domain/ifas-domain-stm/.../validation/StmValidationProperties.java:37-52`

Replace the three-paragraph Javadoc (ULP anecdote + "Open:" block) with the rule that holds now:

```java
    /**
     * Absolute tolerance for INFO_KONTROLL_9 only — kept apart from {@link #kontrollsummenToleranz}
     * because legacy applies <b>no</b> tolerance here since QEKBSD-73393 (2026-04-14,
     * c_st_meldung.cpp:6871 commented out, Protokoll prints "Toleranz: keine"). At 0 the check is an
     * exact {@code Ausschuettung_e < Kontrollsumme}.
     */
```

### 2. `ifas-applications/ifas-main-application/src/main/resources/application.properties:137-141`

Replace the stale block (still mentions "The 0.0001 suppressed a reported case…"):

```
# INFO_KONTROLL_9 has its own tolerance, deliberately not the shared one above: the Altsystem
# applies no tolerance here since QEKBSD-73393 (Protokoll prints "Toleranz: keine"), so 0 makes
# the check an exact "Ausschuettung_e < Kontrollsumme".
ifas.stm.validation.info-kontroll9-toleranz=0
```

The file is currently pure ASCII (verified) — keep the new comment ASCII-only so the ISO-8859-1
encoding of properties files is not disturbed.

### 3. `.../validation/calculated/CalculatedSteuerMeldungValidatorsTest.java:34-35`

The constant is documented as the configured default, so track the default rather than only
rewording the comment:

```java
    /** Default of {@code ifas.stm.validation.info-kontroll9-toleranz}: legacy applies no tolerance. */
    private static final BigDecimal INFO_KONTROLL_9_TOLERANZ = BigDecimal.ZERO;
```

All six `InfoKontroll9Tests` cases stay green at 0 — the shortfalls used are 5.0, 50 and 100, and
the equal-values case (`100` vs `100`) yields no message under an exact `<`. The inline comment at
line 1038 ("inside the shared Kontrollsummen-Toleranz, but INFO_KONTROLL_9 is deliberately not
governed by it") remains accurate.

### 4. `.../validation/KontrollsummenComparisonsTest.java:16-17`

Here `0.0001` must **stay** — the surrounding cases exercise the band mechanics of
`isLessThanBigDecimals` (`givenDiffAtToleranceBoundary…`, `givenDiffJustAboveToleranceBoundary…`)
and would be meaningless at 0. Only the Javadoc is wrong; it must stop claiming to be the
configured default:

```java
    /** A narrow band, for the isLessThan* boundary cases; the configured INFO_KONTROLL_9 value is 0. */
    private static final BigDecimal INFO_KONTROLL_9_TOLERANZ = new BigDecimal("0.0001");
```

`givenZeroTolerance_whenIsLessThanBigDecimalsWithMinimalShortfall_thenTrue` (line 63) already pins
the zero-tolerance behaviour and needs no change.

## Out of scope

No production behaviour changes beyond the value the user already set; the validator
(`CalculatedSteuerMeldungValidators#infoKontroll9`) and `KontrollsummenComparisons` are untouched.

## Verification

```bash
mvn -Pno-proxy test -pl ifas-domain/ifas-domain-stm \
    -Dtest=CalculatedSteuerMeldungValidatorsTest,KontrollsummenComparisonsTest
```

Then `git diff` to confirm the properties file shows only the intended comment lines changed
(no whole-file re-encoding).
