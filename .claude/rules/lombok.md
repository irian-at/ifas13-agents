---
description: When writing or modifying Java classes that could benefit from Lombok annotations
globs:
  - "**/*.java"
---

# Lombok Best Practices

**Always use Lombok annotations where possible to reduce boilerplate code.**

## Utility Classes

Use `@UtilityClass` for utility classes:

```java
import lombok.experimental.UtilityClass;

@UtilityClass
public final class MyUtils {

    public static String doSomething() {
        // implementation
    }
}
```

Benefits:
- Automatic private constructor generation
- Prevents instantiation attempts
- Cleaner code without boilerplate
- Consistent with project standards

Example utility classes in the codebase:
- `at.oekb.ifas.core.temporal.Instants`
- `at.oekb.ifas.core.temporal.LocalDates`
- `at.oekb.ifas.core.temporal.OffsetDateTimes`
- `at.oekb.ifas.core.temporal.Durations`

## Data Classes

Use `@Getter` and `@Setter` for DTOs and data classes:

```java
import lombok.Getter;
import lombok.Setter;

@Getter
public class MyDataClass {
    private final String id;
    @Setter
    private String name;
    @Setter
    private int value;

    public MyDataClass(String id) {
        this.id = id;
    }
}
```

Benefits:
- Class-level `@Getter` generates getters for all fields
- Field-level `@Setter` generates setters only where needed
- Immutable fields (final) only get getters, never setters
- Reduces boilerplate from ~50+ lines to ~10 lines for typical classes

Example: `AsyncStmRecalcService.RecalcTask`