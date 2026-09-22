---
name: feedback_no-nullable-on-local-variables
description: "Never annotate local variables with @Nullable; JSpecify scopes it to fields, parameters and return values only."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 90e09827-1021-41c1-8db8-9731fd935c0c
  modified: 2026-09-22T09:35:53.573Z
---

Never put `@Nullable` (or any JSpecify nullness annotation) on a **local variable** declaration.
Write `String filename = resource.getFilename();`, not `@Nullable String filename = ...`.

**Why:** JSpecify deliberately leaves local variables out of scope — their nullness is inferred by
the analysis, so the annotation is silently ignored and is pure noise. The project's
`.claude/rules/java-conventions.md` matches this: it mandates `@Nullable` for *fields, parameters
and return values* only. It compiles (the annotation is `TYPE_USE`), so nothing will flag it —
the user has to.

**How to apply:** When a nullable-returning call (e.g. Spring's `Resource#getFilename()`) is
assigned to a local, just declare the plain type. Keep `@Nullable` on the signature side —
fields, method parameters, return types. After removing the last one from a file, drop the now
unused `org.jspecify.annotations.Nullable` import (`@NullMarked` on the type stays).

Since 2026-09-22 the negative half is stated in `.claude/rules/java-conventions.md` under
`## Null Safety`, right beside the positive rule. This memory keeps only the origin.

Related: [[feedback_only-change-what-was-asked]]
