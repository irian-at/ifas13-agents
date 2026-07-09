# Enhance `assertSummary` failure messages with grossfile identifier

## Context

In `GrossfileRecalculationTest.givenGrossfile_whenRecalculate_thenMatchValidationDeltaBaseline` (line 67), `SoftAssertions` collects up to 18 mismatches across `error` / `info` / `oekbinfo` log delta reports per grossfile. Because the parameterized test runs once per grossfile (`gf1-d20260724` … `gf8-d20261217`), a single CI run produces many failures. The current `as("%s: Exakte Treffer", label)` description only carries the log type (`error` / `info` / `oekbinfo`) and the German metric name — it does **not** identify which grossfile the failure belongs to, so reading the failure log requires correlating each block back to its parameterized invocation header.

Goal: include the grossfile dataset name in every assertion description so each failure line tells you both the grossfile and which metric diverged at a glance.

## Change

Modify only `assertSummary` and its three call sites in `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/recalc/GrossfileRecalculationTest.java`.

1. Add a `String datasetName` parameter to `assertSummary` (placed before `label`).
2. Pass `baseline.datasetName()` from the three call sites at lines 112–114.
3. Prefix every `.as(...)` description with `[<datasetName>] `.

Resulting descriptions, e.g.:
- `[gf1-d20260724] error log delta report present`
- `[gf1-d20260724] error: Exakte Treffer`
- `[gf1-d20260724] error: Abweichende Treffer`
- … (same for `info`, `oekbinfo`)

No other behavior changes; no new helpers, no new fields. `SoftAssertions` already prints expected vs. actual on a separate line, so the metric name + dataset prefix is enough for a "quick look" scan.

### Sketch

```java
assertSummary(softly, baseline.datasetName(), "error",    result.errorLogDeltaReport(),    baseline.errorLog());
assertSummary(softly, baseline.datasetName(), "info",     result.infoLogDeltaReport(),     baseline.infoLog());
assertSummary(softly, baseline.datasetName(), "oekbinfo", result.oekbInfoLogDeltaReport(), baseline.oekbInfoLog());

private static void assertSummary(
        SoftAssertions softly,
        String datasetName,
        String label,
        @Nullable ValidationDeltaReport report,
        SummaryExpectation expected
) {
    softly.assertThat(report).as("[%s] %s log delta report present", datasetName, label).isNotNull();
    if (report == null) { return; }
    Summary summary = report.getSummary();
    softly.assertThat(summary.getExactMatchCount())
            .as("[%s] %s: Exakte Treffer", datasetName, label).isEqualTo(expected.exactMatch());
    softly.assertThat(summary.getDivergentArgsMatchCount())
            .as("[%s] %s: Abweichende Treffer", datasetName, label).isEqualTo(expected.divergentArgsMatch());
    softly.assertThat(summary.getCoveredMatchCount())
            .as("[%s] %s: Abgedeckte Treffer", datasetName, label).isEqualTo(expected.coveredMatch());
    softly.assertThat(summary.getOnlyInLegacyCount())
            .as("[%s] %s: Nur im Altsystem", datasetName, label).isEqualTo(expected.onlyInLegacy());
    softly.assertThat(summary.getOnlyInNewErrorCount())
            .as("[%s] %s: Nur im Neusystem (Fehler)", datasetName, label).isEqualTo(expected.onlyInNewError());
    softly.assertThat(summary.getOnlyInNewWarningCount())
            .as("[%s] %s: Nur im Neusystem (Warnung)", datasetName, label).isEqualTo(expected.onlyInNewWarning());
}
```

## Files touched

- `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/recalc/GrossfileRecalculationTest.java` (signature + 3 call sites + 7 `.as(...)` strings inside the helper)

## Verification

- Compile: `mvn -pl ifas-testing/ifas-integration-tests -am test-compile -Pno-proxy`
- Smoke-run the test with H2 only and inspect the failure block in the log for one baseline that already deviates (e.g. temporarily tweak one expected number in `baselines()` to force a failure, then revert): `mvn -pl ifas-testing/ifas-integration-tests test -Dtest=GrossfileRecalculationTest -Pno-proxy`. Confirm each `SoftAssertions` failure line carries `[gfN-dYYYYMMDD]` and the German metric name.
