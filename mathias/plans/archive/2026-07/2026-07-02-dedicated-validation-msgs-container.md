# Plan: Dedicated container for grouped validation messages on `SteuerMeldungLieferung`

## Context

Validation runs in two layers — first at the CSV layer (`csv-schema`) and then in
the domain (`ifas-domain-stm`). The CSV layer already models the natural
hierarchy: a submission owns its own file-level errors, and each entry within
the submission owns its entry-level errors. That hierarchy is **flattened**
when CSV messages are mapped to domain `ValidationMsg`s and aggregated into
`SteuerMeldungLieferung.validationMsgs()` as a single `List<ValidationMsg>`.

Every downstream consumer that needs to render or process messages by owner has
to re-derive the grouping by `instanceof`-checking the embedded `Position`. We
have at least three parallel grouping implementations today, plus owner-aware
deduplication. The goal is to restore the hierarchy with a single dedicated
container so consumers stop reinventing it.

Relation to existing plans:

- `refactor-grouped-validation-msgs-at-csv-domain-boundary.md` proposes a deeper
  reshape where the **loader** emits already-grouped `LoadedSteuerMeldung`
  records. That plan changes the load contract and shifts CSV→domain mapping.
- **This plan is narrower**: keep the loader and CSV→domain mapping as-is, just
  replace the flat `List<ValidationMsg>` on the Lieferung with a structured
  container. The two plans are complementary: this step immediately removes
  the three shuffler sites; the boundary plan can build on top of it later (or
  supersede it).

## Current state (what gets shuffled around)

- **Source of truth**: `DefaultSteuerMeldungLieferung.validationMsgs` —
  `List<ValidationMsg>` containing file-level CSV errors, message-level CSV
  errors, and domain validation errors, distinguished only by
  `ValidationMsg.getPosition()` (`CsvFilePosition` vs `CsvMessagePosition`).
- **Three shuffler sites** that reconstruct ownership from that flat list:
  1. `ValidationMsgGroups.getMsgGroupBySeverity()` —
     `ifas-domain-stm/.../meldung/log/ValidationMsgGroups.java`. Builds a
     `CsvMessage → CsvSteuerMeldung` lookup, splits messages into file-level
     vs `Map<SteuerMeldung, List<ValidationMsg>>`. Consumed by
     `ValidationMsgLogWriter`.
  2. `ValidationDeltaCalculator.groupNewValidations()` →
     `ValidationMsgGrouping` (`fileLevelMsgs`,
     `Map<Integer, List<ValidationMsg>>` keyed by START-line,
     `unmatchedMsgs`). Keys by line number because it matches against legacy
     log files where `CsvMessage` identity differs across versions.
  3. `SteuerMeldungLieferungService.ownerOf()` +
     `deduplicateByStmAndText()` — owner-aware dedup that special-cases null
     owner (file-level) by also keying on line number, and the recent
     `csvMessageOwnersWithError(...)` (commit `c3101f0f1`, upstream error
     gate).

## Key design choice — owner key

The user explicitly rejected `CsvMessage` as the owner key: the domain layer
should not be tied to CSV-shaped input. The natural domain abstraction is
**`SubmissionEntry`** (`at.oekb.ifas.core.submission.SubmissionEntry`), already
referenced by `Position`:

```java
// Position.java
@Nullable SubmissionEntry getCorrespondingEntry();
```

`SubmissionEntry` is implemented by `CsvMessage`,
`DbSteuerMeldungSubmissionEntry`, `ExcelSteuerMeldungSubmissionEntry` and
`MockSubmissionEntry` (test). For CSV-file-level `Position`s,
`getCorrespondingEntry()` returns `null` — those are the submission-level
messages. The container therefore works uniformly across CSV, DB and Excel
sources.

(Why not `Position` directly as the key? Two CsvMessagePositions at different
rows of the same meldung have distinct `Position` identities but share an
owner; using `Position` as the key would over-split. `SubmissionEntry` is the
right grain.)

## Proposed structure

Introduce a singular, instance-bearing class in
`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/`.

**Name**: per `java-conventions.md` the plural form is reserved for utility
classes (`Instants`, `ValidationMsgGroups`), so the container needs a singular
name. Chosen: **`ValidationMsgStore`** — matches the existing `Filestore`
container pattern in this codebase. Neutral, container-flavored, no
domain-specific connotation (audit/log/report/protocol metaphors are avoided
on purpose because the class is just storage with owner-aware lookup).

```java
@NullMarked
public final class ValidationMsgStore {

    private final List<ValidationMsg> submissionLevelValidationMsgs;                  // entry == null
    private final Map<SubmissionEntry, List<ValidationMsg>> validationMsgsByEntry;    // entry != null
    // preserve insertion order: ArrayList values, LinkedHashMap keys

    public static ValidationMsgStore empty() { ... }
    public static ValidationMsgStore of(Collection<ValidationMsg> msgs) { ... }

    // Routes by Position.getCorrespondingEntry():
    //   non-null entry -> validationMsgsByEntry[entry]
    //   null entry     -> submissionLevelValidationMsgs
    public ValidationMsgStore add(ValidationMsg msg) { ... }
    public ValidationMsgStore addAll(Collection<ValidationMsg> msgs) { ... }
    public ValidationMsgStore merge(ValidationMsgStore other) { ... }

    // Accessors mirror field names verbatim for record-style symmetry.
    public List<ValidationMsg> submissionLevelValidationMsgs() { ... }
    public List<ValidationMsg> validationMsgsForEntry(SubmissionEntry entry) { ... }
    public Map<SubmissionEntry, List<ValidationMsg>> validationMsgsByEntry() { ... }
    public Set<SubmissionEntry> entriesWithSeverity(Severity s) { ... }

    public ValidationMsgStore filterBySeverity(Severity s) { ... }
    public ValidationMsgStore deduplicate() { ... }   // see service section

    // Flat view for consumers we are NOT migrating in this iteration
    // (counts, log writing, recalc, etc.). Explicit, not the default.
    public List<ValidationMsg> all() { ... }
    public Stream<ValidationMsg> stream() { ... }
    public int count(Severity s) { ... }
    public boolean isEmpty() { ... }
}
```

Design notes:

- **Immutable, copy-on-write** — `add/addAll/merge/filterBySeverity/deduplicate`
  return a new instance. Matches the record-like style of
  `DefaultSteuerMeldungLieferung`.
- **Source-agnostic.** No CSV types appear in the API: CsvMessage,
  CsvFilePosition, CsvMessagePosition are now implementation details consumers
  of the container never see.
- **No `SteuerMeldung` key inside.** A projection helper
  `viewBySteuerMeldung(Map<SubmissionEntry, SteuerMeldung>)` returns
  `Map<SteuerMeldung, List<ValidationMsg>>` on demand. The Lieferung already
  exposes `steuerMeldungenBySubmissionPosition()` (Position→SteuerMeldung);
  a thin adapter or a follow-up rename to `steuerMeldungenBySubmissionEntry()`
  is enough. **Reuse target**:
  `ValidationMsgGroups.createSteuerMeldungLookupMap()` and
  `findSteuerMeldungFor()` — lift / repoint to the new container.
- **`all()` is explicit**, not a default `toList()`. Call sites that genuinely
  need the flat stream remain visible.
- **`ValidationMsgGrouping`'s line-number key is consumer-specific** (delta
  matching against legacy logs). It stays in `validation/delta/`, but its
  construction simplifies to a transform over `validationMsgsByEntry()` instead
  of rescanning the flat list — the START-line is read from the `Position` of
  any one msg in the bucket (or from the entry, if `CsvMessage`).

## `SteuerMeldungLieferungService` — before vs after

This is the service that today does the most "shuffling". The simplification
is the strongest single argument for the new container.

### Today

```
loadAndValidateSteuerMeldungLieferungFromCsv(...)
  ├─ CsvSteuerMeldungen.loadAndValidateInputFromCsv(...)
  │     -> CsvSteuerMeldungenWithValidations { steuerMeldungen, flat List<CsvValidationMsg> }
  │        (the natural CsvFile/CsvMessage hierarchy is flattened here)
  ├─ mapToValidationMsgs(stichtag, bmfVersion, flat List<CsvValidationMsg>)
  │     for each CsvValidationMsg:
  │       if position instanceof CsvMessagePosition cmp ->
  │            lookup Ermittlungsvorgabe via cmp.csvMessage()
  │            new ValidationMsgMapper(ermittlungsvorgabe).toValidationMsgs(...)
  │       else -> new ValidationMsgMapper(null).toValidationMsgs(...)
  │     -> flat List<ValidationMsg> allValidationMsgs                              // first reshuffle
  ├─ csvMessageOwnersWithError(allValidationMsgs)
  │     // scans flat list, calls ownerOf() per msg, collects CsvMessage set      // second reshuffle
  ├─ for each CsvSteuerMeldung:
  │     perMeldungMsgs = status.validate + ermittlung.validate + domain.validate
  │     allValidationMsgs.addAll(perMeldungMsgs)
  │     producedError =
  │       csvMessagesWithUpstreamError.contains(sm.getCsvMessage())
  │       || perMeldungMsgs.stream().anyMatch(isError)
  │     if (!producedError) acceptedState.accept(sm)
  └─ deduplicateByStmAndText(allValidationMsgs)
        // scans flat list, calls ownerOf() per msg,
        // keys on (owner, lineNr?, severity, text)                                // third reshuffle
        -> List<ValidationMsg> deduped, fed into DefaultSteuerMeldungLieferung.builder()
```

Supporting members that exist purely because the shape is flat:
`ownerOf(ValidationMsg)`, `csvMessageOwnersWithError(List)`,
`deduplicateByStmAndText(List)`, the private `DedupKey` record.

### After

```
loadAndValidateSteuerMeldungLieferungFromCsv(...)
  ├─ CsvSteuerMeldungen.loadAndValidateInputFromCsv(...)
  │     // unchanged contract this iteration
  ├─ ValidationMsgStore store = mapToValidationMsgStore(
  │         stichtag, bmfVersion, csvLoaded.validationMsgs())
  │     // for each CsvValidationMsg, the Ermittlungsvorgabe branch stays
  │     // (only CsvMessage-positioned msgs need it for field-name resolution),
  │     // but the OUTPUT is added straight into the store; the store routes
  │     // by Position.getCorrespondingEntry() — no flat accumulator.
  ├─ Set<SubmissionEntry> entriesWithUpstreamError = store.entriesWithSeverity(ERROR)
  │     // direct query, no re-scan, no ownerOf
  ├─ for each CsvSteuerMeldung:
  │     perMeldungMsgs = status.validate + ermittlung.validate + domain.validate
  │     store = store.addAll(perMeldungMsgs)        // auto-routed by Position
  │     producedError =
  │       entriesWithUpstreamError.contains(sm.getCsvMessage())
  │       || perMeldungMsgs.stream().anyMatch(isError)
  │     if (!producedError) acceptedState.accept(sm)
  └─ DefaultSteuerMeldungLieferung.builder()
         .validationMsgs(store.deduplicate())
         .build()
```

What goes away:

- `ownerOf(ValidationMsg)` — **deleted**. Ownership is now encoded in
  the store (bucket key == `SubmissionEntry`), not re-derived per msg.
- `csvMessageOwnersWithError(List)` — **deleted**. Becomes a one-liner
  on the store: `store.entriesWithSeverity(ERROR)`.
- `deduplicateByStmAndText(List)` + private `DedupKey` — **deleted**.
  Dedup moves into `ValidationMsgStore.deduplicate()`:
  - per-entry buckets: dedup by `(severity, formattedMessage)` —
    no owner key needed (the bucket IS the owner);
  - file-level bucket: dedup by `(severity, formattedMessage, lineNr)` —
    preserving the existing carve-out for orphan rows at different lines.
- The first `position instanceof CsvMessagePosition` switch inside
  `mapToValidationMsgs` shrinks: it only chooses **which `ValidationMsgMapper`
  to construct** (with or without Ermittlungsvorgabe). It no longer also
  decides the destination collection — that is the store's job.

What stays:

- The branch that loads `Ermittlungsvorgabe` per `CsvMessage` (still needed
  for field-name resolution inside `ValidationMsgMapper`).
- The `InLieferungAcceptedState` accumulator and the per-meldung
  `producedError` check — these are pre-existing business logic, not shuffling.

### Optional stretch (note, not part of this plan)

If `CsvSteuerMeldungenWithValidations` exposed the hierarchy already present
in `CsvFile`/`CsvMessage` (file-level msgs separately from per-CsvMessage
msgs) instead of a flat list, `mapToValidationMsgStore` would collapse to two
straight passes — no `position instanceof` switch at all. That belongs to
`refactor-grouped-validation-msgs-at-csv-domain-boundary.md`; this plan does
not require it.

## Other files to change

- **New**: `ifas-domain-stm/.../validation/ValidationMsgStore.java`.
- **Change**: `SteuerMeldungLieferung.java` — `validationMsgs()` returns
  `ValidationMsgStore`. Default severity helpers
  (`errorValidationMsgs() / infoValidationMsgs()`)
  keep their signatures temporarily via
  `validationMsgs().filterBySeverity(...).all()` (removed in a follow-up).
- **Change**: `DefaultSteuerMeldungLieferung.java` — record component +
  builder accept/store `ValidationMsgStore`.
- Migrate the two remaining shuffler sites outside the service:
  - `ValidationMsgGroups.getMsgGroupBySeverity()` — drive from
    `filterBySeverity` + `viewBySteuerMeldung`.
  - `ValidationDeltaCalculator.groupNewValidations()` /
    `ValidationMsgGrouping` — transform from `ValidationMsgStore` (still
    line-keyed externally for legacy-log matching).
- Other consumers keep using `.all()` for now and are migrated in a follow-up:
  `AusschuettungUploadDomainService`, `RecalculationDomainService`,
  `SteuerlicheErmittlungDomainService`, `ValidationMsgLogs`,
  `ValidationMsgLogWriter` (entry point only; internals get restructured),
  `ValidationDeltaReportWriter`, `ValidationDeltaReports`, and the test suite.

## Reuse — what was searched and what was found

Per `reuse-before-reimplementing`, before proposing a new class I searched for
existing hierarchical containers:

- `ValidationMsgGroups.ValidationMsgGroup` (record) already models the desired
  read-side shape, but it is a snapshot DTO, not canonical storage, and is
  keyed by `SteuerMeldung` (which we deliberately avoid as the primary key).
  **Decision**: keep it as a derived view emitted by the new container; do not
  duplicate.
- `ValidationMsgGrouping` (line-number-keyed) is delta-calculator-specific.
  **Decision**: keep it, drive it from the new container.
- `CsvMessage.validationMsgs` / `CsvFile.validationMsgs` mirror the desired
  hierarchy on the CSV side. **Decision**: out of scope for this iteration; the
  new container picks up where mapping flattens them.
- `Position.getCorrespondingEntry()` and `SubmissionEntry` already exist as
  the domain-agnostic ownership abstraction. **Decision**: reuse — no new
  ownership type needed.
- Existing helpers `createSteuerMeldungLookupMap()` and `findSteuerMeldungFor()`
  in `ValidationMsgGroups` are reused for the `viewBySteuerMeldung(...)`
  projection.

No suitable existing container was found at the canonical storage level — the
flat `List<ValidationMsg>` is the status quo.

## Verification

1. `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm -am test` — covers
   `ValidationMsgGroupsTest`, `SteuerMeldungLieferungServiceTest`,
   `ValidationMsgLogsTest`.
2. `mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests test` — covers
   `ValidationDeltaCalculatorIntegrationTest`,
   `ValidationMsgLogsIntegrationTest`,
   `SteuerMeldungErmittlungsvorgabeValidationServiceTest`,
   `CsvSteuerMeldungWithReferenceCodesValidationTest`.
3. Add unit tests for `ValidationMsgStore`: routing by
   `Position.getCorrespondingEntry()` (null → submission-level, non-null →
   `validationMsgsByEntry`), `validationMsgsForEntry`,
   `entriesWithSeverity`, `filterBySeverity`, `merge`, `deduplicate` (both
   buckets, including file-level line-number carve-out),
   `viewBySteuerMeldung` (mocking the lookup map). Cover all three
   `SubmissionEntry` implementations (`CsvMessage`,
   `DbSteuerMeldungSubmissionEntry`, `ExcelSteuerMeldungSubmissionEntry`) to
   confirm CSV-independence.
4. Spot-check end-to-end on `LocalH2OnlyIfasApplication`: upload a CSV with
   both file-level (e.g. unknown record type) and meldung-level errors;
   inspect the generated `error.log` / `info.log` via `ValidationMsgLogs` —
   the file-level vs meldung-level sectioning must remain byte-identical to
   the current output.
5. Confirm the upstream-error gate from commit `c3101f0f1` still blocks the
   same set of entries — diff
   `validationMsgStore.entriesWithSeverity(ERROR)` against the old
   `csvMessageOwnersWithError(...)` on the same fixtures.