---
paths:
  - "**/test/**/*.java"
  - "**/ifas-testing/**/*.java"
---

# Testing Conventions

## Test Method Naming

Always use given-when-then pattern:

```java
@Test
void givenValidInput_whenProcess_thenReturnsResult() { }

@Test
void givenNullInput_whenValidate_thenThrowsException() { }
```

## Assertions

AssertJ only. Never use JUnit assertions (`assertEquals`, `assertTrue`, etc.):

```java
assertThat(actual).isEqualTo(expected);
assertThat(list).hasSize(3).containsExactly("a", "b", "c");
assertThatThrownBy(() -> method(null)).isInstanceOf(IllegalArgumentException.class);
```

## Dependency Injection

Use `@Inject` (not `@Autowired`):

```java
private @Inject MyService service;
private @Inject SimpleTransactionTemplate tx;
```

## Integration Tests

Use `@TestTemplate` with `IntegrationTestApplication.MULTI_DB_EXTENSION` for multi-database tests (H2, PostgreSQL 15, Sybase 16).

## Test Data

- Use `{Entity}Testdata` utility classes for creating test entities
- Use `{Entity}Assertions` for complex entity assertions
- Prefer **distinct digits** in numeric test values to reveal formatting bugs:
  `new BigDecimal("1234.5679")` over `new BigDecimal("1000.0000")`
- Test data location: `ifas-testing/ifas-test-support/src/main/resources/at/oekb/ifas/testdata/`
- Use `StmTestResources` utility class to load test data by test ID

## Test Resources

Load from classpath with `ClassPathResource`:

```java
Resource resource = new ClassPathResource("at/oekb/ifas/domain/stm/test-data.csv");
```
