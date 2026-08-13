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

## Formatting

When a call's arguments are chopped down — the first argument starts on a new line after the
opening `(` — the closing `)` must start on its own line as well:

```java
// wrong
return collectInIsolatedTransaction(
        () -> _getDtosForIsin(isin, exportedWfsWkn, stichtag, minStmVersion, excludeBaseData));

// correct
return collectInIsolatedTransaction(
        () -> _getDtosForIsin(isin, exportedWfsWkn, stichtag, minStmVersion, excludeBaseData)
);
```

This also holds for a nested call whose own arguments are chopped down:

```java
// correct
.flatMap(isin -> getDtosForIsin(
        isin, exportedWfsWkn, stichtag, minStmVersion, excludeBaseData, transactional
).stream())
```

Arguments that still fit on the line with the opening `(` keep the closing `)` on that same line.


## Declared Types in Signatures

Method return types, parameters, and fields declare a type callers depend on. Two rules,
in order of strength:

1. **Never expose a concrete implementation.** `ArrayList`, `LinkedHashMap`, `HashSet`,
   `TreeMap`, etc. must not appear in a signature — only the interface they implement
   (`List`, `Map`, `Set`, ...). The concrete class belongs to the `new ...` and its local
   variable, nowhere else.
2. **Among interfaces, declare the most general one that satisfies callers.** `SequencedMap`
   is an interface, not a concrete type — but it is a *stronger* contract than `Map`. Only
   widen the declared interface (`Map` over `SequencedMap`, `Collection` over `List`) when
   nothing forces the stronger one. If a caller genuinely needs the extra contract (e.g.
   `SequencedMap.reversed()`, `List.get(int)`), declaring it is correct — the need must be
   real, not incidental.

```java
// wrong — concrete implementation in the signature (rule 1)
public LinkedHashMap<K, V> byPosition() { ... }
public ArrayList<String> names() { ... }

// correct — signature is an interface, implementation stays concrete
public Map<K, V> byPosition() {
    Map<K, V> map = new LinkedHashMap<>();   // LinkedHashMap: iteration order preserved
    ...
    return map;
}
public List<String> names() { ... }
```

Note: this concerns API surface. Local variables still use explicit concrete types
per **Type Declarations** above (`var` is forbidden).


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

## Javadoc & Inline Comments

Skip Javadoc for self-explanatory methods, fields, and classes — well-named identifiers document themselves.

Add Javadoc when:
- Public API behavior is non-obvious from the signature
- Pre-/post-conditions, invariants, or thrown exceptions need stating
- Domain context (German term, business rule, legal reference) needs explaining

For complex inline logic that requires a second read to follow, add a short comment explaining *why*, not *what*. Typical cases: non-obvious algorithms, workarounds for upstream bugs, intentional ordering, performance trade-offs.

Avoid restating what the code already says, documenting trivial getters/setters, or adding empty `@param`/`@return` tags.

## Comment Brevity

Keep every comment as short and precise as possible — the fewest words that carry the *why*. A comment must earn its lines; when in doubt, cut.

- One fact per comment. State it once, do not restate it in a longer form on the next line.
- Prefer a single line. Only span multiple lines when each line adds a distinct fact (e.g. cause, decision, source/commit).
- Drop narration, hedging, and background the reader can get from the code, git history, or a linked reference. Cite the reference (ticket, commit, `file:line`, legal §) instead of paraphrasing it.
- Name the concrete anchor (method, code, commit hash, date) over prose describing it.

### Describe the code, not the change

A comment states what the code does now, for a reader who never saw the previous version. It is not a
changelog entry and not a bug report. Keep out:

- **Change history** — "used to", "previously", "now also", what an earlier implementation got wrong.
  This belongs in the commit message.
- **Debugging trail** — which test or fixture exposed the problem, how many rows/deviations were
  counted, what the symptom looked like. Measurements go stale immediately; they belong in the plan
  document, if anywhere.
- **Scope beyond the member** — document the method or field the comment sits on. A caller's condition
  is explained at the call site, not in the callee's Javadoc.

```java
// wrong — history, the fixture that exposed it, and a count that will go stale
// The row used to be stored as field -> {BETRAG}, which threw ClassCastException in
// extractCountryVector and broke StmDiffsTest T08/T10 (~152 such rows per return file).

// correct — the rule that holds, stated once
// Without a LAENDERCODE the BETRAG would land where the country level belongs.
```
