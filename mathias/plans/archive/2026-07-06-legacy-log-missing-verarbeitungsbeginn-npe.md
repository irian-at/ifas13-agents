# Legacy log parsing NPE: missing `Verarbeitungsbeginn` header

## Status

**BLOCKED — needs Mathias to confirm domain question first (see "Open question" below).**
Do not implement until it is confirmed whether a legacy log legitimately can lack a
`Verarbeitungsbeginn:` header line.

## Symptom

```
Caused by: java.lang.NullPointerException: processingDate is marked non-null but is null
    at ...LegacyLogFile$LegacyLogFileBuilder.processingDate(LegacyLogFile.java:28)
    at ...LegacyLogParser.parseLog(LegacyLogParser.java:71)
    at ...LegacyLogParser.parseErrorLog(LegacyLogParser.java:40)
    at ...LegacyLogParsers.parseErrorLog(LegacyLogParsers.java:13)
```

## Root cause

`LegacyLogParser.parseHeader` (`LegacyLogParser.java:105-137`) initializes
`processingDate = null` and only assigns it when a line matching
`HEADER_VERARBEITUNGSBEGINN_PATTERN` (`^\s*+Verarbeitungsbeginn\s*+:\s*+(.+)$`) is
found within the **first 10 lines** (`headerEndIndex = Math.min(10, lines.size())`).

If no such line matches, `processingDate` stays `null`. The value is then handed to
`LegacyLogFile.builder().processingDate(...)` (`LegacyLogParser.java:71`), whose
constructor parameter is `@NonNull` (`LegacyLogFile.java:31`) — Lombok's generated
builder throws the NPE.

The author already flagged this gap with two `// todo` comments in `parseHeader`
("what if parsing fails?").

### Ruled out

- **Not a date-format problem.** `CsvTypeConversions.parseLocalDateTime`
  (`CsvTypeConversions.java:36`) *throws* `IllegalArgumentException` on unsupported
  formats — it never returns `null`. A malformed-but-present date would surface as a
  different stacktrace, not this NPE. So the header line is genuinely **absent or
  unmatched**, not merely unparseable.
- **Not CRLF.** The legacy logs use CRLF endings, but `BufferedReader.lines()` strips
  `\r`/`\n`/`\r\n`, so the regex sees clean lines. The standard header
  (`     Verarbeitungsbeginn : 2026.02.25 17:07:09`) matches fine.

### Possible reasons the line is missing/unmatched in a real file (to investigate)

1. The log legitimately has no header block (e.g. a certain legacy code path / log
   variant writes body-only logs).
2. Header present but the `Verarbeitungsbeginn` line sits **beyond line 10** (unlikely
   for the standard 5-line header, but a longer/preamble variant could push it down).
3. File corruption / encoding. Note: the generated `target/grossfile-recalc/*.log`
   fixtures contain embedded NUL bytes on many lines — worth checking whether the real
   failing input is similarly corrupt, or was read with the wrong charset
   (`IFAS_LOG_CHARSET` / `IfasCharsets`).

**Action for Mathias:** identify the actual file that triggered the NPE and confirm
which of the above it is.

## Open question (must be answered before implementing)

> Is it legitimate/expected for a legacy log to be missing the `Verarbeitungsbeginn`
> header line?

- **If YES (legit)** → go with Option A (tolerate).
- **If NO (a header-less log means a wrong/corrupt/misrouted file)** → go with
  Option B (fail fast with a diagnosable error).

## Downstream impact (matters for either option)

`ValidationDeltaCalculator.compareMetadata` (`ValidationDeltaCalculator.java:119-121`)
does:

```java
java.time.LocalDateTime legacyDate = legacyFile.getProcessingDate();
java.time.LocalDateTime newDate = origination.getVerarbeitungsbeginn();
boolean dateMatches = legacyDate.equals(newDate);
```

If `processingDate` becomes nullable (Option A), this line NPEs unless made null-safe.
So Option A is **not** a one-line change — it requires guarding the comparison too.

---

## Option A — Tolerate (nullable date)

Use when a header-less legacy log is a legitimate input we must still process.

1. `LegacyLogFile.java`
   - Change constructor param `processingDate` from `@NonNull` to `@Nullable`
     (`org.jspecify.annotations.Nullable`).
   - Annotate the field / getter `@Nullable` accordingly. (Class should be
     `@NullMarked` per `java-conventions.md`; mark the nullable member explicitly.)
2. `LegacyLogParser.parseHeader` — keep returning `null` when unmatched; optionally
   `log.warn` naming the file so the missing header is visible.
3. `ValidationDeltaCalculator.compareMetadata` — make the date comparison null-safe:
   `boolean dateMatches = java.util.Objects.equals(legacyDate, newDate);`
   (both-null = match, one-null = mismatch). Confirm `Metadata` / `Summary`
   (`validation/delta/Metadata.java`, `Summary.java`) tolerate a null
   `legacyProcessingDate` in their `.equals`/report rendering.
4. Check any other `getProcessingDate()` callers (currently only
   `ValidationDeltaCalculator`).

### Tests
- Parse a fixture log with the `Verarbeitungsbeginn` line removed → returns a
  `LegacyLogFile` with `processingDate == null`, meldung sections still parsed.
- `compareMetadata` with null legacy date → `dateMatches == false`, no NPE.

## Option B — Fail fast (clear, contextual error)

Use when a header-less log indicates a wrong/corrupt/misrouted file.

1. `LegacyLogParser.parseLog` (or `parseHeader`) — after header parsing, if
   `processingDate == null`, throw
   `new IllegalStateException("Legacy log '" + filename + "' has no parseable Verarbeitungsbeginn header line")`.
   Keeps `LegacyLogFile.processingDate` `@NonNull`; replaces the opaque Lombok NPE with
   a diagnosable message naming the file. (Matches IFAS convention: `IllegalStateException`
   for unexpected system state — see `java-conventions.md`.)
2. Consider applying the same guard to `fileName`/`provider` if they can also be null
   (they can: `provider` starts null and is only set on a `Lieferant:` match).
3. No downstream changes needed — `processingDate` stays non-null.

### Tests
- Parse a fixture log without the header line → `IllegalStateException` whose message
  contains the filename; assert message, not just type.

## Notes / conventions

- Properties/log files in this repo are ISO-8859-1; do not touch fixture encodings.
- Reuse `Objects.equals` (Option A) rather than hand-rolling null checks.
- Whichever option: consider whether `fileName` and `provider` deserve the same
  treatment as `processingDate` for consistency (all three feed `compareMetadata`).
