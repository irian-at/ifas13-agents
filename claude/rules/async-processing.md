---
paths:
  - "**/service/**/*.java"
  - "**/config/**/*.java"
---

# Asynchronous Processing

## Do NOT use `@Async` within the same class

Spring's `@Async` uses AOP proxies. Calling an `@Async` method from within the same class bypasses the proxy and executes synchronously.

## Use Executor injection instead

Inject the `Executor` bean directly via constructor:

```java
@Qualifier("workQueueTaskExecutor") Executor taskExecutor
```

Then submit work explicitly:

```java
taskExecutor.execute(() -> processTask());
```

## Reference implementation

See `WorkQueueExecutor` in `ifas-services/ifas-main-service` for the established pattern (task execution, heartbeat scheduling, log flushing).
