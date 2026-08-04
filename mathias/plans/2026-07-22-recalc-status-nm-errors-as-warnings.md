# Treat "Status nicht möglich" errors as warnings during recalc

## Context

Recalculation runs **after** the legacy system, against **already-persisted** data — it
only reads, never persists. Because legacy already advanced meldungen (e.g. `OPEN → FINAL`
via a CONFIRM, or `OPEN → DELETED` via a DELETE), when recalc replays the same delivery the
DB snapshot already shows the *post*-transition status. The status validator then rejects it:

```
Aktueller Status <FINAL>, CONFIRMED nicht moeglich.
```

This is a recalc artifact, not a real defect — exactly the same class of "runs on
already-persisted data" noise we already neutralise with the `vorhandenDiffsAsWarning` and
`meldIdFehltDiffsAsWarning` flags (`ERR_JAHRESM_VORH`, `ERR_AUSSCHM_VORH`, `ERR_MELDID_FEHLT`).

**Goal:** introduce a third flag of the same shape that downgrades the DB-based
status-transition error `ERR_STATUS_NM` to a warning, and teach
`hasOnlyKnownRecalcIssueErrors` to treat it as a known recalc issue so the recalculated STM
is allowed through (OPEN/FINAL/DELETE) instead of being forced to ERROR/DECLINED.

**Scope (confirmed with user):** `ERR_STATUS_NM` **only**, and further **restricted by its
argument pair**. `errStatusNm` (`SteuerMeldungStatusValidators.java:191-201`) can emit 14
distinct `(previousStatus ← deliveredStatus)` pairs (`deliveredStatus ∈ {CONFIRMED, DELETE}`
× the 7 non-OPEN persisted statuses). Only **two** are recalc-on-persisted-data artifacts —
the cases where legacy already *successfully* applied the op and persisted the terminal
result:

- `FINAL ← CONFIRMED`
- `DELETED ← DELETE`

`{FINAL, DELETED}` is precisely `StmStatus.isSuccessfulReturnStatus()` minus `OPEN`
(`StmStatus.java:56-58`). Every other pair (e.g. `ERROR ← CONFIRMED`,
`CONFIRM_DECLINED ← CONFIRMED`) is a genuine error and must stay an error — so we match the
**argument pair**, not the bare code. This is stricter than the vorhanden/meldId precedent
(which match by code alone) because `ERR_STATUS_NM` is overloaded across legitimate and
artifact transitions.

The within-delivery clone `ERR_STATUS_NM_LIEFERUNG` stays an error (not a
recalc-on-persisted-data artifact; fires identically in legacy). `ERR_UPD_OLDM` /
`ERR_UPD_TOLATE` are out of scope for now. Flag wiring is modeled on the existing
single-code `meldIdFehltDiffsAsWarning` flag.

## The mechanism (two independent consumers of one flag)

The flag lives on `ValidationSetting` and fans out into two paths:

- **Path A — recalculated STM's return status.**
  `ValidationSetting` → `SteuerlicheErmittlungRecalcOptions` → `hasOnlyKnownRecalcIssueErrors`
  in `SteuerlicheErmittlungDomainService`. Decides whether the STM is allowed through vs.
  ERROR/DECLINED. **This is the part the user explicitly called out.**
- **Path B — legacy-vs-new delta report.**
  `ValidationSetting` → `ValidationDeltaCalculator` → `ValidationDeltaReport` →
  `ValidationDeltaReports.isShowAsWarningIfOnlyIn{Legacy,New}`. Decides whether the
  discrepancy renders as a warning-delta or an error-delta.

New flag names (following the terse existing convention, keyed to the `ERR_STATUS_NM` code):
- `ValidationSetting.statusNmDiffsAsWarning`
- `SteuerlicheErmittlungRecalcOptions.ignoreStatusNmErrors`

## Changes

### 1. `ValidationSetting` (the source flag)
`ifas-domain/ifas-domain-stm/.../validation/ValidationSetting.java`
- Add `boolean statusNmDiffsAsWarning` as a third record component.
- Update `DEFAULT` → `new ValidationSetting(false, false, false)`.
- Update `VORHANDEN_DIFFS_AS_WARNING` → `new ValidationSetting(true, false, false)`.
- Extend the class Javadoc to document the new flag (covers `ERR_STATUS_NM`; the
  `ERR_STATUS_NM_LIEFERUNG` within-delivery variant stays an error).
- `@Builder` + `@JsonIgnoreProperties(ignoreUnknown = true)` already handle old JSON payloads.

### 2. `SteuerlicheErmittlungRecalcOptions` (Path A carrier)
`ifas-domain/ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungRecalcOptions.java`
- Add `boolean ignoreStatusNmErrors` component.
- Update `DEFAULT` (add `false`) and the Javadoc.

### 3. `RecalculationDomainService` (Path A wiring)
`ifas-domain/ifas-domain-stm/.../recalc/RecalculationDomainService.java` (~line 452, the
`new SteuerlicheErmittlungRecalcOptions(...)` construction)
- Pass `validationSetting.statusNmDiffsAsWarning()` into the new option slot.

### 3a. Shared artifact-transition predicate (reuse by both paths)
`ifas-domain/ifas-domain-stm/.../validation/status/SteuerMeldungStatusValidators.java`
(co-located with `errStatusNm`, which produces the code and args)
- Add one public static helper encoding the two artifact pairs, reused by Path A and Path B
  (avoids duplicating the pair knowledge):
  ```java
  public static boolean isRecalcArtifactStatusTransition(StmStatus previousStatus, StmStatus deliveredStatus) {
      return (previousStatus == StmStatus.FINAL   && deliveredStatus == StmStatus.CONFIRMED)
          || (previousStatus == StmStatus.DELETED && deliveredStatus == StmStatus.DELETE);
  }
  ```

### 4. `SteuerlicheErmittlungDomainService` (Path A logic — the `hasOnlyKnownRecalcIssueErrors` change)
`ifas-domain/ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungDomainService.java` (lines 336–368)
- Add an **arg-aware** predicate (matches code AND the artifact status pair via the shared
  helper). `ERR_STATUS_NM`'s args are `[previousStatus, deliveredStatus]` as `StmStatus`
  (`ValidationMsg.of(pos, ERR_STATUS_NM, ERROR, previousStatus, deliveredStatus)`):
  ```java
  private static boolean isStatusNmRecalcIssue(ValidationMsg valMsg) {
      if (valMsg.getValidationMsgCode() != ValidationMsgCode.ERR_STATUS_NM) {
          return false;
      }
      Object[] args = valMsg.getArguments();
      return args.length >= 2
              && args[0] instanceof StmStatus previous
              && args[1] instanceof StmStatus delivered
              && SteuerMeldungStatusValidators.isRecalcArtifactStatusTransition(previous, delivered);
  }
  ```
- **Refactor `hasOnlyKnownRecalcIssueErrors`** away from the current per-flag if/else
  (already awkward at 2 flags; a 3rd makes it combinatorial). Build the set of enabled
  predicates and require every error to match at least one:
  ```java
  private boolean hasOnlyKnownRecalcIssueErrors(
          SteuerlicheErmittlungRecalcOptions options, List<ValidationMsg> validationMsgs) {
      List<Predicate<ValidationMsg>> known = new ArrayList<>();
      if (options.ignoreBereitsVorhandenErrors()) known.add(SteuerlicheErmittlungDomainService::isBereitsVorhandenError);
      if (options.ignoreMeldeIdFehltErrors())    known.add(SteuerlicheErmittlungDomainService::isMeldeIdFehltError);
      if (options.ignoreStatusNmErrors())        known.add(SteuerlicheErmittlungDomainService::isStatusNmRecalcIssue);
      if (known.isEmpty()) {
          return false;
      }
      Predicate<ValidationMsg> anyKnown = known.stream().reduce(Predicate::or).orElseThrow();
      return validationMsgs.stream().filter(ValidationMsg::isError).allMatch(anyKnown);
  }
  ```
  Preserves existing behaviour for the two current flags and extends cleanly.

### 5. Delta report — Path B (downgrade to warning in the legacy-vs-new comparison)
- **`ValidationDeltaReports.java`** (`ifas-domain/ifas-domain-stm/.../validation/delta/`,
  lines ~84–195): thread a third boolean `statusNmDiffsAsWarning` through
  `getValidationDeltas`, `isShowAsWarningIfOnlyInLegacy`, `isShowAsWarningIfOnlyInNew`. Unlike
  the vorhanden/meldId flags this is **not** a plain code/pattern-set membership check — it
  must also confirm the artifact **status pair**:
  - **only-in-new** (`ValidationMsg`, code `ERR_STATUS_NM`): reuse the same arg-aware check as
    Path A — code is `ERR_STATUS_NM`, args `[StmStatus, StmStatus]`, pair passes
    `SteuerMeldungStatusValidators.isRecalcArtifactStatusTransition`. Factor `isStatusNmRecalcIssue`
    into a shared spot so both paths call it (candidate: a static on
    `SteuerMeldungStatusValidators` taking a `ValidationMsg`, or a small package helper) rather
    than duplicating.
  - **only-in-legacy** (`LegacyLogValidationMsg`, matched `ValidationMsgCodePattern.ERR_STATUS_NM`,
    regex `Aktueller Status <(.*?)>, (.*?) nicht moeglich\.` — confirmed present): extract the
    two capture groups and map them to `StmStatus` by name (the message renders the enum via
    `name()`, so group1→previousStatus, group2→deliveredStatus), then apply the same pair check.
    Add a null-safe name→`StmStatus` lookup (guard `valueOf`); an unrecognised name → not
    downgraded (stays error).
- **`ValidationDeltaReport.java`**: add `private final boolean statusNmDiffsAsWarning;`
  (builder field + getter), matching the two existing flags with the same doc style.
- **`ValidationDeltaCalculator.java`** (lines ~76–89): extract
  `validationSetting.statusNmDiffsAsWarning()`, pass it to `calculateSummary(...)` and into
  the `ValidationDeltaReport` builder.

### 6. Entry points that build a `ValidationSetting`
- **`RecalculationRestController.java`** (~lines 95–99): add `.statusNmDiffsAsWarning(true)`
  alongside the existing two hardcoded-true flags — REST recalc runs opt in fully.
- **UI controllers** (`StmRecalcFormPageController`, `StmRecalcDetailPageController`,
  `StmRecalcListPageController`) and **`RepeatBatchOverride`**: these currently only thread
  `vorhandenDiffsAsWarning`; `meldIdFehltDiffsAsWarning` is left to the builder default. Match
  that precedent — the new flag defaults to `false` via the builder, no new request param or
  UI checkbox in this iteration. (`RepeatBatchOverride` line ~90 already has a `// todo` for
  the second flag; leave the new one on default there too, consistent with meldId.)

Any remaining `new ValidationSetting(...)` / `new SteuerlicheErmittlungRecalcOptions(...)`
positional call sites (incl. tests) must be updated for the new component — the compiler
will flag them.

## Verification

- **Unit — Path A:** in `SteuerlicheErmittlungDomainService`'s test, a recalc STM whose only
  error is `ERR_STATUS_NM(FINAL, CONFIRMED)`, with `ignoreStatusNmErrors=true` and a
  successful/absent legacy return status → `calcFailedStatus` returns `null` (allowed
  through). Same with `(DELETED, DELETE)`. With the flag `false` → still ERROR/DECLINED.
  **Crucially:** `ERR_STATUS_NM(ERROR, CONFIRMED)` (and other non-artifact pairs) with the
  flag `true` → still **not** allowed (the arg pair fails the artifact check). Mixed errors
  (artifact `ERR_STATUS_NM` + an unrelated error) → not allowed.
- **Unit — Path B:** in `ValidationDeltaReportsTest`, `ERR_STATUS_NM(FINAL, CONFIRMED)` and
  `(DELETED, DELETE)` present only-in-new (and only-in-legacy, via the parsed capture groups)
  render as a **warning** delta when `statusNmDiffsAsWarning=true`, and as an **error** delta
  when `false`. `ERR_STATUS_NM(ERROR, CONFIRMED)` stays an **error** even with the flag on.
  Confirm `ERR_STATUS_NM_LIEFERUNG` stays an error either way.
- **Unit — predicate:** `SteuerMeldungStatusValidatorsTest` covers
  `isRecalcArtifactStatusTransition` for the two true pairs and a sampling of false ones.
- **Regression:** existing vorhanden / meldId tests unchanged (refactored
  `hasOnlyKnownRecalcIssueErrors` must preserve their behaviour).
- **End-to-end:** re-run the recalc scenario that originally produced
  "Aktueller Status <FINAL>, CONFIRMED nicht moeglich." (e.g. via `QuickRecalculationTest`
  in `ifas-integration-tests`, or a REST recalc) and confirm the status-NM entries now report
  as warnings / no longer force an ERROR return status.
- **Build:** `mvn clean install -Pno-proxy` (module `ifas-domain-stm` at minimum; annotation
  processing for the touched records).
