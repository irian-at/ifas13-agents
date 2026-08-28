---
name: project_csvsource-testtemplate-provider-limits
description: The @TestTemplate multi-DB extension re-implements @CsvSource itself — no null args, no enum conversion.
metadata:
  type: project
---

`MultipleApplicationContextsProvider` (support-libs/core-test-support) parses `@CsvSource` on
`@TestTemplate` methods itself instead of delegating to JUnit, and its converter is narrower:

- An empty column becomes `null`, but `supportsParameter` rejects `null` args, so the invocation
  fails with a resolution error. Every column must carry a value — use a sentinel (`-`, `0`) for
  "not applicable", never an empty field or a `@Nullable` parameter.
- `convertValue` handles String/primitives/`LocalDate` only. An **enum** parameter silently receives
  a `String` and then fails `isTypeCompatible`. Declare the column as `String` and call
  `valueOf(...)` in the test body.

**Why:** the two limits look like JUnit behaviour but are not; the failure surfaces as an opaque
parameter-resolution error, not a conversion message.

**How to apply:** when adding a column to a `@TestTemplate` + `@CsvSource` table (e.g.
`JiraIssueRecalculationTest`), fill it in every row and keep enum-valued columns typed as `String`.
Related: [[project_validationsetting-flags-have-two-effects]].
