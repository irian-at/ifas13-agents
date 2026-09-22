---
name: project_bundlesof-tempdir-cleaner
description: "SteuerMeldungBundles.bundlesOf registers the unzip temp-dir Cleaner on the returned List, so holding only .getFirst() lets GC delete the files mid-run."
metadata: 
  node_type: memory
  type: project
  originSessionId: 1fee64d9-966a-4d22-b87c-267f691cb0c8
  modified: 2026-09-22T09:28:59.785Z
---

`SteuerMeldungBundles.bundlesOf(Resource)` unzips into a temp dir managed by
`AutoCleanupTempFiles.withAutoCleanupTempDirectory`, which registers the `Cleaner` on **the value the
callback returns** — for `bundlesOf` that is the `List<SteuerMeldungBundle>`, not the bundles. Writing
`bundlesOf(zip).getFirst()` drops the only strong reference to the List, so a GC deletes the unzipped
files while the bundle is still in use. Symptom: `FileNotFoundException` on
`/tmp/<zip>.../<entry>....tmp`, surfacing as e.g. "I/O error loading CSV resource".

**Why:** the Cleaner is reachability-based, not scope-based; `bundleOf(Resource)` (singular) registers it
on the bundle itself, which is why `QuickRecalculationTest` never hit this.

**How to apply:** for a single-bundle zip use `SteuerMeldungBundles.bundleOf(resource)` — it also throws
loudly if the zip yields more than one bundle. When `bundlesOf` is genuinely needed, keep the returned
`List` referenced for the whole run, not just long enough to pick an element. As of 2026-09-22 the only
production caller is `StmRecalcJobExecutionService.executeRecalculation:131`, which passes the List on
into the run and is therefore safe; audit any new `bundlesOf` call site for the same property.
