---
description: When writing or modifying Web UI page controller methods (Spring MVC @Controller classes)
globs:
  - "**/web/**/*Controller.java"
  - "**/web/**/*PageController.java"
---

# Web UI Page Controller Convention

ALWAYS use explicit `@RequestParam` annotations for method parameters in controller handler methods.

Do NOT rely on implicit parameter binding — every request parameter must have an `@RequestParam` annotation.

Example:
```java
// CORRECT
@GetMapping("/search")
public String search(@RequestParam("query") String query, @RequestParam("page") int page) { ... }

// WRONG - missing @RequestParam
@GetMapping("/search")
public String search(String query, int page) { ... }
```