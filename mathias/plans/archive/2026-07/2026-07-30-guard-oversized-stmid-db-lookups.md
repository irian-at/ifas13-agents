# Guard DB lookups against out-of-range stmId + introduce `MAX_STM_ID`

## Context

`SteuerMeldungStatusValidationService.validate(...)` queries the DB by the delivered
`stmId` **before** checking whether that id is even representable as a Steuermeldung PK.
The `stm_id` primary-key column is a 32-bit `int` on Sybase (`sybase16/V004__steuermeldung.sql:10`)
but `bigint` on Postgres (`postgres15/V004__steuermeldung.sql:3`). The JPA id type is `Long`
(`SteuerMeldungEntity.java:42`, `JpaRepository<SteuerMeldungEntity, Long>`), so Java happily
passes a value `> Integer.MAX_VALUE` down to `stmRepository.existsById(stmId)`
(`SteuerMeldungStatusValidationService.java:96`). On Sybase that binds a bigint-magnitude value
against the 32-bit `int` PK and the driver raises an arithmetic-overflow / conversion error,
surfaced as a Spring `DataAccessException`. On Postgres it silently returns `false`.

The legacy C++ prevented exactly this: it never queried when `lStm_id > INT_MAX`, it just emitted
`ERR_MELDID_UNG` (`c_st_meldung.cpp:9326`). The new code already flags the gap with a `todo` at
`SteuerMeldungStatusValidationService.java:95` (`// todo - only if validStmId !`).

**Goal:** short-circuit the by-`stmId` DB lookups when the id is invalid (null, `<= 0`, or
`> MAX_STM_ID`) so an out-of-range id yields `ERR_MELDID_UNG` without ever touching the DB, and
replace the magic `Integer.MAX_VALUE` with a named, documented constant.

This is behaviour-preserving for the validation *output*: the two gated lookups only feed
`errMeldidFehlt` / `errMeldidNichtMehrGueltig`, both of which already guard on `isValidStmId(stmId)`
and would not fire for an invalid id anyway. The change only removes the DB round-trips (and the
Sybase exception).

## Changes

### 1. `SteuerMeldungStatusValidators.java` — constant + expose validity check

- Add a package-private constant (used by both `isValidStmId` and the `errMeldeIdUng` message arg):

  ```java
  /** Sybase 4-byte (32-bit) signed integer */
  static final int MAX_STM_ID = Integer.MAX_VALUE;
  ```

- In `errMeldeIdUng` (line 67): replace the `Integer.MAX_VALUE` message argument with `MAX_STM_ID`.
- In `isValidStmId` (line 132): replace `stmId <= Integer.MAX_VALUE` with `stmId <= MAX_STM_ID`.
- Change `isValidStmId` from `private static` to package-private `static` so the service (same
  package, `at.oekb.ifas.domain.stm.validation.status`) can reuse it — no duplicate validity logic.

### 2. `SteuerMeldungStatusValidationService.java` — gate the two by-stmId DB lookups

Compute validity once near line 92, then gate the two DB calls that bind the *input* `stmId`:

- After `Long stmId = steuerMeldung.getStmId();` add:
  ```java
  boolean validStmId = SteuerMeldungStatusValidators.isValidStmId(stmId);
  ```
- Line 96 — `existsById`: change `(stmId != null && stmRepository.existsById(stmId))` to
  `(validStmId && stmRepository.existsById(stmId))`. (`validStmId` already implies non-null.)
- Line 109 — `getIsinByStmId`: change the guard `existingInputStmForIsin == null && stmId != null`
  to `existingInputStmForIsin == null && validStmId`.
- Remove the now-resolved `// todo - only if validStmId !` comment at line 95.

**No other lookup needs gating.** `getExistingMeldungenByIsin` (line 89) and the
`findAllStmIdsByIsin` / `LazyDbSteuerMeldung` path (lines 476–479) query by **ISIN**, not the input
stmId; `existingMeldungenByIsin.get(stmId)` (line 93) is an in-memory map lookup; and the
`validPersistentInputStm != null` block (lines 178–235, incl. `acceptedState.*` and
`findLatestUndeletedSuccessorStmId`) is only entered when the stm was found in the in-memory
ISIN map, which an oversized id never is.

### 3. Replace remaining `Integer.MAX_VALUE` references with `MAX_STM_ID`

In `SteuerMeldungStatusValidatorsTest.java` (same package) update the stm-id boundary cases and the
expected-message arg to reference `SteuerMeldungStatusValidators.MAX_STM_ID` instead of
`Integer.MAX_VALUE` (lines ~164, 280, 319–320, 341) so the constant is the single source of truth.

### 4. Regression test — oversized id must not hit the DB

Add a test to the integration test
`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/validation/SteuerMeldungStatusValidationServiceTest.java`:
deliver an UPDATE/CONFIRMED/DELETE meldung with `stmId = MAX_STM_ID + 1L` and assert
`validate(...)` returns an `ERR_MELDID_UNG` message and completes **without throwing** (i.e. the DB
lookup was skipped). Follow the existing given-when-then / `@Inject` conventions in that class.

## Verification

```bash
# Unit + integration tests for the touched area (H2 + containers)
mvn test -Pno-proxy -Dtest=SteuerMeldungStatusValidatorsTest,SteuerMeldungStatusValidationServiceTest -pl ifas-domain/ifas-domain-stm,ifas-testing/ifas-integration-tests -am

# Sybase is the backend that actually threw — confirm the guard holds there too
mvn test -Pno-proxy -Dtest=SteuerMeldungStatusValidationServiceTest -pl ifas-testing/ifas-integration-tests -am
```

Expected: oversized-stmId case produces `ERR_MELDID_UNG` and no `DataAccessException`; all existing
`ERR_MELDID_UNG` / `ERR_MELDID_FEHLT` cases stay green (output unchanged).
