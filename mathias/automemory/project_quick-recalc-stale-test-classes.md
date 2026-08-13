---
name: quick-recalc-stale-test-classes
description: "QuickRecalculationTest scans target/test-classes, so a swapped-out zip left behind there breaks the run with a misleading \"must have at least one Melde-CSV\" error."
metadata: 
  node_type: memory
  type: project
  originSessionId: 772a56bf-25c8-422a-9a10-90b8d9a21b60
  modified: 2026-08-12T09:03:05.107Z
---

`QuickRecalculationTest` resolves its input via `Resources.findResourcesInClasspathFolder`
(`support-libs/core-support/.../io/Resources.java`), which uses `classpath:` — i.e.
`ifas-testing/ifas-integration-tests/target/test-classes/at/oekb/ifas/domain/recalc/issues/quick-recalc/`,
**not** `src/test/resources`. Maven/IntelliJ resource copying is additive, so a zip deleted from
`src` stays in `target/test-classes` forever.

Symptom: `IllegalArgumentException: SteuerMeldungBundle must have at least one Melde-CSV, a
prefilled Excel file or a Return-CSV file` (`SteuerMeldungBundles.determineBundleFilename`),
even though the zip clearly contains the Melde-CSV.

**Why:** with 2+ resources on the classpath, the test's `resources.size() == 1` check fails and it
calls `SteuerMeldungBundles.bundleOf(Collection)` instead of `bundleOf(Resource)`. The Collection
overload never unzips — it classifies each resource by its top-level filename, and a `.zip` matches
none of unspecified-CSV/TXT, prefilled-Excel or `_return.csv`. The error names CSV contents but the
real cause is a duplicate resource.

**How to apply:** when this error appears, `ls target/test-classes/.../quick-recalc/` **before**
inspecting the zip. Any extra zip there is the bug; delete it (or `mvn clean test-compile -pl
ifas-testing/ifas-integration-tests -Pno-proxy`). Same trap applies to the multi-file mode of the
test. See [[recalc-fixture-data-recovery]] for the fixture side of quick-recalc work.
