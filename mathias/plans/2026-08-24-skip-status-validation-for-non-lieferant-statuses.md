# Skip status validation for non-Lieferant statuses (fixes the ERR_ISIN_MID deviation)

## Context

The server recalc of `20260804_060124_202410_FR0013209921_JM_1448743_return_1885191` reported exactly
one deviation against the Altsystem:

```
ERROR! Melde-ID <57002> und/oder ISIN <FR0013209921> stimmen mit der Ursprungsmeldung <LU1439782738> nicht ueberein.
```

Re-running the same bundle locally yields 921 validations instead of 922 — the two new-system error
logs differ by exactly this one line and nothing else. Investigating that gap surfaced two separate
findings.

### Why it does not reproduce locally

The bundle's testdata export is **scoped to the delivered ISIN**, not to every row the run read.
`RecalculationOutputs.writeTestDataYamlFile` (`RecalculationOutputs.java:598-603`) builds the ISIN list
from the input Meldungen's own ISINs; the yaml header records it:

```
name: "Fonds Export from 24.08.2026 10:53:13 (key date 2026-08-04), ISINs = [FR0013209921]"
```

`FondsExporter.getAllSteuerMeldungen` (`FondsExporter.java:360-378`) then collects only STMs reachable
from *that* fund's `num_wfs_ku` (177166) — via `findByNumWfsKu`, `Geschaeftsjahr.stmId`, and predecessor
chains. The export therefore holds STM ids `297508, 363611, 438921, 511283, 581485, 667576` and
`WKN_HIST.numWkn` values `FR0013209921, LYX0V3`. `grep -ac '57002'` → 0; `grep -ac 'LU1439782738'` → 0.

`ERR_ISIN_MID` exists to answer *"does this Melde-ID belong to a different ISIN?"*, so its lookup
(`SteuerMeldungRepository#getIsinByStmId`, `SteuerMeldungRepository.java:137`) is deliberately **not**
ISIN-filtered. On the server it resolves `stm_id 57002` to the foreign fund's ISIN `LU1439782738`;
locally no such row exists, the query returns empty, and `errIsinMid` short-circuits on
`isinForForeignStm == null`.

So the one check that reads *outside* the delivered fund is the one thing an ISIN-scoped export cannot
capture. This is a blind spot of the export, not a stale or corrupt snapshot — and it is **not** being
fixed here: pulling foreign funds in would inflate every recalc bundle, and as below the error should
not have been raised at all.

### The actual bug

The delivered status is `OPEN` (`STATUS;OPEN;57002`, line 2 of the input CSV — the input is a re-fed
*return* file, which is also why 900+ `Unerlaubte Satzart <STB>` errors fire). Legacy cannot emit
`ERR_ISIN_MID` for that, because the check is only ever reached for a **Lieferant input status**:

* The check lives in `cSt_Meldung::CheckVorhandeneMeldung()`, called from exactly four places:
  `ProcessMeldung_NEW` (`c_st_meldung.cpp:2803`), `_CONFIRMED` (`:2988`), `_UPDATE` (`:3137`),
  `_DELETE` (`:3306`). `ProcessMeldung` dispatches on `strStm_status_angeliefert` (`:2704-2724`) — for
  `OPEN` no branch matches, so the check never runs.
* Within `CheckVorhandeneMeldung` the emit is **not** further status-restricted. The block at
  `:7826-7919` is gated on `if (nStm_id == 0)` — the *no-Melde-ID* case — and always returns from
  there (`NEW` gets the by-ISIN duplicate check, non-`NEW` gets `ERR_MELDEID_FEHLT`). Once a
  Melde-ID *is* delivered, execution falls through to the by-`stm_id` lookup at `:8029-8032` and the
  `strIsin != szAIsin` emit at `:8149` for **all four** statuses, `NEW` included.

So the legacy gate is exactly `StmStatus.isInputLieferantStatus()` (`StmStatus.java:38-40`:
`NEW || UPDATE || DELETE || CONFIRMED`) — the same predicate `errStatusUngue` already keys off via
`isAllowedStatusCodeForLieferant` (`SteuerMeldungStatusValidationService.java:495-500`).

The new `errIsinMid` (`SteuerMeldungStatusValidators.java:146-164`) has **no status gate at all**. That
omission is the bug.

**The gate is empirically safe.** All five true-positive `ERR_ISIN_MID` cases in the existing grossfile
fixtures are input statuses, and all are `EXAKTER TREFFER` against legacy:

| Grossfile | START line | Melde-ID | delivered status |
|---|---|---|---|
| gf2-d20260731 | 74 | 649551 | `UPDATE` |
| gf2-d20260731 | 107 | 649524 | `CONFIRMED` |
| gf2-d20260731 | 128 | 649524 | `DELETE` |
| gf2-d20260731 | 154 | 649524 | `UPDATE` |
| gf3-d20260805 | 104 | 649528 | `UPDATE` |

The gate removes the `OPEN` false positive and keeps every true positive.

## Change

### 1. Gate the whole status-validation block, not just `errIsinMid`

`errIsinMid` is not the only validator in
`SteuerMeldungStatusValidationService.validate` that legacy cannot reach for a Meldestelle status — it
is just the one this fixture happened to expose. Auditing every code the method emits against its legacy
emit site:

| Validator(s) in `validate` | Legacy emit site | Enclosing legacy function | Reachable for a non-input status? |
|---|---|---|---|
| `errStatusUngue` | `ERR_STATUS_UNGUE` `c_st_meldung.cpp:1844` | **`ProcessZeile`** (per CSV line) | **YES** |
| `errMeldeIdFehlt` | `ERR_MELDEID_FEHLT` `:7925` | `CheckVorhandeneMeldung` | no |
| `errMeldeIdUng` | `ERR_MELDID_UNG` `:9329` | `CheckVorhandeneMeldung` | no |
| `errMeldidFehlt` | `ERR_MELDID_FEHLT` `:9336` | `CheckVorhandeneMeldung` | no |
| `errMeldidNichtMehrGueltig` | models the `guelt_bis is null` lookup `:8032` | `CheckVorhandeneMeldung` | no |
| `errIsinMid` | `ERR_ISIN_MID` `:8149` | `CheckVorhandeneMeldung` | no |
| `errJahresmVorh`, `errAusschmVorh` (+ `_LIEFERUNG`) | NEW branch of `CheckVorhandeneMeldung` | `CheckVorhandeneMeldung` | no |
| `errUnglVorh`, `errUnglVorhF*` | found-row region of `CheckVorhandeneMeldung` | `CheckVorhandeneMeldung` | no |
| `errUpdSelbst`, `errStatusNm`, `errUpdOldm`, `errVergangenUpd`, `errAusschtAktConf` | `CheckVorhandeneMeldung` | `CheckVorhandeneMeldung` | no |
| `errSnInmeldefrist`, `errFristSn`, `errFristNosn`, `errUpdTolate`, `errConUpdTolate` | `CheckLieferfristen` — called at `:3011` (CONFIRMED), `:4175` (via `CheckMeldung()`, itself called only from `ProcessMeldung_NEW` `:2797` and `_UPDATE` `:3129`), `:9260` (UPDATE) | `ProcessMeldung_*` / `CheckVorhandeneMeldung` | no |

So **exactly one** validator in the method belongs outside the gate. `ERR_STATUS_UNGUE` is emitted from
`ProcessZeile` while the STATUS record is parsed — which is why legacy does report
`Der Status <OPEN> ... ist nicht zulaessig` for this fixture. Everything else descends from
`CheckVorhandeneMeldung` / `CheckLieferfristen`, both reachable only through `ProcessMeldung`'s dispatch
on the four Lieferant statuses (`c_st_meldung.cpp:2704-2724`).

**Change** —
`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidationService.java`,
in `validate` (`:82-336`): hoist `errStatusUngue` to the top and return early for anything that is not a
Lieferant input status, *before* the DB lookups at `:89-116`:

```java
List<ValidationMsg> validationMsgs = new ArrayList<>();
StmStatus status = steuerMeldung.getStatus();

SteuerMeldungStatusValidators.errStatusUngue(
        validationMsgs,
        steuerMeldung,
        isAllowedStatusCodeForLieferant(status)
);
// Legacy dispatches Meldung processing only for the four Lieferant input statuses
// (ProcessMeldung, c_st_meldung.cpp:2704-2724). Every check below descends from
// CheckVorhandeneMeldung or CheckLieferfristen and is therefore unreachable for a
// Meldestelle status.
if (status == null || !status.isInputLieferantStatus()) {
    return validationMsgs;
}
```

Then drop the existing `errStatusUngue` call at `:146-150` and leave the rest of the method untouched.

**Why this is behaviour-preserving for every accepted Meldung.** `errStatusUngue` fires exactly when
`status != null && !isAllowedStatusCodeForLieferant(status)`, and
`isAllowedStatusCodeForLieferant` *is* `isInputLieferantStatus()`
(`SteuerMeldungStatusValidationService.java:495-500`). The two conditions are exact complements: for the
four input statuses `errStatusUngue` never adds anything, so hoisting it is a no-op and the returned
list is identical to today's. Only non-input and `null` statuses take the new early return.

Side benefit: it also removes the same latent false positive from the other validators — e.g.
`errMeldeIdFehlt` currently fires for an `OPEN`/`ERROR` Meldung delivered *without* a Melde-ID, which
legacy cannot report either. This fixture only missed it because its Melde-ID was present.

No change to `SteuerMeldungStatusValidators` is needed, and **no** per-validator status gate should be
added there — the dispatch gate is the single correct place, matching legacy's own structure.

### 1b. The other two validation services need no gate

`SteuerMeldungLieferungService:97-99` runs three services per Meldung. Only the status one is gated:
`ermittlungsvorgabeValidationService` and `domainValidationService` are correct as they stand, and the
fixture proves it — for this `OPEN` Meldung all 921 of their messages match legacy exactly
(`Ungueltige Anzahl von Parametern` ×390, `kein Eingabefeld` ×233, `Pflichtfeld nicht befuellt` ×152,
`Unerlaubte Satzart` ×145, plus the one `ERR_STATUS_UNGUE`). Gating them would *break* that match.

### 2. Tests

The gate lives in the service, so the meaningful test is at service level — and the template already
exists: `SteuerMeldungStatusValidatorsTest.java:1551-1590` has a `@Nested ServiceStmIdGuardTests` that
builds the real `SteuerMeldungStatusValidationService` from four Mockito mocks (`EntityManager`,
`SteuerMeldungRepository`, `GeschaeftsjahreDomainService`, `InvRepository`) and asserts
`verify(stmRepository, never()).getIsinByStmId(any(), any())`. No H2 needed.

Add a sibling `@Nested ServiceInputStatusGateTests` following that exact pattern. Stub
`findAllStmIdsByIsin` → `List.of()` (so the delivered Melde-ID is not the ISIN's own) and
`getIsinByStmId` → a foreign ISIN, then per status:

* `OPEN`, `ERROR`, `FINAL` → only `ERR_STATUS_UNGUE`, **no** `ERR_ISIN_MID`; `null` status → no messages
  at all. In both cases also assert the early return happened before the DB work:
  `verify(stmRepository, never()).existsById(any())` and `never()).getIsinByStmId(any(), any())`.
* `NEW`, `UPDATE`, `CONFIRMED`, `DELETE` → `ERR_ISIN_MID` still raised (all four, `NEW` included — see
  the legacy fall-through analysis in Context).

Note: `ifas-testing/ifas-integration-tests/.../SteuerMeldungStatusValidationServiceTest.java` looks like
the natural home but is a **dead scaffold** — 109 lines of helpers, zero test methods, an empty
`setUp()`, and its `BASE_YAML` points at `SteuerMeldungStatusValidatorTest_base.yaml`, which does not
exist (only `SteuerMeldungDomainValidatorTest_*` resources are present). Don't sink time there.

**Validator level** — `SteuerMeldungStatusValidatorsTest` (`ErrIsinMidTests`, `:373-433`) keeps testing
`errIsinMid` as a pure ISIN comparison, since the status decision now sits outside it. One fix worth
making while there: the assertion at `:416` compares against
`ValidationMsgCode.ERR_ISIN_MID.formatMessage(<the same args>)` — tautological, and it would pass even
with a dropped argument (`MessageFormat` renders a missing one as a literal `{n}`). Assert a **literal**
string instead.

### 3. Regression guard — already in place

`GrossfileRecalculationTest` asserts the `ValidationDeltaReport` summary counts per grossfile against a
baseline, and gf2/gf3 already exercise `ERR_ISIN_MID` as exact matches. **The baselines must not move.**
If any count shifts, the gate is wrong.

Two caveats on what the baselines can and cannot prove — both worth knowing before reading a green run
as vindication:

* Every delivered status in both grossfiles is already an input status (gf2: 33 CONFIRMED, 12 DELETE,
  9 UPDATE, 6 NEW; gf3: 6 CONFIRMED, 3 DELETE, 12 UPDATE, 9 NEW). The new early return therefore never
  triggers there — the baselines confirm the change is *neutral*, not that the gate is *right*.
* Neither grossfile contains a `STATUS;NEW;<id>` row (`grep -ac '^STATUS;NEW;[0-9]'` → 0 in both), so
  they cannot distinguish `isInputLieferantStatus()` from the narrower `UPDATE || CONFIRMED || DELETE`
  triple either. That choice rests on the legacy control flow, not on the fixtures.

No new integration fixture is needed; the quick-recalc bundle needs no extra testdata.

## Out of scope (decided)

* **`guelt_bis` divergence.** Legacy's lookup also requires `and guelt_bis is null`
  (`c_st_meldung.cpp:8032`), which `getIsinByStmId` lacks, so a superseded foreign STM still triggers
  the error where legacy would fall into its `else` branch and emit `ERR_MELDID_FEHLT`. Not fixed here:
  it is not a one-line addition (`inputStmExistForAnotherIsin`,
  `SteuerMeldungStatusValidationService.java:99-101`, derives from an unfiltered `existsById` and
  currently suppresses both `errMeldidFehlt` and `errMeldidNichtMehrGueltig`, so filtering the ISIN
  lookup alone would make the ended-foreign-row case emit *nothing*), and no fixture exercises it.
* **`errMeldidFehlt`'s own status gate — a divergence in the *opposite* direction.** Legacy's `else`
  branch (delivered Melde-ID, no active row) emits `ERR_MELDID_FEHLT` regardless of status
  (`c_st_meldung.cpp:9301-9338` — the status there only selects which `*_DECLINED` to set), whereas
  `errMeldidFehlt` (`SteuerMeldungStatusValidators.java:90-93`) gates on `UPDATE || CONFIRMED ||
  DELETE`. So a `NEW` carrying an unknown Melde-ID is likely **under**-reported today. The new service
  gate does *not* address this (`NEW` passes the gate); it would need widening the triple to
  `isInputLieferantStatus()` there too. Left alone: unasked, no fixture covers it, and it changes
  behaviour for a status the grossfiles do exercise.
* **Widening the testdata export** to cover foreign funds — see Context.
* **Hardening `QuickRecalculationTest` resource discovery** — see below; the folder just gets cleaned.

## Prerequisite before any local quick-recalc run

`src/test/resources/at/oekb/ifas/domain/recalc/issues/quick-recalc/` currently holds **both** the zip
and its extracted directory. `Resources.findResourcesInClasspathFolder`
(`support-libs/core-support/.../Resources.java:118-132`) filters on `Resource::exists`, not
`isReadable()`, so the directory comes back as a `NamedResource`. That makes `resources.size() == 2`,
`QuickRecalculationTest:100` takes `bundleOf(Collection)` (which does not unzip), and
`determineBundleFilename` (`SteuerMeldungBundles.java:126`) throws:

```
IllegalArgumentException: SteuerMeldungBundle must have at least one Melde-CSV, a prefilled Excel file or a Return-CSV file
```

**Delete the extracted `…#recalc/` directory** (`target/test-classes` does not have it yet, but the next
Maven build would copy it). The 11:57 run predates the extraction, used `bundleOf(NamedResource)` and the
correct Stichtag 04.08.2026 — which is what made the log comparison apples-to-apples.

## Verification

```bash
# the new gate matrix + the existing service guard test
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm -Dtest=SteuerMeldungStatusValidatorsTest

# regression guard - baselines must be unchanged
mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest

# full STM domain suite - catches anything that relied on the ungated behaviour
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm
```

Then confirm the five grossfile `ERR_ISIN_MID` messages are still present as `EXAKTER TREFFER` in
`target/grossfile-recalc/gf2-d20260731/error#diff.txt` and `.../gf3-d20260805/error#diff.txt`.

Also worth a look while the STM suite runs: any test that feeds a non-input status (`OPEN`, `ERROR`,
`FINAL`, `DELETED`, a `*_DECLINED`) into `SteuerMeldungStatusValidationService.validate` and expects
more than `ERR_STATUS_UNGUE` back will now fail. That is the change working as intended, but each such
expectation should be re-derived from legacy rather than merely re-baselined.

No local run can demonstrate the fix on the quick-recalc bundle itself — the error never fires there
(see Context). Final confirmation is a re-run of that recalc on the server, where the deviation count
must drop from 1 to 0 and the return file must stay `STATUS;ERROR;57002` (it already matches legacy, so
the fix is expected to change the log only, not the outcome).

---

## Implementation notes (as shipped)

**Final shape of the gate** — `isAllowedStatusCodeForLieferant(status)` already *is*
`status != null && status.isInputLieferantStatus()`, so the guard reuses it instead of restating the
predicate, and the `errStatusUngue` emit moved *inside* the guard (it fires under exactly that
condition, so the literal `false` is what the branch means):

```java
StmStatus status = steuerMeldung.getStatus();
if (!isAllowedStatusCodeForLieferant(status)) {
    SteuerMeldungStatusValidators.errStatusUngue(validationMsgs, steuerMeldung, false);
    return validationMsgs;
}
```

**Tests** — added `@Nested ServiceInputStatusGateTests` to `SteuerMeldungStatusValidatorsTest`
(10 cases): Meldestelle statuses yield only `ERR_STATUS_UNGUE` with no DB lookup, a `null` status
yields nothing, and all four input statuses still raise `ERR_ISIN_MID`. The tautological
`formatMessage(<same args>)` assertion in `ErrIsinMidTests` now compares a literal string.

**Verified**
* `SteuerMeldungStatusValidatorsTest`: 188 tests green (10 new).
* `GrossfileRecalculationTest`: 8/8 green, baselines unmoved, and all five true-positive
  `ERR_ISIN_MID` messages still `EXAKTER TREFFER` in gf2/gf3 `error#diff.txt`.

**Paths checked for non-input statuses reaching the gate**
* Return files (`*_return.csv`, `*_EStB_erweitert.csv`) carry `STATUS;ERROR|OPEN|FINAL` but are read
  via `CsvSteuerMeldungen.loadReturnFromCsv` (`RecalculationDomainService:415-434`), never through
  `processLieferung` - so they never reach status validation.
* All four `processLieferung` call sites in recalc (`:481`, `:497`, `:513`, `:544`) take
  STM_MELDUNG / CONFIRM / DELETE csv or a prefilled Excel - never the return csv.
* The prefilled-Excel path is the one case with a **null** status (`ExcelSteuerMeldungen` never reads
  a STATUS field), so it now short-circuits. Legacy-faithful (`ProcessMeldung` dispatches on the
  delivered status and an absent status matches no branch), but it is a genuine behaviour change for a
  new-system-only path - covered by the full integration suite run.

**Environment note**: `-Pno-proxy` (per `CLAUDE.local.md`) does not exist - there is no
`~/.m2/settings.xml` and no such profile in the root POM, so Maven warns
`The requested profile "no-proxy" could not be activated`. Worth removing from `CLAUDE.local.md`.

**Not done**: deleting the extracted `…#recalc/` directory under `quick-recalc/` (the `rm` was
declined). Until it is removed, `QuickRecalculationTest` throws
`SteuerMeldungBundle must have at least one Melde-CSV …` - see the prerequisite section above. All
18 files in it are present in the sibling zip, so it is safe to delete.
