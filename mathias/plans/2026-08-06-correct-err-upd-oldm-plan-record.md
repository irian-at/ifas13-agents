# Correct the ERR_UPD_OLDM plan record + persist the two-effects finding

## Context

The `ERR_UPD_OLDM` recalc-artifact fix is implemented and verified (log delta now `WARNUNG`,
`Abweichungsfehler` 7 → 1, new-system return status matches legacy at `OPEN` / STM-ID 694626). No code
work remains — the user chose to leave the `error#recalc.log` / `statistics#recalc.log` inconsistency
as is.

But two records are now wrong or missing, and both are the durable kind that will mislead later:

1. **The approved plan document** (`~/dev/projects/ifas13-agents/mathias/plans/2026-08-05-err-upd-oldm-recalc-artifact-warning.md`)
   was written believing `ValidationSetting`'s flags only affect delta-report severity. They also feed
   `SteuerlicheErmittlungRecalcOptions.ignore*Errors`, which suppresses the `*_DECLINED` result status.
   So the plan's "Out of scope" item 3 — the 6 `STATUS_*` field diffs stay `FEHLER` — is wrong; they
   were fixed, and the implementation includes an `ignoreUpdOldmErrors` component the plan never lists.
2. **No memory** captures the two-effects coupling, which is the non-obvious fact that changed the
   scope of this task and will change the scope of the next flag added to `ValidationSetting`.

## Changes

### 1. Amend the plan document

`~/dev/projects/ifas13-agents/mathias/plans/2026-08-05-err-upd-oldm-recalc-artifact-warning.md`

- Add `SteuerlicheErmittlungRecalcOptions` (`ignoreUpdOldmErrors`) and
  `SteuerlicheErmittlungDomainService` (`isUpdOldm` predicate in `hasOnlyKnownRecalcIssueErrors`) to
  the implementation section.
- Replace "Out of scope" item 3 with the measured outcome: the `STATUS_*` diffs are resolved; the one
  remaining `FEHLER` is the pre-existing null-vs-explicit-zero country-vector noise
  (`AS_Ertragsausgleich_AusschuettungenSubfonds_nichtDBAbefreit: NEU = n.v. / ALT = [A1=0.0000]`),
  newly visible only because the meldung is no longer declined.
- Add the resolved-as-wontfix note: the new system's own `error#recalc.log` / `statistics#recalc.log`
  still report the downgraded code as an error while the return file says `OPEN`. Pre-existing,
  shared by all four flags, deliberately left alone.
- Note the two implementation choices made during execution that the plan didn't specify: threading
  `ValidationSetting` through the delta layer instead of a fourth positional boolean (with
  `@Builder.Default` on `ValidationDeltaReport.validationSetting` to preserve the old
  unset-means-all-false semantics), and the `ValidationSetting.ofRecalcArtifactDiffsAsWarning(boolean)`
  factory replacing the three `new ValidationSetting(x, x, x)` call sites.

### 2. New memory

`~/dev/projects/ifas13-agents/mathias/automemory/project_validationsetting-flags-have-two-effects.md`
(type `project`), plus its one-line pointer in `MEMORY.md`:

> Each `ValidationSetting` recalc-artifact flag does **two** things, not one: it downgrades the delta
> report severity via `ValidationDeltaReports.isShowAsWarningIfOnlyInNew`, **and** — via the matching
> `SteuerlicheErmittlungRecalcOptions.ignore*Errors` option consumed by
> `SteuerlicheErmittlungDomainService.hasOnlyKnownRecalcIssueErrors` — lets the meldung reach a
> successful result status instead of `*_DECLINED`. Adding a flag and wiring only the report half
> leaves it a half-flag and leaves the `STATUS_*` return-file diffs in place.

Link it to `[[project_gf1-fielddiff-null-vs-zero]]` (the residual diff this fix exposed) and
`[[project_recalc-fixture-data-recovery]]` (why replay fixtures contain the delivery's own product).

## Verification

Both are documentation-only; no build needed.

- `git status` in `ifas13-agents` shows the amended plan file and the two memory files.
- Re-read the amended plan top to bottom and confirm no statement contradicts the measured
  `target/quick-recalc` output (1 Abweichungsfehler, 1 Abweichungswarnung, return status `OPEN`).
- The IFAS13 working tree must stay untouched by this step — `git status` in `oekb/ifas13` should show
  exactly the 17 files of the verified fix (plus the two pre-existing modifications to
  `docs/Rekalkulation/Fachabteilung-FRIST-NOSN-gf4.md` and `QuickRecalculationTest.java`, and the
  stray one-line indentation change in `ValidationMsg.java` that I did not make and left alone).
