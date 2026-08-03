# Plan: Proper CPP mirror for ERR_GJ_ZUKUNFT / ERR_GJ_FE_ZUKUNFT 7-day grace

## Context

For Jahresdatenmeldungen, the reported `GJ-Ende` must lie in the past. Funds with a Fonds-Ende GJ get a grace period: the meldung may be submitted up to N days before the GJ-Ende.

The CPP source (`c_st_meldung.h:611-616`, `c_st_meldung.cpp:261, 4925-4970`) discriminates this grace path on **the matched GJ's `gj_typ == "E"`** via `IsFondsEnde()`. Java currently discriminates on **`inv.status == "B"`** and uses a 10-day tolerance. These differ in real cases:

- Status=B fund whose reported `gjEnde` does NOT match a gj_typ='E' GJ: CPP fires `ERR_GJ_ZUKUNFT`; Java silently skips (missed error).
- Status=A fund whose reported `gjEnde` matches a historical gj_typ='E' GJ (e.g. post-Wiederauflage): CPP grants grace; Java fires strict.

Additionally, `GeschaeftsjahreCalculator.calcGjTypFromSubsequentGeschaeftsjahr` never assigns `GjTypen.FONDS_ENDE` — it only assigns `BEENDET` when followed by a Wiederauflage. CPP sets `strGj_typ = "E"` in six places (`c_geschaeftsjahr.cpp:1521, 2948, 3341, 3380, 3420, 3454`), covering both the exact-match case (`gjEnde == fondsEnde`) and the truncation case (`fondsEnde` falls inside `[gjBeginn, gjEnde)` → truncate `gjEnde` to `fondsEnde` and mark `"E"`). The Java calculator currently returns `null` when `actualGjEnde > fondsEnde` (`GeschaeftsjahreCalculator.java:337-340`), losing the FondsEnde marker entirely.

So a complete mirror needs three coordinated changes:

1. Fix the **calculator** to produce `gj_typ='E'` GJs (exact-match + truncation).
2. Refactor the **validators** to discriminate on `gj_typ='E'` of the matched GJ instead of `inv.status`.
3. Make the **grace-period constant** (currently 7) configurable via an application property.

Bonus cleanups uncovered by exploration:
- The `gj_typ` lookup table is unseeded; `GjTypen.createGjTyp` auto-creates with `bezeichnung="Beendete Phase"` for every type (bug).

## Implementation

### 1. Configurable property — `StmValidationProperties`

**New file:** `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/StmValidationProperties.java`

```java
@Component
@ConfigurationProperties(prefix = "ifas.stm.validation")
@Getter @Setter @NullMarked
public class StmValidationProperties {
    /** Max days a Jahresdatenmeldung for a FondsEnde-GJ (gj_typ="E") may be submitted before GJ-Ende. CPP: nBeendeteISINMaxTageVorGjEnde (default 7). */
    private int fondsEndeMaxDaysBeforeGjEnde = 7;
}
```

Inject into `SteuerMeldungDomainValidationService` (constructor injection — Lombok `@RequiredArgsConstructor`). Remove the `FONDS_ENDE_MAX_DAYS_BEFORE_GJ_ENDE` constant from `SteuerMeldungDomainValidators.java:33`.

### 2. Calculator — emit `gj_typ="E"` for the FondsEnde GJ

**File:** `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/geschaeftsjahr/GeschaeftsjahreCalculator.java`

Two changes in the same method `calcGjBeginnEndeForLastGeschaeftsjahr` (lines 318-344) and its caller `createAndPersistNewGeschaeftsjahrIfApplicable` (lines 347-363):

- **Truncation**: When `actualGjEnde.isAfter(fondsInfo.fondsEnde())`, do NOT return null — instead truncate `actualGjEnde = fondsInfo.fondsEnde()` and let the caller mark gj_typ. (Keep the other null-returning conditions intact: `actualGjBeginn < fondsBeginn`, `actualGjBeginn+1 > actualGjEnde`.)
- **Marking**: In `createAndPersistNewGeschaeftsjahrIfApplicable`, after computing `gjBeginnEnde`, prefer `GjTypen.FONDS_ENDE` over `calcGjTypFromSubsequentGeschaeftsjahr(...)` when `gjBeginnEnde.gjEnde().equals(fondsInfo.fondsEnde())`.

Updated `calcGjTypFromSubsequentGeschaeftsjahr` should keep its current `BEENDET` behavior for non-FondsEnde GJs.

Add `FONDS_ENDE` to `GjTypen.createGjTyp` cleanup (see step 4).

### 3. Validator refactor — discriminate on matched GJ's gj_typ

**File:** `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/SteuerMeldungDomainValidators.java`

Replace the two existing validators with the same names but different signatures:

- `errGjZukunft(msgs, gjEnde, jahresdatenmeldung, isFondsEndeGj, stichtag)`
  - Fires `ERR_GJ_ZUKUNFT` when `jahresdatenmeldung == true && !isFondsEndeGj && gjEnde >= stichtag`.
  - Drop the B/Z status skip entirely (CPP doesn't look at inv.status here).

- `errGjFeZukunft(msgs, gjEnde, jahresdatenmeldung, isFondsEndeGj, stichtag, maxDaysBeforeGjEnde)`
  - Fires `ERR_GJ_FE_ZUKUNFT` when `jahresdatenmeldung == true && isFondsEndeGj && gjEnde > stichtag + maxDaysBeforeGjEnde`.
  - No `invStatus` parameter.

**File:** `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/SteuerMeldungDomainValidationService.java`

- Remove the early `errGjZukunft` call at line 393 (CSV-only section).
- Inside the INV-dependent block (after `gjZeitreihe` is computed at line 408), compute:
  ```java
  boolean isFondsEndeGj = gjZeitreihe.findGeschaeftsjahrByGjEnde(stmGjEnde.value())
      .map(gj -> GjTypen.isFondsEnde(gj.getGjTyp()))
      .orElse(false);
  ```
  Reuse the existing `GjZeitreihe.findGeschaeftsjahrByGjEnde` (exact-match lookup at `GjZeitreihe.java:53-57`) and the existing detector `GjTypen.isFondsEnde` (`GjTypen.java:24-26`).
- Call `errGjZukunft(...)` and `errGjFeZukunft(...)` once each, with `isFondsEndeGj` from above and the day count from `stmValidationProperties.getFondsEndeMaxDaysBeforeGjEnde()`.
- For the **no-INV / `MissingInvGjEndeException` / `IllegalStateException` paths**, treat `isFondsEndeGj = false` and still call `errGjZukunft` so the strict check fires (matches CPP "no matching GJ → ERR_GJ_ZUKUNFT" branch). Restructure the try/catch so the strict call happens regardless of GJ-loading failure.

### 4. Lookup-table seed + `createGjTyp` fix

**New Flyway migrations** (one per supported DB, mirroring existing per-DB migration layout):
- `ifas-database/ifas-database-flyway/src/main/resources/db/migration/{postgres15,sybase16,h2}/V{next}__seed_gj_typ.sql`

```sql
insert into gj_typ (gj_typ, aktiv, bezeichnung) values ('B', 'J', 'Beendete Phase') on conflict do nothing;
insert into gj_typ (gj_typ, aktiv, bezeichnung) values ('E', 'J', 'Fonds-Ende') on conflict do nothing;
insert into gj_typ (gj_typ, aktiv, bezeichnung) values ('W', 'J', 'Wiederauflage') on conflict do nothing;
```

Sybase/H2 will need dialect-appropriate conditional-insert syntax — match existing patterns under `db/migration/{sybase16,h2}/`.

**File:** `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/geschaeftsjahr/GjTypen.java`

Fix `createGjTyp(String)` to return the correct `bezeichnung` per type (switch on `gjTyp`: B→"Beendete Phase", E→"Fonds-Ende", W→"Wiederauflage", default→use input as bezeichnung). The auto-create path in `GeschaeftsjahreDomainService.autoCreateGjTyp` remains a fallback but should now produce correct rows.

### 5. Tests

**Unit tests** — `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/`:

- `validation/SteuerMeldungDomainValidatorsTest.java`
  - `ErrGjZukunftTests`: drop the `givenStatusB_*` and `givenStatusZ_*` tests (no longer relevant — status not in signature). Add `givenIsFondsEndeGjFalse_*` and `givenIsFondsEndeGjTrue_*` variants.
  - `ErrGjFeZukunftTests`: rename signature params, drop status-based variants, add `givenIsFondsEndeGjTrue_andGjEndeMoreThan7DaysInFuture_thenError` etc.

- `geschaeftsjahr/GeschaeftsjahreCalculatorTest.java`
  - Add cases: fund with `fondsEnde` falling exactly on a calculated gjEnde → resulting GJ has `gjTyp = FONDS_ENDE`.
  - Add cases: fund with `fondsEnde` falling inside a calculated GJ → resulting GJ is truncated to `fondsEnde` and has `gjTyp = FONDS_ENDE`.

**Integration tests** — `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/validation/SteuerMeldungDomainValidationServiceTest.java`:

- `givenBeendetFondsAndGjEndeFarInFuture_whenValidate_thenErrGjFeZukunft` (~line 282): the existing CSV `gj_future` reports `gjEnde=2025-06-30` but the overlay has `fondsEnde=2025-12-31`. Under the new logic, the matched GJ won't have `gj_typ='E'`, so this would fire `ERR_GJ_ZUKUNFT` (not `ERR_GJ_FE_ZUKUNFT`). Either:
  - Update `SteuerMeldungDomainValidatorTest_inv_beendet.yaml` so `fondsEnde=2025-06-30` (matches CSV → calc produces a `gj_typ='E'` GJ at 2025-06-30), keep expecting `ERR_GJ_FE_ZUKUNFT`; or
  - Repurpose this test to assert `ERR_GJ_ZUKUNFT` and add a new test+fixture for the FondsEnde grace path.
- `givenBeendetFonds_whenValidateWithGjEndeWithin7Days_thenNoErrGjFeZukunft` (~line 416): same data-mismatch problem — fix consistently with the change above.
- Update day-count expectations from `10`→`7` (already partially done — re-check).

**Test fixtures** — adjust overlay YAML / CSV under `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/stm/validation/` to align with the new semantics.

## Verification

Run in order:

1. **Module compile** (annotation processors): `mvn clean compile -Pno-proxy -pl ifas-domain/ifas-domain-stm,ifas-database/ifas-persistence-inv -am`

2. **Calculator unit tests**:
   `mvn test -pl ifas-domain/ifas-domain-stm -Pno-proxy -Dtest='GeschaeftsjahreCalculatorTest'`
   Assert: FondsEnde test cases produce `gjTyp = "E"`.

3. **Validator unit tests**:
   `mvn test -pl ifas-domain/ifas-domain-stm -Pno-proxy -Dtest='SteuerMeldungDomainValidatorsTest'`
   Assert: `ErrGjZukunftTests` and `ErrGjFeZukunftTests` pass with new signatures.

4. **Integration tests** (multi-DB):
   `mvn test -pl ifas-testing/ifas-integration-tests -Pno-proxy -Dtest='SteuerMeldungDomainValidationServiceTest'`
   Assert: Flyway seed migrations run cleanly on H2/Postgres/Sybase; new ERR_GJ_FE_ZUKUNFT path exercises the `gj_typ='E'` discriminator end-to-end.

5. **Wider sanity check** (catches downstream regressions in KestMeldefristChecks etc.):
   `mvn test -pl ifas-domain/ifas-domain-stm,ifas-testing/ifas-integration-tests -Pno-proxy`

6. **Property override smoke test**: temporarily set `ifas.stm.validation.fonds-ende-max-days-before-gj-ende=14` in an `application-test.yml` or via `-D…` and verify the validator picks it up (a unit test that injects a custom `StmValidationProperties` instance suffices).

## Out of scope (flag as follow-ups)

- Backfill of existing production `geschaeftsjahr` rows with `gj_typ='E'` for already-closed funds. New rows will be marked correctly; existing rows would require a one-off migration analyzing `fondsEnde` per fund.
- The CPP "Beendet" (gap between FondsEnde and Wiederauflage) GJ creation logic — Java already handles a related case via `calcGjTypFromSubsequentGeschaeftsjahr`; full parity is a separate concern.
- Revisiting `errGjeFehlt` / `errGjeBeendet` / `errGjeUngleichO` for similar `inv.status` vs. `gj_typ` discriminator drift — out of this PR's scope.