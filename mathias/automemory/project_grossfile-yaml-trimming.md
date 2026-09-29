---
name: project-grossfile-yaml-trimming
description: "How to shrink a grossfile bundle's testdata yaml (UAT export with full STM history) without changing the recalc result, and how to prove it"
metadata:
  node_type: memory
  type: project
  originSessionId: cd575f92-b450-4dae-9652-11d2ffd92913
  modified: 2026-09-29T11:09:14.784Z
---

A UAT recalc-job export (`exportFondsByIsin`, minStmVersion 0) carries the complete STM history of
every fund: for gf1 (2027-07-23) 4.25M entities, 3.98M of them `STEUER_FIELDS_DATA`, 405 MB. The
recalc reads field data only for Vorherige Meldungen it actually processes; for gf1 (165 NEW, 2
declined UPDATE) it read none, and the bundle runs on a headers-only yaml (18,884 entities, 8.5 MB)
with byte-identical outputs. Verified 2026-09-29.

**How to apply (per bundle, gf2–gf8 pending):**
1. Strip with `FondsYamlStripTool` (ifas-dev-tools; `mvn -pl ifas-dev-tools exec:java
   -Dexec.mainClass=at.oekb.ifas.devtools.FondsYamlStripTool -Dexec.args="<in> <out> <newestPerFund> [ids]"`).
   Bundles whose tests need previous Meldungen keep the newest N per fund or explicit stm ids.
2. Prove it: run the bundle with the full yaml, save `target/grossfile-rerun-recalc/<ds>/`, run
   again with the stripped one and diff all output files with the run timestamps, the
   `Verarbeitungsbeginn`, END-record times, the import-count and duration lines masked. Anything
   else differing means a needed Meldung was stripped.
3. To see which STMs a run reads, pass `-Dlogging.level.org.hibernate.SQL=DEBUG
   -Dlogging.level.org.hibernate.orm.jdbc.bind=TRACE` to `mvn test`; surefire forwards them, and
   the bind lines after selects on `steuer_fields_data` / `steuer_beh_data` carry the stm ids.

**Why:** the rerun tests will be part of every suite for eight grossfiles; the full yaml took
12 min to import row by row and still 2.5 min batched, the trimmed one 8 s.
