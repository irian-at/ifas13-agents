---
paths:
  - "**/*.java"
---

# Java Conventions

## Type Declarations

`var` (local variable type inference) is forbidden. Always use explicit types:

```java
// wrong
var list = new ArrayList<String>();

// correct
ArrayList<String> list = new ArrayList<>();
```

## Logging

Use Lombok's `@Slf4j` annotation. Do NOT declare loggers manually:

```java
// correct
@Slf4j
public class MyService { }

// wrong
private static final Logger LOG = LoggerFactory.getLogger(MyClass.class);
```

## Null Safety

All classes and interfaces must use JSpecify annotations (`org.jspecify.annotations`):
- Mark every class/interface with `@NullMarked`
- Explicitly mark nullable fields, parameters, and return values with `@Nullable`

## Exception Handling

Never propagate `IOException` via `throws` declarations. Catch it and throw an unchecked exception:
- `IllegalArgumentException` for invalid input
- `IllegalStateException` for unexpected system state

Include context in the message. Chain the original cause. No extra logging.

```java
// correct
try {
    Files.readString(path);
} catch (IOException e) {
    throw new IllegalStateException("Failed to read file: " + path, e);
}
```

## Naming Conventions

- **Utility classes**: plural form (`Instants`, `CsvValueFormatters`, not `InstantHelper`)
- **Writer classes**: `{Purpose}Writer` with plural facade (`ValidationMsgLogs` for `ValidationMsgLogWriter`)
- **Test data creators**: `{Entity}Testdata` (e.g., `WaehrungTestdata`)
- **Custom assertions**: `{Entity}Assertions` (e.g., `SteuerMeldungEntityAssertions`)
- **Web controllers**: `{Name}PageController` suffix
