# ERR_UPD_OLDM als Recalc-Artefakt-Warnung im Delta-Report

## Context

`QuickRecalculationTest` reports one deviation for the Candriam bundle:

```
[+] NUR IM NEUSYSTEM (FEHLER)
    ERROR! Zur Melde-ID <693600> wurde bereits ein UPDATE geliefert. Aktuelle Melde-ID: <694626>.
```

This is a **recalc-on-persisted-data artifact**, not a regression. The fixture's testdata YAML
(`.../recalc/issues/quick-recalc/20260804_145114_Erste_..._Korrektur_31122025#recalc.zip`) contains
STM `694626` (`status: OPE`, `vorherigeStmId: 693600`, `gueltAb: 2026-08-04T14:51:13.767`) — the
meldung legacy created *from this very delivery*, because the YAML export ran at 14:51:42, i.e. after
legacy processed the file at 14:51:05. Legacy's successor scan found nothing at that moment; the new
system's scan (`SteuerMeldungStatusValidationService#findLatestUndeletedSuccessorStmId`) finds 694626
and declines the UPDATE.

The test already passes `ValidationSetting.RECALC_ARTIFACT_DIFFS_AS_WARNING`, but plain
`ERR_UPD_OLDM` is in **none** of the four warning levers in `ValidationDeltaReports`, so
`isShowAsWarningIfOnlyInNew` falls through to the default `FEHLER`.

The codebase already models this exact class of deviation — the plain (DB-existence) status codes are
each gated by a `ValidationSetting` flag, while their within-file `_LIEFERUNG` twins sit on the
unconditional always-warning list for a *different* reason (`ValidationDeltaReports.java:38-43`:
legacy declined the first row upstream and never advanced its in-memory state). `ERR_UPD_OLDM` is the
one plain twin that never got its flag:

| Check | plain variant | `_LIEFERUNG` twin |
|---|---|---|
| Jahresmeldung vorhanden | `ERR_JAHRESM_VORH` → `vorhandenDiffsAsWarning` | always-warning list |
| Ausschüttungsmeldung vorhanden | `ERR_AUSSCHM_VORH` → `vorhandenDiffsAsWarning` | always-warning list |
| Status nicht möglich | `ERR_STATUS_NM` → `statusNmDiffsAsWarning` | always-warning list |
| UPDATE bereits geliefert | `ERR_UPD_OLDM` → **nothing** ← gap | always-warning list |

**Outcome:** add the missing fourth granular flag so that under `RECALC_ARTIFACT_DIFFS_AS_WARNING`
an only-in-new `ERR_UPD_OLDM` is reported as `WARNUNG`. With `ValidationSetting.DEFAULT` it stays
`FEHLER`, so `GrossfileRecalculationTest` baselines (which use `DEFAULT`) do not move.

No narrowing predicate à la `StatusNmRecalcArtifacts`: `ERR_UPD_OLDM`'s arguments are
`[stmId, followUpStmId]` — two `Long`s with no discriminator for artifact-vs-genuine. Blanket under
the flag, exactly like `ERR_JAHRESM_VORH`/`ERR_AUSSCHM_VORH`.

## Implementation

### 1. `ValidationSetting` — fourth component

`ifas-domain/ifas-domain-stm/.../validation/ValidationSetting.java`

- Add record component `boolean updOldmDiffsAsWarning`.
- `DEFAULT` → `(false, false, false, false)`; `RECALC_ARTIFACT_DIFFS_AS_WARNING` → all `true`.
- Include it in the `recalcArtifactDiffsAsWarning()` aggregate (the single UI checkbox).
- Extend the class javadoc with a paragraph mirroring the `statusNmDiffsAsWarning` one: legacy
  accepted the UPDATE and persisted the successor, so the replay's DB snapshot shows a successor
  legacy did not see. Note the within-delivery variant `ERR_UPD_OLDM_LIEFERUNG` is unaffected
  (already on the always-warning list).
- `@JsonIgnoreProperties(ignoreUnknown = true)` already covers old JSON payloads that lack the new
  key; Jackson fills the missing boolean with `false`, which is the safe default.

### 2. `ValidationDeltaReports` — new flag-gated set

`ifas-domain/ifas-domain-stm/.../validation/delta/ValidationDeltaReports.java`

- Add `MSG_CODES_SHOWN_AS_WARNINGS_IF_UPD_OLDM_FLAG_SET = Set.of(ERR_UPD_OLDM)` with javadoc
  mirroring `MSG_CODES_SHOWN_AS_WARNINGS_IF_MELDID_NICHT_MEHR_GUELTIG_FLAG_SET` (`:89-98`).
- Extend `isShowAsWarningIfOnlyInNew` (`:177`) with the new clause.
- Thread the flag through both `getValidationDeltas` overloads (`:124-168`).
- Leave `MSG_CODES_ALWAYS_SHOWN_AS_WARNINGS_IF_ONLY_IN_NEW` (`:46`) untouched — the four
  `_LIEFERUNG` entries there are correct on their own rationale.
- Drive-by: the javadoc at `:33` says "Three categories" but lists two. Fix the count while editing
  this block.

### 2b. The second effect — result status, not just report severity

**Found during implementation; the rest of this plan was written without it.** Each existing flag does
*two* things, and wiring only the report half would have left `updOldmDiffsAsWarning` a half-flag:

- `RecalculationDomainService:452-459` copies the flags into
  `SteuerlicheErmittlungRecalcOptions.ignore*Errors`.
- `SteuerlicheErmittlungDomainService.hasOnlyKnownRecalcIssueErrors` (`:335-356`) uses those to
  suppress the `*_DECLINED` status when *every* error on the STM is a known recalc artifact **and**
  the legacy return status was successful — gated on `recalculationMode()`, never production.

So the change also adds:

- `SteuerlicheErmittlungRecalcOptions` — new `boolean ignoreUpdOldmErrors` component (+ `@param`
  javadoc, + `false` in `DEFAULT`).
- `SteuerlicheErmittlungDomainService` — `isUpdOldm` predicate registered in
  `hasOnlyKnownRecalcIssueErrors`. Plain `ERR_UPD_OLDM` only, never `ERR_UPD_OLDM_LIEFERUNG` — a
  second UPDATE inside one delivery is a genuine duplicate and must keep declining. Mirrors how
  `BEREITS_VORHANDEN_ERROR_CODES` lists only the plain codes.
- `RecalculationDomainService:456` — pass `validationSetting.updOldmDiffsAsWarning()` through.

This is what resolves the `STATUS_*` field diffs that "Out of scope" item 3 below wrongly gave up on.

### 3. Plumbing — decision on shape

`isShowAsWarningIfOnlyInNew(msg, b1, b2, b3)` becomes four positional booleans, threaded through six
sites. **Recommended:** pass the `ValidationSetting` record instead of loose booleans, and store the
record on `ValidationDeltaReport` in place of its three boolean fields. The affected getters
(`isVorhandenDiffsAsWarning()` etc.) have exactly two callers — `ValidationDeltaReports:128-130` and
`ValidationDeltaReportWriter:43-45` — so the refactor is contained to the same files this change
touches anyway, and it removes the transposition hazard of four same-typed positional args.
`ValidationDeltaReport` is in-memory only (no JSON/persistence consumers), so the shape change is
safe.

*Minimal alternative if you'd rather keep the diff mechanical:* add a fourth positional boolean
everywhere, mirroring the existing three exactly. Everything below applies either way.

**As implemented:** took the recommended shape. Two details the plan didn't specify:

- `ValidationDeltaReport.validationSetting` needs `@Builder.Default = ValidationSetting.DEFAULT`.
  Three primitive booleans defaulted to `false` when a builder left them unset; an object field
  defaults to `null` and NPEs. `ValidationDeltaReportWriterDeviationsOnlyTest` caught this.
- Added `ValidationSetting.ofRecalcArtifactDiffsAsWarning(boolean)` and used it at the three
  `new ValidationSetting(x, x, x)` call sites (`RepeatBatchOverride`, the two page controllers).
  Those sites exist only to expand the single UI checkbox into every flag, so the factory keeps a
  fifth flag from touching them again.

Sites to touch:

- `ValidationDeltaCalculator.java` — `:76-91` (read flags off `ValidationSetting`, set on report),
  `calculateSummary` signature `:459-461`, aggregation `:472-473` / `:484-485`,
  `countOnlyInNewBySeverity` `:504-509`.
- `ValidationDeltaReport.java` — `:55/62/70` fields (+ javadoc).
- `ValidationDeltaReportWriter.java` — `:25-27` fields, `:43-45` init, `:293-294` severity label.
- `RecalculationDomainService.java` — `:454-456`.
- `RepeatBatchOverride.java` — `:92` `new ValidationSetting(x, x, x)` → fourth `x`; update the
  "toggles all three" comment at `:91`.
- `StmRecalcFormPageController.java:186` and `StmRecalcDetailPageController.java:378` — same
  four-arg construction.

No change needed in `RecalculationRestController` (uses the constant),
`StmRecalcListPageController` (passes the aggregate boolean through), or the three Thymeleaf
templates (they bind the single aggregate `recalcArtifactDiffsAsWarning`).

### 4. UI tooltip

`ifas-web/ifas-web-ui/src/main/resources/templates/stm-recalc-form.html` (~`:180`) — the
Validierungsoptionen tooltip enumerates the covered checks ("Bereits vorhanden"-, "Melde-ID fehlt"-
oder Status-Prüfungen). Add the UPDATE check to that list. File is UTF-8; keep it UTF-8.

### 5. Tests

- New `ValidationDeltaReportsUpdOldmTest` in
  `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/validation/delta/`, modelled on
  the existing `ValidationDeltaReportsStatusNmTest` (same `SimplePosition` helper, given-when-then
  names): `ERR_UPD_OLDM` only-in-new → `WARNUNG` with the flag set, `FEHLER` without;
  `ERR_UPD_OLDM_LIEFERUNG` stays `WARNUNG` regardless (guards the always-list rationale).
- Update `ValidationDeltaReportsStatusNmTest` call sites for the new signature — and assert that
  `statusNmDiffsAsWarning` alone does **not** downgrade `ERR_UPD_OLDM` (flags stay independent).
- `JsonSerializationsTest` (`ifas-services/ifas-main-service`) — extend the `ValidationSetting`
  round-trip assertions (`:30`, `:61`, `:115`) to cover the new component, and add a case pinning the
  rollback direction: a payload containing an *unknown* `validationSetting` key deserializes without
  throwing (guards the `@JsonIgnoreProperties` reliance described under Backwards compatibility).
- `JiraIssueRecalculationTest:127-133` — the explicit three-arg `new ValidationSetting(...)` needs
  the fourth argument (`false`, preserving current behaviour for those CSV rows).
- `GrossfileRecalculationTest` uses `ValidationSetting.DEFAULT` (`:85`), so its `baselines()`
  expectations at `:199-246` must not change. If any do, the flag leaked into the default path —
  treat that as a bug in this change, not a baseline to update.

## Backwards compatibility

Verified — no REST contract changes, and old persisted job settings keep their current behaviour.

**REST request bodies: unchanged.** The only recalc endpoint is
`POST /api/recalculations`, `consumes = multipart/form-data` with parts `FILE` and `supplier`
(`RecalculationRestController:53-58`). `ValidationSetting` is never client-supplied — it is hardcoded
server-side at `:60` to `RECALC_ARTIFACT_DIFFS_AS_WARNING`. The new component therefore adds no
request field, required or optional.

**REST response bodies: unchanged.** `RecalculationDocument.Attributes` exposes name, lieferId,
status, diff counters, createdBy and notes — neither `ValidationSetting` nor the settings JSON. The
wire format does not grow a field.

**Persisted job settings: compatible in both directions.** `RecalculationSetting` (which embeds
`ValidationSetting`) is stored as JSON in `stm_recalc_job.recalculation_settings`
(`StmRecalcJob:41-42`) and read back at `StmRecalcJobExecutionService:316`,
`StmRecalcJobQueryService:75`, `ParallelbetriebJobSubmissionService:610` and `:693`.

- *Old JSON → new code:* the key is absent, Jackson binds the missing primitive `boolean` to `false`.
  Already pinned by `JsonSerializationsTest#givenJsonMissingBooleanFields_whenDeserialize_thenDefaultToFalse`
  (`"validationSetting": {}` → all flags false). Existing jobs re-read or re-executed after the
  deployment classify exactly as they did before.
- *New JSON → old code (rollback / mixed deployment):* `ValidationSetting` carries
  `@JsonIgnoreProperties(ignoreUnknown = true)`, which overrides the plain `ObjectMapper`'s default
  `FAIL_ON_UNKNOWN_PROPERTIES = true` in `JsonSerializations:12-14`. The unknown key is dropped
  instead of throwing. No Flyway migration needed — the column is an untyped JSON string.
- `recalcArtifactDiffsAsWarning()` stays `@JsonIgnore` (derived), so it never enters the payload.

**One intentional behaviour shift:** *repeating* a pre-change job. `RepeatBatchOverride:92`,
`StmRecalcFormPageController:186` and `StmRecalcDetailPageController:378` rebuild the setting from the
single aggregate checkbox (now via `ValidationSetting.ofRecalcArtifactDiffsAsWarning(boolean)`, which
sets all four). So a repeat of an old job that had the checkbox on will now *also* downgrade
`ERR_UPD_OLDM` — and, via section 2b, accept the UPDATE instead of declining it. That is the point of
the feature, but it means a repeat is not bit-identical to the original run. The stored original row is
untouched.

## Verification

1. `mvn -o install -Pno-proxy,dev-build -DskipTests` across the reactor (stale `~/.m2` snapshots
   otherwise surface as unrelated compile errors in downstream modules), then
   `mvn -o test -Pno-proxy,dev-build -pl ifas-domain/ifas-domain-stm -Dtest='ValidationDeltaReports*Test'`.
2. `mvn -o test -Pno-proxy,dev-build -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest`
   — all baselines must be unchanged. Takes ~3 min.
3. Re-run `QuickRecalculationTest#givenSingleLieferungData_whenRecalculate_thenWriteResultsToFilesystem`
   from the IDE (it is `@Disabled`) and inspect
   `ifas-testing/ifas-integration-tests/target/quick-recalc/error#diff-deviations.txt`:
   - summary flips to `Nur im Neusystem (Fehler) : 0` / `(Warnung) : 1`
   - the entry reads `[+] NUR IM NEUSYSTEM (WARNUNG)`
   - `recalc-protocol_without_warnings.txt` no longer lists the Error-Log deviation, while
     `recalc-protocol_only_error_and_warning_details.txt` still does.
4. Optional UI smoke check via `LocalPostgresOnlyIfasApplication` → http://localhost:8080/ifas-uat
   STM-Recalc form: the single "Abweichungen durch bereits vorhandene Daten als Warnung" checkbox
   still round-trips, and its tooltip mentions the UPDATE check.

## Out of scope — follow-ups worth separate tickets

1. **`findLatestUndeletedSuccessorStmId` omits legacy's `and m.guelt_bis is null`**
   (`SteuerMeldungStatusValidationService.java:455` vs `c_st_meldung.cpp:9005`). Legacy added that
   filter on 2024-12-02 (`// abi 20224.12.02`), so a fix needs a date gate to preserve historical
   fidelity for older Stichtage.
2. **Single-level scan instead of legacy's chain walk.** Legacy loops `vorherige_stm_id` down to the
   deepest descendant and reports *that* id; the new system takes `max()` of the direct children.
   For a chain `693600 → 694626 → 695000` legacy reports `695000`, the new system `694626` — a
   `DIVERGENT_ARGS` match rather than an exact one.
3. ~~**The 6 `STATUS_*` field diffs stay `FEHLER`.**~~ **Wrong — they are fixed.** This item assumed
   "there is no leniency lever for return-file field diffs". There is: the flags also drive
   `SteuerlicheErmittlungRecalcOptions.ignore*Errors` (see section 2b), so accepting the UPDATE removes
   the `STATUS_MELDUNGS_ID` / `STATUS_MELDUNGS_ID_REF` / `STATUS_STATUS` diffs at their source rather
   than reclassifying them.

4. **The new system's own logs stay inconsistent with its return file** — decided as wontfix.
   `error#recalc.log` still prints "Steuerdaten-Meldung wird NICHT VERARBEITET" and
   `statistics#recalc.log` still `Fehler: 1` / `UPDATE: 0 von 1 verarbeitet`, while
   `_return#recalc.csv` says `OPEN`. `ERR_UPD_OLDM` is still genuinely raised and still a `declined`
   code; the flags only touch delta severity and result status. Pre-existing and shared by all four
   flags — the same split happens whenever `ignoreBereitsVorhandenErrors` fires. It surfaces as no
   deviation: legacy's `error.log` is empty for the row (so the delta downgrades it) and
   `statistics.log` is not compared at all.

## Measured outcome

`QuickRecalculationTest` on the Candriam bundle, before → after:

| | Before | After |
|---|---|---|
| Log delta severity | `FEHLER` | `WARNUNG` |
| Summary | Fehler 1 / Warnung 0 | Fehler 0 / Warnung 1 |
| `Abweichungsfehler` | 7 (6 Feldwert + 1 Log) | **1** (1 Feldwert + 0 Log) |
| Neusystem return status | `UPDATE_DECLINED`, STM-ID 693600 | `OPEN`, STM-ID **694626**, Ref 693600 — identical to legacy |
| `Altsystem-Return gegen Neusystem-Return` | 3 × `FEHLER` | ✅ keine Differenzen |
| `_return#recalc.csv` | 203 bytes (stub) | 52 637 bytes, 671 lines (legacy: 672) |

The single remaining `FEHLER` is **pre-existing and unrelated**:
`AS_Ertragsausgleich_AusschuettungenSubfonds_nichtDBAbefreit: NEU = n.v. / ALT = [A1=0.0000]` — the
null-vs-explicit-zero country-vector pattern (new system omits zero country-vector entries legacy wrote
as explicit `0.0000`). It was invisible before only because the declined meldung produced no field
values at all; accepting the UPDATE exposed it.

Test gates all green: 1225 `ifas-domain-stm` tests, `GrossfileRecalculationTest` all 8 baselines
**unchanged** (it uses `ValidationSetting.DEFAULT`, so the flag cannot reach it), `RepeatBatchOverrideTest`,
`JsonSerializationsTest`.

Build note for this machine: the reactor needs `-Pno-proxy,dev-build` — without `dev-build`,
`oekb-auth-support` fails on the unresolvable `jespa:jespa-jakarta` (OeKB Nexus only). Stale
`~/.m2` snapshots also produce misleading errors in downstream modules; `mvn -o install -DskipTests`
across the reactor first.
