---
paths:
  - "**/*Test.java"
  - "**/*Tests.java"
  - "**/test/**/*.java"
---

# Unit Tests

## Assertions: Always Use AssertJ

**Always use AssertJ for unit test assertions.** Do not use JUnit's built-in assertions or Hamcrest.

```java
// DON'T use JUnit assertions
assertEquals(expected, actual);
assertTrue(condition);
assertNotNull(value);

// DON'T use Hamcrest
assertThat(actual, is(expected));
assertThat(list, hasSize(3));

// DO use AssertJ
import static org.assertj.core.api.Assertions.assertThat;

assertThat(actual).isEqualTo(expected);
assertThat(condition).isTrue();
assertThat(value).isNotNull();
assertThat(list).hasSize(3);
```

### Common AssertJ Patterns

```java
// Collections
assertThat(list).isEmpty();
assertThat(list).hasSize(3);
assertThat(list).contains("a", "b");
assertThat(list).containsExactly("a", "b", "c");

// Strings
assertThat(string).isBlank();
assertThat(string).startsWith("prefix");
assertThat(string).contains("substring");

// Exceptions
assertThatThrownBy(() -> methodThatThrows())
    .isInstanceOf(IllegalArgumentException.class)
    .hasMessageContaining("expected message");

// Objects
assertThat(object).isNotNull();
assertThat(object).extracting("field").isEqualTo(expected);

// Optional
assertThat(optional).isPresent();
assertThat(optional).contains(expectedValue);
```

## Test Method Naming

Use the given-when-then pattern. No `@DisplayName` needed — the method name is self-documenting.

```java
@Test
void givenValidInput_whenProcess_thenReturnsExpectedResult() {
    // given
    var input = createValidInput();

    // when
    var result = service.process(input);

    // then
    assertThat(result).isEqualTo(expectedResult);
}
```

## Required Maven Profiles

**Always** include these profiles when running `mvn` commands:

```bash
mvn test -Pno-proxy -Pplatform-arm64
```

## Running Tests

```bash
# All tests in a specific module
mvn test -pl ifas-domain/ifas-domain-stm -Pno-proxy -Pplatform-arm64

# Single test class
mvn test -pl ifas-domain/ifas-domain-stm -Dtest=MyClassTest -Pno-proxy -Pplatform-arm64

# Single test method
mvn test -pl ifas-domain/ifas-domain-stm -Dtest="MyClassTest#givenX_whenY_thenZ" -Pno-proxy -Pplatform-arm64

# Skip database-dependent tests
mvn test -Pskip-postgres15-tests -Pskip-sybase16-tests -Pno-proxy -Pplatform-arm64
```

## Module Path Reference

When running tests for a specific module, use `-pl` with the module path:

| Domain | Module path |
|--------|-------------|
| Tax reports | `ifas-domain/ifas-domain-stm` |
| Master data | `ifas-domain/ifas-domain-stamm` |
| Funds | `ifas-domain/ifas-domain-fonds` |
| Securities | `ifas-domain/ifas-domain-wkn` |
| Services | `ifas-services/ifas-main-service` |
| Persistence | `ifas-database/ifas-persistence-stm` (etc.) |
| Integration | `ifas-testing/ifas-integration-tests` |
| CSV schema | `support-libs/csv-schema` |