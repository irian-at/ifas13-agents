---
description: When writing Java code that involves time, date, or clock operations
globs:
  - "**/*.java"
---

# Time and Date Handling

**Never use Java time/date factory methods directly.** The codebase enforces this via the `forbiddenapis` plugin. Use the utility classes:
- `Instants` utility for `Instant`
- `OffsetDateTimes` utility for `OffsetDateTime`
- `LocalDates` utility for `LocalDate`

Forbidden patterns:
```java
// DON'T
Instant.now()
LocalDate.now()
System.currentTimeMillis()

// DO
Instants.now()
LocalDates.now()
```