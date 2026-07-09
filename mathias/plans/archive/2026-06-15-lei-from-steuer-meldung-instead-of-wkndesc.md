# LEI: source from `steuer_meldung` instead of `wkn_desc`

## Context

While checking Entry 2 (`Z122 — ERR_UNGL_VORH on LEI`) of
`gf2-nur-im-altsystem-analysis.md`, we found two issues, not one:

1. **Immediate (silences Z122)**: `previousSteuerMeldung == null` at
   `SteuerMeldungStatusValidationService.java:137` skips the whole `errUnglVorh`
   block. Likely cross-ISIN blind spot or test-data gap — already noted in the
   analysis plan.
2. **Latent schema gap** (this plan): IFAS13's domain `SteuerMeldung.getLei()` does
   **not** read the LEI of the persisted meldung. Both `EagerDbSteuerMeldung` and
   `LazyDbSteuerMeldung` resolve LEI via `InvRepository.getInvNameKagStVertreterLeiByIsin(...)`
   → `WknDesc.lei` (a master-data lookup by ISIN + stichtag). Legacy CPP stores LEI
   per meldung on `kurs..steuer_meldung.LEI` (since `versionsNr >= 4`,
   `c_st_meldung.cpp:7671-7673`) and compares CSV-side LEI against that snapshot
   (`c_st_meldung.cpp:8304-8307`).

Consequence: even when Entry 2's immediate cause is fixed, IFAS13's LEI check is
toothless — both `currentValue` and `previousValue` flow through the same
master-data lookup for the same ISIN+stichtag, so `valuesEqual` is always true and
`ERR_UNGL_VORH` for LEI never fires.

The unit test `LazyDbSteuerMeldungLeiSourceTest` (uncommitted in git status) already
pins down today's behavior; it will need to be inverted as part of this work.

The user has decided the order:
**first fix the schema → then re-visit Entry 2**.

## Approach (recommended)

Persist LEI on `SteuerMeldungEntity` and have both Eager/Lazy `DbSteuerMeldung`
implementations source `getLei()` from the entity. Drop the `WknDesc.lei` route
for `SteuerMeldung.getLei()`. (`WknDesc.lei` itself stays; other call sites — e.g.
master-data listings — keep using it.)

Match legacy's version gate: only treat the entity's `lei` as authoritative for
`versionsNr >= 4`. For older versions, return `null` (legacy didn't compare LEI).

### Step 1 — Flyway migration

New migration in both DB-specific directories:

- `ifas-database/ifas-database-flyway/src/main/resources/db/migration/postgres15/V036__steuer_meldung_lei.sql`
  ```sql
  ALTER TABLE STEUER_MELDUNG ADD COLUMN lei VARCHAR(20);
  ```
  (H2 inherits this directory — see `DbConfigs.FLYWAY_MIGRATION_LOCATION_H2`.)

- `ifas-database/ifas-database-flyway/src/main/resources/db/migration/sybase16/V036__steuer_meldung_lei.sql`
  - Open question: does the production Sybase `kurs..steuer_meldung` already
    have a `LEI` column (added outside Flyway, mirroring legacy)? If so, follow
    the V032 pattern with a comment-only file. If not, use Sybase's no-`COLUMN`
    syntax: `ALTER TABLE steuer_meldung ADD lei varchar(20) null`.

Decide between two transition options:

- **(a) Backfill from `wkn_desc`** as part of the migration: `UPDATE steuer_meldung
  SET lei = (SELECT wd.lei FROM ...)`. Keeps old rows valid, but joins
  `steuer_meldung → wkn → wkn_desc` and requires picking a stichtag (likely
  `gj_ende` or `eintragezeit`). Recommended for any environment that already
  contains real meldungen.
- **(b) Leave existing rows with `lei = null`** — fine for dev/test fixtures, but
  any pre-migration meldung referenced as `previousSteuerMeldung` will read
  `previousLei = null` and may produce false-positive `ERR_UNGL_VORH` on
  reprocessing.

Recommendation: **(a) backfill** for prod paths; tests get the value via the
fixture rewrite (Step 6).

### Step 2 — `SteuerMeldungEntity`

Add a single field near the other text columns (e.g. after `waehrung` at
`SteuerMeldungEntity.java:62-63`):

```java
@Column(name = "lei", length = 20)
@Nullable
private String lei;
```

No setter — the class uses `@Getter` only. Persistence-side population happens
through whichever path already writes `art`, `waehrung`, etc. (Lombok-built
all-args constructor or a dedicated builder — confirm during implementation;
search for the constructor at `SteuerMeldungEntity.java:206-250` referenced by
the prior Explore agent.)

### Step 3 — CSV → entity population

CSV row already exposes LEI as `FieldName.LEI = "LEI_e"` (see
`EagerDbSteuerMeldung.java:36`). The code path from CSV import to entity
persistence runs through `SteuerMeldungLieferungService.java` (currently modified
in git status) and the persistence layer. Locate where `art`/`waehrung` are
written from the parsed CSV row onto a new `SteuerMeldungEntity` and add a
parallel write for `lei`. Skip when `versionsNr < 4` (mirror legacy gating).

### Step 4 — `LazyDbSteuerMeldung.getLei()`

Replace the master-data delegation at `LazyDbSteuerMeldung.java:309-311` with an
entity read:

```java
@Override
public @Nullable String getLei() {
    if (getVersionsNr() < 4) {
        return null;
    }
    return getSteuerMeldungEntity().getLei();
}
```

Drop the `LEI` entry from `THIS_FIELD_RESOLVERS_BY_FIELD_NAME` at
`LazyDbSteuerMeldung.java:35` and let it flow through the standard
`resolveAndCoerceByFieldName` path, OR keep it in the resolver map with the new
body — pick whichever fits the resolver framework better. Verify by inspecting
how `getVersionsNr` and `getSteuerMeldungEntity` are used by neighbors in the
same map.

The `getInvNameKagAndStVertreter()` helper is still used for fonds name / KAG /
steuerlicher Vertreter — keep it.

### Step 5 — `EagerDbSteuerMeldung.getLei()`

Replace `EagerDbSteuerMeldung.java:36` (`FieldName.LEI, e -> e.invInfo.getLei()`)
with `FieldName.LEI, e -> e.getVersionsNr() < 4 ? null : e.entity.getLei()`.

`invInfo` stays in place for `NAME`/`KAG`/`STEUERLICHER_VERTRETER`.

The `of(...)` factory at `EagerDbSteuerMeldung.java:76-90` still receives
`invInfo`; no signature change.

### Step 6 — DTO mapper + tests

- `at.oekb.ifas.importexport.dto.SteuerMeldungDto`: add `private String lei;`.
- `at.oekb.ifas.importexport.dto.DtoEntityMapper`: add `@Mapping(target = "lei",
  source = "lei")` (or rely on auto-mapping if MapStruct sees a same-named field).
  Rebuild the module after editing so MapStruct regenerates the impl.

- Tests:
  - **Invert `LazyDbSteuerMeldungLeiSourceTest`**: assert that `getLei()` reads
    from `SteuerMeldungEntity.lei`, not from `InvRepository`. The test name
    "LeiSource" already implies this is exactly what it pins down. Drop the
    `InvRepository.getInvNameKagStVertreterLeiByIsin` stubbing for the LEI
    assertion and use a real or mocked `SteuerMeldungEntity` with a populated
    `lei`.
  - `MF98ListGeneratorTest.java:62-66` and any fixture that asserts LEI from
    `wkn_desc`: review and re-anchor on the new source.
  - YAML fixtures that today contain `lei:` on `wkn_desc` (e.g.
    `SteuerMeldungDomainValidatorTest_base.yaml:104`): add the corresponding LEI
    to the `steuer_meldung` fixture rows that should carry one. The
    `wkn_desc.lei` field stays in fixtures because other call sites still use
    it.

### Step 7 — Revisit Entry 2

After the above is green:

- Re-run `GrossfileRecalculationTest#givenGrossfileZip_whenRecalculate_thenWriteResultsToFilesystem`
  (currently `@Disabled`) and inspect the resulting
  `target/test-output/grossfile-recalc/gf2-d20260731/error#diff-deviations.txt`.
- Z122 status: with the schema fix alone, Z122 is **still expected to be silent**
  because the immediate cause (the `previousSteuerMeldung != null` guard at
  `SteuerMeldungStatusValidationService.java:137`) hasn't been addressed. The
  schema fix is a precondition: once the cross-ISIN/test-data issue is solved,
  Z122 will finally fire `ERR_UNGL_VORH` for LEI with `previousLei = null` vs
  `currentLei = "U090UTR2IZOR4U9CSZ50"`.
- Update `gf2-nur-im-altsystem-analysis.md` Entry 2 to record both findings:
  upgrade the "best hypothesis" wording to "confirmed legacy mechanics
  (`c_st_meldung.cpp:7676` keys lookup on `stm_id` alone)" and add the schema
  gap as a separate sub-issue with a back-reference to this plan.

## Critical files

- `ifas-database/ifas-database-flyway/src/main/resources/db/migration/postgres15/V036__steuer_meldung_lei.sql` *(new)*
- `ifas-database/ifas-database-flyway/src/main/resources/db/migration/sybase16/V036__steuer_meldung_lei.sql` *(new)*
- `ifas-database/ifas-persistence-stm/src/main/java/at/oekb/ifas/persistence/stm/steuermeldung/SteuerMeldungEntity.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/db/LazyDbSteuerMeldung.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/db/EagerDbSteuerMeldung.java`
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungService.java` (CSV → entity write)
- `ifas-database/ifas-data-import-export/src/main/java/at/oekb/ifas/importexport/dto/SteuerMeldungDto.java`
- `ifas-database/ifas-data-import-export/src/main/java/at/oekb/ifas/importexport/dto/DtoEntityMapper.java`
- `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/meldung/db/LazyDbSteuerMeldungLeiSourceTest.java` (invert)

## Open decisions

- **Backfill in V036 migration**: include it (option a) or skip it (option b)?
  Default recommendation: include for prod paths.
- **Sybase**: does `kurs..steuer_meldung.LEI` already exist there from legacy?
  Confirm before deciding between an ALTER TABLE and a comment-only migration.
- **`WknDesc.lei`**: any remaining callers after Step 4/5? `grep` `WknDesc::getLei`
  and `wknDesc.lei` to decide whether the master-data column itself should be
  deprecated or kept for non-STM use cases.

## Verification

1. `mvn -Pno-proxy clean install -pl ifas-database/ifas-persistence-stm,ifas-domain/ifas-domain-stm,ifas-database/ifas-data-import-export -am` — compiles, MapStruct regenerates.
2. `mvn -Pno-proxy test -Dtest=LazyDbSteuerMeldungLeiSourceTest` — inverted assertions pass.
3. `mvn -Pno-proxy test -Pskip-postgres15-tests -Pskip-sybase16-tests` — H2 path (Flyway picks up the postgres15 migration).
4. Full multi-DB run: `mvn -Pno-proxy test` — verifies postgres15 + sybase16 Flyway scripts apply cleanly.
5. Run `LocalH2OnlyIfasApplication`, upload a CSV with status CONFIRMED carrying a non-null LEI, and confirm the DB row has a populated `kurs..steuer_meldung.LEI` after import.
6. Re-run the disabled `GrossfileRecalculationTest` and diff
   `error#diff-deviations.txt` against the prior version to confirm no
   regressions in unrelated entries.