---
name: mcp-rename-lombok-fields
description: "JetBrains MCP rename_refactoring on Lombok entity fields errors with \"Access from EDT is not allowed\" and misses strings, setters and builder calls"
metadata:
  node_type: memory
  type: reference
  originSessionId: 30601363-4040-41b1-9298-d52b746f6eab
  modified: 2026-10-15T11:21:58.666Z
---

`mcp__idea__rename_refactoring` on a field of a Lombok-annotated JPA entity (`PreisMeldungJob`,
`PreisfileJob`, …) returns "Access from EDT is not allowed". The rename still happens in the IDE
buffers but reaches disk only when `mcp__idea__build_project` flushes them (`search_text` and
`get_file_problems` do not); once it renamed the field without its usages. Verify the disk state with
`git diff` after every such call. The single-file JPS build may report bogus classpath errors; Maven
is the judge.

What the IDE rename does not update, so grep and fix by hand:
- Lombok setter call sites (`setX(`) and builder calls (`.x(`); getters usually follow
- JPQL in `@Query`, `@Param("…")`, Criteria `root.get("…")`, `@PageableDefault(sort = "…")`,
  `Sort.by("…")`, `model.addAttribute("…")`
- Thymeleaf expressions, `T(fully.qualified.Type)`, URL/query params, expected HTML in web tests
- A type rename with file rename gets staged by IntelliJ on its own (`R` in the index)
- Its "text occurrences" pass also rewrites `.md` files in `ifas13-agents` (plans, incl. history
  in closed todos); review that repo's diff after a rename and restore history it falsified

It also re-chops some long lines on rename; restore the original layout.

Seen 2026-10-15 in the Fondspreise naming bundle, see [[naming]].
