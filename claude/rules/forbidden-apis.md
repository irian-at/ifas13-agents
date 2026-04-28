---
paths:
  - "**/*.java"
---

# Forbidden APIs & Enforced Standards

The `forbiddenapis` Maven plugin enforces these rules during the `package` phase.

## Temporal Utilities (REQUIRED)

Direct calls to `java.time.*.now()` are forbidden. Use IFAS temporal utilities instead:

| Forbidden | Required | Package |
|-----------|----------|---------|
| `Instant.now()` | `Instants.now()` | `at.oekb.ifas.core.temporal` |
| `LocalDate.now()` | `LocalDates.now()` | `at.oekb.ifas.core.temporal` |
| `LocalDateTime.now()` | `LocalDateTimes.now()` | `at.oekb.ifas.core.temporal` |
| `System.currentTimeMillis()` | Use temporal utilities | |

## Console Output

`System.out` and `System.err` are forbidden. Use `@Slf4j` annotation for logging.

## Reflection & Non-Portable APIs

- Reflective access methods are forbidden (security)
- `sun.misc.Unsafe` and similar undocumented classes are forbidden

## JUnit Version

- JUnit 5 only (`org.junit.jupiter.api.*`)
- JUnit 4 (`org.junit.Test`, `org.junit.Before`, etc.) is forbidden

## Jakarta EE

Use `jakarta.*` packages, not `javax.*`.

## Apache Commons

Use Collections 4 (`collections4`) and Lang 3 (`lang3`) only.

## Encoding

- Source files: UTF-8
- Properties files: ISO-8859-1
