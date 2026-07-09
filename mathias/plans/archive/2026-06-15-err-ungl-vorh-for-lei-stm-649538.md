# Entry 2 — `ERR_UNGL_VORH` for LEI on stmId 649538 (`gf2-d20260731`)

## Context

The companion analysis at `~/dev/projects/ifas13-agents/mathias/plans/gf2-nur-im-altsystem-analysis.md`
identified five NUR-IM-ALTSYSTEM discrepancies in the gf2 grossfile recalculation. Entry 1 was
implemented in commits `6da611a9` + `e3e7ad11` (within-file ISIN-based duplicate detection). The
user asked to continue with entry 2.

Entry 2's *original* hypothesis was **pattern 4 (cross-ISIN blind spot)** — that
`previousSteuerMeldung == null` because the same-ISIN lookup misses an existing meldung filed
under a different ISIN. **That hypothesis is now refuted** by direct inspection of the seed YAML:

- `STEUER_MELDUNG.id = 649538` has `numWfsKu = 36486`.
- `WKN_HIST` row for `numWfsKu = 36486`, `quelle = "ISIN"` maps to `numWkn = "LU0136043550"` —
  the *same* ISIN the CSV delivers under. The same-ISIN lookup succeeds and
  `previousSteuerMeldung != null`.

The new, more plausible root cause is **pattern 5 (architectural divergence — master-data vs
snapshot)**:

- Legacy stored `LEI` directly on the STM row, so a re-delivery of the same `stmId` compared the
  new CSV LEI against the row's snapshot LEI.
- IFAS13 does **not** store `LEI` on `SteuerMeldungEntity`. Both
  `LazyDbSteuerMeldung.getLei()` (`ifas-domain-stm/.../meldung/db/LazyDbSteuerMeldung.java:309`)
  and the CSV-side `CsvSteuerMeldung.getLei()` route through master data:
  `InvRepository.getInvNameKagStVertreterLeiByIsin(...)` → `WknDesc.lei`
  (`ifas-database/ifas-persistence-inv/.../InvRepository.java:47`). The seed YAML pre-populates
  `WKN_DESC.lei = U090UTR2IZOR4U9CSZ50` for ISIN `LU0136043550`. So previous-LEI and current-LEI
  resolve to the same value, `checkFieldUnchanged` sees equality, and `ERR_UNGL_VORH` stays
  silent.

The user's instruction is to **verify this root cause empirically before committing to a fix
shape**. This plan implements that verification as a focused integration test, then branches
into one of three concrete fix directions based on what the test reveals.

The plan deliberately does **not** re-audit entries 3–5 of the original analysis — those are
treated as independent and revisited only if a similar refutation surfaces.

---

## Phase A — Verification (do first, blocks the fix decision)

Add a verification integration test that reproduces the exact lookup path used by the
grossfile run, without the noise of the full ZIP-based recalc pipeline.

### Critical files

- **`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/validation/SteuerMeldungStatusValidationServiceTest.java`** —
  already has the base+overlay test infrastructure (helpers `loadBaseData`,
  `loadBaseDataWithOverlay`, `loadCsv` at lines 73–97). The class currently has no test
  methods; add a single `@TestTemplate` here.
- **Test fixtures (new)** under
  `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/stm/validation/`:
  - `SteuerMeldungStatusValidatorTest_lei_master_data_only.yaml` — overlay containing one
    `STEUER_MELDUNG` row (mimicking stmId 649538, `numWfsKu` matching an ISIN in the base
    YAML), and one `WKN_DESC` row with `lei = "U090UTR2IZOR4U9CSZ50"`. Status `OPE`,
    `versionsNr = 6`.
  - `SteuerMeldungStatusValidatorTest_lei_master_data_only.csv` — single CONFIRMED meldung
    referencing the same `stmId` and same ISIN, with CSV column `LEI_e =
    "U090UTR2IZOR4U9CSZ50"`.

### Test shape (given-when-then, AssertJ)

```java
@TestTemplate
void givenPreviousMeldungAndMatchingWknDescLei_whenValidateConfirmed_thenNoErrUnglVorh() {
    loadBaseDataWithOverlay("lei_master_data_only");
    List<SteuerMeldung> meldungen = loadCsv("lei_master_data_only");

    // Confirm the assumed lookup is hit:
    Map<Long, DbSteuerMeldung> existing =
            getExistingMeldungenByIsin(meldungen.get(0).getIsin(), STICHTAG_14042024);
    DbSteuerMeldung previous = existing.get(meldungen.get(0).getStmId());
    assertThat(previous).isNotNull();
    assertThat(previous.getLei()).isEqualTo("U090UTR2IZOR4U9CSZ50");
    assertThat(meldungen.get(0).getLei()).isEqualTo("U090UTR2IZOR4U9CSZ50");

    // The discrepancy: no ERR_UNGL_VORH fires even though legacy would.
    List<ValidationMsg> msgs = statusValidationService.validate(meldungen.get(0), ...);
    assertThat(msgs).noneMatch(m -> m.getCode() == ValidationMsgCode.ERR_UNGL_VORH);
}
```

The point of this test is not to *fix* anything — it documents the **current** behavior and
locks down what we'd be changing. After the fix it will either be deleted, inverted, or
moved to the covered-by side.

### What we learn

After the test passes, the three numbers above (previous != null, previous.lei equals current
LEI, no ERR_UNGL_VORH) confirm the master-data-vs-snapshot mechanism. If any of those
assertions fails, the test fails loudly and we revisit before choosing a fix.

---

## Phase B — Fix decision (after Phase A confirms)

Pick one of three branches. The recommended order, weighing scope against fidelity to legacy:

### B1 — Covered-by rule (preferred default)

Treat legacy's `ERR_UNGL_VORH`-on-LEI as a known architectural divergence: IFAS13's
master-managed LEI is arguably more correct than a stale snapshot, so legacy's error in this
scenario is a false positive we explicitly classify.

- Add a rule class to
  `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/delta/` —
  the existing pattern from entry 1 is two files
  (`StatusNmCoveredByStatusNmLieferung.java` + a covered-by-rule sibling for
  `UpdOldm`). The naming convention is `{LegacyCode}CoveredBy{NewCondition}`.
- The rule shape needed here is **legacy-only with no IFAS13 counterpart**, parameterized on
  the affected field. Re-read the existing `CoveredByRules.java` (entry 1 commit) — if the
  framework already supports "legacy-only-but-expected" rules use that; otherwise extend it.
  Cite legacy reference `c_st_meldung.cpp:8307`.
- Add the rule to the registry in `CoveredByRules.DEFAULT_RULES`.
- Unit test under
  `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/validation/delta/`
  following the same template as `StatusNmCoveredByStatusNmLieferungTest`.
- Reuse, do not re-implement: the rule class hierarchy and registry are already established
  by entry 1.

### B2 — Test-fixture fix (smallest behavior change)

If the LEI master-data record in the seed YAML is logically wrong — i.e., `WKN_DESC.lei`
should be empty *at the time the test runs validation* — strip the LEI from the seed and
the existing IFAS13 validator will fire correctly.

- Edit the `gf-d20260724-export-AFTER.yaml.txt` inside `gf2-d20260731.zip`: remove the
  `lei` field from the `WKN_DESC` for ISIN `LU0136043550` (and any other ISIN where the
  CSV delivers a new LEI value).
- **Risk**: this artifact is auto-generated from a real production export. Editing it
  diverges the fixture from its source. Before applying, confirm with the user that
  hand-editing the YAML is acceptable.
- No source code changes.

### B3 — Snapshot LEI on STM (matches legacy literally)

Largest scope. Touches schema, persistence, and reading. Only choose if a future
requirement demands literal legacy fidelity (e.g., audit needs to see the LEI as it was at
delivery time, not the current master value).

- New Flyway migration adding `LEI VARCHAR(20)` to the STM table.
- Add `lei` field to `SteuerMeldungEntity`.
- Add `lei` to `STM` import mapping so it's persisted from incoming CSV.
- Change `LazyDbSteuerMeldung.getLei()` to read from the entity field, falling back to
  `WknDesc.lei` only when the entity field is null (legacy compatibility for pre-existing
  rows).
- Cross-cutting: any other consumer of `SteuerMeldung.getLei()` may need awareness of the
  new behavior.
- Backfill strategy: for historical rows the entity field stays null and the fallback path
  preserves current behavior.

Defer B3 unless B1 is rejected by the user.

---

## Phase C — Reconcile the grossfile baseline

`GrossfileRecalculationTest.java:152` declares the gf2 baseline:

```java
new GrossfileBaseline("gf2-d20260731", false,
        new SummaryExpectation(93, 0, 2, 3, 6, 4),  // error log baseline
        ...
```

Whatever fix lands (B1/B2/B3), the legacy-only count of `3` should drop and either
exact-matches go up (B2/B3) or the delta classification changes (B1 — same count, different
classification). Update the baseline tuple as part of the fix commit.

---

## Verification

After the fix lands:

1. Run the new Phase-A unit test (verifies the architectural assumption either still holds
   under B1, or is broken under B2/B3).
2. Run the broader status-validation unit suite:
   `mvn -pl ifas-domain/ifas-domain-stm test -Pno-proxy
   -Dtest=SteuerMeldungStatusValidationServiceTest,SteuerMeldungStatusValidatorsTest`
3. Re-enable and run `GrossfileRecalculationTest#givenGrossfileZip_whenRecalculate_thenWriteResultsToFilesystem`
   with `WRITE_OUTPUT_FILES = true` (toggle at line 55) and confirm
   `target/test-output/grossfile-recalc/gf2-d20260731/error#diff-deviations.txt` no longer
   lists `[-] NUR IM ALTSYSTEM` for Z122 stmId 649538.
4. Diff the new `error#diff-deviations.txt` against the prior commit's output to confirm
   no new `[+] NUR IM NEUSYSTEM` regressions for other rows.
5. Update the gf2 baseline summary tuple at `GrossfileRecalculationTest.java:152` to match
   the new totals.

## Notes

- Entry 1's commits established two reusable mechanisms: the `seenIsins` within-file
  tracker (`SteuerMeldungLieferungService.java:81`) and the `CoveredByRules` framework
  (`ifas-domain-stm/.../validation/delta/`). Entry 2 should *reuse* the latter if B1 is
  taken — do not introduce a parallel delta-reconciliation mechanism.
- Per `ifas13-agents/mathias/rules/reuse-before-reimplementing.md`: before implementing
  the B1 rule, scan `validation/delta/` for any existing rule shape covering
  "legacy-only-expected" cases. If one exists, extend it; only introduce a new class if
  the existing shapes don't fit.
