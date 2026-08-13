---
paths:
  - "**/*.java"
---

# Comments & Javadoc

Default to none — well-named identifiers document themselves. Never document trivial
getters/setters or add empty `@param`/`@return`.

## When one is warranted

- Public API behaviour not evident from the signature
- Pre-/post-conditions, invariants, thrown exceptions
- Domain context: German term, business rule, legal reference
- Inline: logic needing a second read — non-obvious algorithm, upstream-bug workaround,
  intentional ordering, performance trade-off. Say *why*, not *what*.

## How to write it

- One fact, stated once. Prefer a single line; add a line only for a distinct fact.
- Name the anchor — `Class#method`, `file:line`, commit hash, legal § — don't describe it.
- No narration, hedging, or background obtainable from the code or git history.

## Describe the code, not the change

A comment states what the code does now, for a reader who never saw the previous version.
It is neither a changelog nor a bug report. Keep out:

- **Change history** — "used to", "previously", "now also", what the old version got wrong,
  why an alternative was rejected. → commit message.
- **Debugging trail** — which test or fixture exposed it, the symptom, counts. Measurements
  go stale. → plan document.
- **Scope beyond the member** — document what the comment sits on; a caller's condition is
  explained at the call site, not in the callee's Javadoc.

```java
// wrong — history, the fixture that exposed it, a count that will go stale
// The row used to be stored as field -> {BETRAG}, which threw ClassCastException in
// extractCountryVector and broke StmDiffsTest T08/T10 (~152 such rows per return file).

// correct — the rule that holds, stated once
// Without a LAENDERCODE the BETRAG would land where the country level belongs.
```