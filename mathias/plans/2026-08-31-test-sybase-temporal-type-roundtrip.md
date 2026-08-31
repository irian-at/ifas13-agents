# Test Sybase temporal datatype round-trip

## Context

We need to know, empirically, whether `OffsetDateTime`, `LocalDateTime` and `ZonedDateTime` all
survive a write/read cycle through Sybase as **the same `java.time.Instant`**. The question is not
academic: the codebase currently mixes temporal types on Sybase-backed tables with no test covering
the conversion, and Hibernate handles the three types differently per dialect.

Verified facts that motivate the test:

| Dialect | `getTimeZoneSupport()` | Column type in use |
|---|---|---|
| `H2Dialect` | `NATIVE` | `timestamp(6)` (Postgres tree reused) |
| `PostgreSQLDialect` | `NORMALIZE` | `timestamp(6)`, 11 cols `with time zone` |
| `SybaseASEDialect` (inherits base `Dialect`) | **`NONE`** | **`datetime` exclusively** (112 uses) |

- Sybase `datetime` stores **no offset** and has **1/300 s (~3.33 ms)** resolution. No `bigdatetime`
  anywhere.
- `hibernate.jdbc.time_zone = "Europe/Vienna"` is set at **all 18 JPA config sites** — production and
  test alike — so a test here faithfully mirrors production.
- `hibernate.timezone.default_storage` is set **nowhere**, so Hibernate's default storage strategy
  applies, and it resolves differently per dialect given the table above.
- `hibernate.hbm2ddl.auto = "none"` everywhere; there are **no temporal `AttributeConverter`s**. The
  three `columnDefinition = "timestamp(6) with time zone"` entities (`SteuerField.guelt`,
  `SteuerFieldFormel.guelt`, `Kest98.guelt`) are **dead metadata** — the real columns are
  `timestamp(6)` without tz on Postgres and `datetime` on Sybase.
- Entity convention today: `LocalDateTime` dominant in business entities, `OffsetDateTime` in all new
  infra, `Instant` once (`Land.validFrom`, flagged `// todo - change datatype!`), and
  **`ZonedDateTime` nowhere** — removed project-wide in commit `36575b4ab`.
- No dedicated timestamp/timezone round-trip test exists. Existing timestamp assertions are
  incidental and always use a tolerance.

Intended outcome: one focused test that pins the actual behaviour across H2 / Postgres / Sybase and
makes any divergence visible and explained, rather than discovered later in production data.

## Approach

A purpose-built test entity with the three types on three columns, its table created by the test
itself, exercised through the existing multi-DB harness.

### 1. Test entity + repository

New package `at.oekb.ifas.persistence.temporal` under
`ifas-testing/ifas-integration-tests/src/test/java/`.

Placement is **load-bearing**: `DbConfigs.createEntityManagerFactoryBean` pins
`setPackagesToScan(PersistencePackage.class.getPackage().getName())` → `at.oekb.ifas.persistence`.
Test classes already live in that package (e.g. `at.oekb.ifas.persistence.stamm.WaehrungRepositoryTest`),
so an `@Entity` there is picked up by all three child contexts. `@EnableJpaRepositories(basePackageClasses
= PersistencePackage.class)` likewise picks up a repository interface there.

`TemporalRoundtripItem.java` — follow `TestTableItem` (the repo's only other test-only entity) and the
database conventions (`@Getter`, `@NoArgsConstructor`, `@EqualsAndHashCode(onlyExplicitlyIncluded = true)`,
`@ToString(onlyExplicitlyIncluded = true)`, `@NullMarked`, explicit `@Column`):

```java
@Entity
@Table(name = "temporal_roundtrip")   // no catalog: NoCatalogNoSchemaPhysicalNamingStrategy strips it
public class TemporalRoundtripItem {

    @Id
    @Column(name = "id")
    private Integer id;                      // assigned, not generated - portable across all 3 DBs

    @Column(name = "ts_offset")
    private @Nullable OffsetDateTime tsOffset;

    @Column(name = "ts_local")
    private @Nullable LocalDateTime tsLocal;

    @Column(name = "ts_zoned")
    private @Nullable ZonedDateTime tsZoned;
}
```

`TemporalRoundtripRepository extends JpaRepository<TemporalRoundtripItem, Integer>`.

Safe for the rest of the suite: with `hbm2ddl.auto=none` nothing validates the schema, so a mapped
entity whose table is absent breaks no other test.

### 2. Table creation inside the test

Flyway locations are pinned to the production trees, so the test creates its own table. Inject the
active context's `DataSource`, then on a raw connection:

```java
try (Connection c = dataSource.getConnection()) {
    c.setAutoCommit(true);   // Sybase rejects DDL inside a multi-statement transaction
    // ... drop (ignore failure if absent), then create
}
```

`autoCommit(true)` on a raw connection is the established pattern — `DatabaseCleanups.dropAllTables`
does exactly this, and `SybaseContainerTest` uses raw `DriverManager` + `stmt.execute("CREATE TABLE ...")`.

DDL differs only in the column type, chosen from `connection.getMetaData().getDatabaseProductName()`
(jTDS reports `Adaptive Server Enterprise`; the others `PostgreSQL` / `H2`):

- Sybase → `datetime`
- Postgres / H2 → `timestamp(6)` **without** time zone

Using tz-less columns on Postgres/H2 deliberately mirrors the real columns behind `SteuerField.guelt`
and `Kest98.guelt`. A `with time zone` variant can be added later if we want to cover the 11 infra
columns, but none of those tables exist on Sybase.

Drop-then-create with the drop failure swallowed is more portable than `drop table if exists` (ASE
support is version-dependent) and avoids case-sensitivity guessing in `DatabaseMetaData.getTables`.
No `grant` needed: the test user creates the table and therefore owns it.

Call the helper at the **start of each `@TestTemplate` method body**, not from `@BeforeEach` —
`MultipleApplicationContextsProvider` performs field injection via its own `BeforeEachCallback`, so
method-body invocation avoids ordering ambiguity. `MultiDatabaseExtension` already truncates all
non-excluded tables after each invocation, so the table is cleaned automatically.

### 3. Test class

`TemporalTypeRoundtripTest.java`, same package. Shape follows `WaehrungRepositoryTest`:
`@RegisterExtension static Extension extension = TEST_WITH_ALL_DATABASE_SYSTEMS;`, `@TestTemplate`
methods, `@Inject` for `TemporalRoundtripRepository` / `SimpleTransactionTemplate` / `DataSource`,
and **two separate `tx.doTransactional` blocks** so the read hits the DB rather than the persistence
context.

Fixed `Instant.parse(...)` literals throughout — deterministic, and it sidesteps the `forbiddenapis`
ban on `java.time.*.now()` entirely.

**`givenViennaWinterInstant_whenRoundTrip_thenAllThreeTypesYieldSameInstant`** — `2024-01-15T12:34:56Z`
(Vienna CET, +01:00)
**`givenViennaSummerInstant_whenRoundTrip_thenAllThreeTypesYieldSameInstant`** — `2024-07-15T12:34:56Z`
(Vienna CEST, +02:00)

Both delegate to one helper. Whole seconds, so the value is exactly representable in Sybase `datetime`
and the test cannot fail for precision reasons. The winter/summer pair is what catches offset-normalisation
and DST bugs.

Derive all three from one reference `Instant` using the existing Vienna-anchored utilities
(`OffsetDateTimes.ofInstant`, `ZonedDateTimes.ofInstantInVienna`, `TimeZones.ZONE_ID_VIENNA_AUSTRIA`),
write, then read back and collapse each to an `Instant`:

```java
assertThat(read.getTsOffset().toInstant()).isEqualTo(reference);
assertThat(read.getTsZoned().toInstant()).isEqualTo(reference);
assertThat(read.getTsLocal().atZone(ZONE_ID_VIENNA_AUSTRIA).toInstant()).isEqualTo(reference);
```

`tsLocal` needs the Vienna zone to become an `Instant` at all — that is the contract being asserted,
not a fudge.

**`givenSubSecondInstant_whenRoundTrip_thenPrecisionLossIsBounded`** — `2024-07-15T12:34:56.123456789Z`.
Reuse the existing tolerance helper rather than inventing one:
`OffsetDateTimeAssertions.isCloseToByDefaultOffset` (`DEFAULT_DURATION_OFFSET = 4 ms`, which is
precisely the Sybase 1/300 s quantum; `LocalDateTimeAssertions` uses 100 ms). Log the read values via
`@Slf4j` so the actual per-DB precision is readable from the output.

**`givenStoredRow_whenReadRawString_thenStoredWallClocksAreIdentical`** — the diagnostic. After
writing, read the three columns over raw JDBC with `rs.getString(...)`, which renders the stored value
without client-side timezone conversion and needs no dialect-specific SQL. Assert **the three raw
strings are identical to each other**, and log them.

This is the assertion that explains any failure above: if the three types land on different stored
wall-clocks, the instant equality cannot hold, and the log shows immediately whether Sybase stored
Vienna-local or UTC.

## Files

**New** (all under `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/persistence/temporal/`):
- `TemporalRoundtripItem.java`
- `TemporalRoundtripRepository.java`
- `TemporalTypeRoundtripTest.java`

**Modified**: none. No production schema, migration, or config change.

## Reused rather than rewritten

Searched `support-libs/core-test-support`, `support-libs/core-support/…/temporal`,
`ifas-testing/**`, `ifas-database/**`:

- `IntegrationTestApplication.TEST_WITH_ALL_DATABASE_SYSTEMS` — the multi-DB extension
- `at.oekb.ifas.core.tx.SimpleTransactionTemplate` — transaction boundaries
- `OffsetDateTimes.ofInstant`, `ZonedDateTimes.ofInstantInVienna`, `TimeZones.ZONE_ID_VIENNA_AUSTRIA`
- `OffsetDateTimeAssertions.isCloseToByDefaultOffset` / `LocalDateTimeAssertions` — the 4 ms / 100 ms
  Sybase tolerances, already tuned for exactly this quantum
- `TestTableItem` — template for a test-only entity
- `WaehrungRepositoryTest` / `SteuerFieldRepositoryTest` — save-and-reread test shape
- `DatabaseCleanups` — the `setAutoCommit(true)`-before-DDL pattern

Nothing existing covers a temporal round-trip, so the entity, its table and the test are net-new.

## Prerequisites and expectations

- **Sybase credentials are required and currently absent.** `SybaseTestcontainer` reads
  `SYBASE_TESTCONTAINER_USER` / `_PASSWORD` / `_SA_USER` / `_SA_PASSWORD` from a repo-root `.env` via
  `springboot3-dotenv`. That file is gitignored and **not present in this checkout** (only `.env.local`,
  which carries different keys). Without it the container gets null credentials. This must be sorted
  before the Sybase invocation can run — it is the one thing that could block the whole point of the
  test.
- Sybase container startup is > 1 min (`withReuse(true)` amortises it across runs).
- **Sybase never runs in CI**: `jenkins-build`, `test`, `qas` and `prod` all set
  `ignore-test-dbms-sybase-testcontainer=true`, and a skipped profile silently drops those invocations
  without failing. This test documents Sybase behaviour for local runs only.
- `TEST_WITH_SYBASE_ONLY` exists and is currently unused — handy for fast iteration while developing
  the test.

## Verification

```bash
# all three databases
mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest=TemporalTypeRoundtripTest

# fast loop, H2 + Postgres only
mvn test -Pno-proxy -Pskip-sybase16-tests -pl ifas-testing/ifas-integration-tests \
    -Dtest=TemporalTypeRoundtripTest
```

Expect 4 test methods × 3 contexts = 12 invocations, labelled `Context 'h2-test'`,
`Context 'postgres-testcontainer'`, `Context 'sybase-testcontainer'`. Confirm all three contexts
actually ran — a missing Sybase invocation means the profile skipped it or `.env` is missing, not that
it passed.

Read the logged raw stored wall-clocks and precision values per database; that output is the actual
deliverable of the exercise.

If the test shows divergence, the lever is `hibernate.timezone.default_storage`
(`TimeZoneStorageType.NORMALIZE` / `NORMALIZE_UTC`), currently unset — but decide that after seeing
the numbers, not before. Fixing it is out of scope here.
