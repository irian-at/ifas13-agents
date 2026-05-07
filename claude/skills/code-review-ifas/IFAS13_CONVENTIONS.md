# IFAS13 Convention Checklist

Quick reference for code review. Flag violations of these conventions.

Source: synced from `.claude/rules/` in the IFAS13 project.

## Null Safety (JSpecify)

All classes and interfaces must use JSpecify annotations (`org.jspecify.annotations`):

```java
// ✅ Required on all classes/interfaces
@NullMarked
public class MyService {

    // ✅ Mark nullable explicitly
    private @Nullable String optionalField;

    // ✅ Nullable parameters
    public void process(@Nullable String input) { }

    // ✅ Nullable return
    public @Nullable Result findById(Long id) { }
}
```

**Flag if missing**: `@NullMarked` on class, `@Nullable` on nullable fields/params/returns.

## Type Declarations

`var` (local variable type inference) is forbidden. Always use explicit types:

```java
// ❌ Forbidden
var list = new ArrayList<String>();

// ✅ Required
ArrayList<String> list = new ArrayList<>();
```

## Logging

Use Lombok's `@Slf4j` annotation. Do NOT declare loggers manually:

```java
// ✅ Required
@Slf4j
public class MyService { }

// ❌ Forbidden
private static final Logger LOG = LoggerFactory.getLogger(MyClass.class);
```

## Exception Handling

Never propagate `IOException` via `throws` declarations. Catch it and throw an unchecked exception:
- `IllegalArgumentException` for invalid input
- `IllegalStateException` for unexpected system state

Include context in the message. Chain the original cause. No extra logging.

```java
// ✅ Required
try {
    Files.readString(path);
} catch (IOException e) {
    throw new IllegalStateException("Failed to read file: " + path, e);
}
```

## Temporal Utilities

Direct calls to `java.time.*.now()` are forbidden. Use IFAS temporal utilities instead.

| Forbidden                     | Required               |
|-------------------------------|------------------------|
| `Instant.now()`               | `Instants.now()`       |
| `LocalDate.now()`             | `LocalDates.now()`     |
| `LocalDateTime.now()`         | `LocalDateTimes.now()` |
| `System.currentTimeMillis()`  | Use temporal utilities |

**Package**: `at.oekb.ifas.core.temporal`

## Console Output

`System.out` and `System.err` are forbidden. Use `@Slf4j` for logging:

```java
// ❌ Forbidden
System.out.println(...)
System.err.println(...)

// ✅ Required
@Slf4j
public class MyClass {
    void run() {
        log.info(...);
        log.error(...);
    }
}
```

## Apache Commons

Use Collections 4 (`collections4`) and Lang 3 (`lang3`) only:

```java
// ❌ Old packages
import org.apache.commons.collections.*;
import org.apache.commons.lang.*;

// ✅ Modern packages
import org.apache.commons.collections4.*;
import org.apache.commons.lang3.*;
```

## Jakarta EE

Use `jakarta.*` packages, not `javax.*`.

## JUnit Version

JUnit 5 only (`org.junit.jupiter.api.*`). JUnit 4 is forbidden.

```java
// ❌ Forbidden
import org.junit.Test;
import org.junit.Before;

// ✅ Required
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.BeforeEach;
```

## Encoding

- Source files: UTF-8
- Properties files: ISO-8859-1

## Naming Conventions

- **Utility classes**: plural form (`Instants`, `CsvValueFormatters`, `ValidationMsgCodes`) — never `*Utils` or `*Helper`
- **Writer classes**: `{Purpose}Writer` with plural facade (`ValidationMsgLogs` for `ValidationMsgLogWriter`)
- **Test data creators**: `{Entity}Testdata` (e.g., `WaehrungTestdata`)
- **Custom assertions**: `{Entity}Assertions` (e.g., `SteuerMeldungEntityAssertions`)
- **Web controllers**: `{Name}PageController` suffix

## Javadoc & Inline Comments

Skip Javadoc for self-explanatory methods, fields, and classes — well-named identifiers document themselves.

Add Javadoc when:
- Public API behavior is non-obvious from the signature
- Pre-/post-conditions, invariants, or thrown exceptions need stating
- Domain context (German term, business rule, legal reference) needs explaining

For complex inline logic that requires a second read to follow, add a short comment explaining *why*, not *what*. Typical cases: non-obvious algorithms, workarounds for upstream bugs, intentional ordering, performance trade-offs.

Avoid restating what the code already says, documenting trivial getters/setters, or adding empty `@param`/`@return` tags.

## Writer Pattern

Use `OutputStreamTextWriterHelper`:

```java
try (var wh = new OutputStreamTextWriterHelper(outputStream)) {
    wh.writeLine("Header");
    wh.withIndent(() -> {
        wh.writeLine("Indented content");
    });
}
```

## Testing Conventions

### Test Method Naming

Always use given-when-then pattern:

```java
// ✅ Required
@Test
void givenValidInput_whenProcess_thenReturnsResult() { }

@Test
void givenNullInput_whenValidate_thenThrowsException() { }

// ❌ Avoid
@Test
void testProcess() { }

@Test
void shouldWork() { }
```

### Assertions

AssertJ only. Never use JUnit assertions:

```java
// ❌ Forbidden
assertEquals(expected, actual);
assertTrue(condition);
assertNotNull(object);

// ✅ Required
assertThat(actual).isEqualTo(expected);
assertThat(list).hasSize(3).containsExactly("a", "b", "c");
assertThatThrownBy(() -> method(null)).isInstanceOf(IllegalArgumentException.class);
```

### Dependency Injection

Use `@Inject` (not `@Autowired`):

```java
// ❌ Avoid
@Autowired
private MyService service;

// ✅ Required
private @Inject MyService service;
private @Inject SimpleTransactionTemplate tx;
```

### Integration Tests

Use `@TestTemplate` with `IntegrationTestApplication.MULTI_DB_EXTENSION` for multi-database tests (H2, PostgreSQL 15, Sybase 16).

### Test Data

- Use `{Entity}Testdata` utility classes for creating test entities
- Use `{Entity}Assertions` for complex entity assertions
- Prefer **distinct digits** in numeric test values to reveal formatting bugs:
  `new BigDecimal("1234.5679")` over `new BigDecimal("1000.0000")`
- Test data location: `ifas-testing/ifas-test-support/src/main/resources/at/oekb/ifas/testdata/`
- Use `StmTestResources` utility class to load test data by test ID

### Test Resources

Load from classpath with `ClassPathResource`:

```java
Resource resource = new ClassPathResource("at/oekb/ifas/domain/stm/test-data.csv");
```

## Database Conventions

### JPA Entities

- Use `@Entity` with `@Table(catalog = "...", name = "...")` — catalogs are `ifas`, `kurs`, and `vwkn`
- Explicit `@Column(name = "...")` mappings on all fields
- Lombok: `@Getter`, `@NoArgsConstructor`, `@EqualsAndHashCode(onlyExplicitlyIncluded = true)`, `@ToString(onlyExplicitlyIncluded = true)` — no class-level `@Setter`, only selective per-field
- JSpecify: `@NullMarked` at class level, selective `@Nullable` on individual fields

### JPA Converters (legacy data mappings)

| Converter                     | Purpose                          |
|-------------------------------|----------------------------------|
| `DJaNeinToBooleanConverter`   | "JA"/"NEIN" → Boolean            |
| `TJaNeinToBooleanConverter`   | "J"/"N" → Boolean                |
| `UriConverter`                | URI ↔ String (`autoApply = true`)|

```java
@Convert(converter = DJaNeinToBooleanConverter.class)
private Boolean active;
```

### JPA Repositories

- Extend `JpaRepository<Entity, ID>` and `JpaSpecificationExecutor<Entity>`
- Use `@Query` with named parameters (`@Param`) for complex operations
- Use `@Modifying` on UPDATE/DELETE query methods

### Flyway Migrations

- Scripts location: `ifas-database/ifas-database-flyway/src/main/resources/db/migration/`
- Database-specific directories: `postgres15/` and `sybase16/`
- H2 reuses PostgreSQL migrations directly (`DbConfigs.FLYWAY_MIGRATION_LOCATION_H2 = FLYWAY_MIGRATION_LOCATION_POSTGRES`) — H2 runs in `MODE=PostgreSQL` compatibility mode, so no H2-specific SQL is needed

### Multi-Database Support

The project supports H2 (in-memory), PostgreSQL 15, and Sybase 16. TestContainers is used for database integration tests. Database configuration classes are in `ifas-database/ifas-database-config/`. Each defines a Spring profile:

**H2** (in-memory, PostgreSQL compatibility mode):
- `h2-db1`, `h2-db2`, `h2-db3` — application databases
- `h2-infra-db` — infrastructure (work queue, jobs, filestore)

**PostgreSQL 15**:
- `postgres-localhost-7432` — local development (port 7432)
- `postgres-server` — server deployment (environment-configured)
- `postgres-testcontainer` — TestContainers-managed (integration tests only)

**Sybase 16**:
- `sybase-localhost-5001` — local development
- `sybase-gast` — staging environment
- `sybase-ifasneu` — alternative instance

Database routing uses `database-context.*-db-key` properties in `application-*.properties` files to map service contexts to database profiles.

## Asynchronous Processing

### Do NOT use `@Async` within the same class

Spring's `@Async` uses AOP proxies. Calling an `@Async` method from within the same class bypasses the proxy and executes synchronously.

### Use Executor injection instead

Inject the `Executor` bean directly via constructor:

```java
@Qualifier("workQueueTaskExecutor") Executor taskExecutor
```

Then submit work explicitly:

```java
taskExecutor.execute(() -> processTask());
```

Reference implementation: `WorkQueueExecutor` in `ifas-services/ifas-main-service`.

## IDE Refactoring

Always use IDE/MCP refactoring tools for renames, moves, and structural changes. Never use bash commands for code operations.

**Why**: IDE refactorings are tracked as renames by git, update all imports and usages automatically, and are validated at compile-time.

**Do**:
- `mcp__jetbrains__rename_refactoring` for renaming classes, methods, variables
- `mcp__jetbrains__create_new_file` for creating new files
- IntelliJ "Refactor > Move" for moving to new packages

**Don't**:
```bash
mv Controller.java NewController.java    # breaks git tracking
cp file1.java file2.java                 # doesn't update references
sed -i 's/old/new/' file.java            # bypasses IDE validation
```

## Forbidden APIs Summary

The `forbiddenapis` Maven plugin enforces these during `package`:

- `sun.misc.Unsafe` and other undocumented internals
- Reflective access methods (security)
- `java.time.*.now()` — use temporal utilities
- `System.currentTimeMillis()` — use temporal utilities
- `System.out` / `System.err` — use `@Slf4j`
- `org.apache.commons.collections.*` / `org.apache.commons.lang.*` — use `collections4` / `lang3`
- `javax.*` — use `jakarta.*`
- JUnit 4 (`org.junit.Test`, `org.junit.Before`, …) — use JUnit 5