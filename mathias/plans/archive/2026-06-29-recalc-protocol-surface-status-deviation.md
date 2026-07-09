# Surface final-status deviation (Altsystem vs Neusystem) in the recalc protocol

## Context

During recalculation, when the legacy system ("Altsystem") produced a Meldung with
status `OPEN` but the new system declines it (e.g. `NEW_DECLINED`, driven by the
`declined=true` flag on codes like `ERR_JAHRESM_VORH`), the **final-status divergence
is silently swallowed** by the recalc protocol. The protocol's `FEHLER` tally stays at
zero and the divergence appears nowhere, so a materially different outcome between the
two systems goes unnoticed.

### Why it is swallowed (verified)

- The new return file *does* contain the declined Meldung — written as a status-only
  row (START + STATUS + END) by `CsvSteuerMeldungenWriter.internalWriteSteuerMeldungenToCsv`
  (lines 111-117: only `OPEN` gets the full record; everything else is status-only).
  So `newReturnSteuerMeldung` is non-null and carries `NEW_DECLINED`.
- `StmDiffs.calcDiffs` **always** emits a STATUS field diff at `FieldDiffSeverity.ERROR`
  (`StmDiffs.java:70-80`, via `addNonExcelFieldDiff`), and the return-vs-return configs
  use `IGNORE_STB_PATTERN`, which does **not** ignore STATUS. So a status diff *would*
  be produced and counted as a FEHLER — if `calcDiffs` were reached.
- It is not reached. Both return-vs-return diff builders bail out first:
  - `RecalculationDomainService.newReturnVsOldReturnDiff` — lines 512-515
  - `RecalculationDomainService.oldReturnVsNewReturnDiff` — lines 542-545

  ```java
  if (expReturnStm.getStatus() == StmStatus.OPEN && actReturnStm.getStatus() != StmStatus.OPEN) {
      log.info("... skipping ... file diff");
      return null;   // <-- discards the whole diff, incl. the STATUS divergence
  }
  ```

  The guard's intent is legitimate: a declined Meldung has no real field values, so a
  full field-by-field diff would be pure noise. But it throws away the status divergence
  together with the noise, and only logs at INFO.

### Intended outcome

When the legacy final status and the new-system final status differ, the recalc
protocol must show it as a `FEHLER`-level deviation — visible in both the per-Meldung
detail block and the summary tally — while still suppressing the meaningless
field-value diffs of a declined Meldung.

## Approach

Replace the `return null` in the two guards with a **status-only** `StmDiff` so the
divergence rides the existing diff/count/render machinery (no new record fields, no new
reporting concept).

### 1. Add a status-only diff helper — `StmDiffs` (`ifas-domain-stm/.../recalc/diff/StmDiffs.java`)

Add `calcStatusOnlyDiff(SteuerMeldung expected, SteuerMeldung actual)` that produces a
`StmDiff` containing only the STATUS `FieldDiff`. Reuse the existing
`addNonExcelFieldDiff(..., SteuerMeldung.FieldName.STATUS, String.class,
FieldDiffSeverity.ERROR, "STATUS")` logic so the result is identical to what a full
`calcDiffs` would emit for STATUS. Return `StmDiff.of(expected, actual, statusDiffs)`
(empty diff list when statuses are equal — though callers only invoke it when they differ).

Reuse over reinvention: this isolates the STATUS branch that `calcDiffs` already runs;
do not duplicate the field-iteration logic.

### 2. Surface it from one guard only — `RecalculationDomainService`

In `newReturnVsOldReturnDiff` (line 512), change the guard body to return the status-only
diff instead of `null`:

```java
if (expReturnStm.getStatus() == StmStatus.OPEN && actReturnStm.getStatus() != StmStatus.OPEN) {
    return StmDiffs.calcStatusOnlyDiff(expReturnStm, actReturnStm);
}
```

Leave `oldReturnVsNewReturnDiff` (line 542) returning `null` in its guard. The summary
count (`BundleRecalculationResult.countErrorFieldDiffs`) sums over **both**
`newReturnVsOldReturn` and `oldReturnVsNewReturn`; emitting the status diff from only one
direction avoids double-counting the same divergence.

### Decisions baked in (not open questions)

- **Severity = ERROR** so it counts in the `FEHLER` tally and cannot be hidden by the
  "Warnungen ausgeblendet" mode. This matches the goal of not silently swallowing it.
- **Status-only**, not full diff: preserves the guard's original noise-suppression intent.

## Critical files

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/recalc/diff/StmDiffs.java`
  — new `calcStatusOnlyDiff` helper (reuses `addNonExcelFieldDiff`, lines 103-124).
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/recalc/RecalculationDomainService.java`
  — guard at lines 512-515 returns the status-only diff.

No changes needed to `SteuerMeldungRecalculation`, the protocol writer, or the counting
logic — `newReturnVsOldReturn` already flows into `writeDiffDetails` (rendered as
`STATUS: ALT=OPEN, NEU=NEW_DECLINED [ERROR]`) and into `countErrorFieldDiffs()`.

## Verification

1. **Unit test** for `StmDiffs.calcStatusOnlyDiff`: two STMs differing only in STATUS →
   one `FieldDiff` (`STATUS`, ERROR); identical STATUS → empty diff. (Place alongside
   existing `StmDiffs` tests.)
2. **Recalc integration test**: use a grossfile fixture where the legacy return is `OPEN`
   and the new system declines via `ERR_JAHRESM_VORH` (the gf fixtures under
   `ifas-integration-tests/.../recalc/grossfiles/` are candidates). Assert the produced
   protocol contains the `STATUS: ALT=OPEN, NEU=NEW_DECLINED` line and that
   `countErrorDiffs()` includes it. Confirm the field-value diffs of the declined Meldung
   are still suppressed.
3. **Manual**: run a recalc bundle exhibiting the case and inspect the generated protocol —
   the per-Meldung block shows the status deviation and the summary `FEHLER` count reflects it.
4. Build: `mvn clean install -Pno-proxy -pl ifas-domain/ifas-domain-stm -am` (extend to
   `ifas-integration-tests` for the integration test).